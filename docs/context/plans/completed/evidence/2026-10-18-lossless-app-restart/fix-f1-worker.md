# Step 7-F1 worker report
Scope: read when the task touches lossless restart Step 7-F1 (scheduled follow-up handoff hold and terminal attribution) implementation or review evidence.
Authority: Reference
Last-verified: 2026-10-26

Covers:
- finding F1 in `2026-10-18-lossless-app-restart-spec.md` ("A scheduled follow-up is withdrawn before its runner dispatches it, and the previous turn is marked failed");
- the third "Cross-cutting observability" bullet (distinct diagnostics for the identical "…delivery could not be recorded…" texts).

Base: HEAD `7d7be9b6` (the F7 fix). The spec's line numbers refer to `d971983b`; the line numbers below are for the current working tree.

Nothing is staged or committed. The visible app was not launched, relaunched or stopped. No Oracle, `ask_user`, `context_builder` review or plan, or other agents were used. The XCTest ledger is untouched. Diffs are local only, under `prompt-exports/restart-fixes/`: the reviewed step is `fix-f1-review.diff`, the current full step is `fix-f1-current.diff`, and the review-fix delta is `fix-f1-r1-delta.diff`. No new source or test files were added. Line numbers in the sections before "Review fixes" are as reviewed; "Review fixes" uses current lines.

## Root cause

**Why the schedule was withdrawn.**
1. The non-Codex dispatch commit is deferred to the runner (adopted plan §5). `AgentProviderHandoff.prepareRunStart` writes nothing.
2. `AgentModeRunService.startRun` returns `nil` once the runner owns the input. At that point the runner may still be preparing: MCP bootstrap and `lease.acquire()`.
3. `finishMandatoryScheduledDispatch` read the recovery record at that moment and found the intent still `queued` with no attempt. It read that state as "never dispatched".
4. It then treated `nil` as non-delivery: it withdrew the intent, removed the bubble and failed the schedule, before the runner ever committed.

**Why the earlier turn was marked failed.** The runner's later failure went through the terminal barrier. The barrier attributed the outcome to `session.items.last(where: .user)`. With the scheduled bubble removed, that was the previous turn, so its execution turn received the terminal join, the interruption stamp and the process-run retention.

**A second race (found during the audit, not in the spec).**
- The `.awaitingProviderEvidence` re-check runs R9 `performScheduledSendTransferRepair` as soon as the run is inactive.
- If that happens while a deferred handoff is still uncommitted, the `queued` intent resolves to `completeTransfer(savedInQueue)`.
- A deferred handoff's no-handoff settlement wrote nothing and posted nothing. So it never woke a held schedule.

## Files changed and why

| File | Change | Why |
|---|---|---|
| `Sources/RepoPromptAgentCore/AgentMode/Runtime/AgentModeRunService.swift` | Doc contract on `startRun` (~549-552): `nil` means only that a runner owns the input. DEBUG OMP exits: generation mismatch (624) and context identity mismatch (638) now return `.stale(reason: qualificationStartRefusedReason)` (new constant, 545). Both incomplete-state exits (631, 645) return `.failed(message:)`. Knowledge-profile (654) and workspace/worktree (666) failures return `.failed(message:)` for every agent (before: `nil` for non-Codex). `guard let handoff` (719) returns `.stale(recoveryDispatchRefusedReason)`. A `prepareRunStart` refusal logs `run_start_<reason>` (680). | Requirement 1: every exit before a runner owns the input is explicit. Codex is unchanged (it already returned `.failed`). |
| `…/Runtime/Recovery/AgentRecoveryCoordinator.swift` | Lane registry `deferredRunStartHandoffs` (3053-3096): `deferredRunStartHandoffState(intentID:)`, `clearDeferredRunStartHandoff`, and `noteDeferredRunStartHandoffPrepared` / `Committed` / `NotHandedOff`. The last one posts `.agentRecoveryDeliveryEvidenceDidSettle` (object: lane). New `AgentDeferredRunStartHandoffState` (316). `AgentRecoveryAdmissionFailure.diagnosticReason` (301). | The single new hook (requirement 2). Process memory only; it is never read as evidence after a relaunch. |
| `…/Runtime/Runners/AgentProviderHandoff.swift` | `prepareRunStart` registers durable intents as `.pending` (114). `commitDispatch` success clears them (265). `noteDeferredOutcome` records `.notHandedOff(message:)` and signals (382-386); `noteNoHandoff`, `noteProvenNotWritten` and `noteRejected` now pass their message. New `attributedUserItemID` (46, 110, 119, 157). `enterProviderBoundary` moves attribution to an input that crossed the boundary in the same attempt (344-345). `blockBeforeHandoff` logs. `CommitFailure.diagnosticReason` (196). New `AgentDeliveryRecordDiagnostics` (669-705). | Hooks for requirements 2 and 3, plus the observability bullet. |
| `…/Runners/ClaudeIntegratedAgentModeRunner.swift` (88, 146), `ACPIntegratedAgentModeRunner.swift` (252, 1711), `HeadlessAgentModeRunner.swift` (72, 244) | `beginRunAttempt(…, inputUserItemID: handoff.attributedUserItemID)`. The attach-failure branch logs `not_sent reason=<route>_run_attempt_not_recorded`. | Requirement 3; observability. |
| `…/Runtime/Session/AgentTabSession.swift` (1975-2041) | `beginRunAttempt(inputUserItemID:)` sets `runAttemptInputAttribution`. It is always overwritten, so it is `nil` for Codex and pre-runner attempts. `noteRunAttemptInput(attemptID:userItemID:)` only applies to the active attempt. | Requirement 3. |
| `…/Runtime/AgentRunLifecycleContracts.swift` (100) | `AgentRunAttemptInputAttribution`. | Requirement 3. |
| `…/Runtime/AgentRunTerminalCommitBarrier.swift` (249, 476-487) | `terminalTurnID` comes from `terminalUserItemID(for:in:)`. If the attempt named its input, that item is used. If the item is gone, nothing is attributed (never an earlier turn). Otherwise the legacy last user item is used. The relocated-input mapping (`transcript.executionTurnID(forUserItemID:)`) is kept. | Requirement 3. |
| `…/Runtime/Scheduling/AgentScheduledSendRecovery.swift` (231-262) | `linkedIntentID(record:recoveryRecord:)`. Shares the private `linkedIntents` filter with `linkedIntentDeliveryState`. | Lets the hold find its intent. |
| `Sources/RepoPrompt/Features/AgentMode/ViewModels/AgentModeViewModel+ScheduledSend.swift` | `ScheduledSubmitResult.runnerOwnsInputOnNil` (2098; set for non-Codex at 2138 and 2198). In `finishMandatoryScheduledDispatch` (3228), right after the unchanged `deliveryUnknown` branch, a runner-owned `nil` holds `.awaitingProviderEvidence`; nothing is read or withdrawn. The recheck (1614-1653) calls `settleScheduledDeferredHandoffIfNeeded` (1656-1717) before any R9 repair. The explicit non-delivery path clears the registry entry (3275). | Requirement 2. |
| Tests (3 files) and `docs/context/agent-scheduled-messages.md` (one bullet) | See below. | Tests; context maintenance. |

