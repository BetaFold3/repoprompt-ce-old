# Step 9-activation-a worker report

Scope: read when the task touches the activation composition, subset process registration, the unqualified-provider refusal or Check's Stop (Step 9-activation-a).
Authority: Reference
Last-verified: 2026-10-26
Covers: the pair worker's verbatim reports for Step 9-activation-a, round by round.

## Round 0 — implementation

Step 9-activation-a is implemented with `AgentRecoveryActivation.production = .off`. The build, lint and all 15 suites I ran pass. `make guardrails` and `Scripts/check-agent-context` fail, but only on three evidence docs: `activation-plan-oraclea.md`, `activation-plan-oracled.md` and `activation-scout.md` are new and nothing links to them yet. That's yours to fix since you own the docs; source-layout and allowlist guardrails pass. Both audits came back clean. Nothing is committed or staged and I edited no docs.

**Files changed**
- **New:** `Sources/RepoPromptAgentCore/AgentMode/Runtime/Recovery/AgentRecoveryActivation.swift` with `.off`, `.claudeAndCodex` and `production = .off`. It carries the O32 comment, your O37 line and a note on writer basenames.
- **Recovery core:** `AgentProcessRegistrySupport.swift`, `AgentProcessRegistry.swift`, `AgentRuntimeLaunch.swift`, `AgentRecoveryActionRunner.swift`, `AgentRecoveryCoordinator.swift`, `AgentRecoveryCoordinator+Check.swift`.
- **Controllers:** `ClaudeNativeProcessSessionController.swift`, `CodexAppServerClient.swift`, `ACPAgentSessionController.swift`.
- **App:** `AgentRecoveryAppComposition.swift`, `AppRelaunchCoordinator.swift`, `AgentModeViewModel.swift`, `+RecoveryActions.swift` (comments only), `+RecoveryCheck.swift`.
- **Tests:** `AgentProcessRegistryTests`, `AgentRecoveryActionTests`, `AgentRecoveryCoordinatorTests`, `AgentRecoveryRuntimeOwnershipTests`, `AgentRecoveryStartupCompositionTests`, `AgentRecoveryTestSupport`, `ClaudeNativeRuntimeSessionArgumentsTests`, `CodexAppServerRuntimeFenceTests`, `RegisteredNativeTransportWriteFenceTests`, `App/AppRelaunchCoordinatorTests`.
- **Staging hazard:** `ClaudeNativeProcessSessionController.swift` and possibly `AgentModeViewModel.swift` also hold another session's uncommitted edits. Stage those by hunk. `WorkspaceSwitchRecoveryTests` and `ClaudeAgentModeCoordinatorMCPRecoveryTests` show as modified but aren't mine; I didn't touch them.

**Acceptance**
1. **Build and suites:** pass. Guardrails and the agent-context check fail only on the orphaned docs above.
2. **Values:** `testClaudeAndCodexActivationCoversExactlyTheFourQualifiedPairs` and `testProductionActivationStaysOff…`. They cover the four pairs only, `.off` registering nothing, `production == .off`, the five action kinds, and `safeRestart` off.
3. **Covered vs uncovered pairs:**
   - New test `testUncoveredPairsLaunchUnregisteredUnderClaudeAndCodex`:
     - Claude Code standard joins retirement; GLM and ACP don't.
     - ACP, compatible GLM and headless GLM get no launch and no runtime file.
     - The inherited marker is stripped and none is added.
     - The covered pair reserves one file and its environment carries the marker.
   - Also `testNarrowedProviderQualificationRegistersOnlyCoveredPairs`, which keeps `reserveLaunch` throwing `.unqualifiedProvider`.
   - Also `testPartialCoverageRefusesTheWholeAppStoppedProof`.
   - The Claude half of the native fence suite and the whole Codex fence suite now run under `.claudeAndCodex`.
