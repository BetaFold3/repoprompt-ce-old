# Step 7-F2 worker report
Scope: read when the task touches lossless restart Step 7-F2 (blocked Send-now feedback for scheduled sends) implementation or review evidence.
Authority: Reference
Last-verified: 2026-10-26

Covers finding F2 in `2026-10-18-lossless-app-restart-spec.md` ("Send now" on an overdue new-session schedule silently does nothing). Base: HEAD `03b845d1`; the change is uncommitted and unstaged. The visible app was not launched, relaunched or stopped. No Oracle, `ask_user`, `context_builder` review or plan, or other agents were used. The XCTest ledger, `Scripts/source_layout_guardrails.sh` and the spec are untouched. No new source or test files were added. The reviewed first-pass diff is `prompt-exports/restart-fixes/fix-f2-review.diff`. After the review fixes, the full step diff is `prompt-exports/restart-fixes/fix-f2-current.diff` and the delta against the reviewed diff is `prompt-exports/restart-fixes/fix-f2-r1-delta.diff`.

## Which early return explains the observation

**Reproduced; likely explanation: the new-session recovery gate in `evaluate()`**, not an early return of `confirmAndSendNow`. A test reproduces the observed symptom through this gate. The live run was not observed, so the alternatives below are judged unlikely from the code and the reported UI; none was verified against the live session.

Line numbers below are HEAD `03b845d1`.

- The live record was durable `needsConfirmation` / `missedWhileClosed` with `isNewSessionStart`.
- The UI path is `AgentModeViewModel.sendScheduledSendNow` (`AgentModeViewModel+ScheduledSend.swift:889-965`). It drains, resyncs from disk, persists the Run-alongside change, then calls `completeUserSupersession` (`:954`). Only if that succeeds does it call `confirmAndSendNow` (`:958`) and return `nil`.
- Each early return of `confirmAndSendNow` (`AgentScheduledSendCoordinator.swift:995-1027`), checked in turn:
  - **Pending confirmation obligation (`:1002`): unlikely, unverified live.** A durable `needsConfirmation` record is not eligible for automatic admission without consent (`eligibleState`, `:1605`), so no evaluation pass installs a new obligation for it. `completeUserSupersession` either cleared an existing obligation or found none (`:1129`). Had a newer decision existed, it would return `false` (`:1130`) and the UI would show `scheduledSendConfirmationChangedMessage`, which is not silent.
  - **Startup admission closed (`:1001`): unlikely, unverified live.** The relaunch had finished recovery; the recovery cards (crash holds, the Dismiss and It stopped actions) were being used. With admission closed, nothing evaluates at all.
  - **Transfer hold (`:1001`): unlikely, unverified live.** Holds exist only for a `.dispatching` attempt. The record was `needsConfirmation`, and `sendScheduledSendNow` refuses `.dispatching` itself (`:931`).
  - **No candidate (`:1006`): unlikely, unverified live.** The banner was projected from the hydrated session, and the same host lists it as a candidate.
- So consent was most likely installed. The evaluation then reached the new-session recovery gate (`:1729-1739`; the same check at the handoff, `:1345-1356`). The gate skipped the schedule because a host reported `hasUnresolvedRecoverySession`: the workspace held many unconfirmed crash holds from the kill tests. Nothing about this is shown anywhere.
- Run alongside only changes the workspace-busy gate (`requiresWorkspaceGate`). The recovery gate ignores it by design, which matches the record changing only `runAlongsideOtherSessions`.
- The new dispatch test `testSendNowOnRecoveryBlockedNewSessionShowsWhyAndDispatchesOnceWhenResolved` reproduces this. Both menu items return `nil`, the record is unchanged apart from `runAlongsideOtherSessions`, nothing dispatches, and the schedule is sent once the blocker clears. Before this change the only observable difference was the dispatch.

A second, related gap: when a schedule is held because its **own** session has unresolved recovery, the busy branch skips it (`:1703`) with no reason. A workspace restriction does this to every session in the workspace. This is covered as well.

## Files changed and why

AgentCore:

