# Restart fix F5obs — worker report
Scope: read when the task touches restart-spec Step 7-F5obs (quit-failure dialog and shutdown phase logging) implementation or review evidence.
Authority: Reference
Last-verified: 2026-10-26

Covers: the F5 "Next" observability item and the F5 bullet of "Cross-cutting observability" in `docs/context/plans/2026-10-18-lossless-app-restart-spec.md`. The spec itself was not edited.

## Outcome

Every quit or window close now leaves a persisted unified-log trace, keyed by the shutdown request ID. After the fact you can see:
- whether the Quit click was accepted;
- whether a repeated request was coalesced;
- which Stage A step it was on, including a Stage A parked in a session's composer-preparation join;
- whether the deadline fired;
- which dialog was shown and why;
- what the user chose;
- how the request ended and what reply AppKit got.

Behavior is unchanged:
- the single 8-second deadline;
- waiting indefinitely for the user's choice;
- quit blocking;
- the fence semantics;
- the dialog texts.

Example trace (real output of the new composer-preparation test, read back with `log show`). The `waiting` line format was later trimmed: `still_pending` now appears only on `finished`.
```
shutdown_requested request=15707F5F-… scope=window:4632 reason=windowClose participants=1
shutdown_stage_a_started request=15707F5F-… attempt=B6101C56-… attempt_number=1 participants=1 deadline_ms=8000
shutdown_stage_a_step request=15707F5F-… attempt=B6101C56-… step=participant index=1/1
shutdown_stage_a_composer_preparation request=15707F5F-… tab=62EE93D9-… event=waiting
shutdown_deadline_fired request=15707F5F-… attempt=B6101C56-… phase=preparing
shutdown_stage_a_finished request=15707F5F-… attempt=B6101C56-… outcome=blocked blockers=1 timed_out=true
shutdown_dialog_presented request=15707F5F-… attempt=B6101C56-… presentation=9AF58F33-… scope=window:4632 stage=preparation.deadline_expired timed_out=true blockers=1
shutdown_stage_a_composer_preparation request=15707F5F-… tab=62EE93D9-… event=finished still_pending=true
shutdown_stale_completion_ignored request=15707F5F-… attempt=B6101C56-… stage=preparation phase=preparation_failed
shutdown_dialog_choice request=15707F5F-… presentation=9AF58F33-… stage=preparation.deadline_expired choice=cancel stale=false
shutdown_ended request=15707F5F-… outcome=cancelled reply=false
```
Read it with the command below. The app's executable is `RepoPrompt` in both the release and Dev bundles. The process filter excludes identical lines written by test runs.
```
log show --last 1h --style compact --predicate 'subsystem == "com.repoprompt.app" AND category == "LifecycleShutdown" AND process == "RepoPrompt"'
```
For live F5 acceptance, run that query after a quit that hangs. It shows which of the spec's remaining explanations happened.

## Files changed

- `Sources/RepoPrompt/App/AgentLifecycleShutdownDiagnostics.swift` (new). One `os.Logger`: subsystem `com.repoprompt.app`, category `LifecycleShutdown`. Contains one static function per event plus fixed-token helpers: `scopeToken`, `phaseToken`, `choiceToken`, `dialogStage`. No existing logger covered the shutdown coordinator, so this adds one category.
- `Sources/RepoPrompt/App/AgentLifecycleShutdownCoordinator.swift`. Log calls at each phase transition, plus a private `milliseconds(_:)` helper. No control-flow change. The one structural edit is in the participant loop: `for participant in …` became `for (index, participant) in participants.enumerated()` (same list, same order).
- `Sources/RepoPrompt/App/AppDelegate.swift`. Logs:
  - the terminate decision;
  - the quit-confirmation answer, including a stale answer that is ignored;
  - `beginTermination` started, joined, or already terminating;
  - the terminate reply.
- `Sources/RepoPrompt/Features/AgentMode/ViewModels/AgentModeViewModel+Shutdown.swift`. Brackets the unbounded composer-preparation join (spec lines ~304-309). Logs the session skipped for having no live lane (~310), including whether it had an active run.
- `Tests/RepoPromptTests/App/AgentLifecycleShutdownCoordinatorTests.swift`: three tests added.
- `Tests/RepoPromptTests/AgentMode/Recovery/AgentRecoveryResetBoundaryTests.swift`: one test added, plus two private test fakes: `ShutdownDeadlineSleeper` and `ShutdownPromptRecorder`.

`WindowStatesManager+LifecycleShutdown.swift` is unchanged. The dialog-presented and choice lines are emitted in the coordinator, right around `environment.presentFailure`. That is the only caller of the AppKit adapter, and it knows the request ID, attempt, presentation identity, and whether an answer is stale. The adapter knows none of these.

## Log lines

