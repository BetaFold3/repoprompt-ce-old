# Step 7-F3F6 worker report

Scope: read when the task touches lossless restart Step 7-F3F6 (recovery banner header and quit-failure dialog wording) implementation or review evidence.
Authority: Reference
Last-verified: 2026-10-26

The "Review fixes" section at the end records later changes made in response to the OracleA and OracleB reviews. Where it differs from the sections above, it wins.

Base: `5363ad2e` plus uncommitted changes. Nothing is staged or committed. The spec, `Scripts/source_layout_guardrails.sh` and the XCTest ledger are unchanged. The visible app was not launched, relaunched or stopped; `make dev-build` only repackaged `/Applications/RepoPrompt CE Dev.app`.

## F3: banner header

- `Sources/RepoPrompt/Features/AgentMode/ViewModels/UI/AgentComposerUIModels.swift`: the header wording moved out of the view into `AgentRecoveryListProps.headerText` so it can be tested. When the status is ready:
  - no rows and other items: "Nothing interrupted in this session. N items elsewhere need attention." (or "1 item elsewhere needs attention.");
  - no rows and no other items: "Nothing interrupted in this session." This case is never shown, because `isEmpty` hides the banner;
  - rows and no other items: the wording is unchanged ("1 saved or interrupted item needs your attention." / "N … items need …");
  - rows and other items: both counts stay separate, as in "2 saved or interrupted items in this session need your attention. 5 items elsewhere need attention."

  The loading and failed texts are unchanged.
- `Sources/RepoPrompt/Features/AgentMode/Views/Components/AgentRecoveryListBanner.swift`: the view now renders `props.headerText`, and its private `headerText` was removed.
- Unchanged: catalog scope, how `otherItemCount` is computed (`AgentModeViewModel+RecoveryList.swift`), dismissal, `isEmpty`, and when the button is shown. The dismissed crash hold's paused indicator is still one of this session's rows.

## F6: plain failure text

### Typed classification at the store boundary

- New `Sources/RepoPromptAgentCore/AgentMode/Runtime/Recovery/AgentRecoveryFailureWording.swift`:
  - `AgentRecoveryStorageFailureCause` (`permissionDenied`, `diskFull`, `other`) classifies the underlying `NSError`. It walks at most 4 levels of `NSUnderlyingErrorKey`:
    - Cocoa 513, 257 and 642 (no write permission, no read permission, read-only volume), and POSIX `EACCES`, `EPERM` and `EROFS`, map to permission denied;
    - Cocoa 640 (out of space) and POSIX `ENOSPC` and `EDQUOT` map to disk full;
    - everything else maps to other.

    The file never parses error strings.
  - `AgentRecoveryStoreError.classifiedStorageFailure(_:)` and `storageFailureCause`.
  - `AgentRecoveryControllerFailure.userFacingDescription`. Its mapping moved here unchanged from the app's `recoveryListDescription(of:)`; the only addition is that a store storage failure now returns its cause's text.
  - Fixed `diagnosticName` tokens.
  - `AgentRecoveryFailureDiagnostics`, which writes `.notice` logs: the reason and cause are public; the raw `String(describing:)` detail is `.private`. That detail holds paths and identifiers, never draft text.
- `AgentRecoveryStore.swift`: the case is now `storageFailure(String, cause: AgentRecoveryStorageFailureCause)`. The `.other` default was later removed (R6). Its 4 `catch` throws, and the 2 in `AgentRecoveryStore+Runtimes.swift`, use `classifiedStorageFailure`. `case .storageFailure:` patterns still compile, and `category` is unchanged (`.storage`).

### Presentation sites fixed (same class: a raw typed recovery or store failure interpolated into user-facing text on the recovery, shutdown or commit-failure paths)

1. `AgentModeViewModel+Shutdown.swift`:
   - `shutdownPreparationFailureText`, cases `composerNotPersisted` and `evidenceNotPersisted`, now use `userFacingDescription`. The other cases' text is unchanged.
   - `finalizeTranscriptsAfterShutdown`'s composer-flush blocker gets the same change.
   - Both paths log `shutdown_blocked`, with the raw detail private.
   - Unchanged: the blocker list, its order, quit blocking, and the 8-second deadline.
