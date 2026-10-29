# Phase 1b shutdown initial review — OracleB

Scope: read when the task touches review of the complete R4 quit/window-close preservation step.
Authority: Reference
Last-verified: 2026-10-21

Preset identity verified: OracleB, `7CDD523E-1D7C-47EA-98FE-D5FEA24D2D8C`. Chat: `restart-shutdown-initial-E02144`. Frozen tree: `4dab2d618a1c2babb3e06a4d4155af2d6f91b5eb`. Each lane reviewed the same snapshot independently.

# Oracle Review



# R4 quit/window-close preservation (Phase 1b-shutdown) — OracleB-style independent review

**Snapshot:** tree `4dab2d61`, base `b2ee22a8`. Line numbers marked `~` are counted from the diff hunk headers.

## Summary

This step replaces the irreversible quit path in `AppDelegate.beginTermination` with one app-scoped `AgentLifecycleShutdownCoordinator`, and routes window close through the same coordinator from `InterceptingWindowDelegateProxy`.

- **Freeze.** A synchronous scoped freeze covers recovery admission, dispatch commits, handoff, question answers and reset preparation.
- **Stage A (reversible).** It writes the layout (quit only), the `shutdownInProgress` mark, released-lane settlement, composer preservation, pending-question snapshots (secret answers excluded, with a veto) and run shutdown reasons. It then flushes hydrated transcripts.
- **Stage B.** It checks the forwarded veto, sets the irreversible flags, runs one joinable teardown and a final flush, and writes the clean mark last (quit only).
- **Deadline.** One absolute 8 s deadline applies per user attempt; only Retry re-arms it. Late work is fenced by attempt.

The coordinator's fences, deadline handling and launch-mark ordering look sound. I found no path where late work replies, closes, or leaves a false clean mark. The confirmed data-loss defect is in how question snapshots are replaced. The other findings are smaller gaps in the R4 contract and in test coverage at the real data-loss boundary.

## P1

### R4-1 — A later shutdown deletes earlier-launch recovered questions and their partial answers

**Scenario**
1. Launch 1 quits while a Codex `request_user_input` is pending with a typed non-secret answer. Stage A saves it as a snapshot.
2. Launch 2 shows it as an "Unanswered question" row, because only other-instance snapshots are listed.
3. The owner opens that session (so it gets a live lane), doesn't act on the row, and quits or rebuilds again.
4. Stage A captures that session's live questions. There are none, so the result is `[]`, and `prepareForShutdown` replaces the record's whole `questions` array with it.
5. The launch-1 question and its partial answer are deleted without the user ever choosing Discard.

The same full replacement happens in two other places:
- **Live-resolution refresh:** `refreshRecoveryQuestionSnapshotsAfterLiveResolution`.
- **Window already torn down:** an app quit re-prepares a window whose own close already finished but which is still in `allWindows`. Teardown's `cancelPendingQuestion` has emptied its live questions, so its own Stage A snapshots are overwritten with `[]`. The participant filter only excludes *unfinished* past-point-of-no-return window requests.

**Impact:** User-typed input that the recovery list promised to keep is lost. This conflicts with R8 ("Dismiss never … discards saved input") and with the goal that nothing typed is lost. The owner restarts often, so this is realistic.

**Evidence**
- `AgentRecoveryCoordinator.swift:~1680-1684`: `if let questions { … replaceQuestionSnapshots(questions) }` replaces the whole set.
- `AgentModeViewModel+Shutdown.swift:~179`: always passes a non-nil `capture.snapshots`.
- `AgentModeViewModel+Shutdown.swift:~324`: the refresh also passes the full capture.
- `AgentRecoveryStore.swift` `replaceQuestionSnapshots`: replaces the whole array.
- `AgentModeViewModel+RecoveryList.swift:~129`: rows show only `appInstanceID != currentInstanceID`, which are exactly the snapshots being erased.
- `AgentLifecycleShutdownCoordinator.swift:~219-227`: the participant filter.
- The test at `AgentRecoveryCoordinatorTests` ("an empty set clears resolved questions") covers only the same-instance case.

**Smallest fix**
- In `AgentRecoverySessionLane.replaceQuestionSnapshots`, or in a variant used by Stage A and the refresh, scope the replacement to this instance: `record.questions.filter { $0.appInstanceID != store.appInstanceID } + snapshots`.
- Keep full replacement only for the explicit recovery-list path, which already filters by `interactionID`.
- In `prepareSessionsForShutdown`, return an empty report when `hasPreparedForWindowClose`. A torn-down view model was already preserved; its finalize still runs.
- Add one test: write a snapshot under instance X, run `prepareForShutdown(questions: [])` under instance Y, and assert the snapshot is still there.

