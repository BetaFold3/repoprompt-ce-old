# Step 11: quiet by default
Scope: read when the task touches delivery-uncertain messages after RepoPrompt's own steer or Stop, the delivery warning wording, or settling old ordinary-exit intents.
Authority: Reference
Last-verified: 2026-10-29
Covers: O49-O51 changes, tests, the owner-record count, and the review round

## Summary

- **O49:** a written message whose turn the provider had started settles `providerAccepted` when RepoPrompt itself ended that turn:
  - Claude: Stop, window close, quit, or an acknowledged steer interrupt
  - ACP: Stop, window close, quit, or RepoPrompt's own `session/cancel`

  ACP steer was already accepted. Codex has no equivalent path. Queued, older, overlapped, or not-yet-started turns are never accepted this way.
- **O50:** the crash wording ("Delivery unconfirmed", "RepoPrompt stopped before…", "RepoPrompt closed while sending it…") now appears only when no recorded run end exists, i.e. an unclean exit. When every run of the message ended with recorded evidence, the text is plain instead.
- **O51:** a one-time startup pass settles old `deliveryUnknown` intents whose runs all ended with cause `ordinary`, and only attempts dispatched before the first launch that ran the pass. A marker file makes it idempotent, and the reason is recorded on each intent.

Nothing is staged or committed. Nothing under Application Support was written. The census only reads it.

## What changed (file:line)

### O49: Claude

Started-turn evidence comes from the controller:
- `Sources/RepoPromptAgentCore/AgentMode/Runtime/Native/NativeAgentRuntimeContracts.swift:54` adds the protocol requirement `startedTurnID`. The default at `:99` is `nil`.
- `Sources/RepoPromptAgentCore/AI/Providers/ClaudeCode/SDK/ClaudeNativeProcessSessionController.swift`:
  - `:552`/`:558` add a lock-protected `startedTurnID` snapshot.
  - `:2633`/`:2680`: a stream result that proves acceptance (content, reasoning or tool call; `AgentProviderHandoff.streamResultProvesProviderAcceptance`, `nonisolated static`) credits the producing turn through `noteOutputAttributedToProducingTurn()` (`:4983`). Only results from `assistant` and `stream_event` payloads count. Text in a final `result` payload is never credited, because that payload can be processed after the finishing turn left the FIFO head.
  - The producing turn is the FIFO entry after the turns whose results are already deferred, never a queued one.
  - The snapshot is cleared when that turn is dequeued and when the turn queue is cleared at shutdown.
- `Sources/RepoPromptAgentCore/AgentMode/Providers/ClaudeCompatible/ClaudeCompatibleNativeSessionAdapter.swift:32` forwards it.

`Sources/RepoPromptAgentCore/AgentMode/Runtime/Claude/ClaudeAgentModeCoordinator.swift`. Each written handoff carries three marks, and only the turn `startedWrittenTurnID(of:)` (`:1970`) reports as started can be marked:
- `teardownRequestedByRepoPrompt` (`:170`) is final.
  - It is set by `noteRepoPromptTeardownRequested(_:)` (`:2016`), synchronously before the run detaches, from:
    - Stop: `Sources/RepoPromptAgentCore/AgentMode/Runtime/AgentModeRunService.swift:2007`, before `agentTask.cancel()`
    - window close and app quit: `Sources/RepoPrompt/Features/AgentMode/ViewModels/AgentModeViewModel.swift:3989`
  - A marked turn settles accepted:
    - at its cancelled or failed completion (`:1952`)
    - at run end, stop or release without a completion (`settleWithoutCompletion`, `:2026`; `stop()` at `:307`)

    This happens without waiting for the CLI's result or the cleanup interrupt's acknowledgement.
  - No interrupt outcome removes it.