4. **Runner refusal:** `testUnqualifiedProvidersRefuseEveryChoiceBeforeAnyReservation` (six kinds × every action, no hold, zero writes, Check gives could-not-check, a nil provider says "this provider"). Also `testQualifiedProviderWithoutAHistoryPerformerRefusesOnlyChoicesThatReconcile`.
5. **Check Stop:** `testCheckStopAbandonsAHungReconcileButKeepsItsActionHold` (the hold persists, a second dispatch is refused, the late result updates the row) and the rewritten `testCheckStopHaltsBeforeTheNextItemAndRunsOneAtATime`.
6. **`node` basename:** `testNodeBasenameMemberKeepsBlockingSendsUnderClaudeAndCodex`.
7. **One source:** `testCompositionAndViewModelDefaultReadTheOneProductionActivation` (the VM default, `makeActionRunner()`, the composition and an installed window all resolve to `.production`; an explicit activation reaches the runner). For this I exposed the runner's activation as `package let activation`.

**Audits (D 3.5)**
- **Item 1, Codex owner scope: no gap found.**
  - Agent clients turn on owner-captured scopes: `CodexAgentModeCoordinator.swift:5067`, and `:4809` for recovery.
  - Every thread write runs inside a bound scope:
    - start and resume: `:3641`
    - turn start: `:2986` and `:4588`
    - send and steer: `:5871`, `:5886`, `:5923`
    - thread name: `:4130`
    - compact: `:1730`
    - goal: `:1793`
    - recovery observe: `:4811`
  - The detached memory-mode retry captures its owner's scope (`CodexNativeSessionController.swift:1672`).
  - Non-agent clients are explicitly sessionless (`CodexProviderHelpers.swift:32`).
  - Only the DEBUG stress harness builds a client without a scope (`AgentChatStressHarness.swift:1427`); under registration it would just be refused.
- **Item 2, sessionless Claude launches: no gap found.**
  - The model probe and chat launches are explicitly sessionless (`ClaudeCodeProvider.swift:292`, `ClaudeCLIModelDiscoveryProbe.swift:58`).
  - Headless launches read the message's scope (`ClaudeCodeAgentProvider.swift:397`); Agent Mode sets it at `AgentModeViewModel.swift:19194` and Context Builder sets sessionless at `ContextBuilderAgentViewModel.swift:3550`.
  - Native launches happen only from two bound `startOrResume` calls (`ClaudeAgentModeCoordinator.swift:1466`, `:1601`).
  - One minor case: the fallback message at `AgentModeViewModel.swift:3162` is only built if the VM is gone, and it gets refused.
  - New test `testClaudeAndCodexSessionlessLaunchesReserveAndUnboundLaunchesAreRefused`.

**Deviations and cuts**
- The runner reads the provider from `request.target.providerKindRaw`; I didn't add a `provider:` parameter to `perform` as D suggested. It's the same session-to-provider mapping without changing the API.
- The Check progress summary now reads "Checking N of M… Stopping…".
- Acceptance 3 doesn't spawn a real child to inspect its environment. It checks the same steps the real launch path uses (strip the marker, then build the environment with no runtime ID).
- Ten existing qualified-runner tests now pass a `.nothingImported` history performer. Without one, a qualified Continue or Reconcile is now refused, which is the D 3.3 contract. One count assertion moved from 1 to 2 reconciles, and I added an assertion that the continuation reconciles first. No assertion was weakened.

**Test counts (all 0 failures)**

| Suite | Tests |
|---|---|
| AgentRecoveryActionTests | 32 |
| AgentRecoveryCoordinatorTests | 72 |
| AgentProcessRegistryTests | 39 |
| RegisteredNativeTransportWriteFenceTests | 18 |
| CodexAppServerRuntimeFenceTests | 13 |
| AgentRecoveryStartupCompositionTests | 17 |
| AgentRecoveryReconciliationTests | 54 |
| AgentRecoveryRuntimeOwnershipTests | 12 |
| AgentProcessRegistryAssociationTests | 8 |
| ClaudeNativeRuntimeSessionArgumentsTests | 3 |
| ProcessLauncherRuntimeMarkerTests | 5 |
| AppRelaunchCoordinatorTests | 11 |
| AgentScheduledSendNonCodexMandatoryTests | 7 |
| AgentLifecycleShutdownCoordinatorTests | 51 |
| AppQuitPolicyTests | 6 |


## Round 1 — fixes for the round-0 reviews (worker report, verbatim)