- `Runtime/Scheduling/AgentScheduledSendCoordinator.swift`
  - New `AgentScheduledSendRecoveryBlocker`. It lists the interrupted sessions (crash holds), restricted sessions and unresolved open sessions, plus flags for a workspace restriction, a recovery action in progress, R6 runtime ownership, the destination session, and an unattributed report. It also has `merge`.
  - New `AgentScheduledSendNowRefusal`, one case per early return: `startupAdmissionClosed(state)`, `transferHeld`, `confirmationPending`, `scheduleNotFound`.
  - New `AgentScheduledSendDisposition`: `rejected` / `blocked` / `progressing`.
  - New host requirement `scheduledSendRecoveryBlocker(inWorkspace:excluding:)`, implemented by both conformers (no default witness; see Review fixes, B F2-R4).
  - `confirmAndSendNow` is now `@discardableResult` and returns the disposition. Every early return yields `.rejected(reason)`. After its `evaluate()` it returns `disposition(scheduleID:)`.
  - New `disposition(scheduleID:)` and `recoveryBlocker(scheduleID:)`.
  - `evaluatePass` records a blocker only at the two branches where recovery decides:
    - the new-session gate, which now gates on the merged blocker being non-nil (one host walk; admission unchanged, see B F2-R4);
    - the own-session busy branch, when a busy state reports `hasUnresolvedRecovery`.

    The blocker is kept across the scheduler's own first-eligibility write so the banner doesn't flicker.
  - It posts `.agentScheduledSendDispositionDidChange` (`sessionID`, `scheduleID`) only when a blocker appears, changes or clears.
  - Admission never reads the recorded blockers.
- `Runtime/Recovery/AgentRecoveryCoordinator.swift`: new `unresolvedSessionSummary(inWorkspace:excluding:)`. `hasUnresolvedSession` is now `!summary.isEmpty`, the same predicates as before (unconfirmed crash holds in the workspace, restricted sessions, the workspace restriction).
- `Runtime/Recovery/AgentRecoveryStartupReconciliation.swift`: new `AgentRecoveryRestrictions.restrictedSessionIDs(inWorkspace:excluding:)`, which `hasUnresolvedSession` now uses, and the new `AgentRecoveryWorkspaceUnresolvedSummary`.

App:

- `ViewModels/AgentModeViewModel+ScheduledSend.swift`
  - `scheduledSendRecoveryBlocker` itemizes the same inputs `hasUnresolvedRecoverySession` used. `hasUnresolvedRecoverySession` is now `scheduledSendRecoveryBlocker(...) != nil`, one predicate.
  - `sendScheduledSendNow` maps `.rejected` to `scheduledSendNowRefusalMessage(_:)`, shown as the banner's action error. `.blocked` and `.progressing` return `nil`, because consent is recorded and the reason appears in the banner.
  - New observer of `.agentScheduledSendDispositionDidChange`; it calls `syncComposerUIState` for matching tabs and is torn down on detach.
- `ViewModels/AgentModeViewModel.swift`: the observer property.
- `ViewModels/AgentModeViewModel+ComposerUI.swift`: passes `scheduledSendCoordinator?.recoveryBlocker(scheduleID:)` into the props.
- `ViewModels/UI/AgentComposerUIModels.swift`
  - `AgentScheduledSendProps.recoveryBlockedMessage`; it is `nil` while dispatching or unreadable.
  - Plain wording via `recoveryBlockedMessage(for:)`, first match wins: workspace restriction → own session → interrupted sessions ("Will send after N interrupted sessions in this workspace are resolved: choose It stopped (not Dismiss) in Needs Attention…") → restricted → recovery action → runtime → other open sessions → generic.
- `Views/Components/AgentScheduledSendBanner.swift`: shows the message as an orange, 2-line caption with a hover tooltip. The banner height grows by 26 pt when the message is shown and by 14 pt when an action error is shown (B F2-R6).

Docs:

- `docs/context/agent-scheduled-messages.md`: one bullet on blocked Send-now feedback, and Last-verified set to 2026-10-26.

Unchanged: the gate, its handoff counterpart, revision-scoped consent (`confirmedOverrides`), catalog scope, Dismiss, and It stopped.

## Tests (new or extended)

- `AgentScheduledSendCoordinatorTests`:
  - `testSendNowOnRecoveryBlockedNewSessionReportsBlockedUntilBlockerClears` loops over a crash hold, a session restriction and a workspace restriction. For each one:
    - both Send-now variants return `.blocked(blocker)` and nothing dispatches;
    - one change notification is posted;
    - a re-evaluation with the blocker unchanged stays blocked (the Dismiss analogue);
    - clearing the blocker dispatches once with the consent (`allowsNeedsConfirmation`, `runAlongside`) and announces the change;
    - a further evaluation leaves exactly 1 dispatch.
  - `testOwnSessionUnresolvedRecoveryReportsBlockedDisposition`.
  - `testConfirmAndSendNowReportsEveryRefusalWithoutInstallingConsent` covers each early return: admission awaiting and failed, transfer hold, pending confirmation, not found, and the accepted path.
  - `FakeScheduledSendHost` gained `recoveryBlockers`.