2. `AgentModeRunService.swift`, around line 682: the run-start `.commitFailed` message now comes from `AgentProviderHandoff.deliveryNotRecordedText(_:)`: "This message was not sent because its delivery could not be recorded (<plain cause>). It stays saved." The raw failure was already logged privately by `AgentDeliveryRecordDiagnostics.runStartRefused`.
3. The `noteNoHandoff(message:)` call in each `attachRunAttempt` failure branch: `ClaudeIntegratedAgentModeRunner.swift:147`, `ACPIntegratedAgentModeRunner.swift:1712` and `HeadlessAgentModeRunner.swift:245`. Each used to send "run attempt not recorded: <raw>", which can reach a scheduled-send failure and the recovery action reason. They now use the same plain text. Diagnostics stay distinct per route through `runAttemptNotRecorded(route:)`.
4. `AgentRecoveryCoordinator.swift`, startup `catch`: `startupState = .failed(...)` now holds plain text from `startupFailureDescription`: one complete sentence (R3), such as "Recovery couldn't start: the disk is full. Free up some space, then try again." The raw error is logged. This text reaches the banner, the scheduler's startup refusal and admission refusals.
5. Recovery-list rows in `AgentModeViewModel+RecoveryList.swift`:
   - saved question unreadable, saved message unreadable, message box not saved, original not removed, and message not removed: these now use `recoveryListDescription(of:)`, which delegates to `userFacingDescription`;
   - agent-process records unreadable: the opaque registry string is no longer shown, and the generic sentence is used.
6. `AgentModeViewModel+RecoveryActions.swift:176` (recovery data unreadable) uses the same description.
7. `AgentModeViewModel+ScheduledSend.swift`:
   - an admission `.refused` case used to show the raw refusal enum and a wrong "could not be saved" sentence. It now uses a message chosen per refusal case (R1);
   - `.commitFailed` and the "Delivery evidence could not be read" hold reason use the plain description.
8. `AgentProcessRegistry.swift`:
   - the restart-dialog proof reason "Runtime records are unreadable: <raw>" became "Runtime records are unreadable.";
   - the raw error is logged when it is recorded, but only when it first appears or changes (R9).

### Audit list: left as they are (not this class, or not user-facing)

- `AgentModeViewModel+RecoveryList.swift:16`: `recoveryCompositionFailure`. This was originally listed here as not audited; it was fixed under R5, see Review fixes.
- `print(...)` debug lines that interpolate failures (`AgentModeViewModel+Recovery.swift:353, 363, 434, 462`; `AgentModeViewModel+ScheduledSend.swift:1151, 1326`). These are stdout diagnostics, not UI.
- `AgentModeRunService.providerStartupFailureMessage` (around line 1220) falls back to `String(describing: error)` only when `localizedDescription` is empty. This belongs to provider startup, not recovery.
- `AgentRecoveryComposerPreparationFailure.authorityUnavailable(String)` and `.imagePromotionFailed(String)` already go through the app's own `recoveryListDescription(of:)` overload. Not re-audited.
- `AgentRuntimeRestrictionSnapshot.storageFailure` still holds the raw string internally. Only the user-facing surfaces stopped showing it.
- Other `.failed(message)` and `notProven` texts in `AppRelaunchCoordinator` and the helper channel are fixed strings or helper replies, not recovery-store errors.

## Tests

- New `Tests/RepoPromptTests/AgentMode/Recovery/AgentRecoveryListHeaderTextTests.swift` (6 tests): zero local with nonzero elsewhere (1 and 64), one, many, both counts, empty (hidden, never says "0 … items"), the dismissed crash hold's paused-indicator row (with and without items elsewhere), and the unchanged loading and failed texts.
- New `Tests/RepoPromptTests/AgentMode/Recovery/AgentRecoveryFailureWordingTests.swift` (3 tests):
  - the real `AgentRecoveryStore` write path, using an injected `writeAtomically` failure, classifies three errors correctly:
    - Cocoa 513 wrapping POSIX `EACCES` with a path, which is the live `cycle8.H_shutdownFault` shape;
    - Cocoa wrapping `ENOSPC`;
    - an unknown error.

    The raw detail is kept and `category` is unchanged. Direct Cocoa and POSIX classification is also covered, and an opaque string stays `.other`.
  - `shutdownPreparationFailureText` for permission, disk-full and unknown failures in both cases, `composerNotPersisted` and `evidenceNotPersisted`. The text contains no `Domain=`, `Code=`, enum or type names, `store(`, `UserInfo`, path, `mktemp` or draft sentinel.
  - the commit-failure text, the startup text (permission, unknown, an unreadable record with the sentinel) and the recovery-list description, each checked for plain wording.