All nine fixes are in, but P1-1 is only partly closed and needs your decision. A run card doesn't record which provider produced its run, so the new mismatch guard can't catch the reviewers' scenario of switching a session from Codex to Claude Code and then pressing Continue. Build, lint and 10 suites pass (one filter per run).

**P1-1: the gap that's still open**
- **No existing refusal:** nothing in the store or dispatch path refuses a provider mismatch. The request target is always rebuilt from the session's current `selectedAgent` (`AgentModeViewModel+RecoveryActions.swift:134`, `:285-288`), and the fence at every await compares against that same current value (`:304`).
- **No recorded provider:** `AgentRecoveryRunAttempt` (`AgentRecoveryModels.swift:738`) has no provider field. Only the session-level `agentKind` is persisted, and it follows the current agent.
- **Real effect:**
  - B's exact scenario can't happen as described, because the gate and the performers both read the current provider.
  - Something similar does: after a Codex → Claude Code switch, Continue on the old Codex card is performed as Claude Code, against Claude's conversation ID.
- **What the guard covers:**
  - It's in at `+RecoveryActions.swift:221` and `:277`, with your exact text, before the runner, and with zero writes.
  - It only fires for a cached or earlier request built before a switch.
  - The test `testProviderMismatchedTargetIsRefusedBeforeTheRunner` goes through the real `performRecoveryResumeAction` by seeding such a request.
- **Closing it fully:** the run's provider would have to be recorded at run start, for example in the run attempt's `extras`, and the guard pointed at that value. That's a schema change, so I've left it to you.

**The other fixes**
1. **Check Stop race (A F1, B P2-1, P2-2):**
   - The item task now skips its work if Stop already finished the wait (`AgentRecoveryCoordinator+Check.swift:300`).
   - Abandoning clears `.working` only if this item's reconcile actually started (`:261`, recorded at `:296`), so another action's `.working` is left alone.
   - The window sets `.working` at `+RecoveryCheck.swift:92`, with no `await` before it. Its late completion at `:95` only writes nil or `.failed`, never `.working`, so with the skip in place a finished report can't get `.working` back.
   - To test Stop before the task starts, I added a DEBUG hook, `test_recoveryCheckItemQueued` (`AgentRecoveryCoordinator.swift:534`).
   - Test: `testCheckStopBeforeTheItemsWorkStartsNeverReconcilesAndKeepsAnotherActionsWorkingState`. Its two phases each fail without its fix: no reconcile after Stop, and another action's `.working` is kept.
2. **Cancelled heading (A F3):**
   - Uses `cancelRequested` (`+Check.swift:186`) and reads "Cancelled: checked 1 of 1", leaving out ", 0 not checked".
   - Test: `testCheckStopOnTheOnlyItemReportsCancelled`.
3. **Provider mismatch:** see P1-1 above.
4. **P1-2 audit:**
   - The registry property is renamed `isAnyPairRegistered`. Its consumers:
     - `AgentRecoveryAppComposition.swift:138` (runner registration): "any pair" is enough, because the runner also checks the provider.
     - `AppRelaunchCoordinator.swift:194`: needs all pairs. `verifyAllFamiliesStopped` already refuses partial coverage, and `safeRestart` is off in both activations.
     - `AgentRuntimeLaunch.swift:86`: "any pair" is fine. `:94` checks its own pair.
     - `AgentProcessRegistry.swift:684`: also checks the pair.
     - `AgentProcessRegistry.swift:1086`: also requires all pairs covered.
   - The runner's `isAvailable` and the Check gate only decide whether buttons show; `perform` checks the provider.
   - Controllers use their own pair:
     - Claude native: `:821`
     - Codex app-server client: `:555`, read at `CodexNativeSessionController.swift:4542`
     - ACP: `:388`
   - Quit and shutdown survivors are only the registry's runtime records, which only registered launches create. An unregistered controller can't be mistaken for one, so no fix was needed there.
   - Baseline capture already required `.claudeCode` (GLM, Kimi and custom are separate kinds). It now also requires Claude's own pairs to be covered: `capturesDispatchBaselines(for:)` at runner `:174`, used at VM `:897`. Tested in `testAssociationUnavailableIsNeitherCompletionNorImport`, including GLM, Kimi, custom and a Codex-only activation.