All lines are logged at `.notice`, which `log show` reports as `Default` and is persisted. Every interpolated field is `.public`, and every field is a UUID, a count, a boolean, a fixed token, or a window number. Never logged: blocker text (it carries session titles), draft content, paths, error detail, or tokens.

Shutdown coordinator, category `LifecycleShutdown`:

| Event | Fields | Emitted when |
|---|---|---|
| `shutdown_requested` | request, scope (`application` / `window:N`), reason, participants | An app quit or window-close request starts. |
| `shutdown_request_coalesced` | request (the current one, or `none`), scope, reason, cause | A repeated or refused request. Causes for an app quit: `in_progress:<phase>`, `admission_sealed`, `refused_reason_unavailable`. Causes for a window close: `admission_sealed`, `application_quit_in_progress`, `close_in_progress`. |
| `shutdown_stage_a_started` | request, attempt, attempt_number, participants, deadline_ms | Each Stage A attempt: the initial request or a Retry. `deadline_ms` is the effective work budget (`expiry - start`): 8000, or 8000 minus the cleanup reserve for Restart safely. |
| `shutdown_stage_a_step` | request, attempt, step (`layout`, `launch_mark`, `released_input`, `participant index=i/N`, `relaunch_prepare`) | Before each Stage A step. |
| `shutdown_stage_a_finished` / `shutdown_stage_b_finished` | request, attempt, outcome (`ready` / `blocked`), blockers (count), timed_out | A current attempt finishes. |
| `shutdown_stale_completion_ignored` | request, attempt, stage, phase | A late completion is fenced: a Stage A finish arriving after a timeout, retry, or cancel; or a Stage B finish or `runFinalization` returning nil. |
| `shutdown_deadline_fired` | request, attempt, phase | The single deadline's task fires for a live request. |
| `shutdown_vetoed` | request | The forwarded window delegate vetoed the close at the point of no return. |
| `shutdown_stage_b_started` | request, participants | The point of no return. |
| `shutdown_teardown_finished` | request | The single owned teardown (participants plus scope) finished. |
| `shutdown_finalization_started` | request, attempt, attempt_number, fresh_deadline, plus deadline_ms when fresh_deadline=true | Each Stage B finalization attempt. |
| `shutdown_dialog_presented` | request, attempt, presentation, scope, stage, timed_out, blockers (count) | Immediately before each `presentFailure`, including a re-show. It means the dialog was requested from the presenter, not confirmed visible: a sheet that never appears or is hidden logs the same line. |
| `shutdown_dialog_choice` | request, presentation, stage, choice (`retry` / `cancel` / `proceed_anyway` / `exit_may_reopen`), stale | Each answer, including a dismissal's sentinel. `stale=true` means the answer was ignored. |
| `shutdown_ended` | request, outcome (`completed` / `cancelled` / `superseded`), reply | The request finished. |

Values of the dialog `stage` field (`dialogStage`) are `<preparation|finalization>.<cause>`, where cause is one of:
- `deadline_expired`
- `failure`
- `clean_exit_unacknowledged`
- `relaunch_unresolved`
- `relaunch_unresolved_exit_offered`

App termination entry (`AppDelegate`), same category:

| Event | Fields |
|---|---|
| `app_terminate_requested` | decision (`show_confirmation` / `begin_termination` / `await_current_request`), phase (`idle` / `awaiting_confirmation` / `terminating`), reason, request |
| `app_quit_confirmation_answered` | answer (`quit` / `cancel` / `stale`) |
| `app_termination_began` | started, request, cause (`started` / `refused` / `joined_in_progress` / `already_terminating`) |
| `app_terminate_reply` | should_terminate, request |

Stage A inside a window (`AgentModeViewModel+Shutdown.swift`), same category:

| Event | Fields |
|---|---|
| `shutdown_stage_a_composer_preparation` | request, tab, event (`waiting`, or `finished still_pending=<bool>`) |
| `shutdown_stage_a_session_skipped` | request, tab, cause=`no_live_lane`, has_active_run |

## Tests: already present vs added

Already present (checked first; not duplicated):
- 3a, suspended preparation: `testStageADeadlineDoesNotJoinANonCooperativeTaskAndItsLateCompletionIsFenced` (fake participant hang). `testDelayedDeadlineTaskNeverExtendsTheCapturedExpiry` covers the exact 8-second instant.
- 3a, stalled teardown: `testStageBDeadlineWithAStuckTeardownQuitsAnywayWithoutACleanMark` (uses `clock.fire()`). `testOneAbsoluteDeadlineSpansStageAAndStageBAndOnlyRetryRearmsIt` covers the remaining-deadline timing.
- 3b: only partially covered.
  - `testAppQuitSupersedesAWindowCloseInStageAAndRefusesNewCloses` asserts that a duplicate quit returns `false`, but not that the deadline is unchanged.
  - `AppQuitPolicyTests.testRepeatedRequestsDoNotCreateAnotherPrompt` covers `.awaitCurrentRequest`.