- `AgentRecoveryStartupCompositionTests.testRecoveryListRowsResolveSessionsFromTheCatalogAndOpenAcrossWorkspaces` gained header assertions on the real view model:
  - the props with only items elsewhere read "Nothing interrupted in this session. N items elsewhere need attention.";
  - the props for the dismissed crash hold's paused indicator count this session's rows and keep the count of items elsewhere separate.

## Validation (initial round; superseded by Review fixes)

- `make dev-build`: exit 0. The only new warning, an unused binding at `+RecoveryList.swift:390`, was fixed before the final build.
- The focused test run:

  ```
  RPCE_ALLOW_UNKNOWN_FILTER=1 make dev-test FILTER="'AgentRecoveryListHeaderTextTests|AgentRecoveryFailureWordingTests|AgentRecoveryStartupCompositionTests|AgentRecoveryStoreTests|AgentLifecycleShutdownCoordinatorTests|AgentRecoveryActionTests|AgentRecoveryCoordinatorTests|AgentRecoveryResetBoundaryTests|AgentRecoveryVMProducerAdmissionTests|AgentProcessRegistryTests|AgentProviderHandoffTests|AgentScheduledSendNonCodexMandatoryTests'
  ```

  Exit 0, 278 tests, 0 failures. Per suite: 6, 3, 13, 21, 48, 30, 45, 22, 36, 35, 12 and 7, all passing. Without the override, conductor preflight rejects the alternation with exit 64, because the frozen ledger predates these suites. Every suite was checked to exist in the sources. The override is the documented escape.
- `make dev-lint`: exit 0. SwiftFormat findings in the two new files were fixed by hand; `make dev-format` was not run.
- `make guardrails`: exit 0, run before this report existed. It printed one warning that existed before this change: the AGENTS.md route count.
- `Scripts/check-agent-context`, run after this report was created: 1 error and 1 warning.
  - The error is a `[reachability]` orphan for this report. It clears once the spec's Step 7-F3F6 status line links `evidence/2026-10-18-lossless-app-restart/fix-f3f6-worker.md`, as was done for F2, F4 and F7. I didn't make that edit because I was told not to touch the spec.
  - The warning is the route count that existed before this change.

## Not run

- The full root test run (`make dev-test-parallel`) and `make dev-core-test`. No `Packages/` were changed.
- Any live or visible-app check of the banner or the quit dialog. A live re-check of `cycle8.H_shutdownFault` (a permission-denied quit) would confirm the dialog wording end to end.
- The secret scan. Nothing was pushed.

## Open questions (initial round)

The current open questions are listed at the end of Review fixes.

- The spec's F3 and F6 entries still say "Open; not fixed". Worker instructions forbade editing the spec, so the owning agent should update it.
- Read-only volumes and read denial under "permission denied": resolved by the neutral wording (R7 / A 01).
- The scheduled-send refusal text: resolved by per-case wording (R1).
- The `recoveryCompositionFailure` producers: resolved (R5).

## Review fixes

These respond to `fix-f3f6-review-oraclea.md` (A 01, A 02) and `fix-f3f6-review-oracleb.md` (R1–R10). Every change is text-only or log-only. No outcome, classification, state transition or control flow changed.