5. **`coversProvider` (P2-3):**
   - Now requires every family that serves the provider to be covered (`AgentRecoveryActivation.swift:49`).
   - Test: `testProviderIsCoveredOnlyWhenEveryFamilyServingItIsCovered`, with Codex-exec-only, headless-Claude-only and headless-GLM-only activations, plus a refusal through the runner.
6. **Composition consistency (P2-4):** `assert` that the registry's qualification equals `activation.runtime` (`AgentRecoveryAppComposition.swift:61`).
7. **History text (P2-5):** the new `historyUnavailableText` (runner `:143`) is used at `:203` with your exact text.
8. **Weak assertions (P2-6):** Send saved now uses a real saved intent and expects `.completed(.dispatched, reason: nil)`, with one dispatch and no reconcile. I removed the hold assertion that couldn't fail; "nothing reserved" and "zero writes" still back the claim.
9. **Claude controller (P2-7):** `config` is a `let` (`:464`), so the two derivations could never differ. Even so, the pair is now derived once into `launchFamily` and `launchProvider`.

**Claude controller hunks I changed** (`ClaudeNativeProcessSessionController.swift`; all inside my earlier hunks):
- `:503-511`: added the `launchFamily` and `launchProvider` declarations next to `registersLaunches`.
- `:819-821`: the init computes the pair once and builds `registersLaunches` from it.
- `:1358-1360`: the launch site uses `launchFamily` and `launchProvider`.

**Files changed this round**
- **Sources:**
  - `AgentRecoveryCoordinator+Check.swift`, `AgentRecoveryCoordinator.swift`, `AgentRecoveryActionRunner.swift`, `AgentRecoveryActivation.swift`
  - `AgentProcessRegistry.swift`, `AgentRuntimeLaunch.swift`
  - `ClaudeNativeProcessSessionController.swift`
  - `AgentRecoveryAppComposition.swift`, `AppRelaunchCoordinator.swift`, `AgentModeViewModel+RecoveryActions.swift`
- **Tests:** `AgentRecoveryCoordinatorTests`, `AgentRecoveryActionTests`, `AgentRecoveryReconciliationTests`, `AgentProcessRegistryTests` (rename only).

No docs, staging, commits or `dev-format`.

**Test counts (all 0 failures)**

| Suite | Tests |
|---|---|
| AgentRecoveryCoordinatorTests | 74 |
| AgentRecoveryActionTests | 33 |
| AgentRecoveryReconciliationTests | 55 |
| AgentProcessRegistryTests | 39 |
| AgentRecoveryStartupCompositionTests | 17 |
| AgentLifecycleShutdownCoordinatorTests | 51 |
| AppQuitPolicyTests | 6 |
| AppRelaunchCoordinatorTests | 11 |
| RegisteredNativeTransportWriteFenceTests | 18 |
| ClaudeNativeRuntimeSessionArgumentsTests | 3 |

## Round 1b — recording the run's provider (worker report, verbatim)

Run cards now record the provider their run started with, and Continue and Reconcile refuse when the session's provider differs or the provider wasn't recorded. No schema change was needed: it's stored under `"providerKind"` in the run attempt's `extras`. `make dev-build` and `make dev-lint` pass, and every suite below passes (one filter per run).

**Where it's recorded**
- **Store:** `AgentRecoveryStore.ensureRunAttempt` takes an optional `providerKindRaw` (`AgentRecoveryStore.swift:1174`). It is written only when the attempt is first created (`:1207`); an existing attempt's provider, or a legacy attempt's missing one, is never rewritten.
- **Lane:** `ensureRunAttempt` passes the value through (`AgentRecoveryCoordinator.swift:2962`, `:2972`).
- **Run-start callers** pass `session.selectedAgent.rawValue`:
  - `AgentRecoveryQueuedInput.swift:293`: the ownership dispatch, reached by Codex through `beginUnderActiveRun` and by Claude, ACP and headless steering through `AgentProviderHandoff.begin(ownership:)`.
  - `AgentProviderHandoff.swift:313`: `commitDispatch` at run start for Claude, ACP and headless.