- `interruptPending` (`:173`) is provisional. `noteRepoPromptInterruptRequested` (`:1982`) sets it before the steer interrupt (`:2675`) and the cleanup interrupt (`:2866`).
- `completionDuringInterrupt` (`:176`) holds a cancelled or failed completion that arrives while the interrupt is pending (`:1959`). Nothing is settled at that point.
- `resolveRepoPromptInterrupt` (`:1994`) runs when the interrupt returns:
  - acknowledged: accepted
  - otherwise: the pending flag is cleared, and a held completion gets its normal outcome (`deliveryUnknown`, or accepted only if the teardown mark is set)
- Run end with only a pending interrupt settles `deliveryUnknown`. A later acknowledgement refines it to accepted.
- DEBUG-only seams for tests:
  - `test_holdsCompletionDuringInterrupt(turnID:)` (`:2069`)
  - `test_recordWrittenDispatchHandoff` (`:2075`)

Where `.cancelled` comes from in the real controller:
- It is derived only from a CLI result payload: the interrupt-acknowledged flag or an explicit cancel signal.
- Local synthesis produces only `.failed`: process loss and `failProtocolAndShutdown`.
- Deferred statuses flushed at shutdown or EOF are real observed results.

### O49: ACP

`Sources/RepoPromptAgentCore/AI/ACP/ACPAgentSessionController.swift`:
- `PromptReceiptEvidence` (`:347`) is kept per prompt turn, from `prompt()` start until that prompt returns or throws. Each entry holds:
  - `agentStreamed`: set while the prompt is active (`:4382`/`:4385`)
  - `cancelledByClient`: set only after a successful `session/cancel` write (`:1697`)
  - `overlappedAnotherPrompt` (`:355`)
  - the teardown generation when the prompt started
- Overlap fence (`:773`): a prompt that starts while another entry is outstanding marks every outstanding entry, and itself, as overlapped. Session updates carry no prompt identity, so an overlapped prompt never reports receipt.
- `noteRepoPromptTeardownRequested()` (`:1555`) is `nonisolated` and synchronous. It bumps a lock-protected generation (`:369`). It is called before the run task is cancelled by:
  - Stop: `AgentModeRunService.swift:2008`
  - window close and app quit: `AgentModeViewModel.swift:3990`
- Receipt is `agentStreamed && !overlapped && (cancelledByClient || teardown requested since this prompt started)` (`provesReceipt`, `:359`). The prompt's catch reports it through `onFailure` before rethrowing (`:839`-`:841`). This holds even when the prompt fails from task cancellation before any `session/cancel` is written.
- The entry is inserted at `:777`. Only non-throwing statements follow before the `do`, so no throw can leak it. It is removed on success at `:861`.
- DEBUG-only test hooks:
  - session update, active-turn probe, and failing pending requests as transport-closed without reaping a process
  - `debugAbandonActivePromptTurn()` (`:1612`): simulates the active-turn ID being cleared while the request is still pending, so a second prompt can start

No controller reuse after a prompt removed without a provider reply (checked, no code change). An ACP controller can't run another prompt after one of its prompts ended without the provider's response:
- After the write, a `session/prompt` waits in `withCheckedThrowingContinuation` with no cancellation handler (`:2437`). Task cancellation alone never makes it throw.
- Every other way a pending prompt is removed without a reply leaves the controller unusable:
  - request timeout (`handleRequestTimeout`, `:2593`): the prompt's catch sets `.failed` (`:854`-`:855`)
  - session error (`:1544`): `.failed` (`:1547`)
  - shutdown (`:1810`): `.closing` (`:1805`)
  - process exit (`:2215`): `.failed` (`:2216`)
  - protocol violation (`:2548`): `.failed` (`:2552`-`:2553`)
  - a write failure (`:2461`) means the prompt was never written
- `prompt()` requires `.sessionOpen` or `.promptRunning` (`:733`). Nothing leaves `.failed` or `.closing`:
  - `bootstrap` requires `.idle` (`:529`), which is only the initial value (`:293`)
  - the success path (`:891`) needs a provider response
  - the steering resets (`:1669`/`:1679`) and `prepareForNextTurn` (`:520`) need `.promptRunning` or `.sessionOpen`