- `AgentScheduledSendDispatchTests` (real view model):
  - `testSendNowOnRecoveryBlockedNewSessionShowsWhyAndDispatchesOnceWhenResolved`: Send now and Run alongside each return `nil`; the banner props show the reason; no dispatch; after release, exactly one dispatch.
  - `testSendNowRefusedByClosedStartupAdmissionReturnsAReason`.
  - `testSendNowRefusalMessagesAreDistinctForEveryRefusal`.
  - `testRecoveryBlockedBannerWordingNamesWhatToResolve`: crash hold (1 and 2 sessions), session restriction, workspace restriction, own session, unattributed, none, and dispatching.
- `AgentRecoveryStartupCompositionTests.testRecoveryListRowsResolveSessionsFromTheCatalogAndOpenAcrossWorkspaces` (real host and recovery coordinator): after **Dismiss** of the crash hold, `hasUnresolvedRecoverySession`, `unresolvedSessionSummary` and `scheduledSendRecoveryBlocker` still name the held session. After **It stopped** they no longer do.
- `AgentRecoveryCoordinatorTests.testPreviousInstanceOpenEvidenceHoldsAdmissionUntilExplicitConfirmation`: the summary lists the crash hold, a stale confirmation keeps it, and the exact confirmation empties it.
- `AgentRecoveryStartupReconciliationTests`: summary of a restricted session (`testFailedScheduleTransferCommitStaysHeldAndRestrictsItsSession`), and workspace restriction and `restrictedSessionIDs` (`testStartupSweepUnionsClosedSessionsAndScopesEachRestriction`).

## Validation (first pass)

- `make dev-build`: pass (exit 0), run once before and once after the lint fixes.
- `make dev-test FILTER="'AgentScheduledSendCoordinatorTests|AgentScheduledSendDispatchTests|AgentScheduledSendPersistenceTests|AgentScheduledSendReceiptTransferTests|AgentScheduledSendNonCodexMandatoryTests|AgentScheduledMessagesViewModelTests|AgentRecoveryCoordinatorTests|AgentRecoveryStartupReconciliationTests|AgentRecoveryStartupCompositionTests|AgentRecoveryReconciliationTests|AgentComposerTabOwnershipTests|AgentComposerSubmissionAttemptTests|AgentComposerFocusRequestTests|ComposerFocusTokenPolicyTests|AgentModeSidebarSessionBuilderTests'"`:
  - **pass, 341 tests, 0 failures, 15 suites** on the final source;
  - per suite: Coordinator 55, Dispatch 57, Persistence 34, ReceiptTransfer 11, NonCodexMandatory 7, ScheduledMessagesVM 9, RecoveryCoordinator 45, StartupReconciliation 21, StartupComposition 12, RecoveryReconciliation 52, ComposerTabOwnership 5, ComposerSubmissionAttempt 8, ComposerFocusRequest 4, ComposerFocusTokenPolicy 4, SidebarSessionBuilder 17;
  - an earlier run before the lint fixes was also 341/0.
- `make dev-lint`: the first run failed with two findings, both fixed:
  - `extensionAccessControl`: a 3rd `package` member in the host extension. The new default witness is now internal; both conformers implement the requirement.
  - `no_swiftui_help_modifier`: changed to `.hoverTooltip`.

  The final run passed (exit 0).
- `Scripts/check-agent-context`: pass. Its one warning is the existing AGENTS.md route-count warning.

## Not run

- Full `make dev-test`, `make guardrails` (no files added or moved) and `gitleaks` (nothing pushed).
- Rendered SwiftUI or the visible app: banner layout, the 2-line wrap at the narrowest composer width, and the tooltip are unverified. No live recovery run.

## Open questions

- **No link.** The banner says "Needs Attention…" in text but has no button to open it. A link would need new banner actions.
- **Wording for restrictions** ("unchecked session … Restart RepoPrompt to check again") covers three restriction kinds. A held transfer can also lift without a restart, once its transfer resolves. Owner review of the wording is welcome.
- **Inference, not verified:** a `scheduled` (not yet durable `needsConfirmation`) record that is overdue at launch, with no obligation installed and no armed observation, could get a fresh `missedWhileClosed` obligation from the `evaluate()` that runs when the supersession token is released, just before `confirmAndSendNow`. That Send now now reports `confirmationPending` ("confirm it once more") instead of doing nothing silently. The ordering itself was not changed.