- **Model:** `AgentRecoveryRunAttempt.providerKindExtrasKey` and `recordedProviderKindRaw` (`AgentRecoveryModels.swift:755`, `:759`).
- **Guard:** in `performRecoveryResumeAction`, after the record read (`+RecoveryActions.swift:176`, `:189`), for Continue and Reconcile only. A mismatch gives your existing text naming the recorded provider; a missing value gives the new "wasn't recorded" text (`:285`, `:298`). Nothing is reserved or written.
- **Unaffected:** saved messages and question answers.

**Two behaviours to check**
- **Continue in new conversation is not guarded.** I left it out because you named only Continue and Reconcile, and it deliberately starts a new conversation with the current provider. Say if you want it guarded too.
- **Some paths never record a provider.** The terminal-evidence, shutdown and delegated-child-link writes (`AgentRecoveryCoordinator.swift:2645`, `:3050`; `AgentRecoveryStore+DelegatedChildLinks.swift:82`) pass none. They only matter if one of them is the first write for a run, which shouldn't happen for durable input. If it does, the card fails safe with the "wasn't recorded" refusal.

The cached-request guard from last round is still in place.

**Codec finding:** `extras` round-trips unchanged.
- Decoding keeps every member it doesn't recognise as `extras` (`AgentRecoveryRecordCodec.swift:1063`), and encoding starts from `run.extras` before writing the typed members (`:1068`).
- The contract that records keep unknown members and must re-encode to exactly the decoded value is in the codec's header comment (`:3-8`).
- Older readers therefore keep `providerKind` too: they use the same `extras` path, and the store's update path copies the existing attempt with its `extras`.
- The new run-start test checks the stored record re-encodes to identical bytes.

**Tests**
- **Recorded at run start:** `testRunStartRecordsTheSessionsProviderOnTheRunAttempt` (`AgentRecoveryQueuedInputTests.swift:101`). It goes through the real ownership dispatch, checks the codec round-trip, and checks that a later write after switching provider doesn't rewrite the value.
- **Through the real `performRecoveryResumeAction`** (`AgentRecoveryReconciliationTests.swift:2174`, `:2186`, `:2197`):
  - `testRunCardFromASwitchedProviderIsRefusedNamingTheRecordedProvider` and `testRunCardWithoutARecordedProviderIsRefused` each check that Continue and Reconcile are both refused with the exact text, never reach the runner, and leave nothing written, reserved, sent or cached.
  - `testRunCardFromTheCurrentProviderProceedsToTheRunner` checks a matching provider proceeds.
- **Fixture updates:** three existing view-model tests in the same file now record the session's provider when building their run attempt, so they still reach the runner.

**Files changed this round**
- **Sources:**
  - `AgentRecoveryModels.swift`
  - `AgentRecoveryStore.swift`
  - `AgentRecoveryCoordinator.swift`
  - `AgentRecoveryQueuedInput.swift`
  - `AgentProviderHandoff.swift`
  - `AgentModeViewModel+RecoveryActions.swift`
- **Tests:** `AgentRecoveryQueuedInputTests.swift`, `AgentRecoveryReconciliationTests.swift`.
- **Lint workaround:** I first put the run-start test in `AgentProviderHandoffTests.swift`. That pulled the file into lint, which flagged blank lines inside an embedded Python script string that were already there. I reverted my own addition (the file is back to its original state) and moved the test to `AgentRecoveryQueuedInputTests` rather than edit that script.
- No docs, staging, commits or `dev-format`.

| Suite | Tests (0 failures) |
|---|---|
| AgentRecoveryCoordinatorTests | 74 |
| AgentRecoveryActionTests | 33 |
| AgentRecoveryReconciliationTests | 58 (+3) |
| AgentRecoveryStartupCompositionTests | 17 |
| AgentRecoveryStoreTests | 21 |
| AgentRecoveryQueuedInputTests | 11 (+1) |
| AgentRunTerminalCauseTests | 17 |
| AgentProviderHandoffTests | 12 |
| AgentRecoveryStartupReconciliationTests | 21 |


## Round 2 — fixes after re-review 1 (worker report, verbatim)

All five fixes are in, and build, lint and every listed suite pass (one filter per run). The F1 test, though, checks the helper directly rather than a legacy card through the real path.