- Steer (`interruptActivePromptForSteering`, `:1641`) waits for the active prompt to settle (15 s), which happens only on its reply or failure. A failure leaves `.failed`, so the steering prompt is refused.
- `failAllPromptSettlementWaiters` (`:1776`-`:1777`) clears `activePromptTurnID` only from shutdown (`:1809`), process exit (`:2214`) and DEBUG.

`Sources/RepoPromptAgentCore/AgentMode/Runtime/Runners/AgentProviderHandoff.swift`: `ACPPromptWriteObservation` gains a lock-protected `onFailure` callback and `failedAfterAgentReceipt`.

`Sources/RepoPromptAgentCore/AgentMode/Runtime/Runners/ACPIntegratedAgentModeRunner.swift`:
- Both written-prompt call sites pass `onFailure: promptWrite.onFailure`: the steering prompt (`:687`) and the main prompt (`:1845`).
- Both catches call `noteWrittenPromptFailure` (`:726`). It accepts only on this prompt's own receipt evidence and otherwise records `deliveryUnknown`.
- The handoff is settled in the run task's `defer`, after that catch, so an accepted prompt never records a transient unknown.

### O50: wording

- `Sources/RepoPromptAgentCore/AgentMode/Models/AgentChatModels.swift:373` adds `AgentUserItemRecoveryDelivery.notConfirmedByAgent`. `.unconfirmed` is now documented as unclean-exit only.
- `Sources/RepoPromptAgentCore/AgentMode/Models/AgentRecoveryModels.swift:1119` adds `intentRunsEndedWithRecordedEvidence`. It is true when every attempt's run has terminal or shutdown evidence.
- `Sources/RepoPromptAgentCore/AgentMode/Runtime/AgentSessionRestoreSupport.swift`:
  - `:313`: `unacceptedDelivery(…, runsEndedWithRecordedEvidence:)` returns `.notConfirmedByAgent` instead of `.unconfirmed` when the flag is set.
  - `:294`: if two intents share a bubble, the crash wording still wins.
- The `runsEndedWithRecordedEvidence` inputs are required, with no defaults:
  - `AgentSessionRestoreSupport.swift:311`
  - `AgentRecoveryCatalog.swift:81`
  - `AgentModeViewModel+RecoveryList.swift:704`
- They are passed in at:
  - `AgentSessionDataService.swift:3536` (restored bubbles)
  - `AgentRecoveryCatalog.swift:834` (the catalog intent context)
  - `AgentModeViewModel+RecoveryActions.swift:786`
- `Sources/RepoPrompt/Features/AgentMode/Views/AgentMessageBubble.swift` bubble text:
  - the new "Not confirmed" label and help, "The agent didn't confirm it received this message. Sending it again might duplicate it." (`:411`, `:421`)
  - the neutral `.notSent` help for every exit kind, "This message was not delivered to the agent." (`:419`)
- `Sources/RepoPrompt/Features/AgentMode/ViewModels/AgentModeViewModel+RecoveryList.swift:704-720` (call site `:316`) adds a new recovery-list line: "The agent didn't confirm it received it. Sending it again could deliver it twice."

Left unchanged:
- The row title "Message may have been delivered".
- The scheduled-messages dashboard and banner "Delivery unconfirmed · …" strings (`AgentScheduledMessagesViewModel.swift:435-467`, `AgentScheduledSendBanner.swift:381-383`). Those are live schedule statuses, not exit wording.

### O51: one-time settlement

- `Sources/RepoPromptAgentCore/AgentMode/Models/AgentRecoveryModels.swift:1132` adds `ordinaryExitSettlementQualifies`. An intent qualifies only when all of these hold:
  - its state is `deliveryUnknown`
  - it has at least one attempt
  - every attempt closed `deliveryUnknown`
  - every run has terminal cause `ordinary`, state `completed` or `cancelled`, and no shutdown evidence