| ID | Change | Result |
|---|---|---|
| R1 | **Finality first:** `.notAdmitted` is final. `AgentModeViewModel+ScheduledSend.swift:2993–2996` sends it to `markScheduledSendFailed` (`:2389–2409`), which sets `state = .failed` and `lastFailureMessage` and returns `.failedBeforeHandoff`. Nothing retries it automatically. **Change:** `.refused(refusal)` now uses `scheduledRecoveryAdmissionRefusalMessage(_:)`, with one sentence per case, and each sentence says "not sent". `startupFailed(reason)` passes the reason through: "The scheduled message was not sent. <reason>". The startup-not-ready case says "…not sent because RepoPrompt was still checking what was interrupted by the last restart." **Deviation from the brief:** I didn't use "paused until … ready", because the outcome is final and that wording would promise a retry that never happens. The two existing "Scheduled sending is paused until this session's recovery record is available." texts (`:3273`, `:3285`) are unchanged. Each refusal logs `presentation_failure site=scheduled_admission_refused_<diagnosticName>`. | Tested in `AgentRecoveryFailureWordingTests` (scheduled refusal text) |
| R2 | Added `AgentRecoveryFailureDiagnostics.presentationFailure(site:failure:)`, which logs a public fixed site token and the raw detail as private. It is called at each site where raw detail was removed from the UI and no log existed: recovery-list question or message unreadable, edit composer not saved, edit original not withdrawn, remove not withdrawn, the recovery action record unreadable, the scheduled admission commit failure, and scheduled delivery evidence unreadable. Startup has `startupFailed`, shutdown has `shutdownBlocked`, and the registry has `runtimeRecordsUnreadable`. Run start and the runners were already logged. | Builds; no assertions on log output |
| R3 | `startupFailureDescription(_:nextStep:)` now returns a complete sentence with context. Permission: "Recovery couldn't start: RepoPrompt can't access its data folder. Check that folder's permissions and that its disk is writable, then try again." Disk full: "Recovery couldn't start: the disk is full. Free up some space, then try again." Other: "Recovery couldn't start: RepoPrompt couldn't read or write its saved recovery data." The banner wrapper appends " Sending stays paused until this succeeds.", and the composition wrapper appends " Sending stays paused.". Neither adds a trailing period, so the punctuation is never doubled. | Tested: the startup texts are asserted exactly, and each is checked for no doubled period (`..`) |
| A 01 / R7 | The permission wording is now neutral: "RepoPrompt can't access its data folder; check that folder's permissions and that its disk is writable". It covers read denial (257), write denial (513) and read-only volumes (642 / `EROFS`). The classification is unchanged. | New assertions for Cocoa 257 and 642 (and `EROFS`): each classifies as `.permissionDenied`, and its text contains neither "write permission" nor any raw detail |
| R4 | I grepped Sources and Tests for the old prefixes ("run attempt not recorded", "Recovery startup failed", "could not be saved for recovery (", "Runtime records are unreadable:", "not admitted for recovery") and for raw `storageFailure(String(describing:` constructions. No matcher depended on the old text. The only construction left is inside `classifiedStorageFailure`. The suites R4 named (run-service lifecycle, runners, scheduled send, recovery list) are now in the focused run below. | Clean grep; suites pass |
| R6 | Removed the `cause: .other` default from `AgentRecoveryStoreError.storageFailure`. All 6 store throws classify. The cleanExit throw and the three `"no attempt"` placeholders (`AgentRecoveryComposerPersistenceController.swift:849`, `AgentRecoveryCoordinator.swift:819` and `:3304`) state `cause: .other` explicitly. | Compiles, so every construction site is explicit |
| R5 | `AgentRecoveryAppComposition.swift`: the startup composition `catch` logs `startupFailed(error)`. It then shows and forwards `startupFailureDescription(error, nextStep: "then reopen RepoPrompt")` to both `recoveryCompositionFailure` and `scheduler.failStartupAdmission(_:)`, instead of `String(describing: error)`. The fallback is "Recovery couldn't start.". The banner and refusal flow is unchanged. | Builds; composition suite passes |
| R8 | One source: `AgentRecoveryAdmissionFailure.deliveryNotRecordedText(cause:)` (in `AgentRecoveryFailureWording.swift`). `AgentProviderHandoff.deliveryNotRecordedText(_:)`, the coordinator's `.commitFailed` text, run start, the Claude, ACP and headless `noteNoHandoff` calls, the finalize `errorText`, and headless `errorDescription` all delegate to it. **"It stays saved" checked on each runner:** Claude (`:147`/`:155`), ACP (`:1712`/`:1720`) and headless (`:245`) all fail inside `attachRunAttempt`, before dispatch. The deferred path only binds. The committed path calls `noteNoHandoff`, then `settleToQueue` before the handoff, so the intent stays durable on all three. | Runner and handoff suites pass |
| R9 | `AgentProcessRegistry.recordStorageFailure(_:)` logs `runtimeRecordsUnreadable` only when `String(describing:)` differs from the current `storageFailure`, which means a first failure or a different one. It then stores the value. Both catch sites use it. Repeated identical refresh failures don't log again. | Registry suite passes |
| R10 | `AgentRecoveryStartupCompositionTests` now asserts exact values without conditions. With items only elsewhere: `otherItemCount == 7` and the header "Nothing interrupted in this session. 7 items elsewhere need attention.". With the paused props: 3 rows, `otherItemCount == 4`, and the header "3 saved or interrupted items in this session need your attention. 4 items elsewhere need attention.". | Passes |
| A 02 | Not fixed here. `Scripts/check-agent-context` still reports this report as an orphan. It clears once the spec's Step 7-F3F6 status line links `evidence/2026-10-18-lossless-app-restart/fix-f3f6-worker.md`, which the owner must do; I was told not to edit the spec. | Owner action |

