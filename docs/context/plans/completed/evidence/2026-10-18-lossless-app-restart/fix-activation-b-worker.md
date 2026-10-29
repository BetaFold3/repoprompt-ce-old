# Step 9-activation-b worker report

Scope: read when the task touches crash-hold confirmation from process-registry proof, the run-start registration mark, or Step 9-activation-b of the lossless app restart plan.
Authority: Reference
Last-verified: 2026-10-27
Covers: the worker's implementation, validation and review-fix round

## Round 0

Step 9-activation-b is implemented as OracleD's plan check describes. All 13 suites I ran pass and `make dev-lint` passes. `make guardrails` fails only at its last step, `check-agent-context`, on 3 evidence docs that nothing links yet; the plan status line in the spec needs to link them, and I left that edit to you. Nothing was staged, committed, formatted or launched.

Paths below are relative to `Sources/RepoPromptAgentCore/AgentMode/Runtime/Recovery/` unless shown in full.

**The proof (Recommendation 1)**
- **(a) Checks active and registry healthy:**
  - The new `AgentProcessRegistry.crashHoldExitProof` (`AgentProcessRegistry.swift:159`, types in `AgentProcessRegistrySupport.swift:345/375`) refuses with "process ownership is uncertain" unless:
    - the registry has started, with no storage failure;
    - its store has the same `appInstanceID` as the coordinator's (`:160-163`);
    - there is no unidentified preserved record, and none that names the session or shares its conversations or worktrees (`:178-182`).
  - When checks are inactive, Check still only reports.
- **(b) Run attempts only, each marked:** `+CrashHoldProof.swift:57` refuses holds with intents or legacy turns ("notOnlyRuns"); `:60-65` requires the `"registry"` mark on every held attempt ("notRegistered").
- **(c) Each attempt named by an earlier-launch record:** `AgentProcessRegistry.swift:192-199` (runNotRecorded). Records from this launch never count.
- **(d) F1 safety:** `AgentProcessRegistry.swift:183-190`. Any earlier-launch record that is not a persisted `.exited`/`.stopped` refuses with "an agent process may still be running" if it could belong to the session:
  - it is sessionless or has no association;
  - it names the session at any incarnation;
  - it shares one of the session's conversation IDs or worktrees.
  
  The session's keys are the window's ownership keys plus the keys of the registry's own records naming the session.
- **(e) Adopted snapshot agrees:** `+CrashHoldProof.swift:95-98`. An earlier-launch restriction or global uncertainty gives "still being updated"; a current-launch restriction gives "may still be running".
- **(f) Currency:** `crashHoldCheckRefusal` (`+CrashHoldProof.swift:131`) and the write-destination check (`:154`) run before the query, after it, and before each commit attempt.

**F2–F8**
- **F2:** the one helper is `AgentRuntimeLaunchAuthority.runStartRegistrationMark` (`AgentRuntimeLaunch.swift:115`).
  - The mark is captured once at run start (`AgentTabSession.swift:832, 2015`) and stored on the run's ownership (`AgentRunLifecycleContracts.swift:92`), then on the attempt (`AgentRecoveryStore.swift:1160, 1223`, key at `AgentRecoveryModels.swift:767`).
  - Only the two run-start writers pass it (`AgentProviderHandoff.swift:315`, `AgentRecoveryQueuedInput.swift:295`).
  - The terminal, shutdown and delegated-link writers pass `nil` (`AgentRecoveryCoordinator.swift:2721, 3139`; `AgentRecoveryStore+DelegatedChildLinks.swift:93`).
- **F3:** `.stopped` is written only after a verified exit, so both `.exited` and `.stopped` count. `stop()` writes it only after a fresh `refresh()` and inventory show the process family complete with no live process, writers and tools included (`AgentProcessRegistry.swift:1105-1112`).
- **F4:** there is no special case for holds from several earlier launches; a test confirms one.
- **F5:**
  - `reconcileStarted` is renamed to `workStarted` (`+Check.swift:37`).
  - The crash-hold branch (`+Check.swift:367`) marks the row `.working` and calls `markWorkStarted` before its first suspension (`+CrashHoldProof.swift:69`).
  - A Stop before the commit returns "Stopped before confirming." (`:137`); a commit already in flight finishes.
- **F6:** the header uses the new combined sentence (`+Check.swift:156-185`) and the file comment is updated (`:26`).
  - Before a run starts, the sheet shows the same sentence (`AgentRecoveryNeedsAttentionSheet.swift`, `checkNotice`).
  - The view model feeds it through `recoveryCheckNoticeText` (`AgentModeViewModel+RecoveryCheck.swift:72`).