- `Sources/RepoPromptAgentCore/AgentMode/Runtime/Recovery/AgentRecoveryStore+OrdinaryExitSettlement.swift` adds `settleOrdinaryExitDeliveryUnknownIntentsOnce()`. On top of that predicate, it requires every attempt to have been dispatched before the cutoff and none to carry a `supersededOutcome` (`:143`); otherwise the whole intent is skipped. For each qualifying intent:
  - it sets the intent to `providerAccepted`
  - it adds `intent.extras.deliverySettlement = {reason: "ordinaryRunExit", recordedAt}`
  - it changes each attempt to a `providerAccepted` outcome with `settledBy: ordinaryRunExit`, keeping the old outcome as `supersededOutcome`
- Only records with something qualifying are rewritten, using the store's atomic `replace`.
- The cutoff is the first settlement launch's start:
  - `Sources/RepoPromptAgentCore/AgentMode/Runtime/Recovery/AgentRecoveryStore.swift:375` holds `ordinaryExitSettlementLaunchCutoff`.
  - It is read from the previous launch mark (`:1531`).
  - Every launch mark this build writes carries it forward as `ordinaryExitSettlementCutoffMs` (`:1580`-`:1595`). That includes `running`, `shutdownInProgress` and `cleanExit`. Its first value is this launch's mark time.
  - Startup has already written the mark successfully before the pass runs. So the cutoff survives even when the pass's own marker write fails.
- Hard upper bound: `ordinaryExitSettlementLatestCutoff` = 2026-11-06T00:00:00Z (`AgentRecoveryStore+OrdinaryExitSettlement.swift:18`). The effective cutoff is the earlier of the bound and the persisted or launch-start cutoff (`:56`-`:59`, `:68`-`:71`), and that clamped value is what the marker stores. If the marker and the carried cutoff are both lost (for example across a downgrade), no attempt dispatched on or after the bound is ever settled.
- Older builds ignore the new launch-mark key. `readLaunchMark` (`AgentRecoveryStore.swift:1510`-`:1530`, the same at HEAD) parses a dictionary and checks only `schemaVersion == 1`, `appInstanceID`, `state` and `recordedAtMs`. An older build rewriting the mark drops the key, which the hard bound covers.
- The marker `AgentRecovery/v1/ordinary-exit-settlement.json` holds `{schemaVersion, cutoffMs, completed, recordedAtMs, settledIntentCount, failedSessionCount}`:
  - When the marker is absent, the cutoff is the carried launch cutoff, or this launch's start if none is carried (`:64`). `{cutoff, completed: false}` is written before any record is touched; if that write fails, nothing is modified.
  - An unfinished marker reuses the earlier of its stored cutoff and the carried one (`:55`).
  - An unreadable marker means nothing is modified.
  - A missing sessions directory is an empty, completed pass (`:89`). Any other enumeration error leaves the pass unfinished, with no completion (`:91`).
  - Unreadable or preserved records, and records whose write fails, count as failed.
  - `completed: true` is written only when no record failed (`:127`). `OrdinaryExitSettlementResult.completed` reports it.
  - While a completed marker exists, the pass never runs again.
- The pass shows no UI and logs only to the `RecoverySettlement` category.
- The owner added `ordinary-exit-settlement.json` to the `Scripts/quarantine_fixture_workspaces.py` allowlist (`:147`).
- `Sources/RepoPromptAgentCore/AgentMode/Runtime/Recovery/AgentRecoveryCoordinator.swift:976` calls it in `performStartup`, after `recordCurrentLaunchRunning()` and before `discoverRecords()`. Settled intents therefore never become crash-hold inputs.

### Who writes run-end evidence (audit, no code change)

The run evidence fields are `package internal(set)` (`AgentRecoveryModels.swift:753-754`). Only the store writes them:
- `recordRunTerminal` (`AgentRecoveryStore.swift:1305/1328`), reached from:
  - the live terminal commit: `AgentRunTerminalCommitBarrier.swift:394` → coordinator `recordTerminalEvidence` (`AgentRecoveryCoordinator.swift:3160`) → `recordRunTerminal` (`:3148`)
  - its same-launch retry: `retryFailedTerminalEvidence` (`:3199`) ← `AgentModeViewModel+Shutdown.swift:524`