## P2

### R4-2 — "Close Anyway" after a failed window Stage B leaves no uncertainty, and a later clean quit erases it

**Scenario**
1. A window close's final flush fails (for example a transcript write error). The user picks Close Anyway.
2. The window's unsaved transcript tail is gone. Nothing is recorded, because window close never writes a mark.
3. The app later quits cleanly and writes `cleanExit`.
4. The next launch reads a proven clean exit for those sessions.

R4/Done-when 8 requires that a failure after teardown "is recorded so the next launch treats the affected sessions as uncertain".

**Evidence**
- `AgentLifecycleShutdownCoordinator.swift`: `handle(.finalization, .proceedAnyway)` → `complete`; `correctUncertainCleanMark` is application-only.
- `WindowStatesManager+LifecycleShutdown.swift`: the finalization text only says "already stopped".

**Smallest fix:** Keep a coordinator flag, `hadUnfinalizedWindowClose`, set on window `proceedAnyway`. While it is set, the app quit skips the final `cleanExit` and leaves `shutdownInProgress`.

### R4-3 — Windows opened during an app quit's Stage A are never torn down or finalized, yet the quit is marked clean

**Scenario**
1. Within the up-to-8 s Stage A, a window opens (Cmd-N, a URL or MCP open, or a workspace restore).
2. The app-wide recovery freeze covers its lanes.
3. It is not a participant, because the list is captured once. Its providers aren't stopped by the coordinator, its transcript and composer get no final flush, and `cleanExit` is still written.

**Evidence:** `AgentLifecycleShutdownCoordinator.swift:~202`: `environment.participants(.application)` is evaluated once, and `request.participants` is reused for teardown and finalize (`~360`, `~390`).

**Smallest fix:** At `enterPointOfNoReturn` for `.application`, re-query `environment.participants(.application)` for teardown and finalize. Any newcomer that skipped Stage A is frozen anyway. The alternative is to refuse window creation while `isApplicationRequestActive`.

### R4-4 — The answer freeze is incomplete, and snapshots can go stale after Cancel

**What is not frozen**
- `AgentMCPElicitationCard` is not `.disabled(isShutdownFrozen)`, and `submitMCPElicitationResponse` has no freeze guard (`AgentModeView.swift:~2741-2749`).
- The throwing `submitAskUserResponse(tabID:interactionID:draftsByQuestionID:)` (used for MCP/remote resolution) is unguarded (`AgentModeViewModel.swift`, next to the guarded overloads).

A question answered during Stage A can therefore be delivered *after* its snapshot was written.

**Why snapshots go stale:** After a cancelled Stage A, a question can end through a path that never calls `recordMCPInteractionResolution`, for example Stop or a run ending via `cancelPendingQuestion` (`~20991`). The refresh hook only runs from `recordMCPInteractionResolution` (`~6575`). The this-instance snapshot then stays on disk. After a later crash, the next launch shows a phantom "agent was waiting for an answer" row that has no backing request.

**Smallest fix**
- Add the two guards and the `.disabled`.
- In `endShutdownFreeze` (Cancel), clear this-instance snapshots for tabs in `shutdownQuestionSnapshotTabIDs` (instance-scoped, per R4-1). Only a Stage A that proceeds to teardown needs them.

### R4-5 — Elicitation and ask_user partial answers may be dropped without a veto (unverified)

Elicitation snapshots carry `items: []`. The code comment says elicitation has "no partial-answer surface", but MCP elicitation renders a form whose values live in the card, which is outside this diff.

- If the card holds typed field values, a quit loses them silently: they are neither preserved nor vetoed.
- ask_user capture reads `pending.draftsByQuestionID` and always uses `isSecret: false`. If the wizard keeps typing in local `@State` and only reports drafts later, the latest partial answer is also missed.
- Neither path has a fixture.

**Evidence:** `AgentRecoveryQuestionSnapshotBuilder.swift:~92-104` (elicitation) and `~27-47` (ask_user).

**Smallest fix:** Confirm from the card source. If either card holds unreported input, either move its drafts to the session (as this diff did for `request_user_input`) or veto Stage A when a draft is non-empty. If neither does, record that it was confirmed.