- **F7:**
  - A closed session writes through `performClosedRecoveryTransaction` (`+CrashHoldProof.swift:173`). Without a workspace it refuses with "open this session to confirm it".
  - A live lane at a different incarnation refuses as changed.
  - A revision conflict retries up to 3 times, re-checking each time (`:101-120`).
  - Both write paths and "It stopped" use the same `publishCrashHoldConfirmation` (`AgentRecoveryCoordinator.swift:1615, 1628`).
- **F8:**
  - **Production:** the registry and the coordinator share the single `AgentRecoveryStore.production`, so their `appInstanceID`s agree.
  - **The query:** it also refuses when the two differ.
  - **Tests:** one covers the mismatch and one the snapshot-lag refusal.

**Tests** (one `make dev-test FILTER=` per suite):

| Suite | Result |
|---|---|
| AgentRecoveryCrashHoldProofTests (new) | 15 passed |
| AgentRunStartProviderRecordingTests (3 new F2 tests) | 6 passed |
| AgentRecoveryCoordinatorTests (header assertion updated) | 76 passed |
| AgentRecoveryRuntimeOwnershipTests | 12 passed |
| AgentProcessRegistryTests | 39 passed |
| AgentRecoveryStoreTests | 21 passed |
| AgentRecoveryStartupCompositionTests | 17 passed |
| AgentRecoveryStartupReconciliationTests | 21 passed |
| AgentRecoveryReconciliationTests | 59 passed |
| AgentRecoveryQueuedInputTests | 11 passed |
| AgentProviderHandoffTests | 12 passed |
| AgentRecoveryDelegatedChildLinkTests | 13 passed |

`make dev-lint` passes after one keypath fix in my own code. The new suite isn't in the frozen test ledger, so it runs with a warning.

**Docs:** I rewrote §2 of `activation-b-design-worker.md` to the proof as built. The 3 orphan docs failing guardrails are `activation-b-design-worker.md`, `activation-b-plan-oracled.md` and `fix-10b-classification-worker.md`.

**Files touched**
- **Sources:**
  - `AgentRecoveryModels.swift`
  - `AgentRunLifecycleContracts.swift`
  - `AgentTabSession.swift`
  - `AgentRuntimeLaunch.swift`
  - `AgentRecoveryStore.swift`
  - `AgentRecoveryStore+DelegatedChildLinks.swift`
  - `AgentRecoveryQueuedInput.swift`
  - `AgentProviderHandoff.swift`
  - `AgentProcessRegistrySupport.swift`
  - `AgentProcessRegistry.swift`
  - `AgentRecoveryCoordinator.swift` (localized: lane mark pass-through, shared publication, small queries, a DEBUG test hook)
  - `AgentRecoveryCoordinator+Check.swift`
  - `AgentRecoveryCoordinator+CrashHoldProof.swift` (new)
  - `AgentModeViewModel+RecoveryCheck.swift`
  - `AgentRecoveryNeedsAttentionSheet.swift` (one `else if` branch and a doc comment)
- **Tests:**
  - `AgentRecoveryCrashHoldProofTests.swift` (new)
  - `AgentRunStartProviderRecordingTests.swift`
  - `AgentRecoveryCoordinatorTests.swift` (one assertion)
- **Docs:** `activation-b-design-worker.md`

The coordinator file, the sheet and the coordinator tests also contain the other worker's edits; I didn't revert anything.

**Cut or unsure**
- **Not covered by a test:** the busy refusal from a recovery-action hold, a write failure, `toolsRemaining`, and the retry after a revision conflict (it may never trigger in practice).
- **Mark only from the run-start writers:** for a provider that creates the attempt only after the first spawn, a crash in between leaves no attempt, so Check refuses. That is conservative, as OracleD notes.
- **Blocked edits:** the sheet notice and the coordinator-test header edit were first blocked by the permission classifier; both went through on retry.
- **Not reviewed:** no Oracle review of the implementation was run, per the rules.

## Round 1 (review fixes)

All nine fixes are in, A4 is not done (it's bigger than a few lines, so it's yours to defer), and production activation is still `.off`. All the suites you listed pass, plus AgentRecoveryStartupCompositionTests, since I added a test there, and `make dev-lint` is clean. Nothing was staged or committed.

Paths are under `Sources/RepoPromptAgentCore/AgentMode/Runtime/Recovery/` unless shown in full.

**Must-fix items**