- `recordRunShutdown` (`AgentRecoveryStore.swift:1343/1359`), reached from Stage A `prepareForShutdown` (`AgentRecoveryCoordinator.swift:2747`) ← `AgentModeViewModel+Shutdown.swift:356`

No path stamps evidence after the fact:
- Crash-hold acknowledgement and O43 (`AgentRecoveryStore.swift:1625-1717`) pass run attempts through unchanged.
- Startup classification (`AgentRecoveryStartupReconciliation.swift:134`) only reads.
- The codec only decodes.

So the O51 predicate is unchanged.

## Paths checked

| Path | Equivalent? | Result |
|---|---|---|
| Claude steer, interrupt acknowledged | yes | accepted at the acknowledgement |
| Claude steer or cleanup interrupt not acknowledged | yes | stays uncertain, including when a cancelled or failed completion arrives while the interrupt is still awaited |
| Claude Stop | yes | the started turn is marked before detach. Run end accepts it with no transient `deliveryUnknown`, without waiting for a CLI result or the cleanup interrupt's acknowledgement. Queued and older turns are never marked. The cleanup `interruptTurn` is bounded: a 1.5 s control-request timeout (`ClaudeNativeProcessSessionController.swift:1129`-`:1131`, enforced at `:4381`). |
| Claude window close / app quit | yes | `prepareSessionForWindowClose` marks the started turn before teardown, so release and stop settle it accepted |
| Claude final `result` text | n/a | never credited as a start, so it can't start the queued turn behind it |
| ACP steer | no fix needed | `session/cancel` makes the interrupted `session/prompt` return normally, which was already `noteAccepted()` |
| ACP Stop / window close / quit | yes | the teardown is recorded synchronously before the run task is cancelled. A started, non-overlapped prompt that then fails reports receipt, whether or not `session/cancel` was written first. |
| ACP overlapping prompts | n/a | fenced: neither prompt ever reports receipt |
| ACP prompt removed without a reply, then another prompt | n/a | can't happen: every such removal leaves the controller `.failed` or `.closing` (see O49: ACP) |
| Codex | none | acceptance is the `turn/start` / `turn/steer` RPC response. Interrupt only targets turns that are already accepted, so no change. |

## Tests

`Tests/RepoPromptTests/AgentMode/Recovery/AgentDeliveryQuietByDefaultTests.swift`, 16 tests.

ACP:
- `:202` `testACPPromptCancelledByRepoPromptAfterTheAgentStartedIsEvidenceOfReceipt`
- `:209` `testACPPromptFailureWithoutCancelOrWithoutAgentOutputIsNotEvidence`
- `:219` `testOverlappingPromptsAreFencedAndNeverReportReceipt`: neither prompt reports receipt, in the lend, reset and teardown variants
- `:240` `testDelayedOlderPromptOutputNeverStartsAQueuedNewerPrompt`: A is pending, B starts, A's delayed chunk arrives, then cancel and teardown. B is not accepted.
- `:267` `testRepoPromptTeardownRequestedBeforeCancelIsEvidenceForAStartedPrompt`:
  - teardown with no `session/cancel` → receipt
  - teardown requested before the prompt started → no receipt
  - no output → no receipt

O51:
- `:375` `testOrdinaryExitIntentsSettleOnceWithTheirReasonAndEverythingElseIsUntouched`. Ordinary completed and cancelled intents settle with the reason and the superseded outcome. Nine cases stay byte-for-byte untouched:
  - crash
  - userCancel
  - appQuit
  - providerProcessLost
  - legacy cause
  - failed ordinary
  - shutdown evidence
  - an open attempt
  - no attempt

  A crash-only record is not rewritten at all.