### Hold resolution (`settleScheduledDeferredHandoffIfNeeded`)

As amended by review fixes R3, R8 and R9 (see "Review fixes"), the hold resolves in four ways:

- **`.undecided` → nothing is decided.** This applies when:
  - the owner is not current (e.g. tab replaced), checked before the read and again before acting;
  - the lane is unavailable, retired, or another session's;
  - the recovery record read fails.

  A replaced owner never withdraws.
- **`.notDeferred` → existing R9 repair.** Only after a successful read, when the linked intent has no registry entry (committed, or never deferred) or already has a delivery attempt. Acceptance transfers. A still-`dispatching` intent keeps `.awaitingProviderEvidence`. A commit alone is never Sent.
- **`.pending` → nothing is decided.** This covers the F1 race above.
- **`.notHandedOff(message)`, owner still current, still-queued intent → withdraw and fail.** The steps run in this order:
  1. Consume (clear) the registry entry, then `withdraw` the intent. If the withdraw fails, the hold becomes `.unresolved` and the bubble is kept.
  2. Clear the held-intent presentation.
  3. Remove only the scheduled bubble.
  4. Log the handoff's own reason, then commit `markScheduledSendFailed` with the generic scheduled message. If that commit fails, keep an `.unresolved` hold and stop.
  5. Only then release the hold.

**Release ordering (found by test repetition).** I first released the hold before the failure commit. Releasing re-evaluates the scheduler synchronously while the record is still `.dispatching`, so the scheduler could raise a `deliveryUnknown` confirmation obligation. That obligation later rewrote the failed record to `needsConfirmation` (4 failures in 12 runs before the fix; 0 in 13 after). In production (`dispatchingRecordsRequireTransferResolution = true`) the same window would start a competing transfer resolution. The fix commits the failure before releasing, as the R9 repair already does.

**Not changed:**
- `beginDispatch` refusal of withdrawn intents;
- `intentNeverDispatched`;
- `withdraw` semantics;
- dispatch-before-provider ordering;
- `processRunID` reuse;
- the Codex path, including the Codex `nil` handling in the finisher, which still flows to the old explicit path;
- the `deliveryUnknown` hold branch.

## Audit results

### Pre-runner exits per provider (`AgentModeRunService.startRun`)

| Exit | Before (non-Codex) | Now |
|---|---|---|
| DEBUG OMP generation mismatch (624) | `nil` | `.stale(omp_qualification_start_refused)` |
| DEBUG OMP incomplete state (631) | `nil` | `.failed(message)` |
| DEBUG OMP identity mismatch (638) | `nil` | `.stale(omp_qualification_start_refused)` |
| DEBUG OMP session/workspace mismatch (645) | `nil` | `.failed(message)` |
| Knowledge profile on an unsupported provider (654) | `nil` | `.failed(message)` |
| Workspace/worktree resolution failure (666) | `nil` | `.failed(message)` |
| `prepareRunStart` refusal or commit failure (680-686) | `.stale` / `.failed` | unchanged, now logged |
| Target changed after prepare (695) | `.stale`, `noteNoHandoff` | unchanged |
| Provider handoff revoked (703) | `.stale`, `noteNoHandoff` | unchanged |
| `guard let handoff` (719) | `nil` | `.stale(recovery_dispatch_refused)` |
| Claude / ACP / headless runner (779 / 868 / 883) | `nil` | `nil`: runner-owned (each settles via `settleRunInputScope`) |