## Review fixes

Addresses `fix-f2-review-oraclea.md` and `fix-f2-review-oracleb.md`, smallest change each. Line numbers are current working-tree lines unless marked HEAD.

- **B F2-R1 (conditional P1).**
  - **Answer: no.** `scheduledSendHasUnresolvedRecovery(session)` cannot be true for a tab with nil `activeAgentSessionID`. Its first line is `guard let sessionID = session.activeAgentSessionID else { return false }` (`AgentModeViewModel+ScheduledSend.swift:1511`, HEAD `:1478`). The first-pass rewrite therefore did not change admission.
  - **Fixed anyway.** The loop is back to the pre-F2 shape: `for session in sessions.values where session.activeAgentSessionID != sessionID && scheduledSendHasUnresolvedRecovery(session)` (`:2699`; HEAD `:2652-2654`). A bound tab is added to `unresolvedOpenSessionIDs`; an unbound one sets `unattributed`.
  - **Regression test.** `AgentScheduledSendDispatchTests.testUnboundTabWithUnresolvedRecoveryStateKeepsThePreF2GateMembership`. It uses an unbound tab in a state that is unresolved once bound (mandatory recovery admission with no lane):
    - unbound, the predicate, the blocker and `hasUnresolvedRecoverySession` are all false or nil, the same as at HEAD;
    - after binding, the tab is an attributed blocker, and it is excluded as the schedule's own session.

    An unbound tab cannot reach the `unattributed` branch through the real predicate, and I did not add a test-only seam to force it.
- **B F2-R4.** The new-session gate in `evaluatePass` now computes `workspaceRecoveryBlocker(...)` once per candidate and gates on it being non-nil (`AgentScheduledSendCoordinator.swift:1886`).
  - Removed: the second host walk, the `?? AgentScheduledSendRecoveryBlocker(unattributed: true)` fallback, and the internal default witness of `scheduledSendRecoveryBlocker`. The protocol doc now says the gate is this value being non-nil.
  - Admission is identical for both conformers: each defines `hasUnresolvedRecoverySession` as `scheduledSendRecoveryBlocker(...) != nil`. The existing gate tests (`testUnresolvedRecoveryBlocksNewSessionStartEvenWhenRunningAlongside`, `testWorkspaceGateAggregatesAcrossHostsAndRunAlongsideOverridesIt`, and the rest of `AgentScheduledSendCoordinatorTests`) pass unchanged.
  - Not changed: the handoff validator (`blocksOnUnresolvedRecovery`, `:1498`) still asks each host `hasUnresolvedRecoverySession`. It is the same predicate, and it is a separate check at a later point, not a second walk inside the gate.
- **B F2-R2.**
  - **Dashboard.** `AgentScheduledMessagesViewModel.dashboardProps` gained a `recoveryBlocker:` argument. Hydrated and live rows pass `coordinator.recoveryBlocker(scheduleID:)`, so the row's banner renders the same `recoveryBlockedMessage`. `AgentScheduledMessagesView` also reloads on `.agentScheduledSendDispositionDidChange`.
  - **Test.** `testSendNowOnRecoveryBlockedNewSessionShowsWhyAndDispatchesOnceWhenResolved` now checks that the dashboard row's message equals the composer banner's while blocked, and is nil after dispatch.
  - **Early returns (also B F2-R7, last bullet).** Every return in `sendScheduledSendNow` before `confirmAndSendNow` returns a message: missing tab or binding change (`scheduledSendMissingMessage`), no coordinator or unbound tab ("Scheduled sending is unavailable in this window."), stale owner on resync (`scheduledSendMissingMessage`), file missing or unreadable (`scheduledSendVerificationFailedMessage`), record gone (`scheduledSendMissingMessage`), `.dispatching` or an owned live attempt (`scheduledSendDispatchingMessage`), a failed Run-alongside commit (its own message), an unverified revision (`scheduledSendVerificationFailedMessage`), and a newer confirmation decision (`scheduledSendConfirmationChangedMessage`). `nil` is returned only for `.blocked` and `.progressing`. The composer banner and the dashboard row both show a returned message as the banner's action error. No code change was needed.