- `:429` `testSettlementIsOneTimeAndASecondLaunchIsANoOp`
- `:514` `testEnumerationFailureWritesNoCompletionAndTheResumedPassKeepsItsCutoff`
- `:548` `testAbsentSessionsDirectoryCompletesThePass`
- `:558` `testRecordWriteFailureLeavesThePassUnfinishedUntilTheNextLaunch`
- `:587` `testMarkerWriteFailuresNeverModifyWithoutACutoffAndNeverClaimCompletion`
- `:623` `testFailedInProgressMarkerNeverLetsALaterLaunchSettleTheFirstLaunchsUncertainty`: L1's in-progress marker write fails and L1 creates new qualifying uncertainty. L2 settles only the pre-L1 intent and stores L1's start as the cutoff.
- `:670` `testHardCutoffBoundsTheCohortWhenTheMarkerAndTheCarriedCutoffAreBothLost`. L1 runs after the bound and its in-progress marker write fails. An older-build launch-mark rewrite then drops the cutoff key, and L2 runs later still. L2 settles only the pre-bound intent, stores the bound as the marker cutoff, and leaves L1's uncertainty untouched.
- `:727` `testCoordinatorStartupSettlesBeforeDiscoveryAndLeavesCrashCauseUncertainty`. Reconcile is stubbed, so this test checks records only.

O50:
- `:769` `testRecordedRunEndEvidenceTellsCleanFromUncleanExits`
- `:790` `testDeliveryWordingNamesACrashOnlyForAnUncleanExit`, including the neutral `.notSent` help

Claude, in `Tests/RepoPromptTests/AgentMode/Recovery/AgentProviderHandoffTests.swift` (the `AgentModeRunServiceLifecycleTests` extension):
- `:668` `testClaudeWrittenTurnCancelledLeavesDeliveryUnknown`: control; a cancel RepoPrompt did not request still raises one needs-action item.
- `:932` `testClaudeTurnInterruptedByStopSettlesAcceptedWithNoNeedsAction`: the controller shuts down before any result. The test asserts accepted and `supersededOutcome == nil`. It then waits until the coordinator's live record (the record the catalog projects) carries the accepted outcome, and reads the needs-action count once, at baseline.
- `:1013` `testClaudeStopMarksOnlyTheStartedTurnNeverAQueuedOrOlderOne`: a late `.cancelled` for an older retained turn or a queued, never-started turn leaves it `deliveryUnknown`.
- `:1080` `testClaudeInterruptNotSentLeavesTheMessageUncertain`
- `:1154` `testClaudeCompletionDuringAPendingSteerInterruptWaitsForItsOutcome`: steer, then `.failed` while the interrupt is held.
  - The completion is held and not accepted.
  - If the interrupt fails, the message stays `deliveryUnknown`. If it is acknowledged, it is accepted.
- `:1258` `testClaudeTurnInterruptedBySteerSettlesAcceptedWithNoNeedsAction`

Quit route:
- `Tests/RepoPromptTests/AgentMode/Recovery/AgentRecoveryResetBoundaryTests.swift:380` `testAppQuitTeardownSettlesAStartedClaudeTurnAcceptedWithoutAResult`, through `prepareForWindowClose(reason: .appQuit)`.
- It seeds the written handoff through the DEBUG seam, because the VM harness can't prepare a real Claude session.

Real controller, `Tests/RepoPromptTests/AgentMode/ClaudeCompatible/ClaudeNativeTurnTeardownTests.swift`:
- `:72` `testStartedTurnIsTheTurnOutputIsAttributedToAndNeverAQueuedOne`
- `:98` `testRealisticResultMessageNeverStartsTheQueuedTurnBehindIt`: a result with text, usage and `is_error`, run in both immediate and deferred (`session_state_changed`) completion modes
- `:148` `testOutputWithoutAQueuedTurnStartsNothing`

Mutation check (round 1): accepting a cancelled or failed completion on the provisional steer mark makes the steer-interrupt test fail, with 5 failures (ticket 7328bb48). The source was restored and the test re-run green (ticket e77e4124).

Final round:

| Run | Result | Ticket |
|---|---|---|
| `make dev-swift-build PRODUCT=RepoPrompt` | completed | e1d5744a |
| `AgentDeliveryQuietByDefaultTests` | 16/16 | 7200f962 |
| `AgentProviderHandoffTests` | 12/12 | a81ab62c |
| `AgentModeRunServiceLifecycleTests` (includes the Claude tests above) | 242/242 | ea9fd161 |
| `ACPAgentSessionControllerModeConfigTests` | 51/51 | d19c6b1b |
| `AgentRecoveryCoordinatorTests` | 79/79 | 57d331f6 |
| `AgentRecoveryStartupCompositionTests` | 24/24 | 353be02f |
| `AgentRecoveryResetBoundaryTests` | 24/24 | 0574cd8d |
| `make dev-lint` | completed | 626ef396 |

Earlier round, not re-run:

| Run | Result | Ticket |
|---|---|---|
| `ACPProviderSessionIdentityTests` | 5/5 | a7f02726 |
| `RegisteredNativeTransportWriteFenceTests` | 18/18 | ae3558ed |
| `ClaudeNativeTurnTeardownTests` | 6/6 | 73655f61 |
| `AgentRecoveryReconciliationTests` | 84/84 | b0ffde56 |
| `make guardrails` (not re-run) | fails only on this file being an orphan context document, plus the existing AGENTS.md route-count warning | — |

Not covered:
- Live app acceptance (no relaunch allowed).
- ACP Stop/quit has no route-level test. The fixture controller can't be shut down safely, so the teardown evidence is tested at controller level and the two call sites are one synchronous line each.
- The whole-intent `supersededOutcome` skip can't be reached with records the codec accepts.

## Owner-record count (read-only)

The script is `.agent-artifacts/step11/count_delivery_unknown.py` (git-ignored). It mirrors `ordinaryExitSettlementQualifies` and only reads `~/Library/Application Support/RepoPrompt CE/AgentRecovery/v1/sessions/*.json`. It prints counts, and IDs only with `--ids`.

It does not model the cutoff or the 2026-11-06 hard bound. Every existing attempt predates both. The live launch mark was written by an earlier build and carries no cutoff, so the first launch of this build uses its own start, and every existing attempt predates it.

Results on 2026-10-29, unchanged after the final round:
- `deliveryUnknown` intents now: **24** (the owner saw 23 earlier; one has been added since)
- O51 will settle: **21**
- O51 will leave: **3**
  - `runWithoutTerminal` (crash or unclean exit): 2, `D34C1EF3-ED02-4986-9339-C1B2EDA0BB93`, `849122AE-A97F-48A2-BEE2-CD2CE63D6A7A`
  - `runCause=userCancel`: 1, `98DB00B2-826E-4A9D-AFDC-80C94E15EA1E`
- Settle IDs:
  - 8FBC8848-F40F-411E-BDA5-EAC7197637DB
  - C28B9DEA-B142-40E4-9A38-35533DCDB8CA
  - A20FE98B-2B4C-4468-A236-61ED410DA2D1
  - 4E4AB668-9D3E-40CA-A8F7-CC2253DC3904
  - BAE7D81D-E6CB-46DC-BD5C-99DF780D97DD
  - E71C7763-4A6A-4E1D-A664-F0F277E89367
  - 1C3097B0-AB8C-4EC5-823C-2CE6B739A36B
  - 2270C6D3-B26E-4DB4-A534-AD3D6606931A
  - 5D305E65-A5D4-4F31-8322-723A3042A7E0
  - 64B881A9-EF96-4E29-B5E5-41D24EB1C6EB
  - 7DE15893-D2B1-408D-92BD-96CA2B0DEA0B
  - B0D3B79D-881B-4517-A65C-F53C72503B5F
  - 86823686-C5A6-4867-9A28-C42351587D8A
  - 839A9753-470F-45AD-A1C1-EC8061B8EEA0
  - E48237DE-1533-40F3-8053-569E1314E575
  - 4BE870F2-3D2B-412E-920A-06A711429A51
  - 3C85CDD2-4F3C-47CB-B9D5-8E0084B93C29
  - 71D8500E-0D3E-4F4E-9E85-7B06571BB894
  - 1E8DC474-E021-489D-AE32-5AFF3C22C7DC
  - 36499557-FBD7-4DFA-9C94-05BDB0F6478A
  - 8BA4D6F5-FD60-4305-A641-F6B630D7B31B