For how each caller handles `.failed`/`.stale`, see the `startRun` call-site audit under "Review fixes" (B F1-R7).

### Headless

The run service returns `nil` only after `headlessRunner.startRun`. Every exit inside the runner before its task (invalid route, provider factory failure) settles through its `defer { if !runTaskOwnsHandoff { handoff.settleRunInputScope() } }` (HeadlessAgentModeRunner.swift:48-55). The task settles at 155, and the attach failure is at 244-246. A runner-owned `nil` is valid there. Its no-handoff reaches the hook through `noteDeferredOutcome`, and the finisher's immediate recheck catches a settlement that landed before the hold.

Headless has a fourth identical text, `HeadlessHandoffError.deliveryNotRecorded` (6-15, thrown at 246). Its diagnostic is the `headless_run_attempt_not_recorded` log just before the throw.

### Hook wiring

| Path | Before | Now |
|---|---|---|
| Uncommitted `noteNoHandoff` / `noteProvenNotWritten` / `noteRejected` / `noteDeliveryUnknown` / `settleIfUnresolved` → `noteDeferredOutcome` (AgentProviderHandoff.swift:382) | In-memory observation only: no write, no notification | Records `.notHandedOff` on the issuing lane (`heldLane`) and posts `.agentRecoveryDeliveryEvidenceDidSettle` (AgentRecoveryCoordinator.swift:3087-3096) |
| `settleRunInputScope` (470) | — | Reaches the same hook through `settleIfUnresolved` |
| Observer | — | `AgentModeViewModel+ScheduledSend.swift:153` → `recheckScheduledSendTransferAwaitingEvidence` |
| Run-state changes (`AgentModeViewModel.swift:4229` → `notifyScheduledSendRunStateChanged`, ScheduledSend.swift:198-210) | Already recheck | Unchanged |

The recovery observer at `AgentModeViewModel+Recovery.swift:653` also receives the notification. It only joins pending handoffs, so it is harmless.

### Diagnostics

The four identical user texts now have distinct reasons. All are `os.Logger`, subsystem `com.repoprompt.agents`, category `DeliveryRecord`, level `.notice`. Reasons are fixed vocabulary and public; the private detail is the failure's `String(describing:)`. No message content is logged.

| Source | Reason |
|---|---|
| `AgentRecoveryAdmissionFailure.commitFailed` (`run_start_…` / `blocked_before_handoff …` logs) | `dispatch_commit_failed` |
| Claude run-attempt attach (ClaudeIntegratedAgentModeRunner.swift:146) | `claude_run_attempt_not_recorded` |
| ACP (ACPIntegratedAgentModeRunner.swift:1711) | `acp_run_attempt_not_recorded` |
| Headless (HeadlessAgentModeRunner.swift:244) | `headless_run_attempt_not_recorded` |

`CommitFailure.diagnosticReason` covers the other blocked-before-handoff causes: `run_attempt_not_bound`, `pending_handoff_not_attached`, `pending_handoff_after_commit`, `already_settled`, `dispatch_<admission reason>`, `pending_handoff_not_saved`.

The user texts are unchanged. Read the log with:

```sh
log show --last 1h --style compact --predicate 'subsystem == "com.repoprompt.agents" AND category == "DeliveryRecord"'
```

I did not do a live readback of this category; it uses the same facility F7 verified.

## Tests

**`AgentScheduledSendNonCodexMandatoryTests`.** Added a production-shaped starter, `StarterProbe.deferredRunStarter`: `prepareRunStart`, then the runner is admitted (`running`), then it returns `nil`. The test then plays the runner's attach, commit, boundary, accept or no-handoff. Four new tests:

- `testClaudeDeferredRunStartHoldsUntilItsRunnerCommitsAndTheProviderAccepts`:
  - after the `nil`, the schedule is held with the intent still `queued` and the registry `.pending`;
  - an inactive-run recheck while still pending decides nothing (the F1 race);
  - after the commit, the intent is `dispatching` and an inactive-run recheck still holds (a commit is not Sent);
  - acceptance transfers as `providerAccepted`;
  - the earlier turn is unchanged.
- `testClaudeDeferredRunStartNoHandoffFailsTheScheduleAndRemovesOnlyItsBubble`: `.failed` with the handoff's message; the intent is withdrawn; only the scheduled bubble is removed; it stays `.failed` with no confirmation reason after the rechecks.
- `testOpenCodeDeferredRunStartCancelledDuringPreparationFailsTheSchedule`:
  - the ACP agent is cancelled during preparation;
  - it stays held until the runner's scope settles;
  - it then fails with the generic message.
- `testDeferredRunStartSettlingAfterTheTabWasReplacedNeverWithdrawsTheInput`: tab replacement while preparing; the intent stays `queued`; no withdrawal.