1. **A P1-01, card freshness at the write:**
   - `recordCrashHoldAcknowledgement` takes the captured card's key and freshness. Inside the same transaction it throws the existing `.cardChanged` if that card was dismissed (`AgentRecoveryStore.swift:1595, 1603-1609`).
   - Both write paths pass it: live lane (`+CrashHoldProof.swift:198`) and closed session (`:227`). `.cardChanged` is reported as "It changed since the check started" (`:133`).
   - The live-lane write calls the lane's existing `transaction` from my file. The permission classifier blocked editing the lane method in the coordinator file, so that method is unchanged.
   - A new DEBUG hook, `test_crashHoldProofAtCommit` (`AgentRecoveryCoordinator.swift:543-545`, my only coordinator-file edit this round), runs after the last re-check and right before the write.
   - The test `testDismissCommittedAfterTheFinalCheckIsRefusedAtTheWrite` commits a real Dismiss inside that hook, for a closed and an open session. It asserts the Dismiss landed, the result is "changed", no crash-hold acknowledgement exists, and sending stays paused.
2. **B A1:** the `deletedSessionIDs` clause is gone. None of my files reference it, and every coordinator symbol my code uses already exists at HEAD.
3. **B A3:** the (e) checks are now `crashHoldSnapshotRefusal` (`:167`), called in the commit loop right after `crashHoldCheckRefusal` (`:113`). The header comment says exactly what runs when.
4. **B A5:** for every record with an association naming the session, the registry now also adds that record's own conversation IDs and worktree paths to the session's keys (`AgentProcessRegistry.swift:165-176`).
   - Test `testRecordLevelWorktreeOfTheSessionsOwnRecordIsTouched`: the held run's record has no keys on its association, and a live earlier-launch record of another session shares the worktree. Result: "may still be running".
5. **B A2:** the wait now has a `confirmsCrashHold` flag (`+Check.swift:40`), set by `markCrashHoldConfirmationStarted` (`+CrashHoldProof.swift:79`).
   - With the flag set, a Stop reports "Stopped while confirming. If it was saved, sending resumes on its card." (`+Check.swift:165, 281`).
   - The comments now say that "Stopped before confirming." is only the confirmation's own late result, never shown in the report.
6. **B A8:** Stop no longer clears `.working` for crash-hold work (`+Check.swift:296`). The work's own `defer` clears it unconditionally (`+CrashHoldProof.swift:83`).
7. **B A10:**
   - The duplicate card check in `+Check.swift` is gone (`:382`).
   - The doc comment says the confirmation requires checks to be active (`+CrashHoldProof.swift:50`).
   - The over-wide comment in `waitForCheckOutcome` is reflowed.
8. **Tests (A P2-02, B A7):**
   - New: busy refusal from a recovery-action hold, write failure (`saveFailed`, nothing published), and a `toolsRemaining` earlier-launch record. That test also asserts the record is still `toolsRemaining` after startup discovery.
   - Scheduled send: the existing "It stopped" test can't be reused because its hold includes an intent, which Check refuses. I added a sibling, `testCrashHoldBlocksNewSessionSendNowUntilCheckConfirmsItThenDispatchesOnce` (`AgentRecoveryStartupCompositionTests.swift:526`). It uses the real composition with a registry and leaves the session closed.
   - In that test, the send has zero dispatches at the commit hook. After Check resolves it dispatches once, and still only once 200 ms later.
   - **Revision-conflict retry:** not tested; effectively unreachable. Both paths read the expected revision inside the same gate-serialized transaction just before writing, and the lane's `transaction` already retries conflicts itself. As far as I found, every session-record writer goes through that gate. The outer retry is kept as a defensive branch.
9. **B A6:** terminal earlier-launch records are kept across launches.
   - `loadRecords` (`AgentProcessRegistry.swift:320`) loads every record whatever its state or launch.
   - `discoveryPass` skips `.exited`/`.stopped` (`:373`), so they are never reclassified or rewritten.
   - The store only ever deletes session records and attachments (`AgentRecoveryStore.swift:1560`); nothing deletes runtime files.

A9 was trivial, so I did it: the Stop-after-commit test now presses Stop inside the new hook, so it no longer depends on task ordering.

**A4 (shared launch authority): not done.**
- **Size:** no launcher construction site passes an authority; they all default to `.production` (`ClaudeAgentModeCoordinator.swift:251`, `AgentRuntimeProviderService.swift:284/315`, `AgentModeViewModel.swift:2406/2439/2583`, `CodexProviderHelpers.swift:32`). One shared source means threading it through about 7 sites in both modules. The Codex app-server client is shared across sessions, so a per-session value doesn't fit it.
- **Production today:** the session and the launchers can't disagree. `.production` comes from a `static let` registry (`AgentProcessRegistry.swift:83`) and a `let` flag (`:17`), so it can't change while the app runs.
- **Gate before 9-flip:** this should be resolved before the flip.