Recount after a relaunch, from the repo root:

```
python3 -I .agent-artifacts/step11/count_delivery_unknown.py
```

Expect `O51 would settle: 0`. The total will be **3, not 0**, because the three intents left above don't qualify by design. The userCancel one was a Stop recorded by an earlier build. O51 is scoped to cause `ordinary`, so widening it to user cancels is an owner decision.

## Review round

Three OracleA/OracleB rounds were run: the initial review and two re-reviews, which is the policy cap. A re-review was allowed only because each earlier round found a P1 (O52). The raw exports are in `prompt-exports/` and are not kept here.

**Round 0 (initial review)**
- **OracleA P0, downgraded as an owner decision (O51).** The one-time pass accepts intents without proof that each message's own turn started. O51 chose that group of intents deliberately, so the pass is unchanged.
- **P1s fixed in round 0** (F1–F5 above):
  - ACP receipt evidence came from a shared "last prompt" flag.
  - Claude marked every unresolved turn and never cleared the mark.
  - Marker failure paths could finish or rerun the pass wrongly.
  - A Claude Stop raised a needs-action item for a moment, and could leave it permanently.
  - The quit path had not been traced.
  - OracleB P1-3 asked whether run-end evidence could be written after the fact (F4). It was verified by reading every writer, and none can.
- **P2s fixed in round 0:**
  - The "not sent" help text is neutral.
  - The new parameters are required.
  - An existing superseded outcome is never overwritten.

**Round 1 (re-review 1)** found new P1s in the fixes, all fixed (G1–G5):
- **G1:** a late chunk from an older ACP prompt could be credited to a newer one. It is now fenced.
- **G2:** a provisional steer mark could accept before a failed interrupt took it back. The completion is now held until the interrupt's outcome is known, and teardown has its own final flag.
- **G3:** the text of Claude's final `result` message could start the queued turn behind it. Only `assistant` and `stream_event` payloads count now.
- **G4:** a failed marker write let the next launch take a fresh cutoff. The cutoff is now carried in every launch mark.
- **G5:** ACP Stop and quit acceptance depended on task-cancel ordering. A synchronous teardown generation now handles it.

**Round 2 (re-review 2, the cap)** confirmed G1–G5 and found two narrow P1s, fixed without a further review:
- **H1 (OracleA).** If the marker write failed and an older build then rewrote the launch mark, the cutoff could be re-taken. The cutoff is now also capped by a fixed date, 2026-11-06T00:00Z, so no attempt dispatched after it can ever be settled. A test covers the legacy rewrite.
- **H2 (OracleB, conditional).** An ACP controller reused after a Swift-side cancelled prompt could wrongly credit output. Shown impossible by reading the code: a written `session/prompt` waits on a continuation with no cancellation handler (`ACPAgentSessionController.swift:2441`). Every path that drops a pending prompt without a reply leaves the controller `.failed` or `.closing`, and `prompt()` then refuses. The main agent spot-checked this.
- **P2 fixed:** the "Stop adds no needs-action item" test waits for the settled record, then asserts the count once.

**Deferred P2s:**
- No route-level ACP Stop or quit test, because the fixture transport must not be shut down. ACP is covered at controller level.
- Claude teardown routes other than Stop, quit and window close (agent or model switch, MCP-health restart, session reset) record `deliveryUnknown` first, and an interrupt acknowledgement then refines it to accepted.
- Wall-clock skew against the cutoff.
- An unreadable launch mark loses the carried cutoff, though the fixed date still bounds it.
- If the app is force-killed after Stage A of quit, the crash wording is lost.
- An attempt still `dispatching` after a clean run end gets the "not confirmed" wording.
- An unfinished pass rescans every record on each launch.
- The persisted `notConfirmedByAgent` value may not decode in older builds.
- Remote-session records are settled locally; no remote sessions exist on this machine.
- Cold restores may read records before the pass, so a session restored during it could show "not confirmed" for an intent the pass then settles. Whether a saved stamp keeps that wording was not verified.