The two existing tests pass unchanged. The Claude test now holds immediately and resolves through the existing evidence hook.

**`AgentModeRunServiceLifecycleTests`**, including its extension in `AgentProviderHandoffTests.swift`:

- `testClaudeDeferredStartWithDelayedLeaseAcquireStaysPendingUntilItsRunnerCommits`:
  - real Claude runner, with the delay coming from a gated `expectedPIDPolicyArmer` inside `lease.acquire()`;
  - `nil`, then `.pending` with the intent `queued` and no attempt;
  - the run attempt's attribution is its own item;
  - after release: registry cleared, `dispatching`, then accepted.
- `testClaudeDeferredStartEndedDuringPreparationSettlesNotHandedOffAndSignals`: real Claude runner, two variants:
  - acquire failure;
  - `cancelRun` during the gated acquire.

  Each gives `.notHandedOff`, the lane signal is observed, there is no `claude:send`, the intent stays `queued` and there is no attempt.
- `testACPDeferredStartWithDelayedLeaseAcquireIsPendingThenCommittedOrNotHandedOff`: real ACP runner with `LifecycleFakeACPProvider` (cursor) and a gated armer:
  - a pending phase;
  - then accepted on the prompt response, or, if acquisition fails, `.notHandedOff` with no `session/prompt`.

  This is the real runner, not a closer seam.
- `testPreRunnerStartupExitsReturnAnExplicitFailureForClaudeAndACP`: `.failed` for workspace failure (Claude and OpenCode) and for the knowledge profile on ACP. The intent stays `queued`, nothing is prepared and no provider is created.
- `testTerminalBarrierAttributesTheAttemptsOwnInputNeverANewerQueuedUserItem`: a newer queued item never takes the outcome. A removed own item gives no attribution, never an earlier turn. Legacy attempts keep the last user item.
- `testTerminalBarrierAttributesARelocatedOwnInputToItsExecutionTurn`:
  - the relocated input lands on execution turn E, not on its historical turn H nor on a newer item;
  - another attempt's `noteRunAttemptInput` is ignored;
  - steering in the same attempt moves the attribution.

**Deliberate contract updates.** These two tests pinned the old `nil` and now expect `.failed`:
- `testStartupFailureTransitionsBeforeProviderDispatch` (Claude and OpenCode now match Codex);
- `testNonCodexStartupFailureBeforeAnyRunnerSettlesTheCarriedRecoveryAction`.

No assertion was weakened.

## Validation

All commands are coordinated `make dev-*` runs.

- `make dev-build`: **pass**. Run after the last source change. Exit 0; no new warnings in changed files; the existing Swift 6 isolation warnings in `AgentProviderHandoff.swift` / `HeadlessAgentModeRunner.swift` were already present at HEAD.
- Final focused run, over 20 suites: **pass, 669 tests, 0 failures**.

  ```sh
  make dev-test FILTER="'AgentScheduledSendCoordinatorTests|AgentScheduledSendDispatchTests|AgentScheduledSendNonCodexMandatoryTests|AgentScheduledSendPersistenceTests|AgentScheduledSendReceiptTransferTests|AgentModeRunServiceLifecycleTests|AgentProviderHandoffTests|AgentRecoveryQueuedInputTests|AgentRunTerminalCauseTests|AgentRecoveryActionTests|AgentRecoveryVMProducerAdmissionTests|AgentRecoveryCoordinatorTests|RemoteAgentDispatchEvidenceTests|ACPSynchronousMCPStartupTests|ACPAgentSessionControllerModeConfigTests|ACPProviderSessionIdentityTests|AttentionNotificationAdmissionTests|AgentRecoveryStartupReconciliationTests|AgentRecoveryResetBoundaryTests|AgentRunLifecycleContractsTests'"
  ```

  The lifecycle suite includes the Claude runner tests (`ClaudeAgentModeCoordinatorLifecycleTests.swift` extends it). The ACP runner tests are in the lifecycle suite plus the `ACP*` suites.
- Stability: `make dev-test-artifact FILTER=AgentScheduledSendNonCodexMandatoryTests` ×12 after the release-ordering fix: **0 failures**. Before the fix: 4 failures in 12 runs.
- `make dev-lint`: **pass**, exit 0. Two lint findings in my test edits were fixed (`redundantThrows`, `hoistTry`).
- `Scripts/check-agent-context`: **pass**. Its one warning is the existing AGENTS.md route count.
- `make guardrails`: **fails, but the failure predates this change**. The tracked F7 evidence files committed in `7d7be9b6` are not on the tracked-docs allowlist. No source or test files were added.

**Not run:**
- the full `make dev-test`;
- `make dev-core-test`;
- live Dev-app acceptance;
- an OMP pre-runner exit test (the DEBUG qualification exits were audited by inspection only; constructing OMP qualification contexts is heavy);
- a headless-provider runner test (audited by inspection);
- a direct shutdown-during-preparation test. The registry is process memory, so after a relaunch the intent is a plain `queued` saved input handled by the existing R9 startup repair. The tab-replacement test covers "a non-current owner never withdraws".

## Open questions

