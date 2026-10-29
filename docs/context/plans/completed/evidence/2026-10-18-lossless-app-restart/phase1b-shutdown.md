# Phase 1b R4 shutdown: validation evidence

Scope: read when the task touches R4 quit/window-close preservation of the [lossless app restart spec](../../2026-10-18-lossless-app-restart-spec.md). Unstaged working tree on top of `b2ee22a84be72e8793e535e92655ec17d6b66019`. Fixture and compile evidence only.
Authority: Reference
Last-verified: 2026-10-21

## Initial independent reviews

Both lanes received frozen tree `4dab2d618a1c2babb3e06a4d4155af2d6f91b5eb` against `b2ee22a8`, with the same diff, spec and validation evidence. Preset identities were verified before synthesis. Findings: [OracleA](phase1b-shutdown-oraclea.md), [OracleB](phase1b-shutdown-oracleb.md).

Status: two re-review rounds are complete. After R2, neither lane has an open P0 or P1, and every required finding is closed. Small post-R2 follow-ups were applied afterwards and were not independently re-reviewed (see [Post-R2 follow-ups](#post-r2-follow-ups-not-independently-re-reviewed)). This is not live acceptance: O3 stays owner-pending.

A pre-R1 closure round reworked A R4-01 to use exact interaction IDs. The boundary implementation round that followed replaced the dynamic late-window handling of B R4-3 (and its Case N residual) with an admission seal at the app quit's point of no return. It also replaced R4-02's unclean correction with a verified Stage A launch mark plus ownership of the clean write. No Case N residual or open choice remains; see B R4-3.

## Claim scope

These results come from coordinated `conductor` jobs on one machine.

`AgentLifecycleShutdownCoordinator` fixtures use:
- fake lifecycle participants and a scripted failure presenter;
- a manual absolute-instant clock (`now`, `sleep(until:)`, `advance`, `jump`);
- the real `AgentRecoveryCoordinator` launch-mark tail and the real `AgentRecoveryStore`, including its clean-exit gate, over a temporary directory. Launch-file writes can be held or failed per state.

Their assertions read what was committed to disk (`launch-state.json` and a committed-write log), never recorded requests.

VM fixtures use:
- the real `AgentModeViewModel` save, teardown (`prepareForWindowClose`), `ask_user` continuation and final-flush paths;
- the real `AgentSessionDataService` gate;
- temporary stores.

No app was launched, quit or closed. No real provider, credential or network was used. No packaging ran, and there was no full-root or parallel suite run. The following are compile-checked only:
- NSAlert presentation and `applicationShouldTerminate` `.terminateLater` replies;
- `InterceptingWindowDelegateProxy` close routing and `WindowStatesManager` environment wiring;
- SwiftUI card identity and the disabled composer.

## Boundary planning consultation

The [focused admission/clean-exit planning consultation](phase1b-shutdown-boundary-plan.md) resolves the concrete late-window race by refusing activation after the point of no return. Main adopts the distinction between a delayed clean acknowledgement and invalid preservation proof. No owner exception for false-clean termination is assumed. This was planning, not a re-review round. The implementation is complete on the unstaged tree (R4-02 and B R4-3 below); both independent re-review rounds are complete with no open P0/P1.

**Implementation interpretation (adopted by main; not an Owner Decision).** A delayed clean-write acknowledgement is not uncertainty about saved input when all of these hold: every admitted participant was prepared and finalized with zero blockers, every participant stays torn down and frozen, admission is sealed, and the write was enqueued under a current authorization. Such a write is never corrected. It times out with its own message, and Retry joins it. Quit Anyway terminates without waiting, and its late completion never terminates the app by itself. A real proof invalidation would still need an owner decision; none is reachable after the seal (see B R4-3).

## First independent re-review

[OracleA R1](phase1b-shutdown-oraclea-r1.md) and [OracleB R1](phase1b-shutdown-oracleb-r1.md) reviewed frozen tree `1c704e777d0ca799bcd7a1a93d24ae290280ead7`, each with only its own initial findings and dispositions. Both accepted the sealed registration and delayed-acknowledgement interpretation. The R1 fixes (see [R1 dispositions](#r1-dispositions)) were reviewed in R2.

## Second independent re-review (R2, final)

[OracleA R2](phase1b-shutdown-oraclea-r2.md) and [OracleB R2](phase1b-shutdown-oracleb-r2.md) each reviewed the R1 delta, and main verified both preset identities.
- **Outcome:** neither lane has an open P0 or P1, and every required finding is closed.
  - The N2 / A R4-01-R1 serialization was traced for both supersession orderings.
  - N1 is closed in code. Its original failure was never reproduced, and real-window behaviour is pending under O3.
- **Policy:** there is no third review round.

## Post-R2 follow-ups (not independently re-reviewed)

Only the small follow-ups the R2 review named were applied. They had no review of their own after R2.
- **N7: no UI republish while closing.** `publishShutdownFreezeToObservedUI` returns early when `hasPreparedForWindowClose`. A window already past its own close's point of no return (Cmd-Q during its Stage B) is not republished or re-synced; its stores already show it frozen.
- **N4-r1: status pills covered.** `.disabled(composerUI.props.isShutdownFrozen)` moved after the status-pills `.overlay` in `AgentInputBar.body`, so the pills are disabled too.
- **N4-r2: image drop checked.** `handleImageDrop` checks the live freeze twice:
  - at entry, it returns `false` while frozen, so the drop is refused and never accepted, and the source keeps it;
  - inside the async load completion, before `attachPreparedImages`, it does not change the composer.

  Outside a freeze both checks pass, and the existing drop path is unchanged.
- **N9: doc comment.** The R4-06 doc comment moved back above `testNativeUserInputCardReseedsRetainedPartialAnswersPerRequest`. This is a comment-only change.

The three source changes are compile-checked with focused neighbour suites only. No fixture drives the SwiftUI disabled state or a real drop.

**Residual (limit).** A drop accepted before the freeze whose async load completes during it is not attached. It stays unattached; temporary prepared files are cleaned up, and the composer is preserved as it was at the freeze. Narrowing that window needs O3.

**Deferred with plain limits (no change):**
- **N6 (P2):** a failed snapshot removal that never succeeds blocks every later Stage A in that window; the only way out is force quit. Over-preservation only: a resolved question may reappear as a recovery item, which Dismiss clears.
- **N4-r3:** composer mutations that bypass the text view's `shouldChangeText` are not refused by the view model. This includes `attachImages`, `commitTaggedFile` and snippet-palette insertion; whether the delegate is the `Coordinator` is compile-checked only. At worst, Stage A reports a "kept changing" blocker, or a late attachment is lost on Quit Anyway.
- **N8:** a preparation that never finishes delays every later Stage A on that view model until it does; each is bounded by its own deadline.
- **N9 (async gate):** `RecoveryStoreRunShutdownWriteHold` blocks a cooperative-pool thread with a semaphore. It is single-use, and is released by `defer`.
- **Older deferrals:** B N3, B N5, B R4-8 and R4-9.

**O3 live checklist (owner-pending; from the R2 review):**
- window-close → app-quit supersession;
- Cancel → immediate re-quit;
- typing, paste and drop during the freeze, including whether the text view's delegate is the `Coordinator`;
- status pills during the freeze;
- New Window and tab "+" staying registered across admission (real `WindowGroup`).

## Final checkpoint checks

Main inspection added cleanup of temporary prepared-image files when an asynchronous drop is refused because shutdown froze the composer. This is part of the bounded post-R2 drop guard, not a new review round. Source-validating `make dev-test FILTER=AgentInteractionLatencyProbeTests` passed 22/22 (`d8c8ed28-d228-4343-9ada-15b9d71b85ff`); `make dev-lint` passed (`9d4e112a-d4ce-49dd-a802-a30527f98b1c`). `make guardrails` and `Scripts/check-agent-context` passed, with the existing 24-route warning. Full-root and live acceptance were not run.

## Jobs: post-R2 follow-ups (before final temporary-file cleanup)

| Ticket | Operation | Result |
|---|---|---|
| `233c483e-4146-447f-8a99-79b7d92df5d3` | test `AgentRecoveryResetBoundaryTests` (compiles every target) | 16/16; no warnings in touched files (the only one reported is pre-existing, in untouched `AgentStaleResetOwnershipTests.swift:2306`) |
| `97a16bd5-5eca-42ff-b819-4f818a3a0c41` | test `WindowCloseCoordinatorLifecycleTests` | 7/7 |
| `46cf843d-db7e-456c-964f-ecd79484ea4d` | test `SnippetPaletteShortcutRoutingTests` (input neighbour) | 2/2 |
| `e6d3e589-e0ca-4e34-aeac-3a9560a0a39b` | test `AgentInteractionLatencyProbeTests` (input neighbour) | 22/22 |
| `1bf19853-a866-43bc-b4e1-279f191b5ab0` | lint | exit 0 |

No full-root, parallel or artifact runs. No flake was observed.

## Review dispositions

### OracleA

- **R4-01 (P0), fixed with exact interaction IDs (pre-R1 closure).** A later owner's Stage A deleted questions that another owner had preserved.
  - The first fix scoped writes by app instance. That still deleted a question preserved by a window closed earlier in the same launch: close → reopen the session in the same app instance → no live continuation → quit or close again. The closed window's snapshot carries the current `appInstanceID`.
  - Store: `AgentRecoveryStore.QuestionSnapshotUpdate { upserting, removing }` replaces the scope enum. There is no new layer.
    - An upserted snapshot replaces the stored one with the same `interactionID` in place; otherwise it is appended.
    - `removing` deletes exactly those IDs.
    - Every other snapshot is kept, whichever launch or owner wrote it.
    - The write reports `alreadyStored`: the upserted IDs that were already present.
  - Lane:
    - `prepareForShutdown(questions: QuestionSnapshotUpdate?, run:)` succeeds with `alreadyStored`;
    - `updateQuestionSnapshots(_:)` replaces `replaceQuestionSnapshots(_:scope:)`.
  - VM: `shutdownQuestionSnapshots[tab]` holds `(lane, live, introduced)`.
    - Stage A upserts the live capture. It removes only IDs that an earlier attempt of this window introduced and that are no longer live.
    - `introduced = live − (alreadyStored − earlier.introduced)`. A question another owner already preserved is adopted (rewritten in place) but never counted as introduced.
    - If an introduced question is resolved while Stage A's write is in flight, it is removed after the write. If Stage A is cancelled during its write, it removes what it introduced.
    - Live resolution goes through the funnel `recordMCPInteractionResolution`, which now passes its `interactionID`. It removes exactly that ID, and only if this window tracked it live on that lane. Teardown cancellations never reach the funnel.
    - Cancel removes only `introduced`, on the tracked non-retired lane, and never for a torn-down window.
    - All removals are serialized on one task chain, which a later Stage A joins before writing.
  - Recovery list: `updateQuestionSnapshots(.init(removing: [id]))`.
  - A view model already torn down (`hasPreparedForWindowClose`) is never prepared again.
  - Tests:
    - `testQuestionWritesNameExactInteractionsAndKeepOtherOwnersSnapshots` (coordinator, real store). An earlier launch's snapshot and a same-launch closed owner's snapshot both survive a reopened owner's empty preparation; the reopened owner is a second lane claim on the same store instance. Re-upserting replaces in place and is reported as already stored, and removals are exact.
    - VM `testReopenedWindowKeepsASameLaunchClosedOwnersQuestionsThroughStageAAndCancel`. A closed owner's same-instance snapshots survive an empty Stage A, Cancel, an adopted live re-capture followed by Cancel, and an untracked live resolution. Cancel removes only the introduced question.
    - VM `testLiveResolutionRemovesExactlyItsSnapshot`.
    - VM `testCancelClearsThisLaunchQuestionSnapshotsBeforeALaterStageAWritesAgain` (asserts the exact tracking).
    - VM `testTeardownKeepsQueuedIntentAndQuestionAndTheFinalFlushWritesLateContent` (torn-down skip).
  - Limit: the VM regression writes the closed owner's snapshot through the reopened window's lane. It does not drive a second `AgentModeViewModel` through a real reopen, because binding a second VM to a persisted session needs the window-restore path. The two-owner, same-instance store state is covered at coordinator level.
- **R4-02 (P1), fixed by a verified Stage A mark and an owned clean write. No correction, no new journal, no unbounded wait (boundary implementation round).** Quit Anyway could exit before the unclean correction reached disk.
  - Stage A now awaits and checks its `shutdownInProgress` launch mark (`recordLaunchState(.shutdownInProgress).value`) under the attempt's 8 s deadline.
    - A failed mark is a Stage A blocker (`launchMarkFailureMessage`, Retry / Cancel).
    - A held mark is a Stage A timeout.
    - Nothing is prepared or torn down behind it.
    - Stage B is therefore entered only once the launch file records this quit as unclean.
  - The clean mark is written last and once.
    - The store's `AgentRecoveryCleanExitGate` writes `cleanExit` only if the single-use authorization is still current when the write begins. A write that already began is atomic and cannot be revoked; the gate's comments now say so.
    - The coordinator authorizes only when all of these hold: the final flush returned zero blockers; the captured expiry has not passed; no unknown participant exists (defensive, fail-closed: `unpreparedWindowMessage`); and no window close ended unfinalized.
  - Once enqueued, the clean write is owned by the request (`Request.cleanWrite`):
    - a timeout while it is pending reports `cleanExitAcknowledgementMessage` with `awaitsCleanExitAcknowledgement`;
    - Retry joins it and never finalizes or writes again; a write that wrote nothing is released, and Retry then finalizes and authorizes afresh;
    - Quit Anyway completes at once;
    - a late completion of a no-longer-current attempt never completes the request.
  - Every other Stage B failure leaves the verified `shutdownInProgress` on disk: a failed or unstarted clean write commits nothing. This is the delayed-ACK interpretation recorded under the boundary consultation above.
  - Removed: the coordinator's `revokeCleanExit` environment field, `correctUncertainCleanMark`, `cleanCorrection`, `correctionFailureAcknowledged`, the bounded correction wait (`OutcomeRace` / `firstOutcome`), and `correctionFailureMessage`. Also removed is the second Quit Anyway that bypassed an unconfirmed correction. The store/coordinator `revokeCleanExit()` APIs remain, unused by shutdown.
  - Alerts (compile-checked):
    - A delayed acknowledgement reads "RepoPrompt is still finishing its quit… Nothing is left to save. If the clean exit was not recorded, the next launch asks you to review the stopped sessions."
    - Any other Stage B quit failure reads "Sessions were already stopped. This exit stays recorded as interrupted…", which the verified Stage A mark makes true.
  - Tests:
    - `testUnconfirmedStageALaunchMarkTimesOutBeforeAnythingIsTornDown` (replaces `testAuthorizedButUnstartedCleanWriteIsPreventedWithoutACorrection`; Cancel's `running` lands last);
    - `testFailedStageALaunchMarkPreventsTeardownUntilRetryConfirmsIt`;
    - `testDelayedCleanAcknowledgementIsNeverCorrectedAndQuitAnywayRepliesAtOnce` (disk `shutdownInProgress, cleanExit`; no corrective write; one reply);
    - `testRetryJoinsADelayedCleanWriteWhoseLateCompletionNeverTerminates` (a bounded Retry prompt while still pending, no automatic termination after the late ACK, then one write and one finalization);
    - `testRetryAfterADelayedCleanWriteThatWroteNothingAuthorizesAfresh`;
    - `testFailedCleanWriteLeavesTheUncleanMarkWithoutACorrection`.
  - Removed tests (their correction contract no longer exists): `testCleanWriteInProgressAtExpiryIsCorrectedBeforeQuitAnywayReplies` and `testUnconfirmedCorrectionIsReportedOnceThenQuitAnywayProceeds`.
- **R4-03 (P1), fixed at the shared boundary before mutation, elicitation included.** The payload-bearing `ask_user` submission bypassed the shutdown freeze.
  - `submitAskUserResponse(…draftsByQuestionID:)` throws `AgentModeShutdownAnswerRefused` before it replaces drafts.
  - Both private resolvers (`resolveAskUserResponse`, `resolveRemoteAskUserResponse`) throw the same error. Every local, remote, skip and legacy `ask_user` path goes through them.
  - `mcpResolvePendingInteraction` refuses `.question`, `.mcpElicitation` and `.userInput` with `invalidParams`, before it stages attribution.
  - `submitMCPElicitationResponse` returns while frozen, and the elicitation card is disabled.
  - Native user input was already guarded (`submitUserInputResponse`, `updateUserInputDraft`).
  - Test: `testFrozenAnswersAreRefusedBeforeAnyMutationAndAcceptedAfterCancel`. A real pending `ask_user` keeps its draft, request and continuation while frozen, the elicitation stays pending, and after Cancel the same answer is delivered.
- **R4-04 (P1), fixed.** Retry did not retry failed terminal-evidence persistence.
  - The lane keeps each failed terminal-evidence operation (`failedTerminalEvidence[runAttemptID] = (commit, transcriptTurnID)`) and clears it when that operation succeeds.
  - `retryFailedTerminalEvidence()` joins the tail, re-enqueues the failed operations (storage only) and waits for them.
  - `finalizeTranscriptsAfterShutdown` calls it after `settleEvidenceWrites`, so every Stage B Retry re-attempts the write. Teardown is never repeated: the coordinator joins its single teardown task.
  - Tests:
    - lane: `testFailedTerminalEvidenceIsRetainedAndRetriedStorageOnly`;
    - VM: `testFinalFlushRetriesFailedTerminalEvidenceStorageOnly` (after the real teardown: blocked while storage fails, empty report and terminal on disk after it recovers).
- **R4-05 (P1), fixed.** The deadline was one relative sleep, not an absolute request deadline.
  - `armDeadline` captures `expiry = now() + 8 s` synchronously when the user attempt starts. The deadline task sleeps until that absolute instant.
  - The expiry is also checked at each success transition:
    - the end of Stage A (never crosses the point of no return late);
    - before the clean authorization;
    - Stage B completion.
  - Tests:
    - `testDelayedDeadlineTaskNeverExtendsTheCapturedExpiry`: the deadline task first runs 5 s late, yet the requested deadline is t0 + 8 s, and it fires at 8.0 s, not 7.9 s;
    - `testWorkFinishingAfterTheExpiryNeverCrossesTheBoundaryOrMarksClean`: Stage A and Stage B both finish after a jump past expiry, with no boundary crossing and no clean mark; Retry then succeeds.
- **R4-06 (P1), fixed.** Reused native-question cards discarded the restored draft projection.
  - The native card's identity is now its request (`pendingUserInputRequest-<request UUID>`).
  - The card seeds its state from the session-owned partial answers (`initialDrafts`) on creation and whenever `request.id` changes (`seededDrafts(for:initialDrafts:)`).
  - Test: `testNativeUserInputCardReseedsRetainedPartialAnswersPerRequest` (A → B → A, and a later draft keeps the other answers). The SwiftUI identity change itself is compile-checked only.

### OracleB

- **R4-1 (P1), fixed.** This is the same finding as A R4-01; see that disposition.
- **R4-2 (P2), fixed.** "Close Anyway" after a failed window Stage B left no uncertainty, and a later clean quit erased it.
  - Close Anyway sets `hasUnfinalizedWindowClose`. Every later app quit of this launch completes without authorizing a clean mark, so Stage A's `shutdownInProgress` stays and the next launch treats the launch as unclean.
  - There is no new layer, and window close still writes no launch mark. On a crash before any quit, the mark stays `running`.
  - A run shutdown reason recorded in Stage A is intent, never terminal proof (`AgentRecoveryStartupReconciliationTests`). Runs without terminal evidence therefore become crash holds; that is the per-session uncertainty the existing record supports.
  - Limit: a session whose only failure was a transcript write has no per-session marker beyond the unclean launch mark.
  - Test: `testCloseAnywayKeepsALaterQuitFromMarkingClean`.
- **R4-3 (P2), fixed by an admission seal at the point of no return (boundary implementation round). No residual or open choice remains.** Windows opened during an app quit were never torn down or finalized, yet the quit was marked clean.
  - Window creation cannot be blocked at a seam we own.
    - `RepoPromptApp` uses `WindowGroup(id: "main")` with no `.newItem` replacement, so SwiftUI's default New Window and the tab "+" create windows without `AppWindowOpener`.
    - Every window does register synchronously through `WindowStatesManager.registerWindowState`. That is the only place that appends to `allWindows`, and `allWindows` is the app quit's participant list, so this is the seam.
  - **Admission is decided before the window becomes app state.** `registerWindowState` now calls `lifecycleShutdown.admitApplicationWindow(state.agentModeViewModel)` before `allWindows.append`. It returns `Bool`; `WindowContentView.onAppear` stops at `false`.
    - **No app quit, or one in Stage A:** admitted. During Stage A the window is frozen synchronously and joins the request (`participants`, `preparationParticipants`, `participantRevision += 1`). The current attempt then fails with `newWindowMessage` (Retry / Cancel). Retry preserves the layout again and prepares the window before the boundary; Cancel unfreezes it.
    - **Sealed:** `isApplicationAdmissionSealed` is latched synchronously in `enterPointOfNoReturn` for the app scope, after the (window-only) veto and before `beginIrreversible`. It is never reset; the process exits.
      - A refused window is not appended, notifies no open waiters, and gets no listeners, restore entry, `pendingURLs`, MCP routing, scheduler, lanes, hydration, freeze or teardown.
      - `refuseApplicationAdmission()` shows it as an inert "RepoPrompt is quitting" shell through the existing `WindowContentView` body.
      - The seal also refuses a later `requestApplicationQuit` and `requestWindowClose`.
    - A window close never seals.
  - **Initialization order (existing activation gated, no new framework).**
    - Scene windows use `WindowState.forWindowScene()` (`@StateObject`). Its only pre-registration activation was the initial workspace activation `Task` (sessions, hydration, lanes) and the scheduled-send host attach. Both are deferred, through `defersActivationUntilAdmission` → `WindowStateComposition` → `WorkspaceManagerViewModel(defersInitialWorkspaceActivation:)`, until `activateAfterApplicationAdmission()`, which `registerWindowState` calls right after the append.
    - `ContentView` renders only for `.admitted`; `.pending` is an empty view for that frame.
    - Restore, URLs, listeners and MCP routing already hang off registration and `allWindows`.
    - `WindowState()` (tests and DEBUG initializers) keeps immediate activation. It has no production caller, and `registerWindowState` remains the only `allWindows` append.
  - **Post-seal invalidation check: none reachable.**
    - New scene windows are refused.
    - Every admitted participant is torn down and frozen.
    - A joined window close's later Close Anyway concerns a participant this quit itself prepared and finalized.
    - Closing an admitted window after the point of no return (`isTerminating`) only removes a participant and joins its single teardown.
    - An unknown participant is reachable only by bypassing the seal in a test, and fails closed before authorization (`unpreparedWindowMessage`) without any correction.
    - So no owner decision between a strict correction and an unconditional Quit Anyway is needed.
  - Removed: `participantRegistered`, `lateParticipants`, `hasLateParticipant`, `lateWindowMessage`, the post-write late check, and registration-time revocation.
  - **Case T, a delayed clean acknowledgement:** see R4-02 and the implementation interpretation above. It is not a proof invalidation.
  - **Case N, a window arriving while the clean write is gated:** the window is refused before registration, so the case no longer exists.
  - Tests:
    - `testWindowRegisteredDuringStageAFailsTheAttemptAndRetryPreservesLayoutAndPreparesIt` (Stage A admits; layout called twice; prepared before the boundary);
    - `testWindowRegisteredDuringAStageAPromptIsUnfrozenByCancel` (Cancel restores usability; a cancelled quit never sealed admission);
    - `testAdmissionIsSealedAtThePointOfNoReturnAndARefusedWindowIsUntouched` (unsealed in Stage A, sealed at the point of no return; the refused window is never frozen, prepared, torn down or finalized; disk `shutdownInProgress, cleanExit`);
    - `testWindowArrivingWhileTheCleanWriteIsGatedIsRefusedAndTheCleanClaimHolds` (the concrete race: the clean write is held in the store; the refused window never becomes a participant; one layout call; no prompt; no correction; after completion the seal still refuses windows, a second quit and a window close);
    - `testWindowCloseNeverWritesALaunchMarkAndHonorsTheForwardedVeto` (also: a window close never seals, and admission still succeeds);
    - `WindowCloseCoordinatorLifecycleTests.testWindowSceneActivationWaitsForAdmissionAndARefusedWindowNeverActivates` (real `WindowState.forWindowScene()`: the workspace is not initialized before admission; a refusal is final and never activates; admission runs the deferred activation).
  - Removed tests (their late-participant contract no longer exists):
    - `testWindowRegisteredAfterTheBoundaryIsNeverPreparedAndTheQuitIsNeverMarkedClean`;
    - `testWindowRegisteredWhileTheCleanMarkIsWrittenCorrectsItBeforeQuitAnyway`;
    - `testWindowRegisteredDuringTheCleanWriteWithAnUnconfirmedCorrectionLeavesTheCleanMark`.
- **R4-4 (P2), fixed.** The answer freeze was incomplete, and snapshots could go stale after Cancel.
  - For the answer freeze, see A R4-03.
  - `endShutdownFreeze` removes, by ID, only the snapshots this window introduced on the lanes they were written to. The removal goes through the serialized task chain that a later Stage A joins. Questions preserved by another owner are kept. Covered by the R4-01 VM tests.
- **R4-5, settled from source; no change needed.**
  - The elicitation card (`AgentApprovalCard`) offers only Decline / Cancel Run / Accept and holds no editable `@State`. `schemaJSON`/`defaultContentJSON` are not rendered as a form, so there is no partial answer to lose.
  - The `ask_user` wizard (`AgentAskUserWizardCard`) keeps every draft in the VM (`pendingAskUser.draftsByQuestionID` via `updateAskUserDraft`, frozen during shutdown). The snapshot builder captures those drafts; the B07 fixture asserts the preserved `"staging"` answer.
  - No secure-storage scope applies.
- **R4-6, settled from source; `shutdownTeardownReason` removed.**
  - Teardown withdraws nothing durable:
    - `cancelPendingInstruction` only resumes the instruction-wait continuation and clears `waitingPrompt`;
    - `prepareSessionForWindowClose` touches no recovery intent.
  - Withdrawals happen only in recovery-list actions, scheduled-send rollback, and admission-projection failure. All three are refused or drained under the freeze.
  - HEAD's `shutdownAllAgentSessions` (each window's `prepareForWindowClose` plus the polling shutdowns) is covered by participant teardown plus `tearDownScope(.application)`: OhMyPi resolver cancel, the three polling shutdowns and `stopAllServers`.
  - Fixture: a lane-admitted `queued` intent is still `.queued` after the real teardown and final flush.
  - Limit: the fixture's intent has no VM queue projection.
- **R4-7, fixed.** Tests did not reach the real data-loss boundary.
  - New real-VM fixtures:
    - teardown → late transcript content → `finalizeTranscriptsAfterShutdown` writes it with an empty report and a clean projection;
    - the queued intent and the preserved question survive teardown, and a re-prepare of the torn-down window is a no-op;
    - the terminal-evidence retry and the answer freeze.
  - Store fixtures cover the multi-launch snapshot lifecycle. The recovery-list row actions (copy to composer, dismiss) are still not driven through the VM; their store operation (`.removingInteraction`) is covered.
- **R4-8 (P3), deferred.** Serial preparation is a timeout-likelihood issue only, with no data loss.
- **R4-9 (P3), deferred.** `AgentMCPElicitationRequest` has no ask time, so fixing it needs a model change; that is not tiny.
- **R4-10 (P3), fixed.** The composer was not edit-frozen.
  - `AgentInputBar` is disabled while `isShutdownFrozen`.
  - `ResizableTextField.updateNSView` sets `textView.isEditable` from the environment's `isEnabled`; its only caller is `AgentInputBar`.
  - Compile-checked, plus `SnippetPaletteShortcutRoutingTests` and `AgentInteractionLatencyProbeTests`, which build `ResizableTextFieldFeatures`.
- **R4-11 (P3), fixed.** A dismissed Stage B prompt is shown again with its own messages and `timedOut` (`lastFailure`). Asserted in `testStageBOffersNoCancelAndRetryFlushesAgainWithoutRepeatingTeardown`.

## Final normal re-review

[OracleA R2](phase1b-shutdown-oraclea-r2.md) and [OracleB R2](phase1b-shutdown-oracleb-r2.md) reviewed frozen tree `9f938f44cc977a9a0697033c71ff2ee7bfcd56c5`, each with only its own R1 findings and dispositions. Both identities were verified; both report no open P0/P1. The three small reviewed followups (closing-window UI publication, status-pill disabling, async image-drop refusal) and a test-comment correction were applied and passed affected validation, without another review round. Live acceptance remains pending.

## R1 dispositions

- **A R4-01-R1 (P0) / B N2, fixed: whole preparation serialized per view model across requests.** A cancelled or superseded request's Stage A that completed after a successor's upsert enqueued the removal of a question the successor had just preserved. Entry only joined the removal tail, so that removal landed after the successor's write.
  - `prepareSessionsForShutdown` captures its request (`freezeRequestID`) at call time and chains on `shutdownPreparationTask`. It runs only after the previous preparation (Retry, a cancelled request's, or a superseded window close's) has returned.
  - The successor then joins `shutdownQuestionSnapshotWriteTask` (the predecessor's stale cleanup and any Cancel or live-resolution removal), and only then captures and upserts. The stale branch keeps its removal. That removal now always lands before the successor's capture, so the successor re-preserves the question, tracks it as `introduced`, and owns it.
  - Both supersession patterns go through the same seam. Cancel → new quit is `endShutdownFreeze` then a new `beginShutdownFreeze`. Window close → app quit is a new `beginShutdownFreeze`, after which the superseded `endShutdownFreeze` is ignored.
  - A hung predecessor is bounded by the successor's own Stage A deadline. Removals stay refused after teardown (`hasPreparedForWindowClose`), so none can follow a clean authorization.
  - Regressions use the real VM, store and lane:
    - `testCancelledPreparationsLateCleanupNeverErasesTheSuccessorsSnapshot`;
    - `testSupersededWindowClosePreparationsLateCleanupNeverErasesTheSuccessorsSnapshot`.
  - In each regression, the predecessor is held in the store's write of the run's shutdown reason, which is after its question upsert has landed, with an active run attempt. The successor starts, then the hold is released. Assertions:
    - the successor has no blockers;
    - the stored and raw record keeps Q and its "staging" draft;
    - the successor tracks `(live: [Q], introduced: [Q])`.
  - **Mutation check (`04aa9daf`).** With chaining disabled (`predecessor = nil`), both regressions failed on exactly the defect: stored `[]`, draft lost, Q missing from the raw record. The other 14 tests passed. The fix was restored before every later job.
- **A R4-01-R2 (P2), fixed: failed removals keep IDs and lane ownership.**
  - `enqueueQuestionSnapshotRemoval` records each result. A failure goes into `shutdownFailedQuestionSnapshotRemovals[ObjectIdentifier(lane)]` (weak lane, `tabID`, IDs) and is never dropped before a receipt; a later success subtracts its IDs.
  - Every preparation retries those removals after joining the tail and before capture.
  - A retry that still fails is a Stage A blocker ("…could not be removed from its saved recovery state"). It returns before any new write, so nothing is upserted over it.
  - Fixture: `testFailedQuestionSnapshotRemovalIsKeptAndRetriedBeforeTheNextStageA`.
  - Limits:
    - a retired lane's entry is kept but not retried (its lane can no longer write);
    - a deallocated lane's entry is dropped.
- **B N1 (P1), fixed structurally; UI runtime pending.** `WindowContentView`'s lifecycle callbacks moved into one stable production container, `WindowAdmissionLifecycleHost` (a `ZStack` owning `onAppear`/`onDisappear`). The admission branch (`admittedContent(_:)`) sits beneath it, and the title, background, accessor and sheet modifiers stay on the host.
  - Fixture: `testAdmissionBranchChangeNeverReportsTheWindowContentDisappearing` in `WindowCloseCoordinatorLifecycleTests`. It is a real `NSHostingView` in an offscreen borderless window that is never ordered front, with no providers. Across pending → admitted:
    - the admitted branch appears and the pending leaf's own `onDisappear` fires, so the fixture observes branch disappearance;
    - the host reports no `onDisappear` and no second `onAppear`.
  - **Not reproduced.** A control with the same modifiers on a bare inline `@ViewBuilder` conditional (the pre-fix shape) also reported no outer disappearance in this fixture, in two runs (initial and inline-shape; tickets not retained). The control was removed. So the fixture does not demonstrate B's predicted teardown, and the fix is defensive: the callbacks no longer depend on how SwiftUI treats modifiers on a changing conditional. The real `WindowGroup` scene was not run (O3 owner pending).
- **B N4, fixed at the observed stores and the edit entry; UI runtime pending.** `AgentModeChatDetailView` and `AgentInputBar` observe narrow stores, not the view model, so `.disabled(agentModeVM.isShutdownFrozen)` could stay stale.
  - The freeze is published on `beginShutdownFreeze`/`endShutdownFreeze` through `AgentComposerProps.isShutdownFrozen` (`ui.composer`) and `AgentRunInteractionUISnapshot.isShutdownFrozen` (`ui.runInteraction`).
  - `AgentInputBar` disables from its props. The elicitation, ask_user and native user-input cards disable from the snapshot.
  - Edits are refused at mutation entry rather than accepted and then lost:
    - `ResizableTextField`'s `textView(_:shouldChangeTextIn:replacementString:)` asks `acceptsEdits` live (`!isShutdownFrozen()`), so typing, text paste, drop and snippet insertion are refused before the text view accepts them;
    - image paste or drop is consumed and not attached while frozen;
    - `composerDidChange` is not filtered.
  - Fixture: `testShutdownFreezeIsPublishedThroughTheObservedComposerAndAnswerStores`.
  - The SwiftUI disabled rendering and the AppKit refusal are compile-checked plus neighbour suites only.
- **B N3 (unused `revokeCleanExit`/`Revocation`), deferred.** Not changed in this round.
- **B N5 (wording after a late successful clean write, recomputed prompt flag), deferred.** No auto-termination was added, per the task.

## Jobs: R1 fixes (superseded by the post-R2 follow-ups for the files they changed)

| Ticket | Operation | Result |
|---|---|---|
| `f7ca0e37-0000-45b6-a379-724000a8a782` | swift-build RepoPrompt | exit 0; one new warning (unused `await predecessor?.value`), fixed with `_ =` before the jobs below |
| `28236640-3792-4de2-884c-f4ddca0d8c47` | test `AgentRecoveryResetBoundaryTests` | 16/16 (before the warning fix; superseded by `3be21dcb`) |
| `04aa9daf-e907-49a1-b45e-e6693ce6488b` | test `AgentRecoveryResetBoundaryTests` with chaining disabled (mutation check) | 10 failures, all in the two supersession regressions; restored |
| — (2 runs, tickets not retained) | test `WindowCloseCoordinatorLifecycleTests` with a bare-conditional control | 7/8 and 7/8; the control did not reproduce; removed |
| `9020e4bd-43a2-45ea-b359-89b31d97b02e` | test `WindowCloseCoordinatorLifecycleTests` | 7/7 |
| `3be21dcb-489d-4e31-857f-2fe783b3eb75` | test `AgentRecoveryResetBoundaryTests` | 16/16 |
| `9b710874-d731-4ef4-b995-390af91cace8` | test `AgentLifecycleShutdownCoordinatorTests` | 24/24 |
| `478735b0-a9dd-42a8-bee7-1bcace69e1b0` | test `WindowCloseCoordinatorPolicyTests` | 3/3 |
| `37b2479a-fcde-4f18-98c4-c8ba8acb64bb` | test `AgentRecoveryComposerPersistenceControllerTests` | 21/21 |
| `8b6458d2-ba9f-4acc-b795-b0e304eb277c` | test `AgentRecoveryCoordinatorTests` | 36/36 |
| `540c266d-2ccb-49c2-808a-a95bb583e716` | test `SnippetPaletteShortcutRoutingTests` (builds `ResizableTextField`) | 2/2 |
| `ed3f802e-bab9-4f3e-a19b-b242f415b4f7` | test `AgentInteractionLatencyProbeTests` (builds `ResizableTextFieldFeatures`) | 22/22 |
| `f1af7111-a21a-4d29-9705-e8838631feb3` | test `AgentModeViewModelDelegatedQuestionTests` (resolution funnel) | 26/26 |
| `db204fa1-53cb-4985-af61-535816f07e14` | lint | failed: `indent` on the host's modifier chain; dedented |
| `9627aad1-ac45-4ea5-aebe-a9bdcec19136` | lint | failed: `docComments` (local func comment) and `preferCountWhere` (test helper); fixed |
| `524f3d8c-424e-41f7-94c0-0810098b3810` | lint | exit 0 |
| `40ff71a8-6cbc-4d4c-a94e-08caab0bf1be` | test `WindowCloseCoordinatorLifecycleTests` (after the lint fixes; compiles every target) | 7/7 |

The lint fixes after `3be21dcb`…`f1af7111` changed whitespace and one comment in source, and `count(where:)` in a test helper; `40ff71a8` recompiled and passed after them. No flake was observed, so no `dev-test-artifact` reruns. The index stayed empty and HEAD stayed `b2ee22a8`.

## Jobs: boundary implementation (admission seal, verified Stage A mark, owned clean write; superseded by the R1 fixes for the files they changed)

| Ticket | Operation | Result |
|---|---|---|
| `16a96cb8-5848-4f46-987d-9b3887d3978d` | swift-build RepoPrompt | exit 0; the only warning in a touched file is pre-existing (`WindowStateManager.swift:157`) |
| `671808c8-a461-495d-9190-abc65e1367a5` | test `AgentLifecycleShutdownCoordinatorTests` | 24/24 |
| `9f7fc6bf-2aea-48ab-97d3-ca84732265be` | test `WindowCloseCoordinatorLifecycleTests` (with the new scene-admission test) | 6/6 |
| `83ceb163-aec7-403f-818b-ecfc3c70b1bb` | test `WindowCloseCoordinatorPolicyTests` | 3/3 |
| `2c09fc7d-7748-4ea2-b694-075fcff2e063` | test `AgentRecoveryStartupCompositionTests` (registers windows through `WindowStatesManager.shared`) | 8/8 |
| `45bcdb16-e2e3-4c39-94f8-58a64212a23a` | test `AgentRecoveryResetBoundaryTests` | 12/12 |
| `142c4a31-a07d-4c96-b351-f68785ae6654` | test `WindowStateDisplayedTitleTests` (registers windows) | 2/2 |
| `66ab1985-b1ae-454b-b01f-b53e21dd3a5b` | test `AppQuitPolicyTests` | 4/4 |
| `ea8ad71a-0f15-49a4-8298-fbfac9bcd791` | test `WindowSessionRestorePersistenceGateTests` | 7/7 |
| `ed818772-b206-48a4-9540-b924f8841a58` | test `WorkspaceManagerInitializationWaitTests` (initial activation path) | 6/6 |
| `485d9e18-8839-4086-bcd4-62d87a9f8159` | lint | failed: `docComments` on the pre-existing `// Tracks whether initialization is complete` beside the new property; changed to `///` |
| `77f0b4f8-f3f8-4c50-a113-19a5e5b0e174` | lint | exit 0 |

The lint fix only changed a comment, after the compile and tests. The `AgentRecoveryStore` / `AgentRecoveryCoordinator` changes this round are comments only (gate and launch-mark docs), so `AgentRecoveryStoreTests` and `AgentRecoveryCoordinatorTests` were not rerun. No flake was observed, so there were no `dev-test-artifact` reruns.

## Jobs: pre-R1 closure (A R4-01 exact IDs, B R4-3 registration seam; superseded by the boundary implementation for the files it changed)

| Ticket | Operation | Result |
|---|---|---|
| `1e46fa2e-7b06-4fdf-afc9-8c76359a22a9` | swift-build RepoPrompt | exit 0; the warnings in touched files are on pre-existing lines (`AgentModeViewModel.swift:2321`, `:2572`, `:4061`; `WindowStateManager.swift:157`) |
| `c5f196d5-a625-4944-8652-33b3395bab80` | test `AgentLifecycleShutdownCoordinatorTests` | 23/23 |
| `28f165a0-fe04-4a81-8e1d-cf8ee08c6d4e` | test `AgentRecoveryResetBoundaryTests` | 12/12 (superseded by `65e5f26a`) |
| `37c982a7-05d9-4725-a8c8-133e7e60381c` | test `AgentRecoveryCoordinatorTests` | 36/36 |
| `80e22724-568e-4510-8e21-71d271533890` | test `AgentRecoveryStoreTests` | 17/17 |
| `a5feeb92-74ec-43fa-9d36-fb8322e2fef8` | test `AgentRecoveryStartupCompositionTests` (registers windows through `WindowStatesManager.shared`) | 8/8 |
| — | `make dev-test FILTER=WindowCloseCoordinatorDecisionTests` | rejected before build: the file's suites are `WindowCloseCoordinatorLifecycleTests` / `…PolicyTests`; no ticket |
| `dc82d151-58ef-49ba-99cb-fbade2bee850` | test `WindowCloseCoordinatorLifecycleTests` (registers windows on a manager) | 5/5 |
| `054a394f-883a-49ab-a1fe-95f3553b4425` | test `AgentModeViewModelDelegatedQuestionTests` (drives the resolution funnel) | 26/26 |
| `24de4478-b5c6-4a67-9b05-f36701ba6348` | lint | failed: `trailingCommas` in the new test helper; fixed |
| `582e0254-9dce-4f8d-9d2d-27d8fd688460` | lint | exit 0 |
| `65e5f26a-9353-4abc-9246-0489681066ad` | test `AgentRecoveryResetBoundaryTests` (after the lint fix) | 12/12 |

Not rerun this round, because their paths are unchanged with no shutdown tracking (the funnel's refresh is a no-op unless a window's Stage A tracked that ID): `AgentRunMCPToolServiceWaitTests`, `AttentionNotificationAdmissionTests`, `AgentModeRunServiceLifecycleTests`, and the other neighbour suites in the table below. No flake was observed, so no `dev-test-artifact` reruns.

## Jobs: review fixes (superseded by the pre-R1 closure for the files it changed)

| Ticket | Operation | Result |
|---|---|---|
| `6e198aff-72f7-421e-a0e6-ea2c39578483` | swift-build RepoPrompt (review-fix source) | exit 0; the only warning in touched files is pre-existing (`AgentModeViewModel.swift:2321`, `RemoteHostCatalog = .shared`, identical at HEAD:2310) |
| `7d53b36a-aa39-4d7f-8df0-6297cf58ab82` | test `AgentLifecycleShutdownCoordinatorTests` (rewritten on the real store) | 20/20 (superseded) |
| `5d47b01e-580b-48be-962e-4f6cb6bbfad7` | test `AgentRecoveryResetBoundaryTests` | 10/10 (superseded) |
| `be7cfae7-03b5-40d3-ad44-a233003d832c`, `d550d3f8-3606-486f-9daf-b957603f66f2`, `9639c81e-7845-424a-a92e-c0fb5d9d79a0`, `6bfea43f-5d85-402a-85a0-3cb7eaf970fe`, `7d8664d5-d38f-43f4-9a03-2853c7d018c8` | coordinator 36, queued-input 10, store 17, VM producer admission 21, startup reconciliation 16 | all passed (superseded by the final reruns below) |
| `263cb44a-129e-4307-927a-f50e3fbcaddb` | test `AgentModeViewModelDelegatedQuestionTests` (calls the guarded `submitAskUserResponse` / `mcpResolvePendingInteraction`) | 26/26 |
| `1136c985-5bdf-42b6-9d26-4fcdf5830dec` | test `AttentionNotificationAdmissionTests` | 28/28 |
| `3df1de3f-6578-4e0b-9bb9-e56b4a9c9e8b` | test `AgentInteractionLatencyProbeTests` | 22/22 |
| `5cc4b6cf-0647-47f5-94ee-8be0c537ed5e` | test `SnippetPaletteShortcutRoutingTests` | 2/2 |
| `9930ca10-a89d-42fb-98b3-e3101c72c1a1` | test `AgentRunMCPToolServiceWaitTests` | 54/54 |
| `59592081-53b0-42a2-bd59-09623137f632` | test `AgentModeRunServiceLifecycleTests` | 182/182 |
| `c6fcfd26-7336-4f8d-8687-c4dab4a1447e` | lint | failed: `redundantSendable` on the two new package enums in `AgentRecoveryStore.swift`; fixed |
| `a640954e-2470-47e0-bb1d-a5dbb3b733c8` | lint | exit 0 |
| `75615c5f-cf1b-4496-b5ca-07e872bd944e`, `b8ddba33-6332-4eca-9f22-6f6f5b3aca0d` | lifecycle coordinator 20/20, recovery coordinator 36/36 (after the lint fix) | passed |
| `5912c6b2-5cfc-42a6-9918-e8e746718359` | test `AgentRecoveryStartupCompositionTests` | 8/8 |
| `16d8038b-d52f-43e4-8142-c02ec005d697` | test `AgentRecoveryPendingHandoffTests` | 10/10 |
| `44be1147-60aa-4012-9068-b1fefd1f1467` | test `AgentRecoveryComposerPersistenceControllerTests` | 21/21 |
| `55fa143a-9111-45d9-acfc-c8880b746742` | test `AgentSessionRecoveryIntegrationTests` | 5/5 |
| `19c1f589-42c8-4b63-8ebb-f86ed99b0ba9` | test `AgentTranscriptSaveMaxWaitTests` | 13/13 |
| `f7f014cb-fbe0-440b-80de-ae62051666ed` | test `AgentStaleResetOwnershipTests` | 38 passed, 2 skipped (the opt-in scale reports below), 0 failed |
| `9af25353-4ff7-4178-a5e2-699422cdc770` | test `AgentModeChatSwitchActivationTests` | 48/48 |
| `1e2b01b5-3636-495b-98b5-a2c9a24000c6`, `636dafa8-1ffe-4d3c-b066-f84c180a6055`, `d7cc4a15-7d5d-466e-bbfb-3ba6499c8c32`, `6cd2eebc-b39d-413a-b8b9-5eb78c82036d` | `AppQuitPolicyTests` 4, `WindowCloseCoordinatorPolicyTests` 3, `WindowCloseCoordinatorLifecycleTests` 5, `WindowSessionRestorePersistenceGateTests` 7 | all passed |
| `bdf5604f-e961-4e1c-b9b7-8881ea726e4e`, `e6494d91-1a6c-4c10-ac93-d97b6a3033ee`, `40385b91-e5f2-4fec-a3ea-c7b1b6aca9e5`, `c68c3abd-d40f-4b73-aafe-106564bbc101`, `223d115d-3b46-4473-8ce1-42726bd8bab6` | queued-input 10, store 17, VM producer admission 21, startup reconciliation 16, reset boundary 10 | all passed |
| `b7fd016c-039b-44f8-9a8d-39b73dd0cdb2` | test `AgentLifecycleShutdownCoordinatorTests` (after the post-write newcomer check) | 21/21 |
| `219ea7c0-1ba2-460e-876b-8151ab3a4e2b` | test `AgentRecoveryResetBoundaryTests` (with the `ask_user` answer assertion) | 10/10 |
| `920e6361-7e57-40fd-9437-1560f1bd0922` | lint (final source) | exit 0 |
| `03707d67-2a9b-480f-a5fb-65bf41f06445`, `839b5e8c-a661-4fd9-889b-4b0d4d7caebc`, `adc85ccc-7957-4c13-a8e3-e21d1771a3de`, `70fa2fcc-b3d5-44aa-aa79-3c3e2a0b3a9b`, `66fab22c-f510-457e-9e4c-c08d32000883`, `c7505d13-533e-43c5-b560-0be9a5f0d3e9` | `dev-test-artifact` flake reruns (coordinator ×3, reset boundary ×3, before the post-write check) | all exit 0 |
| `05877699-1b83-4de6-beaa-8f98bab421d5`, `cf70150f-449d-4f8a-8641-afc7f72ddb18`, `6600a76a-8ffd-43d5-9cac-98c30d0e6266` | `dev-test-artifact` coordinator ×3 (final) | all exit 0 |

### Source stability (review fixes)

The final source differs from the 16-suite batch (`5912c6b2`…`223d115d`) by one change: the post-write newcomer check in `AgentLifecycleShutdownCoordinator.runFinalization`, which only the coordinator suite calls. Its reruns are `b7fd016c`, `219ea7c0` (a test-only assertion) and lint `920e6361`.

These neighbour jobs ran before the lint-only `Sendable` removal and that check: `263cb44a`, `1136c985`, `3df1de3f`, `5cc4b6cf`, `9930ca10` and `59592081`. Neither change touches their paths.

### Skips

`AgentStaleResetOwnershipTests` skips two opt-in advisory reports that need `RPCE_RUN_SCALE_TESTS=1`. Neither was touched by R4:
- `testRestartPhase0LongTextOnlyStreamSaveTimelineReport`
- `testRestartPhase0LargeSessionSaveCostReport`

## Jobs: initial delivery (before the reviews)

| Ticket | Operation | Result |
|---|---|---|
| `fc532486-0ee0-4d21-ac9f-40f11acbb456` | swift-build RepoPrompt | failed: `Task<()?, Never>` vs `Task<Void, Never>` (teardown task); fixed |
| `aa1db578-5ede-4dbd-b753-6ffd3de65c3c` | swift-build RepoPrompt | failed: `ProcessTermination` not in scope; fixed with `import RepoPromptPlatform` |
| `9125bb20-5a66-4059-98b3-12775b50eaba`, `9549e97e-105e-419a-8606-62a132cd9658` | swift-build RepoPrompt | exit 0 |
| `e77dbf3a-3366-4bad-ab6d-8e931045b079` | test (unquoted `FILTER` alternation; ran only the first suite) | failed: test compile error, `Task<()?, Never>` in a fake participant; fixed |
| — | `conductor test --filter 'A\|B\|…'` | rejected before build (alternation does not resolve to a suite; no ticket); suites then ran one per job |
| `be5a6860-9dc1-4362-b500-c75ee67f912c` | test `AgentRecoveryCoordinatorTests` | 34/35. The fixture re-enabled writes before the predecessor's failing hand-over flush settled. Test-only fix: join settlement through a refused admission. Rerun `31b7afad-5103-4481-99d4-262c3d3d0af9` passed. |
| `82ddcda8`, `510110af`, `8833a27a`, `f98c8a30`, `256aaa06`, `cf7d5b86`, `f43a8549`, `2651f122`, `6dfff137`, `057b5910`, `3000a835`, `dfbc0e65`, `e0819828`, `91c24afc`, `c505f5eb`, `3081f0eb`, `325d7e8d`, `fef3adef` | initial suite runs | all passed; superseded by the review-fix reruns above |
| `9e44b0e9-dec9-410c-a3b3-22768b1ef966` | lint | failed: style findings; fixed |
| `e8fdc5ed`, `e39227f6`, `5a2093b7`, `b1460133` | reruns and lint after the deadline/cancel fix | passed; superseded |

## Covered behavior (fixtures)

- Stage A failure → Cancel → continued interaction (disk: `shutdownInProgress`, `running`) → a second attempt quits cleanly. The clean mark is committed last and only once.
- Layout/released-input blockers, then Retry.
- One absolute deadline per user attempt:
  - its expiry is captured at the request, and a delayed deadline task never extends it;
  - Stage B gets only the remainder, and only Retry arms a fresh 8 s;
  - work that finishes after the expiry never crosses the boundary or marks clean.
- A non-cooperative Stage A task never delays the prompt, and its late completion is fenced.
- Cancel fences late Stage A side effects: no `shutdownInProgress` after Cancel's `running`, and no participant prepared.
- Stage B has no Cancel; a dismissed prompt shows its own reasons again. Retry flushes again without a second teardown.
- The Stage A launch mark is verified: a held mark times out Stage A, and a failed one blocks it. Nothing is torn down until Retry confirms it.
- The clean mark at the persistence boundary:
  - a failed clean write needs no correction;
  - a delayed acknowledgement is never corrected, and Quit Anyway replies at once;
  - Retry joins a pending write: its prompt is bounded, a late ACK never terminates by itself, and there is one write and one finalization;
  - a delayed write that wrote nothing is released, and Retry authorizes afresh.
- A stuck Stage B teardown times out, and Quit Anyway does not finalize late.
- Window close:
  - never writes a launch mark;
  - honors the forwarded veto before the point of no return;
  - duplicate requests join;
  - Close Anyway keeps a later quit from marking clean.
- App quit supersedes a Stage A window close, and joins (never repeats) a window teardown already past its point of no return.
- Window admission during an app quit:
  - in Stage A, a window is admitted and frozen, and the attempt fails; Retry preserves the layout again and prepares it;
  - Cancel unfreezes it, and a cancelled quit never seals;
  - admission is sealed at the point of no return, and a refused window is untouched;
  - a window arriving while the clean write is gated is refused, and the clean claim holds without correction;
  - the seal persists after completion, and a window close never seals;
  - a real scene `WindowState` stays inactive until admitted, and a refusal never activates.
- The finalized-close authorization is one-shot.
- Scoped freeze refusal on queued, direct, dispatch-commit and handoff routes. Unaffected owners keep admitting, an app freeze covers lanes claimed later, and Cancel reopens.
- Stage A vetoes unsaved predecessor input without writing.
- Stage A persists the composer, question snapshots and the first run shutdown reason; the reason is kept across attempts.
- Question snapshots:
  - writes are exact by interaction ID: an earlier launch's snapshots, and a same-launch closed owner's snapshots, survive a reopened owner's writes;
  - re-upserting replaces in place;
  - only exact removals (live resolution, the recovery list) erase a snapshot;
  - they round-trip, and a stored secret answer makes the record unreadable.
- A shutdown reason without terminal evidence:
  - keeps `uncertainInputHoldReason` nil;
  - still yields a crash hold for the run and its intent next launch;
  - leaves `shutdownInProgress` proving neither a clean exit nor a launch reason.
- VM:
  - Stage A joins an in-flight save and flushes again, and skips a partially hydrated session without writing it.
  - A secret answer vetoes Stage A, answers are frozen, and the secret never reaches disk.
  - `ask_user` partial answers are preserved.
  - Answers (including elicitation) are refused while frozen, before any mutation.
  - Cancel removes only the snapshots this window introduced. A closed owner's same-launch question survives an empty Stage A, Cancel, an adopted re-capture and an untracked resolution.
  - Live resolution removes exactly its snapshot.
  - Teardown keeps queued intents and preserved questions, and the final flush writes late content.
  - Failed terminal evidence is retried, storage only.
  - Native user-input drafts are reseeded per request.

## Not run / limits

- No live acceptance, and no visible app quit or close.
- Not covered by tests:
  - NSAlert prompts and the Retry/Quit Anyway user interaction;
  - delegate-proxy routing and termination reply timing;
  - SwiftUI card identity, and the disabled composer's rendering and AppKit edit refusal (B N4; only the store publication is fixture-tested);
  - the real window scene's lifecycle across admission (B N1; the offscreen host fixture did not reproduce the predicted teardown, see its disposition). UI runtime is pending (O3 owner).
- Failed question-snapshot removals on a retired lane are kept but not retried (A R4-01-R2).
- `mcpResolvePendingInteraction`'s frozen refusal is not fixture-tested: it needs an MCP-controlled run. Its unfrozen paths pass in `AgentModeViewModelDelegatedQuestionTests` and `AgentRunMCPToolServiceWaitTests`.
- The recovery-list question rows (copy to an empty composer, dismiss) are not driven through the VM.
- The delayed clean acknowledgement is handled under main's implementation interpretation, not an Owner Decision. No owner decision is open for B R4-3 or R4-02.
- Admission limits (compile-checked or source-reasoned only):
  - SwiftUI New Window or tab "+" during a real quit, the inert "RepoPrompt is quitting" shell and the one blank pre-admission frame were not run.
  - A refused window may already have claimed the initial refresh deferral for a new window (`claimInitialRefreshDeferralForNewWindow`). That waiter then ends by its own timeout.
  - The registry-level refusal (`registerWindowState` returning `false`) is not fixture-tested: sealing `WindowStatesManager.shared` would be irreversible for the test process. The coordinator seal and the `WindowState` refusal are tested separately.
- Accepted limits, each detailed in its disposition above:
  - B R4-2: no per-session marker for a transcript-only failure;
  - B R4-6: the queued-intent fixture has no VM projection;
  - A R4-01: the same-launch reopen is not driven through a second real VM.
- The `registerWindowState` admission is compile-checked and exercised (admitted path) by the window-registering suites.
- Deferred: B R4-8 and R4-9.
- No full-root or `dev-test-parallel` run, and no `make dev-format-check` beyond lint.
- `Scripts/check-agent-context` was not run; main owns plan, reviews and allowlist.