- 3c: `testStageADeadlineDoesNotJoin…`, `testStageBDeadlineWithAStuckTeardown…`, `testWorkFinishingAfterTheExpiryNeverCrossesTheBoundaryOrMarksClean`, `testCancelFencesLateStageASideEffects`.

Added:
- `testRepeatedQuitRequestsNeverExtendTheSingleDeadline` (3b). Repeated quits at 5 s and while the prompt is showing:
  - start no attempt, request no new or later deadline, and add no second prompt or extra reply;
  - the prompt appears at the first request's 8.0 s, not at 7.9 s;
  - the prompt carries that request's ID and `dialogStage == "preparation.deadline_expired"`.
- `testStalledTeardownPresentsTheStageBPromptForItsRequestAtTheSingleDeadline` (3a, 3c):
  - the Stage B prompt appears at exactly 8.0 s on the single deadline;
  - it carries the request ID and `finalization.deadline_expired`;
  - the late teardown neither finalizes nor marks clean nor replies.
- `testDialogStageTokenNamesTheStageAndCause`: the token for each prompt kind. Replaced in the review follow-ups by `testDialogStageTokenPairsWithTheAlertTitleForEachFailureKind`.
- `AgentRecoveryResetBoundaryTests.testPermanentlySuspendedComposerPreparationPresentsTheStageAPromptAtTheSingleDeadline` (3a, 3c, view-model level). Setup: a real `AgentModeViewModel` with recovery composed, a composer preparation that never resumes, and a real `AgentLifecycleShutdownCoordinator` (window scope, manual deadline). It checks that:
  - Stage A parks in the join and shows no prompt before the deadline;
  - the requested deadline is `origin + 8 s`;
  - firing the deadline presents the Stage A Retry/Cancel prompt with the request ID, `timeoutMessage`, and `preparation.deadline_expired`;
  - the window stays frozen while the prompt waits;
  - after the preparation is released, the late completion is fenced: the phase stays `preparationFailed`, there is no second prompt, no point of no return, and no finish;
  - Cancel reopens the window.

Log-line assertion: the coordinator has no event or diagnostics hook, so no test observes the `os.Logger` lines directly. As instructed, I did not build a logging abstraction. The tests assert what the dialog line logs: the failure passed to `presentFailure` carries the request's ID, and `dialogStage` (the exact function the log line uses) yields the expected stage. I also read the persisted lines from the test run with `log show`; the trace is above. If direct assertions on log lines are wanted, add an optional `diagnostics` closure to `AgentLifecycleShutdownEnvironment`. I propose it but did not build it.

## Validation (exact commands, all run from the repo root)

- `make dev-build`: completed, exit 0. Run again after the final log-format tweak: exit 0. No compiler warnings in the touched files.
- `make dev-test FILTER="'AgentLifecycleShutdownCoordinatorTests|AgentRecoveryResetBoundaryTests|AppQuitPolicyTests'"`: completed, exit 0. Executed 80 tests, 0 failures: 51 coordinator, 23 reset boundary, 6 quit policy. Re-run after the tweak: same result.
- `make dev-lint`: completed, exit 0 (swiftformat: 0/2183 files need formatting; swiftlint `--strict` clean).
- `make guardrails`: exit 0. Its only warning is the existing `[route-count] AGENTS.md has 24 direct docs/context routes`, which this change did not cause.
- Unified-log check: `log show --last 15m --style compact --predicate 'subsystem == "com.repoprompt.app" AND category == "LifecycleShutdown"'`. The lines from the xctest process show as `Df` (Default, persisted), with public UUIDs and tokens.

- `Scripts/check-agent-context`: one error.
  - `[reachability]`: this report is an orphan until the restart spec links it. The F7 and F3F6 reports are linked from the spec's Step 7 status lines. I may not edit the spec, so the main agent needs to add that link.
  - The header's `Scope:` line uses the checker's required phrase, "read when the task touches …". The originally requested wording, "read when reviewing …", fails the `[header]` check.

Not run: the full `make dev-test`, and any live app quit. No visible app was launched or stopped.

## Left out, and why