**F1 finding:** yes, a run card reaches Continue or Reconcile today with no run attempt ID.
- A legacy interrupted turn's interruption stamp carries a nil `runAttemptID` (`AgentTranscriptModels.swift:461`, "nil for a legacy turn"). Its card has a `.turn` payload that yields `(nil, turnID)` (`+RecoveryActions.swift:1522`).
- With no attempt, the card classifies as interrupted (`AgentRecoveryStartupReconciliation.swift:160`). The row then offers Continue and Reconcile (`+RecoveryList.swift:225`, via `recoveryRunActions`), and `sourceRunAttemptID` is set to nil (`+RecoveryActions.swift:145`).
- So the round-0 guard was skipped and B F1 was a real P1 once activation is on.

**F4 finding:** confirmed, Check is guarded. Check's Reconcile calls `performRecoveryResumeAction(rowID:action: .reconcileHistory, report:)` (`+RecoveryCheck.swift:95`, inside `reconcileRecoveryCheckItem` at `:81`). The only production call to the runner's `perform` is inside `performRecoveryResumeAction` (`+RecoveryActions.swift:251`).

**Per fix**
1. **B F1 (fail closed):**
   - For Continue and Reconcile, a nil `sourceRunAttemptID` or an attempt missing from the record now gets the "provider wasn't recorded" refusal, with zero writes (`+RecoveryActions.swift:187`). This is B's logic, moved into a static helper `recoveryRunProviderRefusal(sourceRunAttemptID:runAttempts:current:)` (`:302`) so it can be tested.
   - Test `testRunProviderGuardFailsClosedWithoutAKnownRunAttempt` (`AgentRecoveryReconciliationTests.swift:2202`): nil ID and an unknown ID are refused; a found attempt with a matching provider proceeds.
   - The test calls the helper, not a real card. A legacy turn card only enters the catalog through a startup relaunch, which the view-model harness doesn't build. The zero-writes wiring is already covered by the three real-path run-card tests.
2. **B F2 (required argument):**
   - **Required now:** `providerKindRaw` on the store's `ensureRunAttempt` (`AgentRecoveryStore.swift:1174`) and on the lane's (`AgentRecoveryCoordinator.swift:2968`). In production the store's is only reached from lane code, so I made it required too.
   - **Terminal evidence:** `recordTerminalEvidence` takes a required provider (`:3054`), keeps it for the retry (`:3086`), and gets the session's provider from the commit barrier (`AgentRunTerminalCommitBarrier.swift:394`).
   - **Shutdown:** `ShutdownRunEvidence` has a required provider (`:2594`), filled from the session (`AgentModeViewModel+Shutdown.swift:345`) and passed on at `:2654`.
   - **Delegated child link:** this path can create the parent's attempt, so `commitDelegatedChildLink` now takes the parent session's provider (`AgentRecoveryStore+DelegatedChildLinks.swift:76`/`:91`, caller `AgentModeViewModel+DelegatedChildLinks.swift:300`).
   - **Behaviour unchanged:** the provider is still written only when the attempt is created. No production path passes an explicit nil; test callers that don't act on cards do.
3. **B F3 (Claude run start):**
   - New file `AgentRunStartProviderRecordingTests.swift`, test `testClaudeRunStartCommitDispatchRecordsTheSessionsProvider`. It runs `prepareRunStart`, binds the attempt, then `commitDispatch` with `.claudeCode`, and asserts the attempt doesn't exist before the commit and records `claudeCode` after it.
   - **Correction to my last report:** `commitDispatch` (`AgentProviderHandoff.swift:232`) records through `AgentRecoveryDispatchEvidence.begin(ownership:)`, i.e. `AgentRecoveryQueuedInput.swift:293`. The `:313` site is `attachRunAttempt` (`:273`), for evidence committed before its run attempt was known.
4. **B F4:** no change; see the finding above.
5. **A F2 (pre-start Stop wording):** when the item's Reconcile never started, the item now reads "Stopped before checking this item." (`AgentRecoveryCoordinator+Check.swift:149`, chosen at `:260`). The existing "check continues" text is kept when it did start. The pre-start test now asserts the new text (`AgentRecoveryCoordinatorTests.swift:2773`).