- **A F2-01 / B F2-R3 (wording).**
  - Restricted sessions: "Will send after N unchecked session(s) in this workspace is/are resolved. Restart RepoPrompt to check again."
  - Own session (`destinationUnresolved`): "Waiting until this session's recovery is resolved." There is no Needs Attention pointer, because some own-session causes (a held transfer, a restriction, earlier-launch processes) can't be resolved there.
  - `testRecoveryBlockedBannerWordingNamesWhatToResolve` was updated to match.
- **B F2-R5.** The `rejected` doc comment now reads "Send now was refused: no consent applies, and Send now must be repeated once the refusal clears."
- **B F2-R6.** The banner's fixed height adds 14 pt when `actionError` is shown, so the error line is no longer clipped.
- **A F2-02.** The diagnosis now reads "Reproduced; likely explanation". Each alternative is marked "unlikely, unverified live" instead of "ruled out".
- **B F2-R7.** Added with the composition harness; it was cheap because the harness already builds real startup crash holds: `AgentRecoveryStartupCompositionTests.testCrashHoldBlocksNewSessionSendNowUntilItStoppedThenDispatchesOnce`.
  - Setup: a real earlier-launch crash hold through `AgentRecoveryAppComposition`, a real scheduler attached to the real view model, and a second tab in the same workspace with a new-session schedule.
  - Send now with Run alongside returns `nil`. The blocker names exactly the held session, and the composer banner reads "…choose It stopped (not Dismiss) in Needs Attention…". Nothing is sent.
  - Dismiss of the crash row: still blocked, same banner, nothing sent.
  - It stopped on the paused row: exactly one dispatch, the blocker clears, and a later re-evaluation does not dispatch again.
  - The run starter is the injected `scheduledDispatchRunStarter`; the provider is not exercised.
- **Re-review r1 P3s (`fix-f2-review-oracleb-r1.md`).** P3-1: the protocol default `hasUnresolvedRecoverySession` now returns `scheduledSendRecoveryBlocker(inWorkspace:excluding:) != nil`, and the two identical conformer implementations (view model, `FakeScheduledSendHost`) are deleted; access control and lint allow it (the extension still has two `package` members). P3-2: the banner's action-error text has `.lineLimit(1)` plus `.hoverTooltip(actionError)`. P3-3: the dispatch test asserts exactly one dashboard row for the blocked schedule before reading its message, and no row for the schedule or its session after it is sent. Validation: `make dev-build` pass; the same focused filter 343 tests, 0 failures; `make dev-lint` pass.

### Validation after the review fixes

- `make dev-build`: pass (exit 0).
- `make dev-test FILTER="'AgentScheduledSendCoordinatorTests|AgentScheduledSendDispatchTests|AgentScheduledSendPersistenceTests|AgentScheduledSendReceiptTransferTests|AgentScheduledSendNonCodexMandatoryTests|AgentScheduledMessagesViewModelTests|AgentRecoveryCoordinatorTests|AgentRecoveryStartupReconciliationTests|AgentRecoveryStartupCompositionTests|AgentRecoveryReconciliationTests|AgentComposerTabOwnershipTests|AgentComposerSubmissionAttemptTests|AgentComposerFocusRequestTests|ComposerFocusTokenPolicyTests|AgentModeSidebarSessionBuilderTests'"`:
  - **pass, 343 tests, 0 failures, 15 suites**: the first pass's 341 plus 2 new tests;
  - per suite: Coordinator 55, Dispatch 58, Persistence 34, ReceiptTransfer 11, NonCodexMandatory 7, ScheduledMessagesVM 9, RecoveryCoordinator 45, StartupReconciliation 21, StartupComposition 13, RecoveryReconciliation 52, ComposerTabOwnership 5, ComposerSubmissionAttempt 8, ComposerFocusRequest 4, ComposerFocusTokenPolicy 4, SidebarSessionBuilder 17;
  - the only item in the log's "Test failures" excerpt is an existing compiler warning (`AgentRecoveryStartupCompositionTests.swift:604`, `??` on a non-optional), not a failure.
- `make dev-lint`: pass (exit 0), first run.
- `Scripts/check-agent-context`: fails only with reachability errors for the three F2 evidence documents (this report and the two F2 reviews). Earlier steps' reports are linked from the spec's step line, and the spec is out of scope for this worker, so the main agent should link them. The AGENTS.md route-count warning is the existing one.
- Not run: full `make dev-test`, `make guardrails` (no files added or moved), `gitleaks` (nothing pushed), the rendered UI, and the visible app.