- Dialog texts, the deadline, the wait for the user, and quit blocking were not touched, as the task requires.
- No new persistence files or on-disk records; unified-log lines only.
- No change in `WindowStatesManager+LifecycleShutdown.swift`; see "Files changed".
- No bound or timeout on the composer-preparation join. That would change Stage A behavior; the coordinator's single deadline already ends it, and the new lines make it visible.
- Main-actor starvation and an obscured sheet (two of the spec's remaining explanations) are not diagnosed directly. Starvation shows up only indirectly, as a gap between `shutdown_stage_a_started` and `shutdown_deadline_fired` well past 8 s. Telling apart an obscured sheet from one that is visible but unanswered still needs the screenshot step from the spec.
- No routed context doc lists log categories, so none was updated. The main agent should mark the F5 "Next" logging bullet and the F5 cross-cutting bullet as done in the restart spec; I was told not to edit it.

## Working diff

`prompt-exports/restart-fixes/f5obs.diff`: `git diff` of the five modified files, with the new diagnostics file and this report appended via `git diff --no-index /dev/null <file>`. Several files that were already dirty in the working tree are excluded: `.gitignore`, `AGENTS.md`, `CodemapSeamTestSupport.swift`, the code-mode docs, the restart spec, and `live-acceptance-handoff.md`.

## Review follow-ups (2026-10-26)

Review B (`prompt-exports/oracle-review-2026-10-26-055844-f5obs-review-b-39eab-f824.md`) raised no P0 or P1. Applied: F5OBS-01, 02, 03, 05, 07, 08. Not done, as instructed: F5OBS-06, 09, 10. F5OBS-04 (the spec link) belongs to the main agent. The only behaviour change is log text, plus one new read-only property used for logging.

- **F5OBS-01:**
  - Added `AgentLifecycleShutdownCoordinator.activeApplicationRequestID`, which is `nil` once the app quit has finished.
  - It is used for the coalesced lines (`refused_reason_unavailable`, `admission_sealed`, window close refused during an app quit) and for `app_terminate_requested` and `app_termination_began`.
  - `app_terminate_reply` cannot use it: by the time the reply runs, the request is already finished. Instead `AppDelegate` records `shutdownRequestID` after `requestApplicationQuit` returns (`nil` for a refusal) and logs that.
  - A refusal replies synchronously, so its reply line reads `request=none`.
- **F5OBS-02:**
  - When `requestApplicationQuit` returns `false`, `app_termination_began` now logs `cause=refused` in two cases. One is a synchronous `reply(false)`, which has already reset `quitRequestPhase` to `.idle`. The other is `isApplicationAdmissionSealed`. Any other `false` result logs `joined_in_progress`.
  - The adjacent `appDelegateDebugLog` text now reports that cause instead of always saying "joined".
- **F5OBS-03:** new `testDialogStageTokenPairsWithTheAlertTitleForEachFailureKind` covers 10 failure kinds. Each one asserts `dialogStage(failure)` and `makeLifecycleShutdownFailureAlert(failure).messageText` together:
  - app and window Stage A, deadline and failure;
  - Stage B deadline and failure, including window scope;
  - clean-exit acknowledgement missing;
  - relaunch unresolved, in Stage A and Stage B;
  - uncertain exit offered.

  It replaces `testDialogStageTokenNamesTheStageAndCause`, whose token-only cases it covers. No shared enum was extracted.
- **F5OBS-05:**
  - `armDeadline` now returns the effective work budget (`expiry - start`). `shutdown_stage_a_started deadline_ms` logs that value.
  - `shutdown_finalization_started` logs `deadline_ms` only when it armed a fresh deadline (`fresh_deadline=true`).
  - Confirmed in the test run's unified log: Restart-safely traces show `deadline_ms=7000` (8 s minus the 1 s cleanup reserve), and plain quits show `8000`.
- **F5OBS-07:** documented in the `dialogPresented` doc comment and in the table above that `shutdown_dialog_presented` means "requested from the presenter", not confirmed visible. The event was not renamed.
- **F5OBS-08:** the documented query now filters on `process == "RepoPrompt"`, in the diagnostics file's doc comment and in this report. I confirmed the process name from `CFBundleExecutable` in both `/Applications/RepoPrompt CE Dev.app` and `/Applications/RepoPrompt CE.app`.
- **Test addition:** `testRepeatedQuitRequestsNeverExtendTheSingleDeadline` now also asserts `activeApplicationRequestID == nil` after Cancel, while `applicationRequest` still holds the finished request.

Validation after the follow-ups:
- `make dev-build`: completed, exit 0. Run on the final source.
- `make dev-test FILTER="'AgentLifecycleShutdownCoordinatorTests|AgentRecoveryResetBoundaryTests|AppQuitPolicyTests'"`: completed, exit 0. Executed 80 tests, 0 failures: 51 coordinator (one test replaced), 23 reset boundary, 6 quit policy. No warnings in the touched files.
  - The first run failed to compile because of a test-helper signature mistake: a defaulted unlabeled `scope` parameter. Labeling it fixed it.
- `make dev-lint`: completed, exit 0 (0/2183 files need formatting; swiftlint strict clean).

Not run: the full test lane, a live quit, and `make guardrails`. Guardrails was not requested this round and passed in the first round.

Files: the same five modified files and the one new source file as above. The delta against the first-round diff is in `prompt-exports/restart-fixes/f5obs-delta.diff`.