**Files changed this round**
- **Sources:**
  - `AgentModeViewModel+RecoveryActions.swift`, `AgentModeViewModel+Shutdown.swift`, `AgentModeViewModel+DelegatedChildLinks.swift`
  - `AgentRecoveryStore.swift`, `AgentRecoveryStore+DelegatedChildLinks.swift`
  - `AgentRecoveryCoordinator.swift`, `AgentRecoveryCoordinator+Check.swift`
  - `AgentRunTerminalCommitBarrier.swift`
- **New test file:** `AgentRunStartProviderRecordingTests.swift`.
- **Tests with explicit `nil` provider arguments** (mechanical), plus the F1 and A F2 edits in the first two:
  - `AgentRecoveryReconciliationTests`, `AgentRecoveryCoordinatorTests`
  - `AgentRecoveryActionTests`, `AgentRecoveryQueuedInputTests`, `AgentRecoveryStoreTests`
  - `AgentRecoveryStartupCompositionTests`, `AgentRecoveryStartupReconciliationTests`
  - `AgentRecoveryVMProducerAdmissionTests`, `AgentRecoveryResetBoundaryTests`, `AgentRecoveryDelegatedChildLinkTests`
- None of these files had other sessions' changes. No docs, staging, commits or `dev-format`, and the ledger is untouched. The new suite's frozen-ledger notice is informational; it runs with default deadlines.
- The first `make dev-build` failed because another session modified `MCPConnectionManager.swift` during the build. The rerun passed.

| Suite | Tests (0 failures) |
|---|---|
| AgentRecoveryCoordinatorTests | 74 |
| AgentRecoveryActionTests | 33 |
| AgentRecoveryReconciliationTests | 59 (+1) |
| AgentRecoveryQueuedInputTests | 11 |
| AgentRecoveryStoreTests | 21 |
| AgentProviderHandoffTests | 12 |
| AgentRunTerminalCauseTests | 17 |
| AgentRecoveryStartupCompositionTests | 17 |
| AgentLifecycleShutdownCoordinatorTests | 51 |
| AgentRunStartProviderRecordingTests (new) | 1 |
| AgentRecoveryStartupReconciliationTests | 21 |
| AgentRecoveryVMProducerAdmissionTests | 36 |
| AgentRecoveryResetBoundaryTests | 23 |
| AgentRecoveryDelegatedChildLinkTests | 12 |

B F5 and all P3s are deferred as you asked.

## Round 3 (after re-review round 2: B P2-1, P2-2, P3-1..P3-3)

The main agent applied these fixes after the last allowed re-review round. It read the source delta itself; no further Oracle review was run (policy: two re-review rounds).

All five round-2 items are in. The run's provider is now captured once at run start and every writer that can create a run attempt records that value, never the session's current provider. Build, lint and every suite listed below pass (one filter per run).

**Per fix**
1. **B P2-1 (capture once at run start)**
   - `AgentRunOwnership` gains `providerKindRaw` (`AgentRunLifecycleContracts.swift:88`), set by the lifecycle tracker's `begin` (`:208`, `:220`).
   - `session.beginRunAttempt` passes `selectedAgent.rawValue` (`AgentTabSession.swift:2006`).
   - Ownership tokens are only created by the tracker, so adding the field to their equality changes nothing in production.
   - Writers now read the provider from the ownership:
     - **Run-start dispatch:** `ownership.providerKindRaw` (`AgentRecoveryQueuedInput.swift:293`, `AgentProviderHandoff.swift:313`).
     - **Terminal evidence:** `commit.ownership.providerKindRaw` (`AgentRecoveryCoordinator.swift:3062`).
     - **Shutdown:** `run.ownership.providerKindRaw` (`:2651`).
     - **Delegated child link:** `parentOwnership.providerKindRaw` (`AgentRecoveryStore+DelegatedChildLinks.swift:91`).
   - Every writer has an ownership, so none passes an explicit nil. An ownership without a captured provider still records nothing and fails closed.
   - I removed the provider parameters I added last round to `recordTerminalEvidence`, `ShutdownRunEvidence` and `commitDelegatedChildLink`. Their production callers (the commit barrier, `+Shutdown` and `+DelegatedChildLinks`) no longer pass one, so nothing can feed them the session's provider.
   - The lane and store `ensureRunAttempt` keep the required argument. The provider is still written only when the attempt is created.