1. **Guardrails.** Resolved by the main agent: diffs live in `prompt-exports/restart-fixes/`, and `fix-f1-worker.md` is allowlisted.
2. **Generic failure message.** Superseded by R9: the schedule banner always shows `AgentModeViewModel.scheduledNotHandedOffMessage`, and the handoff's own text is logged.
3. **Reason codes in the registry.** `AgentModeRunService` exits after `prepareRunStart` (target changed, revoked) pass reason codes, not user text, to `noteNoHandoff`. Those reach the registry, but the scheduled finisher handles those outcomes on the explicit path with `scheduledNotAcceptedMessage(outcome)` and clears the entry, so the codes are never shown.
4. **Context doc.** `docs/context/agent-scheduled-messages.md` gained one bullet describing the live non-Codex hold. Keep it, or move it into the spec when F1 is accepted.

## Review fixes

Addresses `fix-f1-review-oraclea.md` and `fix-f1-review-oracleb.md`. Current line numbers. The delta against the reviewed diff is `prompt-exports/restart-fixes/fix-f1-r1-delta.diff`.

### B F1-R2: successor owner while the handoff is pending

**Answer: yes, tab replacement or reopen retires the old lane, and a late commit through `heldLane` is refused.**

1. A new owner is a new `AgentTabSession`. Its persistence state calls `coordinator.claimLane(owner:persistenceState:)` (`AgentModeViewModel+Recovery.swift:712`).
2. `claimLane` returns the predecessor only if it is unretired, has the same owner and has the same persistence state. Otherwise it calls `predecessor.beginRetirement(...)` (`AgentRecoveryCoordinator.swift:1574`), which sets `isRetired = true` synchronously (3154). `releaseLane` also retires.
3. The old session still points at its old lane, so `commitDispatch`'s `issuingLaneIsCurrent` identity check (`AgentProviderHandoff.swift:252`) alone would pass. But the next step, `AgentRecoveryDispatchEvidence.begin(ownership:)` (253), is refused:
   - by `dispatchRefusal`: `guard let lane = session.recoveryLane, !lane.isRetired else { return .refused(.laneRetired) }` (`AgentRecoveryQueuedInput.swift:211`, again at 281);
   - and by the lane's `beginDispatches`, which checks `guard !isRetired` before and after its admission await (`AgentRecoveryCoordinator.swift:2716`, 2727).
4. The new test asserts `.failure(.dispatch(.refused(.laneRetired)))` and that the intent stays `queued`.

**Gap found and fixed.** The registry was per-lane, so a successor's lane could not see its predecessor's `.pending` entry. The fix:
- **Coordinator-scoped registry.** The registry moved to the coordinator (`deferredRunStartHandoffs`, `AgentRecoveryCoordinator.swift:1617`). The lane accessors forward to it (3071-3115).
- **Observer.** The scheduled-send observer also rechecks owners of the same durable session (`AgentModeViewModel+ScheduledSend.swift:159`), so a retired predecessor's settlement signal wakes the successor.
- **`resolveScheduledSendTransfer` (1739) consults the registry before the R9 repair**, via `settleScheduledDeferredHandoffIfNeeded`:

  | Settle result | Action |
  |---|---|
  | `.pending` | Hold `.awaitingProviderEvidence`; nothing read as saved input |
  | `.notHandedOff` | Apply the no-handoff settlement |
  | `.notDeferred` | R9 repair |
  | `.undecided` | Unresolved hold "The recovery record for this session is not available yet." (the same text the repair used for a missing lane), only while the owner is current |

  A record without an attempt goes straight to the repair.

**Test:** `testSuccessorHydratedWhileTheHandoffIsPendingWaitsForItsSettlement`.
1. Remove the live session, then claim and hydrate a successor tab through `test_hydrateBoundSession`.
2. Old lane retired; successor lane sees `.pending`; hold `.awaitingProviderEvidence`; record `.dispatching`; no `lastScheduledDispatch` (no `savedInQueue`); intent `queued`.
3. The old runner's late commit is refused (`laneRetired`).
4. Its no-handoff wakes the successor: the schedule fails with the generic message, the intent is `withdrawn`, the registry is consumed, never Sent, `startCount == 1`.

### B F1-R3: settlement only after a successful read

`settleScheduledDeferredHandoffIfNeeded` (1683) gains `.undecided`. It is returned when:
- the owner is not current, both before the read and again before acting;
- the lane is unavailable, retired, or another session's;
- the record read fails.

`.notDeferred` is returned only after a successful read, when the linked intent has no registry entry or already has a delivery attempt. The recheck treats `.undecided` like `.pending` (decide nothing). The "Hold resolution" section above is corrected: the earlier "owner not current → `.pending`" claim was only true for the second guard.

### B F1-R4 / A F1-R1: no prepare-time pin to an earlier item

`attributedUserItemID(of:)` (`AgentProviderHandoff.swift:120`) names only a constituent's `userItemID`; the `session.items.last(where: .user)` fallback is gone.

**Can durable input lack a user item?** No, by type:
- `AgentRecoveryAdmission.userItemID` is non-optional (`AgentRecoveryCoordinator.swift:33`);
- `AgentRecoveryIntent.userItemID` is non-optional (`AgentRecoveryModels.swift:479`);
- `AgentQueuedInputIdentity(receipt:)` takes it from the receipt (`AgentRecoveryQueuedInput.swift:59`).