### R4-6 — The preserve disposition isn't visible in this step; `shutdownTeardownReason` is write-only

Spec R4 Stage B says "Stop runtimes … using the *preserve* disposition."

- The teardown still calls the unchanged `cancelPendingInstruction(for:)`, `cancelPendingQuestion` and `cancelAgentRun`.
- The new `shutdownTeardownReason`, set at `AgentModeViewModel.swift:~3847`, is never read in the diff, even though the doc comment says interrupted work "is preserved … for `reason`".

If the baseline `cancelPendingInstruction` withdraws durable intents, queued follow-ups are lost on every quit (that would be P0). I can't confirm either way from this snapshot.

**Evidence:** `AgentModeViewModel.swift:~3914` (`cancelPendingInstruction` inside `prepareSessionForWindowClose`).

**Smallest fix:** Cite the baseline test that shows `prepareSessionForWindowClose` leaves committed intents `queued` or `dispatching`, then delete the unused field. If no such test exists, add one assertion to the reset-boundary harness: queue an intent → `prepareForWindowClose(reason: .appQuit)` → the intent is not `withdrawn`.

### R4-7 — Tests don't reach the real data-loss boundary

| What is covered | Where the actual loss risk is |
|---|---|
| Stage B with fake participants | The real view-model path, `prepareForWindowClose(reason:)` → terminal commit → `finalizeTranscriptsAfterShutdown`, is untested. That is the "second flush after terminal commits" the clean mark depends on. |
| Snapshot round-trip within one instance | The multi-launch snapshot lifecycle and the question rows (copy into composer, dismiss) are untested. That is where R4-1 sits. |
| Coordinator one-shot logic | Proxy routing, the order of `consumeFinalizedCloseAuthorization`, and the `isTerminating` branch are compile-only. |

**Smallest additions (no new framework):**
1. Reset-boundary harness: dirty session → `prepareForWindowClose(reason: .appQuit)` → append → `finalizeTranscriptsAfterShutdown()` → the file contains the new content and the report is empty.
2. The R4-1 cross-instance snapshot test.

## P3

- **R4-8 — Preparation and finalization run one at a time.** Windows run serially (`AgentLifecycleShutdownCoordinator.swift:~293`, `~390`) and so do sessions (`AgentModeViewModel+Shutdown.swift:~131-143`), all inside one 8 s budget. The spec says sessions are handled concurrently. Many large sessions make a timeout prompt more likely; nothing is lost. Fix: use a task group over participants.
- **R4-9 — Elicitation snapshot time.** `askedAt: AgentRecoveryTimestamp(Date())` (`AgentRecoveryQuestionSnapshotBuilder.swift:~100`) records the capture time, not when the question was asked, and it forces a record rewrite on every attempt. Fix: carry the request's own timestamp.
- **R4-10 — The composer isn't edit-frozen.** While an app-quit Stage B failure sheet is up on one window, another window's composer still accepts typing. Retry re-flushes it; Quit Anyway loses it. Fix: disable composer input while `isShutdownFrozen`.
- **R4-11 — Wrong message on a re-shown Stage B prompt.** `handle(.finalization, .cancel)` shows it again with `timeoutMessage`, whatever the original blockers were. Fix: pass the original messages.

## Recommendations

1. **Fix R4-1 before committing.** Make Stage A and refresh replacements instance-scoped, skip Stage A for already torn-down view models, and add the cross-instance test. It is small, local, and the only confirmed data-loss path.
2. **Fix R4-2, R4-3 and R4-4 in the same pass.** Each is a few lines in the coordinator or the view model.
3. **Settle R4-6 with evidence.** Cite or add the "teardown leaves intents un-withdrawn" assertion, then remove `shutdownTeardownReason`. If withdrawal turns out to happen, it becomes P0.
4. **Resolve R4-5 by reading the elicitation and ask_user card sources,** then either preserve/veto or record that it was checked.
5. **Add the two R4-7 tests** and rerun the suites that went stale after the late change, at least `AgentRecoveryVMProducerAdmissionTests` and `AgentRecoveryQueuedInputTests`, since the freeze guards touch their routes.
6. **Check `stopAllServers` / `tearDownScope` against the removed `shutdownAllAgentSessions()` call** for app-scoped cleanup that may have been dropped.
7. **Defer R4-8 to R4-11.** Live acceptance stays pending (O3): NSAlert flows, `.terminateLater` reply timing, `performClose` after authorization, and logout behavior during a Stage A prompt.