2. **B P2-2 (tests)**, each with the provider changed after the run started:
   - **Terminal and shutdown:** `testTerminalEvidenceCreatingTheAttemptRecordsTheRunStartProvider` and `testShutdownEvidenceCreatingTheAttemptRecordsTheRunStartProvider` (`AgentRunStartProviderRecordingTests.swift:53`, `:76`). Each starts the run on Codex and switches to Claude Code, then the write creates the attempt with Codex recorded.
   - **Lane level only:** these two call the lane methods directly, without the commit barrier or the view model's shutdown path. Those callers now only pass the commit or ownership, so the provider is chosen inside the lane methods.
   - **Delegated child link:** `testLinkCreatingTheParentAttemptRecordsTheParentRunStartProvider` (`AgentRecoveryDelegatedChildLinkTests.swift:128`) goes through the real `mcpCommitDelegatedChildLink`. The parent starts on Codex and switches to Claude Code, the child uses OpenCode, and the parent's attempt records Codex.
   - No path needed new test tooling.
3. **B P3-1 (doc comments):** each overload now has its own comment (`+RecoveryActions.swift:297`, `:309`).
4. **B P3-2 (neutral texts):** your exact wording, with tests updated:
   - Missing provider: `:288`.
   - Mismatch: `:320`. This also applies to the guard for requests cached before a provider switch.
5. **B P3-3 (Claude run-start test):** `testClaudeRunStartCommitDispatchRecordsTheSessionsProvider` (`:18`) first asserts the fixture defaults to Claude Code. It then runs the same `commitDispatch` path with Claude Code and with custom Claude-compatible, and checks the ownership captured each one.

B P3-4 is a note for your status line: the nil or unknown run-attempt case is tested only at the helper level, not through a real legacy card.

**Files changed this round**
- **Sources:**
  - `AgentRunLifecycleContracts.swift`, `AgentTabSession.swift`
  - `AgentRecoveryQueuedInput.swift`, `AgentProviderHandoff.swift`
  - `AgentRecoveryCoordinator.swift`, `AgentRecoveryStore+DelegatedChildLinks.swift`
  - `AgentRunTerminalCommitBarrier.swift`
  - `AgentModeViewModel+Shutdown.swift`, `AgentModeViewModel+DelegatedChildLinks.swift`, `AgentModeViewModel+RecoveryActions.swift`
- **Tests:**
  - `AgentRunStartProviderRecordingTests.swift` (rewritten, now 3 tests).
  - `AgentRecoveryDelegatedChildLinkTests.swift` (new test).
  - `AgentRecoveryReconciliationTests.swift` (new refusal texts).
  - Removed last round's now-invalid `nil` arguments from `AgentRecoveryCoordinatorTests`, `AgentRecoveryQueuedInputTests`, `AgentRecoveryReconciliationTests` and `AgentRecoveryStartupCompositionTests`.
  - `AgentRecoveryResetBoundaryTests` and `AgentRecoveryVMProducerAdmissionTests` are back to their committed state.
- No docs, staging, commits or `dev-format`, and the ledger is untouched.

| Suite | Tests (0 failures) |
|---|---|
| AgentRunStartProviderRecordingTests | 3 |
| AgentRecoveryDelegatedChildLinkTests | 13 (+1) |
| AgentRecoveryCoordinatorTests | 74 |
| AgentRecoveryReconciliationTests | 59 |
| AgentRecoveryQueuedInputTests | 11 |
| AgentProviderHandoffTests | 12 |
| AgentRunTerminalCauseTests | 17 |
| AgentLifecycleShutdownCoordinatorTests | 51 |
| AgentRecoveryStartupCompositionTests | 17 |
| AgentRecoveryResetBoundaryTests | 23 |
| AgentRecoveryVMProducerAdmissionTests | 36 |
| AgentRunLifecycleContractsTests | 5 |
| AgentRecoveryActionTests | 33 |
| AgentRecoveryStoreTests | 21 |
| AgentRecoveryStartupReconciliationTests | 21 |