Only `AgentQueuedInputIdentity.untracked(userItemID: UUID?)` (67), under inactive admission, can be `nil`. That gives a `nil` attribution, so the barrier uses its legacy terminal-time last user item, for untracked routes only. For durable input whose item is not (or no longer) in the transcript, the barrier attributes nothing (`terminalUserItemID`, `AgentRunTerminalCommitBarrier.swift` ~476-487).

**Test:** `testRunStartHandoffAttributesOnlyItsOwnInputNeverAnEarlierTranscriptItem`.
- A durable input whose own item is absent from a transcript holding an earlier turn names its own item, not the earlier one, and the barrier attributes nothing.
- An untracked `nil` input names nothing and keeps the legacy attribution.

### B F1-R5 / A F1-R3: exact regression

`testTerminalBarrierOrdinaryFailureAfterOwnInputRemovedNeverTouchesTheEarlierTurn`:
- **Setup:** transcript `[earlier (completed), own]`, with `own` removed (item and turn); ordinary `.failed` (`cause: .ordinary`) with nonempty `errorText`.
- **Asserts:** nothing attributed; `earlier.terminalState == .completed`; no interruption; no run ID retained in its span; the earlier turn is equal to its pre-commit value; the error text is shown once, as the session's error item.

### B F1-R1 / R11: `runnerOwnsInputOnNil`

- The field is now `let runnerOwnsInputOnNil: Bool` with no default (2144).
- Both start sites compute `session.selectedAgent != .codexExec` before their await: the injected starter (2198) and the non-Codex `startAgentRun` (2253).
- Every other construction passes an explicit `false`: busy/remote early return, revoked, missing identity, and Codex.
- `AgentScheduledSendDispatchTests` rerun: 53 tests, 0 failures.

### A F1-R2 / B F1-R8: registry cleanup