`AgentRecoveryFailureWordingTests` now has 5 tests: store-boundary classification, shutdown text, commit/startup/recovery-list text, neutral read-denied/read-only wording, and scheduled refusal text.

### Validation (review round)

- `make dev-build`: exit 0, with no new warnings in the changed files.
- The focused run, using `RPCE_ALLOW_UNKNOWN_FILTER=1` with an alternation over 21 suites: exit 0, 712 tests, 0 failures. Per suite: HeaderText 6, FailureWording 5, StartupComposition 13, Store 21, LifecycleShutdownCoordinator 48, RecoveryAction 30, RecoveryCoordinator 45, ResetBoundary 22, VMProducerAdmission 36, ProcessRegistry 35, ProviderHandoff 12, ScheduledSendNonCodexMandatory 7, AgentModeRunServiceLifecycle 221, AgentRunTerminalCause 17, ScheduledSendCoordinator 55, ScheduledSendDispatch 58, ScheduledSendPersistence 34, ScheduledSendReceiptTransfer 11, DelegatedChildLink 12, EditProposal 14 and RuntimeOwnership 10. The Claude, ACP and headless runner paths are covered by the lifecycle, handoff and terminal-cause suites. The recovery list is covered by HeaderText, StartupComposition and RecoveryAction.
- Full `make dev-test`, run once: exit 2. It executed 7828 tests: 25 skipped, 60 failures, 45 of them unexpected. 12 suites failed:
  - AgentRunWorktreeStartTests (`managerNotFullyStopped`);
  - CursorCLIProviderTests (one count assert);
  - MCPCodeStructureWorktreeTests (the known `…ForegroundRecoversOnce`);
  - TabContextRoutingTests;
  - WorkspaceFileContextStoreExactCapabilityTests;
  - WorkspaceFileContextStoreTests (most failures were watcher `streamStartFailed`);
  - WorkspaceGitDataRootLoadingTests;
  - WorkspaceRootBindingProjectionTests;
  - WorkspaceRootSyncTests;
  - WorkspaceSwitchRecoveryTests;
  - WorktreeAPISmokeHarnessTests (`CancellationError`);
  - WorktreeStartupInstrumentationTests.

  None of these suites touch the changed recovery or wording code.
- Those 12 suites, rerun on their own (`RPCE_ALLOW_UNKNOWN_FILTER=1 ./conductor test --filter '<12-suite alternation>'`): 368 tests, 1 failure, the known pre-existing `MCPCodeStructureWorktreeTests.testRetainedProjectionPreloadStopsAfterIndexAdvanceAndForegroundRecoversOnce`. The other 11 suites passed:
  - AgentRunWorktreeStart 41;
  - CursorCLIProvider;
  - TabContextRouting 57;
  - ExactCapability 5;
  - WorkspaceFileContextStore 128;
  - GitDataRootLoading 2;
  - RootBindingProjection 12;
  - RootSync 15;
  - SwitchRecovery 22;
  - WorktreeAPISmokeHarness 5;
  - WorktreeStartupInstrumentation 22.

  The full-run failures in those 11 were caused by load.
- `make dev-lint`: exit 0.
- Not run: `make dev-core-test` (no `Packages/` changed), live or visible-app checks, and the secret scan (nothing was pushed).

### Open questions (current)

- R1's wording deviates from the brief, as explained above, because the outcome is final. If the owner prefers "paused" wording, that would need an actual retry path, which is a control-flow change outside this task's text-only scope.
- A 02: the spec link needs an owner edit, and the spec's F3/F6 status lines still need updating.