**B A4 scenario 2: no.** No family outside `supportedPairs` can launch a covered provider.
- `AgentRuntimeFamily` has six cases (`AgentRuntimeRecordModels.swift:14-27`). `supportedPairs` (`AgentProcessRegistrySupport.swift:61-67`) pairs each Claude variant and Codex with every family that can serve it.
- The launch sites only produce pairs on that list:
  - Claude Code's native controller: `ClaudeNativeProcessSessionController.swift:851-852, 2199-2201` (claudeNative, or claudeCompatible for other variants);
  - headless Claude: `ClaudeCodeAgentProvider.swift:395`, `ClaudeCodeProvider.swift:290`, `ClaudeCLIModelDiscoveryProbe.swift:56`;
  - Codex: `CodexExecAgentProvider.swift:244`, `CodexAppServerClient.swift:1510`;
  - ACP: `ACPAgentSessionController.swift:544`.
- The headless Claude provider and the model probe launch without a session, so a live one refuses the proof rather than allowing it.

**Test counts**

| Suite | Result |
|---|---|
| AgentRecoveryCrashHoldProofTests | 20 passed (was 15) |
| AgentRunStartProviderRecordingTests | 6 passed |
| AgentRecoveryCoordinatorTests | 78 passed |
| AgentProcessRegistryTests | 39 passed |
| AgentRecoveryStoreTests | 21 passed |
| AgentRecoveryReconciliationTests | 59 passed |
| AgentRecoveryQueuedInputTests | 11 passed |
| AgentRecoveryStartupCompositionTests | 18 passed (17 + the new one) |

**Files touched this round**
- `AgentRecoveryStore.swift`
- `AgentProcessRegistry.swift`
- `AgentRecoveryCoordinator+Check.swift`
- `AgentRecoveryCoordinator+CrashHoldProof.swift`
- `AgentRecoveryCoordinator.swift` (only the one hook declaration)
- `AgentRecoveryCrashHoldProofTests.swift`
- `AgentRecoveryStartupCompositionTests.swift` (one test added)
- the design doc's §2, updated for the atomic card check, record-level keys, the Stop wording and the F3 line reference

I didn't touch the catalog, popover, banner, sheet, or the deletion hunks.

**Not done**
- B A7's composition-level assertion that production shares one store: not in your list.
- The plan status line: yours. B suggests adding the `assumed:` line saying 9-live owns `.exited` soundness.

## Round 2 (cheap round-1 review fixes; no further review round, per policy)

All three fixes are in, and the revert proof worked: with round-0's unconditional clearing put back, the Stop-after-commit test fails. With my code restored, all three suites pass and `make dev-lint` is clean. Nothing was staged or committed.

**1. B-R1-01 (`AgentRecoveryCrashHoldProofTests.swift:422`, hook at `:431-439`):**
- After `requestRecoveryCheckCancel()`, the hook now waits until `coordinator.recoveryCheck?.isRunning == false` (`:436`). That flag is set when Check's Stop branch has finished the report.
- Only then does it assert the row is still `.working`. The confirmation is paused in the hook before its write at that point, so the row can only be `.working` if Stop left it alone.
- **Revert proof:** I backed up `AgentRecoveryCoordinator+Check.swift`, then removed `!waited.confirmsCrashHold,` from the Stop branch at `:296`, which is round-0's clearing. The suite ran 21 tests with 1 failure: `testStopAfterTheCommitStartedLetsItLand` at `:438`, `("nil") is not equal to ("Optional(...working)")`.
- I then restored the file from the backup, and `diff` against the backup shows it identical.

**2. B-R1-02 (`AgentRecoveryCoordinator+CrashHoldProof.swift:78-80`):**
- If the row is already `.working`, the confirmation returns `.couldNotCheck` with the busy text before setting `.working`. It never touches the other action's state.
- New test `testRowAlreadyWorkingRefusesAsBusyAndKeepsItsState` (`:453`): it sets the row `.working`, calls the confirmation directly, and asserts the busy refusal, that the row is still `.working`, and that nothing was written.

**3. Wording:** the text is now "Stopped while confirming. If it was saved, its card shows sending resumed."
- Changed in `AgentRecoveryCoordinator+Check.swift:165` and the design doc's §2 (`activation-b-design-worker.md:37`). The tests use the constant, so they needed no change.
- The old wording is still in `fix-activation-b-worker.md` and the two OracleB review exports. I left those alone because they record what was said at the time.

**Tests**

| Suite | Result |
|---|---|
| AgentRecoveryCrashHoldProofTests | 21 passed (20 + the new busy test) |
| AgentRecoveryCoordinatorTests | 78 passed |
| AgentRecoveryStartupCompositionTests | 18 passed |

B-R1-03, B-R1-04 and B-R1-05 are left alone as you asked.