`AgentRecoveryIntentReceipt` carries no origin, so the scheduled owner marks its intent explicitly.
- **The mark.** `noteScheduledRunStartAwaited` (`AgentModeViewModel+ScheduledSend.swift:2150`, called at 2199 and 2254, before the start's await) calls `noteDeferredRunStartHandoffAwaitedByOwner` (`AgentRecoveryCoordinator.swift:3084`).
- **Retention.** On a no-handoff settlement (3105), only owner-awaited intents keep `.notHandedOff`. Every other entry (ordinary, MCP and recovery-action input) is cleared at settlement, and the settle signal is still posted.
- **Clearing.** `clearDeferredRunStartHandoff` removes both the entry and the mark. A commit clears both.
- **Scheduled owner exits.** The scheduled owner clears in:
  - the `scheduledHandoffWasRevoked` branch (3275);
  - the `deliveryUnknown` branch (3289);
  - every explicit-outcome path after the runner-owned hold (3314);
  - the withdraw-failure branch of the settlement (the entry is consumed before `withdraw`, 1704).
- **Scheduled settlements** stay until their owner consumes them.

Tests: the two `.mcp`-origin assertions that pinned a retained `.notHandedOff` now assert the settle signal and a cleared entry. This is a deliberate contract change:
- `testClaudeDeferredStartEndedDuringPreparationSettlesNotHandedOffAndSignals`;
- `testACPDeferredStartWithDelayedLeaseAcquireIsPendingThenCommittedOrNotHandedOff`.

### A recommendation: failure persistence before the release

- **What was wrong.** `markScheduledSendFailed` ignored `commitScheduledSend`'s `Bool`. A failed write (unavailable workspace, conflict, write failure) left disk at `.dispatching`, and the hold was then released, so the scheduler could re-read an unowned `.dispatching` attempt.
- **Fix.** It now returns the commit result (`@discardableResult`; other callers are unchanged). On `false`, the settlement keeps an `.unresolved("This scheduled message was not sent, but its status could not be saved.")` hold and does not release.
- **Deleted session.** A deleted session (`scheduledSend == nil`) returns `true`; there is nothing to keep.
- **Not exercised.** No test injects a schedule-commit failure; the fixtures have no cheap seam for one.

### B F1-R9: banner text

The settlement always shows `scheduledNotHandedOffMessage`. The handoff's own text is logged by the new `AgentDeliveryRecordDiagnostics.scheduledNotHandedOff(scheduleID:sourceMessage:)` (`AgentProviderHandoff.swift:699`):
- `reason=scheduled_not_handed_off` (public);
- `schedule=<id>` (public);
- `source=handoff_message|none` (public);
- the detail (private).

No raw internal string or "It stays saved." reaches the banner after withdrawal. `testClaudeDeferredRunStartNoHandoffFailsTheScheduleAndRemovesOnlyItsBubble` now expects the generic message (deliberate).

### B F1-R10: doc comment

`F1ArmerArrival` now sits above `DispatchCommitGate`'s doc comment, and each class has its own comment (`AgentProviderHandoffTests.swift` 1787-1800).

### B F1-R7: `startRun` call-site audit

What changed in F1: the pre-runner exits that now return `.failed`/`.stale` instead of `nil`. These are the DEBUG OMP qualification exits, the knowledge-profile provider, workspace/worktree resolution, and the unreachable `guard let handoff`.

On every `.failed` exit, `failBeforeProviderStartup` already appends the one error item, through the barrier (`errorText`) with `supportsFollowUp: false`. So no follow-up drain is triggered.

| Call site | `.failed` / `.stale` handling | Duplicate error item? | Re-queue loop? |
|---|---|---|---|
| `AgentModeViewModel.swift:3241`, `startFollowUpRun` | Durable instruction re-inserted at the head of `pendingInstructions` (`runStartDidNotHandOff`); untracked input is dropped | No; the caller appends none | No. Re-insertion does not start a run; the next drain needs a later completed terminal, and the failure terminal has `supportsFollowUp: false`. Before F1 the same exits returned `nil`, which silently dropped the durable instruction. It is now kept queued |
| `AgentModeViewModel.swift:17198`, MCP Codex send | Codex only; unchanged (Codex already returned `.failed`) | — | — |
| `AgentModeViewModel.swift:17271`, Claude wait-for-user with attachments | Result discarded; the durable intent stays `queued` for recovery presentation (same as before F1, when it was `nil`) | No | No |
| `AgentModeViewModel.swift:17391`, idle composer start | `noteRecoveryActionStartReturned` ends a carried recovery action with the reason. Idempotent with the run service's fenced defer | No | No |
| `AgentModeViewModel.swift:17730`, ACP completed-run steering follow-up | Same as `startFollowUpRun`: durable input re-inserted | No | No (same reason) |
| `AgentModeViewModel+ScheduledSend.swift:2226` (Codex) / `2255` (non-Codex), mandatory | `finishMandatoryScheduledDispatch` explicit non-delivery path: withdraw, remove the bubble, fail the schedule. Registry and mark cleared (3314) | No; the schedule banner, not a chat error | No; the schedule is failed, not re-armed |
| Same, non-mandatory | `scheduledProviderAccepted` is `false` for an explicit outcome, so `markScheduledSendFailed(scheduledNotAcceptedMessage(outcome))`. The revoked `.stale` reverts and re-arms (unchanged) | No | No: only the revoked gate re-arms, and that gate is process-wide. Other `.stale` reasons fail |
| `AgentModeViewModel.swift:19068` (`startAgentRun` itself) | `stagedInputStartDisposition` releases staged input for an explicit non-delivery | — | — |

**Defects found: none in the F1 change.** One pre-existing observation, not fixed: the non-mandatory scheduled banner shows `.stale` reasons verbatim. These include the existing `recovery_dispatch_refused`, and now the DEBUG-only `omp_qualification_start_refused`. These are reason codes, not user text.

### B F1-R6: tests

- **`.appQuit` during preparation: done.** It was cheap: the existing real-Claude gated-armer test is now a 3-variant loop (acquire failure, `.userCancel`, `.appQuit`). After every evidence write has landed (`deliveryEvidenceWritesSettled`), it asserts the persisted record:
  - the same intent is `queued`;
  - there is no delivery attempt;
  - exactly one run attempt, with terminal evidence only;
  - for `.appQuit`: `terminal.cause == .appQuit` and `terminalState == .cancelled`.

  The terminal's own run-attempt record is expected; the deferred handoff writes no dispatch.
- **Scheduled send driving the real Claude runner: skipped.** The scheduled harness runs the production `AgentModeViewModel` run service, whose Claude runner cannot take the private `LifecycleFakeNativeController` / gated `expectedPIDPolicyArmer` from `AgentModeRunServiceLifecycleTests`. Wiring that in would mean new injection seams on the view model's run-service construction. That is the heavy new tooling the brief says to stop on. Coverage is split:
  - the real runner's pending, commit and no-handoff behaviour is covered by the lifecycle tests;
  - the scheduled owner's response to those exact handoff transitions is covered by the scheduled tests through `prepareRunStart`.

### Validation

All coordinated `make dev-*` runs.

- `make dev-build`: **pass**.
- 20-suite filter (same command as above; it includes `AgentScheduledSendDispatchTests`): **pass, 672 tests, 0 failures**. That is 669 plus the three new tests: R2 successor, R4 attribution, R5 regression.
- After the lint fix: `AgentModeRunServiceLifecycleTests|AgentProviderHandoffTests` rerun, **233 passed, 0 failures**.
- Flakiness: `make dev-test-artifact FILTER=AgentScheduledSendNonCodexMandatoryTests` ×10: **10/10 runs pass, 7 tests each, 0 failures**.
- `make dev-lint`: **pass**, after one `preferCountWhere` fix in a new test line.
- `Scripts/check-agent-context`: **fails with 3 reachability errors.** The three evidence files are orphans: `fix-f1-worker.md`, `fix-f1-review-oraclea.md` and `fix-f1-review-oracleb.md`. Nothing links them from AGENTS.md or a routed doc. The only natural parent is the lossless-restart spec, which is pre-existing user dirt and was not touched. Its one warning is the existing AGENTS.md route count.
- `docs/context/agent-scheduled-messages.md`: the F1 bullet was updated for the coordinator-scoped registry and successor behaviour, the generic banner text, and the unresolved hold on a failed failure commit.
- **Not run:**
  - the full `make dev-test`;
  - `make dev-core-test`;
  - `make guardrails`;
  - live Dev-app acceptance;
  - a schedule-commit-failure injection test.

### Re-review 1 follow-ups

Addresses `fix-f1-review-oraclea-r1.md` and `fix-f1-review-oracleb-r1.md`. Neither found a P0 or P1. Only the requested cheap follow-ups were done.

- **B N2 / A R4: registry-empty fast path.**
  - The coordinator now records each deferred entry's session (`deferredRunStartHandoffSessionIDs`, `AgentRecoveryCoordinator.swift:1622`) and exposes `hasDeferredRunStartHandoff(sessionID:)` (1627).
  - The session is set on prepare (3103) and removed with the entry: on commit, on consumption, and on a non-awaited settlement (3090).
  - `resolveScheduledSendTransfer` (`AgentModeViewModel+ScheduledSend.swift:1762`) runs the registry pre-check only when the coordinator holds an entry for this session. Otherwise it calls `performScheduledSendTransferRepair` exactly as before this step.
  - The Codex and restart repair paths are therefore unchanged: no deferred handoff exists in a fresh process, and Codex never prepares one.
  - A's R4 liveness concern (an `.undecided` read failure with no later wakeup) is now bounded to a process that holds a deferred entry for that session.
- **B N1: memory agrees with the hold.** When `markScheduledSendFailed`'s commit returns `false` in the settlement, the caller restores `session.scheduledSend` to the dispatching member and `isDirty` to its value just before the call (1719-1727), and refreshes the index summary. The `.unresolved` hold, memory and disk (`.dispatching`) then agree, and a later dirty save cannot persist the unsaved failure. This is still not exercised by a test (N3, deferred).
- **B recommendation 3: Codex never reaches `guard let handoff`.** In `AgentModeRunService.startRun`:
  - `selectedAgent` is a `let` captured at 572;
  - the prepare block is `if selectedAgent != .codexExec` (674);
  - `if selectedAgent == .codexExec` (707) returns unconditionally through `return await codexRunner.startRun(...)` (709);
  - so `guard let handoff else { return .stale(...) }` (719) is unreachable for Codex, and Codex's `nil` meaning is unchanged.

  No change needed.
- **B P3-b: missing coordinator.** The lane's `deferredRunStartHandoffState(intentID:)` now returns `.pending` when its coordinator is `nil` (3082), so nothing is decided and it is never `.notDeferred`. That was the smaller change than an assert, which could trap fixtures whose coordinator is released.
- **B P3-c: observer.** Dropped the redundant `session.recoveryLane === lane ||`. Matching `recoveryLane?.sessionID == lane.sessionID` covers it (158).
- **B P3-d: test comment.** `testDeferredRunStartSettlingAfterTheTabWasReplacedNeverWithdrawsTheInput` now says the settlement stays recorded and a later successor consumes it and fails the schedule (see the successor test).
- **Deferred, unchanged:**
  - B P3-a (rare retained entries; memory only);
  - N3 (no failed-status-save injection test);
  - R6 (a scheduled send through the real Claude runner).

### Re-review 1 validation

All coordinated `make dev-*` runs.

- `make dev-build`: **pass**.
- 20-suite focused filter: **pass, 672 tests, 0 failures**.
- Full `make dev-test`: **7721 passed, 54 failed, 25 skipped**. The exit is non-zero because of the failures.
  - **Known failure:** `MCPCodeStructureWorktreeTests.testRetainedProjectionPreloadStopsAfterIndexAdvanceAndForegroundRecoversOnce` (:1805), which also fails on clean `d971983b`.
  - **The other 53 are all in workspace, watcher, worktree, or tab-routing suites.** None of these suites touch files changed in this step:
    - `WorkspaceFileContextStoreTests` (34);
    - `WorkspaceRootBindingProjectionTests` (3);
    - `WorkspaceFileContextStoreExactCapabilityTests` (3);
    - `WorktreeAPISmokeHarnessTests` (4);
    - `TabContextRoutingTests` (2);
    - `WorkspaceSwitchRecoveryTests` (2);
    - `WorktreeStartupInstrumentationTests` (2);
    - `AgentRunWorktreeStartTests`, `WorkspaceGitDataRootLoadingTests` and `WorkspaceRootSyncTests` (1 each).

    38 report `streamStartFailed` (FSEvents watcher start). The rest are `CancellationError`, `managerNotFullyStopped`, `baseSnapshotUnavailable`, or worktree-path assertions.
  - **Isolation rerun.** I reran exactly those 10 suites plus `MCPCodeStructureWorktreeTests` alone (`make dev-test FILTER=...`): **366 passed, 1 failed**, and the one failure is the known `MCPCodeStructureWorktreeTests` test. The other 53 therefore fail only under full-lane load (watcher-stream exhaustion), not because of this change.
- `make dev-core-test`: **pass, 66 tests, 0 failures**.
- `make dev-lint`: **pass**.
- `prompt-exports/restart-fixes/fix-f1-current.diff` was regenerated.
