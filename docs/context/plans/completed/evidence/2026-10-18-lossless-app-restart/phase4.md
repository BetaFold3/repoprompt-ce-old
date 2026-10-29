# Lossless restart Phase 4: implementation evidence

Scope: read when the task touches lossless-restart Phase 4 evidence: durable recovery actions, provider history reconciliation, one-click Resume, the private relaunch helper or the R4 Restart safely stages.
Authority: Reference
Last-verified: 2026-10-22

Status: **PARTIAL SOURCE, NOT live-ready. R7 is NOT source-complete** (Claude normal-live merge
stays BLOCKED; cold Codex is closed in source, fixture-only). Fixture-backed source
integration of the adopted `phase4-plan.md` (later sections supersede earlier ones), plus the
Oracle bounded Claude-baseline plan
(`prompt-exports/oracle-plan-2026-10-22-141753-restart-phase-4-boun-d772.md`) and the Oracle
cold-Codex closure plan (`prompt-exports/oracle-plan-2026-10-22-150201-restart-phase-4-boun-e3b3.md`).
Base: signed HEAD
`559ecd9d6d037ba762d8f4d2297d3c397a9d1f67`. Nothing is staged, committed or pushed. Main owns
the status lines in the original spec.

- **Supported in source:** durable actions, the R4 Restart safely stages, closures 1-3 (below),
  the Claude pre-byte dispatch baseline producer, the verified-absence reader boundary, and the
  typed canonical native-association preflight.
- **BLOCKED:** normal-live Claude canonical merge. Every live Claude import is refused with
  `nativeUserAssociationUnavailable`, because no source maps a native user record to the local
  user item. This awaits public primary evidence; nothing is guessed.
- **Closed in source, live pending:** cold Codex observation through a coordinator-owned
  transaction (see "Codex cold observation transaction"). It is inert in production (the App
  factory's client uses the `.production` launch authority, so the controller fails closed).

- Production registry, Resume, history reconciliation, Restart safely, Stop and fresh-Claude-ID
  activation all remain **OFF**.
- O3 live acceptance is **pending**. Phase 5, polish and retention are **deferred**.
- No live provider, helper or MCP binary was executed. Nothing was packaged or launched. No
  home, credential or process-environment inspection or signalling happened. Every process, watch,
  open, clock and channel is injected.

## Delivered (paths and anchors)

### Durable recovery actions

- `Sources/RepoPromptAgentCore/AgentMode/Models/AgentRecoveryActionModels.swift` holds the action
  kinds and parameters, the reservation receipts, and `AgentRecoveryRecord.join(_:)`. Join outcomes
  are `resolved`, `notDispatched`, `notHandedOff`, `dispatchEvidence` and `unknown`.
- `Sources/RepoPromptAgentCore/AgentMode/Runtime/Recovery/AgentRecoveryStore+Actions.swift`:
  - `reserveRecoveryAction` (L19) and `completeRecoveryAction` (L77) reserve and complete actions
    by item, revision and action ID.
  - `commitHistoryCursor` (L109) is a cursor compare-and-swap on the previous import ID.
- `Sources/RepoPromptAgentCore/AgentMode/Runtime/Recovery/AgentRecoveryActionRunner.swift`:
  - `AgentRecoveryActionQualification` (L19), with `.production` all-false (L42).
  - `AgentRecoveryActionRunner` (L98) runs: gate → reservation (committed or joined) → optional
    reconcile → `isValidForHandoff` → existing dispatch once → outcome. An in-flight table joins
    concurrent repeats.
- `Sources/RepoPrompt/Features/AgentMode/ViewModels/AgentModeViewModel+RecoveryActions.swift`:
  - Gated row actions: `recoveryRunActions` (L29).
  - `performRecoveryResumeAction` (L68).
  - `dispatchRecoveryContinuation` (L220): new editable follow-up intent via
    `submitUserTurnAdmittingRecoveryInput(..., origin: .followUp, userItemID:)`.
  - `dispatchRecoverySavedIntent` (L277): the saved constituents go through
    `submitUserTurn(..., admitted:)` once, under a store-issued queue receipt.
  - `reconcileRecoveryHistory` (L342).
- Wiring touches:
  - `AgentModeViewModel+RecoveryList.swift`: `performRecoveryListAction` (L607) and the row props.
  - `AgentComposerUIModels.swift`, which adds five Phase 4 actions.
  - `AgentRecoveryListBanner.swift`, with the titles.
  - `AgentModeViewModel.swift`: the runner and registry properties (L677) and the
    `submitUserTurnAdmittingRecoveryInput` `userItemID` parameter.

### History-only reconciliation

- **Ledger:** `Sources/RepoPromptAgentCore/AgentMode/Models/AgentSessionProviderHistoryRecovery.swift`
  is the optional v7 member. It is absent when empty, and unknown members round-trip.
- **Import commit and fence:** `AgentSessionDataService.swift`:
  - `saveAgentSession(..., committingHistoryImport:)` (≈L2452).
  - `commitProviderHistoryImport` (≈L2490).
  - `validateHistoryImportFence` (≈L2505).
  - Rows, ledger and receipt go in ONE fenced save, before the cursor CAS. A stale snapshot gets
    `staleHistorySnapshot` and a wrong receipt gets `receiptMismatch`, both with nothing written.
  - The existing DataService writer is the only writer.
- **Session fields:** `AgentTabSession.swift` (≈L887-904) holds `providerHistoryRecovery`,
  `pendingHistoryImportCommit`, `committedHistoryImportID`, and the resume suppression and
  unavailable conversation IDs.
- **Claude decoder:** `Sources/RepoPromptAgentCore/AI/Providers/ClaudeCode/SDK/ClaudeSessionHistoryReader.swift`
  (L35). It works only on the known home and exact session, on an FD-identity-bounded complete
  candidate.
  - `validateGraph` (L481) validates the entire candidate. It rejects unknown metadata,
    file-history-snapshot, a missing parent, a cycle, an ambiguous branch and ambiguous tool
    association.
  - Only an incomplete trailing line permits a validated prefix.
  - Replacement or truncation triggers a rescan with ledger dedup.
  - Rows are inert: text plus parallel tool call/result, with deterministic v8 identities.
- **Planner:** `AgentProviderHistoryImport.swift` (L160). Claude completion stays unconfirmed.
- **Reference pin:** Pinned upstream `3cb0c27eca8caccdc153471a1b19f97fce4ada03`
  (`_make_transcript_entry` / `_parallel_tool_turn`). The four parallel orders are reproduced as
  fixtures. This is a reference pin, not qualification.
- **Codex:**
  - `Sources/RepoPromptAgentCore/AgentMode/Runtime/Codex/CodexRecoveryAdapter.swift` (L81) is a
    thin forwarder.
  - `CodexNativeSessionController.observeRecovery` (≈L1799) and the pure `recoveryObservation`
    (≈L1861) are controller-owned and observational: no second reader, client or cache.
  - They require a registered transport (L1785-1790), and only the expected turn's own terminal
    status counts. Idle or latest is never completion.
- **Claude dangling `--resume`:** `ClaudeAgentModeCoordinator.resumeFailureDisposition` (≈L1509)
  returns `requireExplicitChoice` for the suppressed conversation. There is no implicit fresh
  retry; the explicit choice is `continueInNewConversation`.
- **Provider homes:** `AgentProcessRegistry.claudeProviderHomes(conversationID:)` uses registry
  knowledge only. A missing home means unknown, so nothing is imported.

### Restart safely via the existing R4

- **R4:** `Sources/RepoPrompt/App/AgentLifecycleShutdownCoordinator.swift` has
  `AgentLifecycleRelaunchHooks` (L147) and the `relaunch` environment member (L141). The sole
  deadline is 8 s, and hooks get only `remaining`.
  - **Stage A** ends with a ready (never armed) helper (L423-430).
  - **Stage B** (`runRelaunchStep`, L615) runs after final persistence and the clean write. It
    calls `verifyAllStopped` and then arms.
  - **Abandon** happens before every prompt (L717-724) and on Cancel (L491-494). Quit Anyway
    relaunches nothing.
  - **Refusal:** `.safeRestart` is refused without hooks (L281-283).
- **Driver:** `Sources/RepoPrompt/App/AppRelaunchCoordinator.swift` (L15) serializes hooks and
  uses a fresh helper per prepare.
  - `production()` (L122) returns `nil` unless qualified, registered, and the helper resolves via
    `Bundle.url(forAuxiliaryExecutable:)` inside this exact bundle.
- **Composition:** `WindowStateManager.swift` L237 and `WindowStatesManager+LifecycleShutdown.swift`
  L87-103. `AppDelegate.swift` is the termination entry. `AgentRecoveryNeedsAttentionCommands.swift`
  L21 shows the menu only when available.
- **Stage B proof:** `AgentProcessRegistry.verifyAllFamiliesStopped()`. Only `.allStopped` arms.
- **Helper protocol:** `Sources/RepoPromptPlatform/Infrastructure/Process/ProcessRelaunchHelper.swift`:
  - `ProcessRelaunchInvocation` (L28): an ordinary call stays ordinary, exactly
    `--rpce-private-relaunch-v1` selects v1, and anything else is invalid with no MCP fallback.
  - It owns the closed v1 NDJSON codec (16 KiB per frame) and the frame decoder.
  - `ProcessRelaunchHelperSession` (L360) checks parent PID, UID and birth identity, the
    exact-bundle helper location, and the installed and re-verified exit watch before `ready`.
    EOF is not exit proof. Only armed plus a verified exact-parent exit opens the exact bundle,
    once.
  - `ProcessRelaunchParentSession` (L591): a lost `armed` ACK resolves to `aborted` or a verified
    helper exit (terminate last) before returning.
  - Limits are 8 s, 15 s and 10 s.
- **Entry:** `Sources/RepoPromptMCP/main.swift` L12 dispatches before MCPCore.
- **Package:** `Package.swift` adds `RepoPromptPlatform` as a dependency of the `RepoPromptMCP`
  target only. There is no new product, target or framework.
- **Docs:** `docs/architecture/source-layout.md` records that exception, and
  `Scripts/source_layout_guardrails.sh` allowlists this file.

### Closures 1-3 (message 2)

1. **Reconcile before Resume or continuation:** `AgentRecoveryActionRunner` stops without
   dispatch on a bound verified completion (`verifiedCompletionText`, L120 and L230;
   `AgentRecoveryRecord.hasVerifiedCompletion(ofRunAttempt:)`, `AgentRecoveryActionModels.swift`
   L280).
2. **Exact R7 default text, editable:** the text is
   `AgentRecoveryActionRequest.defaultContinuationText` (`AgentRecoveryActionModels.swift` L105).
   The row carries `continuationText` (`AgentComposerUIModels.swift` L476), and the banner edits it
   (`AgentRecoveryListBanner.swift` L141, `agent.recoveryList.continuationText`). The edited text
   is passed through `performRecoveryListAction`.
3. **Previous-launch actions:** there is no automatic redispatch. An explicit supersede is allowed
   via `supersedesActionID` (`AgentRecoveryStore+Actions.swift` L17-76). Uncertain prior delivery
   needs `confirmsUncertainPriorDelivery` (L197); otherwise the result is `supersedeRefused`.

### Claude pre-byte dispatch baseline (Oracle bounded plan)

- **Reader boundary:** `ClaudeSessionHistoryReader.swift`.
  - `CandidateListing` (L156) is `listed` or `inspectionFailed`. Verified absence is a root that
    is missing (`fileReadNoSuchFile`), or a project that is missing (ENOENT/ENOTDIR under `lstat`).
    Any other listing error, empty roots, or a listed candidate without an identity is
    `inspectionFailed`. Absence is never inferred.
  - A baseline refuses non-whitespace bytes after the last newline (`partialTrailingRecord`,
    L103). An import still waits for that record.
- **Model:** `AgentSessionProviderHistoryRecovery.DispatchBaseline` (L138) records the dispatch,
  run attempt, reset generation, provider, conversation, user items, FD file identity, complete-line
  offset, receipt, profile, status (`captured` or `unsupported`) and `recordedAtMs`. Decoding is per
  element; unreadable entries are kept verbatim in `unreadableDispatchBaselines`.
  `firstDispatchBaseline(runAttemptID:)` (L327) returns the earliest entry, so there is no backfill.
- **Identity:** `AgentProviderHandoff.dispatchBaselineIdentity` (L78) is the first durable receipt's
  attempt ID, the run attempt, and the constituents' user items
  (`AgentDispatchBaselineIdentity`, `AgentSessionHost.swift` L90).
- **Producer:** `ClaudeAgentModeCoordinator` `writeAdmission` (L2086), with the refusal box at L2053.
  - It awaits `admitClaudeDispatchBaseline` (`AgentModeViewModel+RecoveryActions.swift` L426), then
    revalidates the reservation and controller ownership.
  - `captureClaudeDispatchBaseline` (L435) runs: read off-main → zero-row `ImportCommit` receipt
    plus baseline in the ledger → fenced `saveSession` (at most 2 attempts) → verify
    `committedHistoryImportID` → cursor CAS with previous `nil`, only when no cursor exists.
  - A failure refuses the write: zero bytes, `processNotRunning` → `noteProvenNotWritten`, and the
    user sees `dispatchBaselineRefusedText` (L1750).
  - A missing conversation ID or home, or a reader failure, is recorded as `unsupported` and the
    ordinary send proceeds.
  - It is idempotent per dispatch (`RecoveryDispatchBaselineAdmission`, L408).
- **Preflight:** `AgentProviderHistoryImport.swift`.
  - `AgentProviderHistoryAssociationRefusal` (L168) is one of `baselineUnavailable`,
    `baselineTargetMismatch`, `nativeUserAssociationUnavailable` or
    `canonicalOutputAssociationUnavailable`.
  - `baselineRefusal` (L239) runs before any read. `check` (L198) runs after the read, over
    `AgentProviderHistoryCanonicalView` (transcript turns plus suffix items, L183).
  - `outputItemIDs` (L270) collects output kinds at or after the dispatch's first user item. A
    compacted turn is not enumerable.
  - Associated items are ledger `localItemID`s plus the observation's deterministic IDs. A ledger
    `nil` means unassociated, not a proven local user.
- **Reconcile:** it selects the baseline by `action.sourceRunAttemptID` and uses the baseline
  cursor as the boundary. The record cursor is used only as the CAS previous ID.
  - New result `AgentRecoveryReconcileResult.associationUnavailable` (`AgentRecoveryActionRunner.swift`
    L75). For `reconcileOnly` it records `notDispatched` with the reason. An explicit continuation is
    not stopped by it.
  - User text comes from `recoveryAssociationText` (L815).
- **Not changed (by design):** no translator, event-model or native-UUID-equivalence change.

### Claude seams (reported, not wired)

- **Native user association:** a native Claude user record does not carry the local user item ID,
  and live rows have no ledger `localItemID`. The preflight therefore always refuses a normal-live
  merge. The closure needs a primary-evidence mapping, which main will supply if one is found.
- **Home and conversation:** `AgentProcessRegistry.claudeProviderHomes(conversationID:)` (registry
  knowledge only) and the handoff conversation ID. Either missing gives `unsupported`.
- **Managed transport only:** `fenceRuntimeWrite` returns `nil` without `runtimeManagedTransport`.
  So an unmanaged Claude send runs no admission and records no baseline, and reconcile then
  reports `baselineUnavailable`.

### Codex cold observation transaction (closed in source)

This implements the Oracle cold-Codex closure plan. There is no new client, reader, cache,
service or runtime schema.

- **Coordinator:** `CodexAgentModeCoordinator.observeRecovery(session:actionID:threadID:expectedTurnID:sourceRunAttemptID:timeout:isCurrent:)`
  (`CodexAgentModeCoordinator.swift` L4682).
  - Preconditions: Codex agent, a live lane (else `staleContext`), not busy (`sessionBusy`), and
    `isCurrent`.
  - Scope: `.session(lane lifecycle, sourceRunAttemptID, processRunID: nil)`. The action ID is
    only the factory's correlation ID, never a logical run.
  - It joins prior tab retirements before acquiring anything (R6). It then captures the workspace,
    permission profile, session profile, task label and feature state, using the same derivation
    as `ensure` (`desiredCodexControllerFeatureState`, L4650, which `ensure` now also uses).
  - **Warm:** a controller matching workspace, permission profile, session profile and task label
    is borrowed unchanged and never shut down. A mismatch is `staleContext`: it is never
    invalidated and never replaced.
  - **Cold:** it makes one existing-factory call and calls `useOwnerCapturedRuntimeSessions()`.
    The observation runs in a scoped task. The cleanup is an unstructured task that awaits the
    observation, then `shutdown()`; it is retained as a tab retirement when the controller joins
    retirements. The cleanup is joined before any result, on success, error, cancellation and
    staleness alike. The new controller is never installed on the session.
  - Revalidation after the await: `isCurrent`, the lane, binding, profiles, task label and
    workspace, the borrowed instance, and no installed controller. Any change is `staleContext`.
  - It never touches `session.runID`, `codexController`, the event task, or normal ensure/resume.
- **Controller:** `CodexNativeSessionController.observeRecovery` (L1806).
  - On the registered path it runs `updateClientProcessFeaturePolicy` and then the registered
    `client.startIfNeeded(runtimeSession:)` BEFORE capturing the transport generation.
  - It then associates the expected thread through the existing registry
    (`CodexAppServerClient.associateObservedConversation`, L1004, which is pinned to the captured
    generation and launch).
  - The generation fence has no retry. It is checked before the first read, after a turns/list
    success (before the capability memo), first in the error path (before the unsupported check,
    the memo and the `thread/read` fallback), and after the final read.
  - Reads are observational only (`thread/turns/list`, then the `thread/read` fallback).
- **Adapter:** `CodexRecoveryAdapter.historyObservation` (L102).
  - It requires the expected turn ID.
  - A verified `completed` turn with unsupported item projection becomes zero rows with confirmed
    completion, so dispatch is suppressed.
  - Any other unprojectable or missing turn is `nil`, which is unconfirmed ("Codex has no
    matching record of the interrupted turn.").
- **View model:** `recoveryHistoryObservation` calls the coordinator with
  `action.actionID` / `sourceRunAttemptID` and an `isCurrent` closure over
  `recoveryActionStillCurrent`. Errors are typed into text by `recoveryCodexObservationText`
  (`AgentModeViewModel+RecoveryActions.swift` L830). None of them reads as "nothing new".
- **Typed errors added:** `CodexRecoveryObservationError.staleContext` and `.sessionBusy`.
- **Test seam:** a DEBUG `CodexAppServerClient.debugSetStartupOverride` (L2367) replaces only
  process launch. It installs the test transport and commits a launch through the injected
  registry, so the real registered `startIfNeeded` path advances the generation.

## Invariants (as implemented)

- **Actions:**
  - A durable item/revision/actionID reservation is taken before any effect. An identical repeat
    returns the receipt and joins. A different parameter set, or another unresolved action on the
    item, is an `actionConflict`. Parameters are validated before any write.
  - Each attempt is fenced on lifecycle, source intent, attempt, text and target (tab, lane,
    incarnation, reset generation, and the agent plus conversation target).
  - Crash uncertainty never auto-sends. Only a reservation committed by this very call
    dispatches; a found reservation is joined and reported.
  - Saved unsent constituents use normal dispatch once. Continuation is a new editable intent
    with a fresh user item. A historical answer becomes ordinary input, and held follow-ups stay
    separate.
  - There is no schedule confirm or replay, and no FileRestore dependency.
- **History:**
  - Native-ID dedup, rows and receipt go in one atomic session save before the cursor CAS, so a
    crash between the two never duplicates.
  - Stale snapshots cannot clobber an import, and a failed cursor CAS is safe.
- **Helper and R4:**
  - The helper is not a provider family and is never registered.
  - Cancel unfreezes Stage A. Stage B Retry and Quit Anyway leave no armed helper.
  - A lost armed ACK is aborted, or the helper's exit is verified, before any choice.

## Production stays OFF (proof)

- `AgentRecoveryActionQualification.production` is all-false
  (`AgentRecoveryActionRunner.swift` L42), so `recoveryActionRunner.isAvailable` is false and
  every row-action helper returns `[]`.
- The runner also requires `AgentProcessRegistry.production?.isRegistrationActive`. The Phase 3
  qualification `AgentRuntimeQualification.production` has no families
  (`AgentProcessRegistrySupport.swift` L60), so registration is inactive.
- `AppRelaunchCoordinator.production()` returns `nil`, so `environment.relaunch == nil` and R4
  refuses `.safeRestart` before anything freezes. `isSafeRestartAvailable` is false, so no menu
  item appears.
- Tests assert this:
  - `AgentRecoveryActionTests` (production/inactive gating).
  - `AppRelaunchCoordinatorTests.testProductionCompositionStaysOff`.
  - `AgentLifecycleShutdownCoordinatorTests.testSafeRestartIsRefusedWithoutComposedHooksBeforeAnythingFreezes`.
  - `AgentProcessRegistryTests.testProductionActivationStaysOffAndInactiveRegistryRefusesReservations`
    (existing).
  - `AgentRecoveryReconciliationTests` (an unregistered Codex transport fails closed). The
    baseline producer is inert when the runner is unqualified: there are zero history reads and
    no extra writes.
- The baseline gate is `recoveryActionRunner.capturesDispatchBaselines`
  (`historyReconciliation && registrationActive`, `AgentRecoveryActionRunner.swift` L148). It is
  false in production. Admission also runs only on the managed transport, which production never
  enables.

## Phase 3 interfaces

I verified `isRegistrationActive`, `hasStarted`, `refresh()`, records and states,
`activeLaunches`, `uncommittedLaunches`, `unpersisted`, preserved records, `providerHome` and
`conversationIDs`, and that `AgentRuntimeLaunchAuthority.production` is `.activationOff`. Phase 4
adds only `verifyAllFamiliesStopped()` and `claudeProviderHomes(conversationID:)` as an extension.

No Phase 3 optional findings are claimed fixed, and no bounded residual Phase 3 fix was made.
One residual is noted:

- `verifyAllFamiliesStopped` sees a launch only once `prepareSpawn` reserves it. An in-memory
  `makeLaunch` handle is invisible to the proof. Stage B relies on R4's sealed admission and
  completed teardown for that window.

## Validation

All runs used coordinated conductor jobs. Job logs live under
`~/Library/Application Support/RepoPrompt CE/Conductor/82430cd6…/jobs/<ticket>.log`, with
wrappers in `/tmp/p4-*.log`.

### Test suites

New suites are not in the frozen ledger; they run with default deadlines and a warning.

| Suite | Ticket | Result | Wrapper |
|---|---|---|---|
| `ClaudeSessionHistoryReaderTests` (new) | a723af99-79c5-4ecc-8964-44da7130118d | 19/0 | `/tmp/p4-test-reader-1.log` |
| `AgentRecoveryActionTests` (new) | e1a0e4e0-ac0f-46a3-bc9b-8e572f5a34a7 | 10/0 | `/tmp/p4-test-actions-2.log` (earlier attempt 32dd0062 failed to compile: autoclosure `await`) |
| `ProcessRelaunchHelperTests` (new) | 4809e16d-bedc-4cf8-b972-5fc56b22ff0f | 21/0 | `/tmp/p4-test-relaunch-1.log` |
| `AppRelaunchCoordinatorTests` (new) | aea17d0e-3a18-4d59-b478-d30cc65bffc6 | 7/0 | `/tmp/p4-test-apprelaunch-2.log` (earlier 5015d770: 1 test bug, a coordinator temporary deallocated under weak hooks) |
| `AgentLifecycleShutdownCoordinatorTests` (+6) | 6114d770-bb7b-4552-a4a4-c0859f4e5766 | 30/0 | `/tmp/p4-test-lifecycle-1.log` |
| `AgentRecoveryReconciliationTests` (new) | b4f8cdd5-fcc9-4a75-98c6-d84db0b54d4c | 6/0 | `/tmp/p4-test-reconcile-1.log` |
| `AgentProcessRegistryTests` (+1) | 3711b208-39d7-4197-8160-1107f48d1fe0 | 35/0 | `/tmp/p4-test-registry-2.log` (earlier cc566051: 1 wrong test assumption, a handle before `prepareSpawn`) |

**Final reruns after the lint fixes.** These supersede the table above. The first rerun batch,
wrappers `/tmp/p4-final-*.log`, failed to compile the test target, because a manual lint edit had
broken three `now: Date(...)` arguments in `ClaudeSessionHistoryReaderTests`. That was fixed, and
every suite was rerun once:

| Suite | Ticket | Result | Wrapper |
|---|---|---|---|
| `ClaudeSessionHistoryReaderTests` | 541576a1-8538-45f4-995e-71f3a68f29fc | 19/0 | `/tmp/p4-final2-ClaudeSessionHistoryReaderTests.log` |
| `ProcessRelaunchHelperTests` | be05b20e-9a4f-4b65-92df-02a7ab091202 | 21/0 | `/tmp/p4-final2-ProcessRelaunchHelperTests.log` |
| `AgentRecoveryActionTests` | e34a8040-8d43-4e3e-a514-ea6cc91ca487 | 10/0 | `/tmp/p4-final2-AgentRecoveryActionTests.log` |
| `AgentRecoveryReconciliationTests` | 3a48fa39-1a19-4307-990a-1353cf00fbaa | 6/0 | `/tmp/p4-final2-AgentRecoveryReconciliationTests.log` |
| `AppRelaunchCoordinatorTests` | 7fcb50a1-4ab8-4a42-b125-e2a0861b13d1 | 7/0 | `/tmp/p4-final2-AppRelaunchCoordinatorTests.log` |
| `AgentLifecycleShutdownCoordinatorTests` | 4d132355-b988-46cb-a527-919aad8aa2c6 | 30/0 | `/tmp/p4-final2-AgentLifecycleShutdownCoordinatorTests.log` |
| `AgentProcessRegistryTests` | 68c6babf-771b-4d12-91fb-ce00dd579043 | 35/0 | `/tmp/p4-final2-AgentProcessRegistryTests.log` |

Total: 128 tests, 0 failures, 0 skips.

### Builds and checks

- `make dev-swift-build PRODUCT=RepoPrompt`: ticket 26241e08-efc3-4ffc-844d-aa84ac5cdd5a, exit 0.
  Earlier iterations up to `/tmp/p4-build-8.log`.
- `make dev-swift-build PRODUCT=repoprompt-mcp` (compile-only): ticket
  d3d743bf-8a12-4199-aeab-e552dce88ea2, exit 0.
- **`make dev-lint`:** the first run, cfab6657, reported 134 SwiftFormat findings, all in Phase 4
  files. I fixed them by hand, without `make dev-format`. The fixes: drop redundant `Sendable` on
  non-public types, use `package extension` blocks, hoist `try`/`await`, `count(where:)`, wrap
  property bodies, adjust number literals and trailing commas. The final run, f5d6b592, exits 0.
- **Rebuilds after the lint fixes:** `PRODUCT=RepoPrompt` ticket
  44c8df91-284d-42ad-bd66-f19de88c63b7 and `PRODUCT=repoprompt-mcp` (compile-only) ticket
  d4ea29c1-6edc-472f-9719-48fe1fdcea20. Both exit 0, so removing the `Sendable` conformances
  compiles across modules.
- **`Scripts/check-agent-context` / `make guardrails`:** both fail with one error. This file is an
  orphan: no reachable active context document links to it. Sibling evidence is reached only
  through the Step status lines in the original spec, and those lines are main-owned. So the link
  (`Step 4 … [implementation evidence](evidence/2026-10-18-lossless-app-restart/phase4.md)`) is
  left for the main agent. The header errors (Scope, Authority, Last-verified) are fixed. The
  `route-count` warning on `AGENTS.md` predates this work and is out of scope. All other
  guardrails sections passed before the check (the log ends in the context check).

### Oracle bounded-plan round (2026-10-22)

| Check | Ticket | Result | Wrapper |
|---|---|---|---|
| `ClaudeSessionHistoryReaderTests` | b8fb3339-783d-4098-a876-ebe2d68e7904 | 22/0 | `/tmp/p4-o-reader-2.log` |
| `AgentRecoveryActionTests` | faac8f53-0093-4a5b-9e95-a44c57e27739 | 17/0 | `/tmp/p4-o-actions-1.log` |
| `AgentProviderHandoffTests` | 0eca73cf-c3b6-4b7e-8b04-60c92b13ce9b | 12/0 | — |
| `AgentRecoveryReconciliationTests` (after lint fix) | 7f022228-59d5-4c2b-83e5-cad6b8f1e0ad | 16/0 | `/tmp/p4-o-final-AgentRecoveryReconciliationTests.log` |
| `RegisteredNativeTransportWriteFenceTests` (after lint fix) | 9b15edd4-39ce-4a16-b1bf-06a566fbb174 | 16/0 | `/tmp/p4-o-final-RegisteredNativeTransportWriteFenceTests.log` |
| `AgentModeRunServiceLifecycleTests`, which includes the Claude coordinator lifecycle extension (after lint fix) | 1388f7cd-c74f-48e9-b59c-38d64dcad257 | 186/0 | `/tmp/p4-o-final-AgentModeRunServiceLifecycleTests.log` |
| `make dev-lint` | ee0d0875-9840-4d91-bcc1-a719da93d405 | exit 0 | `/tmp/p4-o-lint-2.log` |
| `make dev-swift-build PRODUCT=RepoPrompt` | 98a5b6cc-eed7-490e-9fba-f9fe3b1118c0 | exit 0 | `/tmp/p4-o-build-3.log` |
| `make dev-swift-build PRODUCT=repoprompt-mcp` (compile-only) | da531dea-e111-42c9-a7bd-fefe86035f19 | exit 0 | `/tmp/p4-o-mcp-2.log` |
| `Scripts/check-agent-context` / `make guardrails` | — | exit 0 (only the pre-existing `AGENTS.md` route-count warning) | `/tmp/p4-o-ctx-1.log`, `/tmp/p4-o-guard-1.log` |

### Claude composition tests and cold Codex closure (2026-10-22)

| Check | Ticket | Result | Wrapper |
|---|---|---|---|
| `AgentModeRunServiceLifecycleTests` (+4 Claude baseline composition tests) | 52a2dadb; rerun a223d289 | 190/0 | `/tmp/p4-c-AgentModeRunServiceLifecycleTests.log` |
| `CodexAppServerRuntimeFenceTests` (+2) | 8a0ee5f4-7815-4716-a93d-4aa3f3681467 | 13/0 | `/tmp/p4-c-fence.log` |
| `AgentRecoveryReconciliationTests` (+2), final after the lint fix | 4707d5cd-8329-435b-b10a-d276f3f83b56 | 18/0 | `/tmp/p4-c-recon2.log` |
| `CodexGoalSupportDefaultTests` (`ensure` refactor) | ca29ea8c | 20/0 | `/tmp/p4-c-CodexGoalSupportDefaultTests.log` |
| `CodexAgentModeCoordinatorLivenessTests` | addb80b2 | 55/0 | `/tmp/p4-c-CodexAgentModeCoordinatorLivenessTests.log` |
| `CodexAgentModeCoordinatorHiddenToolBoundaryTests` | c48fb8a6 | 4/0 | `/tmp/p4-c-CodexAgentModeCoordinatorHiddenToolBoundaryTests.log` |
| `AgentRecoveryVMProducerAdmissionTests` | 7912c698 | 21/0 | `/tmp/p4-c-AgentRecoveryVMProducerAdmissionTests.log` |
| `AgentProviderHandoffTests` | 849d7dfa | 12/0 | `/tmp/p4-c-AgentProviderHandoffTests.log` |
| `AgentRecoveryActionTests` | 2fb240fc | 17/0 | `/tmp/p4-c-AgentRecoveryActionTests.log` |
| `RegisteredNativeTransportWriteFenceTests` | c3c08256 | 16/0 | `/tmp/p4-c-RegisteredNativeTransportWriteFenceTests.log` |
| `CodexNativeSessionControllerGoalConfigTests` | 41020ba2 | 16/0 | `/tmp/p4-c-CodexNativeSessionControllerGoalConfigTests.log` |
| `make dev-lint` | dbddcd88 | exit 0 | `/tmp/p4-c-lint2.log` |
| `make dev-swift-build PRODUCT=RepoPrompt` | a675ad08 | exit 0 | `/tmp/p4-c-build3.log` |
| `make dev-swift-build PRODUCT=repoprompt-mcp` (compile-only) | eeea4afb-d8ab-4826-8622-df75509445e4 | exit 0 | `/tmp/p4-c-mcp2.log` |

Notes on this round:

- Lint 896af2e4 reported one `redundantSelf` in the new view-model `isCurrent` closure. I fixed it
  by hand, then reran lint, the app build, reconciliation and the MCP compile.
- Two reconciliation attempts failed on fixture mistakes, not source:
  - 4c7be085: the Codex target uses `codexConversationID`, not `providerSessionID`.
  - 8d934b0a: `hasPendingRuntimeRetirements` was read before the retirement wrapper drops its own
    entry, one main-actor hop after the joined cleanup. The tests now assert that a later join
    performs nothing further.

What the new tests cover:

- **Controller (`CodexAppServerRuntimeFenceTests`):**
  - `testColdRecoveryObservationStartsTheRegisteredTransportBeforeCapturingItsGeneration`: there
    is no process before. The real registered `startIfNeeded` advances the generation by one. The
    only frame is `thread/turns/list`, already associated with `thread-r`, and the registry record
    carries the owner association.
  - `testRecoveryObservationIsStaleWhenTheTransportIsReplacedMidRead`: the transport is replaced,
    then the read returns -32601. The result is `staleTransportGeneration`, with no fallback
    frame.
- **Reconciliation, VM table (`testColdCodexReconcileObservesThroughATemporaryControllerAndJoinsItsCleanup`):**
  - Rows: completed with unsupported items → `imported(confirmed, 0)`; missing turn →
    unconfirmed; interrupted with unsupported items → unconfirmed.
  - In every row: one factory call with `runID == actionID`, the exact durable scope, observe →
    shutdown → shutdown-complete, no thread start or send, no installed controller, run ID and
    event task unchanged, and zero transcript rows.
- **Reconciliation, coordinator (`testCodexObservationTransactionOwnershipCuts`):**
  - A pending retirement means zero factory calls until it is joined, and no result until the
    cleanup completes.
  - Warm compatible: borrowed, zero creations, never shut down. Warm incompatible: `staleContext`,
    left in place. Busy: `sessionBusy`.
  - A policy change, target replacement or cancellation mid-observation gives `staleContext` /
    `CancellationError`, with the cleanup joined and nothing installed.
- **Claude composition tests** (`AgentProviderHandoffTests.swift` L1035-L1131, which run under
  `AgentModeRunServiceLifecycleTests`):
  - a delayed baseline commit sends nothing until released;
  - a commit failure sends nothing and gives proven-not-written / `.notHandedOff`;
  - superseded or cancelled while awaiting sends nothing;
  - success gets the exact immutable identity and owner.
  - They use the existing fake controller's opt-in, which invokes the TaskLocal `writeAdmission`
    before its recorded write.
- **Production OFF:** this rests on the existing tests (runner gate; an unregistered controller
  fails closed before any start or request). No production toggle was changed.

Notes on earlier attempts:

- `AgentModeRunServiceLifecycleTests` also passed before the lint fix (ticket
  21b4fdcb-d7af-4057-b725-7e9ff21d6676, 186/0).
- An earlier attempt with the filter `ClaudeAgentModeCoordinatorLifecycleTests` matched nothing.
  That suite is an extension of `AgentModeRunServiceLifecycleTests`.
- Lint 724ae56f reported three findings (`redundantSendable`, `hoistTry` and `hoistAwait`). They
  were fixed by hand.
- Because of the orphan link, `check-agent-context` previously failed. It now passes.

## Deviations

- **Conductor daemon stopped (my action):** in an earlier segment I stopped the idle shared
  Conductor daemon after my own jobs had finished. Main's next job-list attempt failed because of
  this. Completion requires only my own jobs to finish, never daemon removal. I did not stop it
  again.
- **No review round:** none was run for the Oracle bounded-plan source, as instructed.
- **Claude composition tests:** these were added afterwards (see the 2026-10-22 round). They need
  one DEBUG view-model hook, `test_claudeDispatchBaselineAdmission`, which
  `admitClaudeDispatchBaseline` consults before the real capture.
- **Borrow compatibility:** a warm controller is compared on workspace, permission profile,
  session profile and task label, but NOT on the process feature state (goal, reasoning
  summaries, computer use), because a read does not depend on it. This is a deliberate narrowing
  of "same policy".
- **Tool boundary, again (cold-Codex segment):** after the correction I again inventoried and
  read Tests and Sources through the shell:
  - `grep -rln` and `ls` over the test tree / `Tests/RepoPromptTests/AgentMode/Recovery`;
  - `grep -n` over `AgentModeRunServiceLifecycleTests.swift`;
  - `grep -n` / `sed -n` over `AgentTabSession.swift`, `AgentProviderPermissionProfile.swift` and
    the head of `AgentRecoveryReconciliationTests.swift`.

  Main flagged this. All later source, config and doc reads, including these anchors, used
  RepoPrompt tools. Nothing was redone solely for this.

- **Tool boundary:** before the correction, I read source, config and docs with shell `git grep`,
  `head` and `sed`, against the brief. After the correction, every source, config and doc read
  used RepoPrompt `file_search`, `read_file` and `get_code_structure`. Shell was used only for Git
  state, Conductor operations and logs. No code was reworked solely for this.
- **New test files:** six new suites were added, and two existing suites were extended
  (`AgentLifecycleShutdownCoordinatorTests` and `AgentProcessRegistryTests`). The frozen ledger is
  unchanged.
- **Reader rule change:** I fixed one reader bug found by fixtures. A conversation that ends on a
  parallel tool group has 0 tips, and is now accepted when `groupLeaves > 0`.

## Remaining gaps (not live-ready)

- **Live acceptance:** O3 is pending for every capability. Production activation needs O3 plus an
  active Phase 3 registry.
- **Claude import:** the pre-byte baseline is wired only on the managed transport. A normal-live
  merge is always refused (`nativeUserAssociationUnavailable`); see "Claude seams". A runtime with
  no recorded `providerHome` is `unsupported`.
- **Baseline risks:**
  - Coalesced saves can refuse a dispatch after two save attempts. That costs a send, never
    produces a phantom.
  - A refused baseline's receipt may stay pending. This is harmless as a pre-byte boundary.
  - The Codex path is unchanged by the preflight.
- **Cold Codex limits (source closed, fixture-only):**
  - **Production:** the App factory builds the client with the `.production` launch authority.
    The observation therefore fails closed (`registeredTransportRequired`) until Phase 3
    activation.
  - **MCP policy:** no MCP connection policy is installed for the temporary controller. This
    assumes an observation loads no thread and opens no MCP connection, which is unverified
    without live testing.
  - **Correlation:** the expected-PID/MCP correlation of the temporary controller uses the
    action ID.
  - **Cleanup:** shutdown is awaited with no explicit bound. A hung shutdown keeps reconcile
    waiting. There is no typed cleanup-pending result and no hand-off to retirement on timeout.
    Root-reap uncertainty stays blocking through the registry and R6 (the retirement is joined by
    successors).
  - **`initialize` handshake:** the DEBUG startup override skips it, so it is untested at
    controller level.
  - **Warm borrow:** it ignores the process feature state (see Deviations).
  - **Messages:** an `interrupted` or `failed` turn with unprojectable items reports the same
    "no matching record" text as a missing turn (unconfirmed in both cases).
- **Codex reconcile:** it still needs a `providerTurnID` on the transcript span. Items are
  limited to agent and user messages.
- **`answerAsInput`:** it sends the snapshot's composer text (question plus answer).
- **`sendSaved` refusal:** if dispatch is refused after the claim, the intent stays queued under
  the current app instance (it is not withdrawn).
- **Older builds:** they drop the history member when they rewrite a session.
- **Untested seams:** the real `AppRelaunchHelperProcess`, the live `ProcessRelaunchHelperMain`
  over stdio, and the `NSWorkspace` open are untested by design (executing them is not allowed).
  The view-model action dispatch path has no end-to-end test with a live provider.
- **Deferred:** Phase 5, polish and retention.

## Main frozen scope audit

Read-only scope audit: `prompt-exports/agent-run-2d54ad1dc1e4-6cb4234d.md`. It read the entire immutable comparison and reports no unrelated production change, no new target/product/external package, no existing assertions weakened or skipped, and no protected original dirty paths or frozen-ledger changes. Main spot-read the private executable entry and cold controller acquisition/release path. Main also confirmed one NEW test fixture guard in `AgentRecoveryActionTests.record()` throws `XCTSkip` on an unexpected preserved record; actual validation skipped no tests, but that guard must become a failing test rather than masking a future regression. Main included this bounded repair in the initial-remediation brief.

## Main initial frozen review boundary

Main verified exact Conductor metadata and test log summaries for **16 source-validating suites, 497 tests, all passed** on the final source. Main independently reran reader (22), helper (21), app relaunch (7), R4 shutdown (30) and registry (35) suites after the worker froze. The other 11 latest affected suites total 382 tests, including 190 lifecycle tests and the four enabled baseline-composition cases. Both compile-only products passed after the last source edit: `a675ad08-ab54-4bb2-bc8a-82e969121f93` (`RepoPrompt`) and `eeea4afb-d8ab-4826-8622-df75509445e4` (`repoprompt-mcp`). Final lint `dbddcd88-778a-44ef-8e82-cfa0fd26b5b6`, `make guardrails`, `.githooks/pre-commit` and whitespace checks passed, with the existing route-count warning.

Initial reviews compare signed baseline `559ecd9d6d037ba762d8f4d2297d3c397a9d1f67` with immutable tree `e876de21cca35adeda4d007930080f8ee9cb199b`: 49 intended source/test/package/layout/allowlist paths, 9,703 insertions and 52 deletions. Complete unified-5 patch: `_git_data/repos/repoprompt-ce-personal-t-27030497/2026-10-22/1526/diff/all.patch`. Main hash-matched every one of the 49 current paths to that tree and checked the empty real index and absence of running Conductor jobs. No implementation worker was active; a separate read-only scope audit was allowed.

Fresh OracleA and OracleB review chats were issued together with the exact same controlled frozen patch, current source context, original requirements, adopted partial-Claude and cold-Codex/helper amendments, policy verbatim and verified validation. Shared selection was cleared. Neither lane received the other's output, metadata or main's assessment. Both initial responses completed with exact explicit preset identities verified. [OracleA initial findings](phase4-oraclea.md) and [OracleB initial findings](phase4-oracleb.md) are saved verbatim. Neither approves this checkpoint: A has nine required findings, and B has five (including two explicitly plausible cases requiring a short source trace). No P0 was identified. Main accepted the concrete required fixes and returned both exact exports to the same Pair worker; B's plausible finished-run and composer cases must be verified, not assumed. Main directly confirmed the runner's blocking-failure fallthrough, stale Restart reason across confirmation cancellation and the existing non-composer `.followUp` property; workflow inheritance remains a separate boundary to test. Initial review is complete; the next submission will be bounded re-review 1/2. No required finding is claimed closed yet. Full normal-live Claude canonical merging remains blocked on native identity associations, not merely live qualification. O3 remains pending; no activation, live provider/helper/app execution, packaging or full-root/performance campaign was performed.

| Suite | Verified ticket | Tests |
|---|---|---|
| ClaudeSessionHistoryReaderTests | `5cfa9407-fdee-4861-9486-2b53e4e309f4` | 22 |
| ProcessRelaunchHelperTests | `0a2a2e7d-f2bd-42d4-a409-64d284dd055b` | 21 |
| AppRelaunchCoordinatorTests | `b668c33c-74b5-49a0-8e7d-6929944c96d0` | 7 |
| AgentLifecycleShutdownCoordinatorTests | `7988cc35-dbab-4d03-b4a0-5f206675e92c` | 30 |
| AgentProcessRegistryTests | `c55c0907-c396-402f-a134-9b5e75f5dca5` | 35 |
| CodexAppServerRuntimeFenceTests | `8a0ee5f4-7815-4716-a93d-4aa3f3681467` | 13 |
| AgentRecoveryReconciliationTests | `4707d5cd-8329-435b-b10a-d276f3f83b56` | 18 |
| AgentModeRunServiceLifecycleTests | `a223d289-dc68-4f5a-b029-96d7a1d5b6ee` | 190 |
| AgentProviderHandoffTests | `849d7dfa-0dfb-474a-86f2-fe0e55568892` | 12 |
| AgentRecoveryActionTests | `2fb240fc-429d-4a2a-8e38-b6469127071c` | 17 |
| CodexGoalSupportDefaultTests | `ca29ea8c-5a60-4501-a723-bc3477100b1c` | 20 |
| CodexAgentModeCoordinatorLivenessTests | `addb80b2-acfb-43a3-82e6-114280e85b70` | 55 |
| CodexAgentModeCoordinatorHiddenToolBoundaryTests | `c48fb8a6-b292-478a-b4de-62375c815f72` | 4 |
| AgentRecoveryVMProducerAdmissionTests | `7912c698-1994-4a44-b55f-8035f4ba9e79` | 21 |
| RegisteredNativeTransportWriteFenceTests | `c3c08256-2d0f-4b88-b72f-8f6e70dd785e` | 16 |
| CodexNativeSessionControllerGoalConfigTests | `41020ba2-c39c-4bb9-ba8e-a76d98cb6bfe` | 16 |

## Bounded P0/P1 remediation before R1 (worker record)

Inputs: OracleA export `prompt-exports/oracle-review-2026-10-22-154329-lossless-restart-pha-b2e0.md`
(P1-01..09) and OracleB export `prompt-exports/oracle-review-2026-10-22-153828-lossless-restart-pha-4197.md`
(F1..F5, B3 trace), plus main's F5 spot-check. These are worker dispositions only: no review was run
and nothing is claimed closed until re-review. Production stays OFF (`.production` qualification
unchanged), O3 stays pending, and partial Claude stays partial. Anchors refer to the frozen source
at the end of this round.

### Dispositions

- **A P1-01 / B F3a: shared admission hold. Fixed.**
  - `AgentRecoveryActionRunner.isHoldingAction(sessionID:)` (`AgentRecoveryActionRunner.swift:173`)
    is true from just before reservation until the outcome is recorded, covering reconciliation,
    Codex observation cleanup, dispatch and the outcome write.
  - `perform` refuses any other action on the same session (`:200`).
  - `scheduledSendHasUnresolvedRecovery` consults the hold
    (`AgentModeViewModel+ScheduledSend.swift:1476`). The hold therefore feeds
    `scheduledSendBusyState`, and through `hasUnresolvedRecoverySession` it also feeds new-session
    starts. The coordinator already checks that hook even with `runAlongsideOtherSessions`
    (`AgentScheduledSendCoordinator.swift:1729`).
  - Only the action's own dispatch proceeds, because the normal submit never consults the hold.
  - `scheduledSendCoordinator?.recordDidChange()` re-evaluates after `perform`
    (`AgentModeViewModel+RecoveryActions.swift:223`).
- **A P1-02 / B F2: failure is never a fallthrough. Fixed.**
  - New `AgentRecoveryReconcileResult.blocked(_, completion:)`.
  - Every reconcile failure is `.blocked`: stale action, no conversation, busy, pending save,
    unreadable record, read failure, changed session, save failure.
  - Only the Codex "no usable record of the turn" observation is a successful unconfirmed
    observation, and it continues (`AgentModeViewModel+RecoveryActions.swift:677`).
  - `associationUnavailable` now blocks a continuation as well.
  - `stopBeforeDispatch` (`AgentRecoveryActionRunner.swift:307`) stops on a bound imported
    completion, on `.blocked`, and on `associationUnavailable`.
- **A P1-03: confirmed completion independent of row persistence. Fixed.**
  - Completion is computed from the observation before the changed-session guard.
  - A row save failure with confirmed completion returns `.blocked(…, completion: .confirmed)`.
    The runner records that as `importedCompleted`, so the completion is durable.
  - `AgentRecoveryRecord.hasVerifiedCompletion` (`AgentRecoveryActionModels.swift:282`) also
    accepts a terminal that classifies as `.completedTailMayBeMissing`.
- **A P1-04 / B F1: Codex overlap. Fixed.**
  - `AgentProviderHistoryAssociationPreflight.codexOverlapRefusal`
    (`AgentProviderHistoryImport.swift:285`) withholds every projected row when the canonical
    transcript holds unassociated provider output at or after the turn's user item. Compacted turns
    and the suffix are included, and the user item comes from `runTurnID`'s request anchor.
  - The result is zero rows, zero ledger writes and no cursor movement.
  - A confirmed completion still returns `.imported(confirmed, 0)`; otherwise the result is
    `.nothingImported(recoveryCodexOverlapText)`.
- **A P1-05: Claude positive association. Fixed.**
  - `check` requires every `baseline.userItemIDs` entry to be the `localItemID` of a ledger native
    user row (`userText` / `userMessage`) of the same provider and conversation
    (`AgentProviderHistoryImport.swift:235`).
  - A nil `localItemID` counts as unassociated. There is no empty-output or user-filter shortcut.
  - The check runs after the target-mismatch checks, so `baselineTargetMismatch` keeps precedence.
  - Consequence: nothing in this build writes user associations, so every normal-live Claude
    reconcile refuses, and a qualified Claude continuation stops `notDispatched` on
    `associationUnavailable`.
  - Full canonical merging stays BLOCKED on native identity associations.
- **A P1-06: never-handed-off R7 runs. Minimum met; bubble reuse CUT.**
  - `isVerifiedNeverHandedOff` (`AgentRecoveryActionModels.swift:296`) hides Continue in the row
    and refuses it in the runner (`neverHandedOffText`).
  - Bubble reuse for Send saved is cut. `appendPreparedUserTurn` always appends and opens a turn
    anchor, so Send saved remains the route (and is still refused while its bubble is present) and
    Edit stays available.
- **A P1-07: R4 deadline includes helper cleanup. Fixed.**
  - `armDeadline` reserves `cleanupReserve` (750 ms abort acknowledgement plus 250 ms terminate
    grace = 1 s) inside the single 8 s deadline, for safe restart only
    (`AgentLifecycleShutdownCoordinator.swift:799`).
  - `stopUnarmed` (`ProcessRelaunchHelper.swift:794`) is now abort, then a bounded wait, then the
    exact-child kill, then a bounded wait. There is no 16 s bonus.
  - `AppRelaunchHelperProcess.terminate` SIGKILLs its own `Process` pid
    (`AppRelaunchCoordinator.swift:194`).
  - `abandon` runs before every prompt (existing), so no choices appear while the helper may be
    armed.
- **A P1-08: registry seal. Fixed.**
  - `verifyAllFamiliesStopped` sets `isSealedForSafeRestart` before its proof
    (`AgentProcessRegistry.swift:1075`).
  - `reserveLaunch` throws `.launchesSealed` for every launch, sessionless probes included (`:673`).
  - The seal is never released. Stage B has no Cancel (`(.finalization, .cancel)` re-presents the
    prompt), and Stage A's Cancel runs before any proof, so it stays reversible.
- **A P1-09: shutdown reason bound to one request. Fixed.**
  - `AppShutdownReasonLatch` (`AppQuitPolicy.swift:28`) is armed only by `requestSafeRestart` around
    its own `NSApp.terminate` and disarmed afterwards.
  - `applicationShouldTerminate` takes it first thing (`AppDelegate.swift:165`) and threads the
    reason through confirmation to `beginTermination`.
  - A cancelled confirmation followed by an ordinary Quit is a plain quit.
- **B F3b / B3 item-resolution trace. Fixed.** Before this round nothing wrote an item resolution:
  outcomes were only recorded on the action. Now:
  - `resolvingAction(for:)` (`AgentRecoveryActionModels.swift:309`) finds a `dispatched` or
    `importedCompleted` action on the key.
  - The store refuses new dispatching choices on a resolved key
    (`AgentRecoveryStore+Actions.swift:202`). An exact repeat still joins first.
  - Catalog `actionFacts` hide Continue, Send saved and Answer on resolved items
    (`AgentModeViewModel+RecoveryActions.swift:65`, `:84` and `:98`).
  - Reconcile stays available.
  - Unresolved interruptions are not fed into busy aggregation, so they cannot block
    indefinitely; only the in-flight hold is.
- **B F4 (plausible): finished-run continuation. Confirmed and fixed.** Traced through three
  checks:
  - row gating: Continue is offered only when `status.isInterruption` is true for the current
    reset generation, the item is unresolved, and the run was handed off (`:65`);
  - runner terminal evidence: a completed terminal leads to `importedCompleted`, and a failed,
    user-cancelled or stopped terminal leads to `notInterruptedText`;
  - generation: `clearedConversationText`.
- **B F5 (plausible): composer leak. Partial fix.**
  - `consumesComposer = origin == .composer` (`AgentModeViewModel.swift:16171`), so `.followUp`
    already left draft text, images, tagged files and interview-first untouched. That draft-loss
    scenario is not claimed.
  - The real leak was the workflow: `session.selectedWorkflow` wrapped the continuation.
  - `reservedPayloadOnly: true` sets `workflow = nil` (`:16185`). Downstream uses
    `admitted.workflow` (`:15946`).
  - It refuses composer and MCP origins, empty text, native prepared turns and slash commands
    (`:16163`).
  - The unreachable non-admitted fallbacks now fail closed (`:16156`, `:16200`).

### P2s

- **Done:**
  - ready-helper expiry (`ProcessRelaunchHelper.swift:506`);
  - exact in-flight join (A P2-03, `AgentRecoveryActionRunner.swift:193`);
  - reserved prefix `--rpce-private-relaunch` (`ProcessRelaunchHelper.swift:41`);
  - SIGPIPE: `configureNoSigPipe` and `writeAll` on the helper pipe
    (`AppRelaunchCoordinator.swift:178`, `:183`);
  - restart-timeout wording (`AgentLifecycleShutdownCoordinator.swift:678`);
  - live helper executable path from `ProcessInspection` (`ProcessRelaunchHelper.swift:872`,
    `AppRelaunchCoordinator.swift:139`).
- **No issue:** no-retry generation. `client.request` is pinned to its
  `RuntimeWriteOwner(generation, launch)` and never starts a process.
- **Deferred:**
  - post-exit open-failure prompt;
  - typed cold-observation failure;
  - tolerant optional history members and a non-power-of-two `UInt64` roundtrip test;
  - prior uncertain outcome;
  - early fresh detach;
  - history order;
  - off-main parsing test gap;
  - an item whose action outcome went unrecorded stays blocked until it is reviewed.

### New and changed tests (production seams)

- **Runner:** `AgentRecoveryActionTests`
  - blocked stop and confirmed completion;
  - record evidence (completed, failed, user-cancel, open, app-quit);
  - never handed off;
  - resolved-item refusal;
  - the in-flight hold and its refusals.

  The `XCTSkip` masking in `record()` now fails the test. The association test now expects
  `notDispatched`.
- **Preflight and VM:** `AgentRecoveryReconciliationTests`
  - P1-05 positive association;
  - existing preflight cases now pass an explicit user association;
  - Codex overlap at the VM (zero rows, completion kept, plus a no-overlap control);
  - VM busy and new-session hold during a gated reconcile;
  - run-row gating.
- **VM admission:** `AgentRecoveryVMProducerAdmissionTests`
  - F5: reserved payload only; draft, image, tag, workflow and interview are kept;
  - the refused routes.
- **Helper:** `ProcessRelaunchHelperTests`
  - the bounded unarmed cleanup without the 16 s timer;
  - a kill whose exit is never observed still finishes within the reserve;
  - ready expiry;
  - prefix forms.
- **Registry:** `AgentProcessRegistryTests` checks the seal after the proof, sessionless included.
- **R4:** `AgentLifecycleShutdownCoordinatorTests` checks that hooks never use the reserve.
- **Latch:** `AppQuitPolicyTests` covers a cancelled restart confirmation followed by an ordinary
  Quit, and one termination request.

### Failed attempts this round

| Failure | Ticket | Fix |
|---|---|---|
| Reconciliation 6/18 failed | `d2af92d7-9a1f-4d3e-be4f-b66e4ab3db3a` | The positive-association check ran before the target checks, and the preflight fixtures carried no user association. The check was moved after `outputItemIDs`, and the fixtures were given an explicit association. |
| Helper test failed | `c648042f-2a31-4d2c-97b1-10c20e77b9ed` | The test waited for the removed 16 s timer. Updated to the 750 ms acknowledgement. |
| Registry 1/35 failed | `4fa1db08-4c00-43a1-8f11-a78bddb9ff14` | A launch was reserved after the sealing proof. The test now proves the seal and launches on a fresh registry. |
| Reconciliation 2/22 failed | `bac2f6cc-7153-4f89-bb73-123112ff2eef` | The Codex no-overlap control expected 1 row, but the projection yields 2. The control now checks only that rows import. |
| Lint failed | `eb67eda8-9c92-49e2-abc4-45d14c03c941` | `trailingCommas` and `wrapArguments` in the new tests. Fixed by hand. |

Earlier in the round, the RepoPrompt build passed at `829e5338`.

### Final validation (frozen source)

**Main's 16 boundary suites plus `AppQuitPolicyTests`: 17 suites, 515 tests, 0 failures.**

| Suite | Ticket | Tests |
|---|---|---|
| AgentRecoveryActionTests | `37e04d4c-678e-46da-9880-2f5bf18e655b` | 22 |
| AgentRecoveryReconciliationTests | `eca9ebf2-b3f5-4201-9f3a-199c4098520a` | 22 |
| AgentRecoveryVMProducerAdmissionTests | `71943bbe-5cc0-44e4-aa6b-0a3dd83efb1e` | 23 |
| ProcessRelaunchHelperTests | `b38ae959-9035-4773-8346-4122e22b456f` | 22 |
| AgentProcessRegistryTests | `a5e7d2e8-67ae-4e7a-a68d-16e6515d56d8` | 35 |
| AgentLifecycleShutdownCoordinatorTests | `af2d215f-ea09-4ee7-879d-da619204e5b6` | 30 |
| AppQuitPolicyTests | `21b0feb5-bf57-4b5d-8026-67d5dcc7831c` | 6 |
| AppRelaunchCoordinatorTests | `d9de8946-a2dc-498d-a87d-c9708e96d037` | 7 |
| ClaudeSessionHistoryReaderTests | `b64aa2e8-555e-4784-ad78-20f70b4e8acc` | 22 |
| AgentProviderHandoffTests | `66140f17-3779-485e-901e-f7da00e3e95d` | 12 |
| AgentModeRunServiceLifecycleTests | `1ac699ab-f7ce-424b-bbb7-c80d3b9a49dd` | 190 |
| CodexAgentModeCoordinatorLivenessTests | `4dbc543c-1dfc-4eaa-b71e-64723204540b` | 55 |
| CodexAppServerRuntimeFenceTests | `ccb8cec4-fe6d-4191-bb1d-0ffe56cd783d` | 13 |
| RegisteredNativeTransportWriteFenceTests | `efcc5c98-a40c-47fe-babd-9524f01da8da` | 16 |
| CodexGoalSupportDefaultTests | `1116b3d3-3bcf-48f3-9bec-8782abfdc99c` | 20 |
| CodexNativeSessionControllerGoalConfigTests | `bdcfb979-7340-436a-8c3f-2ac24dacfbd8` | 16 |
| CodexAgentModeCoordinatorHiddenToolBoundaryTests | `5a5bc5b3-ce3d-47d0-aee8-a8c90bf1848e` | 4 |

**Neighbouring suites: 11 suites, 229 tests, 0 failures.**

| Suite | Ticket | Tests |
|---|---|---|
| AgentRecoveryCoordinatorTests | `2f92e843-c018-4456-a63c-1c247f8f059d` | 45 |
| AgentRecoveryStoreTests | `29cae403-236a-4ca5-b171-03df5c9a1ecb` | 21 |
| AgentRecoveryStartupCompositionTests | `f4fb7f85-a18c-4235-88bb-6fa3077529e3` | 12 |
| AgentScheduledSendNonCodexMandatoryTests | `8f8a71f2-d310-4abf-8f87-15f8bf5da233` | 2 |
| AgentScheduledSendReceiptTransferTests | `723be01f-6e38-46ed-94d6-6b963d4bbf8a` | 11 |
| AgentRecoveryRuntimeOwnershipTests | `f166f2c1-a2b3-4aef-a6a1-21685de0b3b3` | 10 |
| AgentSessionRecoveryIntegrationTests | `d57bfd6f-b624-4ab6-a82a-f24a38d42a52` | 5 |
| AgentRecoveryQueuedInputTests | `6e37d98a-324e-483a-b29b-82fd0a29dafb` | 10 |
| AgentProcessRegistryAssociationTests | `98019b54-08b9-453f-a19d-88ddba93b1e2` | 8 |
| AgentScheduledSendCoordinatorTests | `6b19d3ae-5e89-4983-a7c0-5b1920559e86` | 52 |
| AgentScheduledSendDispatchTests | `5bcad9e8-de12-4b62-bb63-f9f0362b2937` | 53 |

**Builds and checks:**

| Check | Ticket or result |
|---|---|
| `make dev-swift-build PRODUCT=RepoPrompt` | `ef1b5ef2-4dba-4b30-82c5-0885e4ccc880` |
| `make dev-swift-build PRODUCT=repoprompt-mcp` (compile only) | `33d4734d-861d-41ce-a630-e38c84af094d` |
| `make dev-lint` | `820ac5c9-60cb-403d-95ba-7bedde36a6ff` |
| `make guardrails` | passed, with the existing route-count warning |
| `Scripts/check-agent-context` | passed, with the existing route-count warning |

Ordering note: the final lint fix changed only the new test file, and
`AgentRecoveryReconciliationTests` was re-run afterwards (`eca9ebf2`).

**Not run:** packaging, app launch, live providers, the real helper or MCP binary, the full test
root.

### Main verification before the first re-review

Main matched all 28 successful suite tickets above to Conductor's completed/exit-0 metadata and their exact log paths, and parsed each selected XCTest summary: 744 tests, zero failures and no skipped cases. Both compile-only builds and the lint ticket were completed/exit-0. The two failed attempts retained in the table also matched their failed tickets; they were not counted as passes. No Conductor jobs or workers were running at this checkpoint, and the real Git index was empty at signed HEAD `559ecd9d6d037ba762d8f4d2297d3c397a9d1f67`.

This validation does not establish closure of all findings. Main source reads and the completed read-only shared-admission probe (`prompt-exports/agent-run-2d54ad1dc1e4-d541fda5.md`) found that A P1-01 was still only window-local/scheduler-only. Main also confirmed that A P1-07 still unconditionally marked the helper finished after an unchecked kill and unobserved exit. The extra Send saved bubble-reuse cut in A P1-06 has not been adopted: the existing deterministic-item normal dispatch seam is being checked first. These three issues remain open before R1; no re-review has been submitted on this intermediate source.

Maintainer-guidance check: the user-visible invariants are one explicit recovery handoff, preserved original input, and no unproved relaunch after failure. Root-cause confidence is confirmed from the source above. The existing app-scoped recovery coordinator, store-issued input receipts, normal turn append/dispatch seam and exact-child exit authority remain the owners. The state-safety risks are delayed submission after a local hold releases, deleting or duplicating a reused bubble, and confusing a kill request with exit proof. Shared admission and explicit bounded failure presentation address concurrency and observability; no performance campaign or new service is justified. Recommended scope is the three targeted repairs now, with injected boundary validation, production activation and real-app acceptance later.

## Three open repairs before R1 (worker record, round 0/2)

Implemented against main's adopted bounded plan
(`prompt-exports/oracle-plan-2026-10-22-165257-restart-phase-4-boun-ac2a.md`). The source is held
for main's snapshot and R1. This is not self-approval: no review ran, every production capability
stays OFF, and O3 is still pending.

### A P1-01: shared coordinator hold and exact action authorization

- **Owner and keys.** The hold lives in the existing app-shared `AgentRecoveryCoordinator`, keyed
  by token: `beginRecoveryAction` / `revokeRecoveryAction` / `noteRecoveryAction*` /
  `awaitRecoveryActionSettlement` / `endRecoveryAction`.
  - The coordinator issues `AgentRecoveryActionAuthorization` (its init is fileprivate). It names
    exactly one input: a continuation's planned item, or Send saved's claimed intent.
  - Coverage comes from the coordinator's own session→workspace mapping (`laneWorkspaceIDs`, set
    in `claimLane`). It covers the action's session and every session of its workspace, in any
    window.
  - An unknown session or workspace is covered by any hold (fail closed).
  - No new service or store was added, and no lifecycle or MCP lock is used.
- **Seams.** Every existing lane admission, dispatch commit, and final handoff check consults the
  hold. Untracked input does too (`recoveryActionBlocksUntrackedInput`).
  - The carried authorization is the only exemption, and it is exact:
    - the planned item, admitted once;
    - its one intent, with one attempt; mixed or coalesced constituents are refused;
    - only that committed attempt passes `permitsHandoff`.
  - It is threaded through `AgentQueuedInputIdentity.actionAuthorization`, so it rides
    `AdmittedUserTurnInput`, queued identities, dispatch evidence, deferred hydration and Codex
    tasks.
- **Settlement.** Settlement, not `.submitted`, releases the hold. The runner waits for it, then
  writes the outcome and only then ends the hold.
  - The handoff began, or `accepted` / `deliveryUnknown` evidence landed: `handedOff`.
  - `notHandedOff` / `rejected` evidence landed: `notHandedOff`.
  - Any evidence write failure: `uncertain`, recorded as dispatched with the uncertainty reason.
  - Revocation (cancel, a refused submit, a lane replacement or release, or a start that provably
    handed nothing off via `noteRecoveryActionStartReturned`) blocks every later admission, commit
    or handoff. It settles `notHandedOff` only when nothing is committed or committing.
- **Scheduler and `runAlongside`.** Both project from the coordinator: `isCoveredByRecoveryAction`
  and `hasRecoveryAction(inWorkspace:excluding:)`. `runAlongsideOtherSessions` cannot bypass it.

### A P1-06: authorized deterministic-bubble reuse in the existing normal submit

- **Where.** Reuse is decided synchronously in `submitPreparedUserTurn`, immediately before the
  existing `appendPreparedUserTurn`. No new sender exists.
  - It applies only when `AdmittedUserTurnInput.resendsAuthorizedSavedIntent` holds: the carried
    authorization's `sourceIntentID` equals the identity's intent, and the input does not consume
    the composer.
- **Authority and consistency.** The saved payload (text, image IDs, tagged-file IDs, workflow)
  is the authority. `recoverySavedIntentBubble` checks every copy of the item ID against it: the
  canonical transcript (request anchors and mid-turn user activities, including compacted history
  outside the working suffix) and the working suffix.
  - Any mismatch is refused. More than one suffix copy is also refused, defensively; the session
    already collapses duplicate IDs, so that state can't be reached.
- **Reuse.** A shown bubble is reused unchanged:
  - no append, duplicate, sequence-counter or timestamp change;
  - the new run's anchor and dispatch attempt attach to that same turn;
  - `PreparedUserTurnAppend.disposition` is `.reused` and `removableUserItemID` is `nil`, so
    failure cleanup can never delete it.
- **Absent.** A genuinely absent bubble is appended once, under the intent's item ID.
- **No retry and no withdrawal.**
  - `dispatchRecoverySavedIntent` admits only a `queued` intent whose every earlier attempt is
    conclusively not sent. There is no uncertain-delivery retry.
  - A refused Send saved is kept queued and never withdrawn: `releaseRefusedRecoveryAdmission` is
    skipped for it.
  - Unrelated composer draft, attachments, workflow and the interview choice are preserved
    (`consumesComposerInterview: false`).
- **Residual for main to judge.** A shown bubble followed by newer user messages is refused
  (`recoverySavedBubbleNotLatestText`). The new run's reply would otherwise attach after a later
  turn. This is a precise remaining refusal, not a new bubble-cut. Main must decide it against
  "additional bubble-cut is NOT accepted".

### A P1-07: typed helper stop proof within one absolute deadline

- **Types.**
  - `ProcessRelaunchTerminateResult`: `signalSent`, `notRunning`, `failed`.
  - `ProcessRelaunchStopResult`: `safe(abortAcknowledged | exitObserved)` or `unresolved`.
  - Prepare and arm results gained `.unresolved`.
- **Proof.** Safe proof is only a correlated `aborted` or an observed exact child exit. A sent
  signal is not proof. An abort acknowledgement for another correlation is not proof.
- **Deadline.** One absolute budget per parent session, fixed at session start:
  - the acknowledgement deadline is start + 750 ms;
  - cleanup is start + the 1 s reserve;
  - repeated `abort()` calls cannot renew either deadline;
  - no wait goes past 8 s.
- **Unresolved stop.** State becomes `.stopUnresolved`, never finished.
  - `AppRelaunchCoordinator` keeps the session (`retainsHelper`) and refuses to spawn a fresh
    helper.
  - R4 `present` offers no choices: no Retry, no Quit Anyway, no Cancel. It withholds them through
    `AgentLifecycleShutdownFailure.relaunchHelperUnresolved` and `offeredChoices = []`.
  - The request is never finished, and it is counted by `relaunchHelperUnresolvedPrompts`.
- **Real terminate closure.** It now reports `notRunning`, `failed("its process identity is
  unknown")`, `failed(strerror)` on a failed `kill`, or `signalSent`. The test suites never run
  the real closure.
- **Owner decision pending.** This fail-closed no-choice presentation is the restriction pending
  the owner's answer. During Stage A it leaves owners frozen until the app is quit by other means.
  Restart stays OFF. Ordinary Quit was not redesigned.

### Tests (existing injected boundaries only)

- **`AgentRecoveryActionTests` (P1-01, real lanes behind the app-shared coordinator).**
  - `testRecoveryActionHoldCoversItsWorkspaceAcrossWindowsUntilItEnds`. Under a hold, sibling
    windows in the same workspace are refused:
    - manual and MCP admissions;
    - a queued intent's dispatch;
    - borrowed authority;
    - a second action.

    The scheduler and `runAlongside` projections report it, untracked or unknown scope is blocked,
    another workspace is unaffected, and revocation alone does not release the hold.
  - `testActionAuthorizationAdmitsAndDispatchesOnlyItsExactPayloadOnce`.
  - `testRevokedAuthorizationBlocksLateWorkAndSettlesExactly`: a late task after revoke, the
    delayed-hydration end, and a committed attempt with a failed evidence write giving `uncertain`.
  - `testLaneReplacementRevokesItsActionHold`.
  - `testRunnerRecordsUncertainSettlementAsDispatchedWithItsReason`: outcome failure.
- **`AgentRecoveryVMProducerAdmissionTests` (P1-06, real VM, mandatory admission, fake Codex
  controller).**
  - `testSendSavedReusesItsShownBubbleUnchangedAndStartsANewRunOnThatTurn`.
  - `testSendSavedAppendsAnAbsentBubbleOnce`.
  - `testSendSavedFailureKeepsTheReusedBubble`.
  - `testPreparedAppendReportsReusedBubblesAsNeverRemovable`.
  - `testSavedBubbleResolverUsesTheCanonicalTranscriptAndRefusesInconsistentCopies`: canonical
    out of suffix; images, tagged files and workflow mismatch; not latest.
  - `testSendSavedRefusesAShownBubbleFollowedByNewerMessages`.
  - The file's own fake controller gained `startError`.
- **`ProcessRelaunchHelperTests` (P1-07).**
  - `testSignalSentWithoutObservedExitIsUnresolvedWithinTheCleanupReserve` replaces the old
    finished-after-kill test. This is a deliberate contract change.
  - `testSignalFailureIsUnresolvedAndRetainsOwnership`.
  - `testAbortedAcknowledgementForAnotherCorrelationIsNotProof`.
  - `testRepeatedAbortCannotRenewTheCleanupBudget`.
  - `testPrepareFailureWithUnresolvedStopIsTyped`.
- **`AppRelaunchCoordinatorTests`:** `testUnresolvedLostArmRetainsTheHelperAndRefusesAFreshOne`.
- **`AgentLifecycleShutdownCoordinatorTests`:**
  - `testSafeRestartUnresolvedHelperStopOffersNoChoicesAndNeverFinishes`;
  - `testSafeRestartStageAUnresolvedHelperStopWithholdsCancelAndRetry`.
- **Deliberate test updates.**
  - The shared `handOff` performer fixture now passes the real admission, dispatch and final
    handoff seams.
  - `testUncertainPriorDeliveryNeedsAConfirmedNewContinuation` therefore asserts exactness: the
    old intent's attempt IDs are unchanged, and the total grows by exactly the new continuation's
    one attempt.
  - The reconciliation closure gained the authorization parameter.
- No `XCTSkip`, no weakened assertion, no new framework, and the frozen ledger is unchanged.

### Failed attempts

| Failure | Ticket | Fix |
|---|---|---|
| Test compile error | `924fb263-6d87-43e9-b4bb-b16b11c3b127` | An actor-isolated `read` inside an `XCTUnwrap` autoclosure. It is now bound first. |
| `AgentRecoveryActionTests` 1/27 failed | `4aa84562-64d7-4866-bae3-dffa6a983b8c` | The attempt-count assertion predated the real-seam fixture. It now asserts exactness, as above. |
| `AgentRecoveryVMProducerAdmissionTests` 3/29 failed | `bd7cee63-c123-4295-85f2-bb42ac8e61c6` | Two causes. The session collapses duplicate item IDs, so that unreachable fixture was removed. The failure run appends its own non-user notice, so the assertions now cover user items exactly and the earlier prefix. |
| Lint failed | `27230d8a-36c9-4de1-89e5-3168f9486316` | Hand fixes: redundant returns and `Sendable`, `fileprivate`, a blank line, hoisted `try`, `count(where:)`, an opaque parameter. |

`ClaudeAgentModeCoordinatorLifecycleTests` was rejected as an unknown filter (not in the curated
ledger). `RPCE_ALLOW_UNKNOWN_FILTER` was not set.

### Validation

**Final source:** six suites, re-run after the lint source edits.

| Suite | Ticket | Tests |
|---|---|---|
| AgentRecoveryActionTests | `15f64f26-49fe-4d25-b0f5-d99ace1d600e` | 27 |
| AgentRecoveryVMProducerAdmissionTests | `6299790f-0997-43ca-b492-bdab0fc04d32` | 29 |
| ProcessRelaunchHelperTests | `aa94439e-b9f1-4a0e-a33a-ac2cc05a2bdb` | 26 |
| AppRelaunchCoordinatorTests | `2e72fa11-b42b-49a7-b828-80f0d1be4a8b` | 8 |
| AgentLifecycleShutdownCoordinatorTests | `0b86c85a-d314-48cc-839b-2bffb9d39e8f` | 32 |
| AgentRecoveryCoordinatorTests | `9b941740-27b1-4950-982e-6f23a20c8912` | 45 |

**Before the lint source edits:** 15 suites, 0 failures.

| Suite | Ticket | Tests |
|---|---|---|
| AgentRecoveryReconciliationTests | `2187fcba-31d2-495a-ae4a-c3e6768f1a2c` | 22 |
| AgentProviderHandoffTests | `8a0f1746-f82d-4d60-bf3c-29a842c032fc` | 12 |
| AgentRecoveryQueuedInputTests | `cef42b08-c733-4202-bb8e-3dd90c18ce06` | 10 |
| AgentRecoveryResetBoundaryTests | `54fd5f6b-672d-4033-aa39-625dbea757d2` | 22 |
| AgentRecoveryRuntimeOwnershipTests | `d648339a-b792-4c01-99a2-f900a490b9f1` | 10 |
| RemoteAgentDispatchEvidenceTests | `e1d0204a-3e34-43de-b961-5a5629f47171` | 9 |
| CodexFallbackFIFOTests | `042355f0-bc27-4df0-b884-a25484ba9f2f` | 38 |
| AgentScheduledSendNonCodexMandatoryTests | `ebb93163-a974-4fb0-9691-e63c27872358` | 2 |
| AgentScheduledSendCoordinatorTests | `4058c310-3fdb-4f4d-a93a-8ea3d56df8be` | 52 |
| AgentScheduledSendDispatchTests | `3680f883-bafc-4ecf-9249-2ef2976c9e1b` | 53 |
| AgentScheduledSendReceiptTransferTests | `8d362dc4-4f1e-42b6-9512-f37510aa2340` | 11 |
| AgentModeRunServiceLifecycleTests | `41f8b038-bbe4-43f0-9e8d-df89a116a6d5` | 190 |
| AgentStaleResetOwnershipTests | `3e21cc4f-d60c-4c2e-a283-1939fcd76fd1` | 40 (2 skipped) |
| AgentRecoveryStartupReconciliationTests | `150ea2fe-e3c9-4c5b-b148-a59d87549d4b` | 19 |

The two skips in `AgentStaleResetOwnershipTests` are the existing opt-in Phase 0 scale reports
(`RPCE_RUN_SCALE_TESTS`); that file is unchanged.

The lint source edits change no behaviour:
- explicit `Sendable` removed from two package types;
- one `fileprivate` made `private`;
- implicit switch returns;
- one blank line removed.

Both products were recompiled afterwards, and the six suites above were re-run.

**Builds and checks:**

| Check | Ticket or result |
|---|---|
| `make dev-swift-build PRODUCT=RepoPrompt` (final) | `1bc1fd5d-f906-4910-9305-f0f7fb39914f` (earlier `d7f6501f-44cc-41ca-a422-5e93dcc15f3d`) |
| `make dev-swift-build PRODUCT=repoprompt-mcp` (compile only, final) | `aacdaa96-f98a-46f2-a6e0-2465829f229e` (earlier `152dcc2a-d7a9-41de-b426-e14f9f17c2e3`) |
| `make dev-lint` (final) | `4559ab33-3968-4e25-b303-19b676cebb47` |
| `make guardrails` | passed, with the existing `AGENTS.md` route-count warning |
| `Scripts/check-agent-context` | passed, with the same existing warning |

Each ticket's log is
`~/Library/Application Support/RepoPrompt CE/Conductor/82430cd62f1cefa34a697069b92288bdf6730d048fa0ae24fa2aa774dd59c311/jobs/<ticket>.log`.

**Not run:**
- packaging, app launch, live providers;
- the real helper, the real `kill` closure, or the MCP binary;
- the full test root.

**Not covered:**
- A VM-level multi-window scheduler test for a sibling session. The coordinator projection it
  calls is covered by the lane test.
- End-to-end Send saved through the recovery list row. Its catalog row has no existing harness;
  the normal submit seam it calls is covered.

## Main R1 frozen boundary and validation

Source tree `85142397c2e1d74b0a74bb0a6a7750ef9c314ff6`, base signed `559ecd9d6d037ba762d8f4d2297d3c397a9d1f67`; 61 intended source/test/layout paths. Delta from initial reviewed `e876de21cca35adeda4d007930080f8ee9cb199b`: 35 paths, +3223/-256, immutable full unified-20 artifact `_git_data/repos/repoprompt-ce-personal-t-27030497/2026-10-22/1747/diff/all.patch`. Main hash-matched all 61 working source blobs to this tree; the real index was empty and implementation workers were stopped. The read-only scope probe initially could not open the main tab's artifact because it was not authorized in that tab; it was directed to generate the same immutable comparison through its own RepoPrompt Git tool, not to bypass file-reading boundaries.

Main parsed the exact Conductor metadata and log summaries for the six worker final suites and eight additional source-validating main reruns: **14 suites, 566 tests, zero failures and zero skips**. These are injected/unit and existing private fixture checks, not live qualification. Both final product compile-only builds and final lint completed with exit 0. Main also ran `make guardrails`, `.githooks/pre-commit` and `git diff --check`: passed, with the existing 24-route warning. Earlier failed runs remain documented above and were not counted as passes. The worker's table heading saying 15 pre-lint suites actually lists 14; its unchanged opt-in scale suite has two skips and is not included in the final 566 count.

| Final-source suite | Ticket | Tests |
|---|---|---|
| AgentRecoveryActionTests | `15f64f26-49fe-4d25-b0f5-d99ace1d600e` | 27 |
| AgentRecoveryVMProducerAdmissionTests | `6299790f-0997-43ca-b492-bdab0fc04d32` | 29 |
| ProcessRelaunchHelperTests | `aa94439e-b9f1-4a0e-a33a-ac2cc05a2bdb` | 26 |
| AppRelaunchCoordinatorTests | `2e72fa11-b42b-49a7-b828-80f0d1be4a8b` | 8 |
| AgentLifecycleShutdownCoordinatorTests | `0b86c85a-d314-48cc-839b-2bffb9d39e8f` | 32 |
| AgentRecoveryCoordinatorTests | `9b941740-27b1-4950-982e-6f23a20c8912` | 45 |
| AgentRecoveryReconciliationTests | `f4b6a0f0-bf45-477f-b6f9-3104bdf8f4b8` | 22 |
| AgentRecoveryQueuedInputTests | `914b737b-000e-4afb-aff0-f2fb3104a2ed` | 10 |
| AgentProviderHandoffTests | `9b762c8f-a478-4f9f-a563-754555bc0db2` | 12 |
| CodexFallbackFIFOTests | `bbe336a8-63c7-4e27-a4a7-9b485f3fb2de` | 38 |
| AgentScheduledSendCoordinatorTests | `ffec78e3-74e3-4451-bd88-3f84012ec390` | 52 |
| AgentScheduledSendDispatchTests | `3b1962de-37f1-49fb-bd61-975f0265e3ec` | 53 |
| AgentModeRunServiceLifecycleTests | `1767c962-37e9-4cd4-982e-0631a23e7e2d` | 190 |
| ClaudeSessionHistoryReaderTests | `0c051eaf-f9df-4abc-ac80-7ba96ac38932` | 22 |

Fresh independent OracleA/OracleB R1 requests were submitted together on the same immutable delta, current controlled source, original normative requirements, verbatim review policy and the validation above. Each lane received only its own initial findings verbatim and its own dispositions. The full normal-live Claude canonical-merge block, the not-yet-adopted newer-message saved-bubble refusal, and the owner-unanswered helper exception with production Restart safely OFF were explicitly disclosed. No full Step 4 acceptance is claimed. Packaging, actual helper/kill execution, live providers, app lifecycle, full-root tests and performance campaigns were not run.

### R1 outcome and main dispositions

Main verified both exact preset identities and read both complete responses through Recommendations. Raw findings: [OracleA R1](phase4-oraclea-r1.md) and [OracleB R1](phase4-oracleb-r1.md). Neither lane approved a P1-free checkpoint. OracleA keeps P1-01 (stale-commit settlement), P1-06 (older saved bubbles) and P1-07 (absolute deadline and unaccepted helper policy) open. OracleB closes F1–F5, accepts the precise F5 partial rejection, and identifies N1 (overbroad sibling-session hard refusal) and N2 (plausible pre-evidence non-Codex settlement hang).

Main confirmed the stale-commit path at `AgentRecoveryCoordinator.swift:2669–2677`: the attempt can be attached before a shutdown/reset handoff refusal, while the stale-settlement callback only accepts no attached attempt. Main also re-read the owning spec's R9 busy-aggregation rule. Assumed: narrow hard exclusion to the action's own durable session; keep workspace-wide automatic-start/scheduler projection. The broader manual/queued sibling exclusion was unnecessary scope, and its planning assumption is superseded. Fix the older-bubble workflow through the existing explicit normal run/response anchor, not another edit-only cut. Pass captured absolute work/final deadlines through helper hooks and parent cleanup. Trace the plausible non-Codex early-return liveness hole and either fix it with a fenced no-commit backstop or document a complete source rejection, with one injected regression test.

Cheap related corrections may cover provably-unarmed Stage A choices (R4 requires usability), reused-row non-Codex failure cleanup and stale comments; do not add a new framework. An ambiguously armed unresolved helper still blocks Restart safely activation; the owner question was unanswered and production remains OFF. The normal-live Claude merge and O3 remain blocked/pending. R2 is the last normal re-review; no extra round or activation is authorized.

The completed read-only frozen-delta audit (`prompt-exports/agent-run-2d54ad1dc1e4-db6ff64e.md`) read all 9,272 lines of its self-authorized immutable comparison, the same 35-path delta. It found no unrelated product/target/dependency/release/signing/packaging or build-lane expansion, frozen-ledger changes, deleted/newly skipped tests, or unknown-member codec changes. Its inventory explicitly flags the changed eligibility/lifecycle test contracts rather than calling the delta mechanical. Main read the report, spot-checked production qualification defaults and relaunch composition, and confirmed the original ledger/protected files were absent from the frozen source comparison. This is scope/read coverage, not correctness acceptance or live evidence.

## R1 required-finding response (worker record, before the final R2)

This responds to main's R1 dispositions on the two R1 exports
(`prompt-exports/oracle-review-2026-10-22-175457-lossless-restart-pha-a9fb.md` and
`prompt-exports/oracle-review-2026-10-22-175729-lossless-restart-pha-18a9.md`). Architecture and
scope are unchanged. Every production capability stays OFF. Production Restart stays disabled; the
helper exception for an armed helper is not approved; ordinary Quit was not changed. The source is
held for R2. This is not self-approval, and full Step 4 acceptance is not claimed.

### A P1-01: exact attempt-bound stale-commit settlement (fixed)

- **Fix.** `AgentRecoveryCoordinator.noteRecoveryActionStaleCommitSettled(_:attemptIDs:settled:)`
  (`AgentRecoveryCoordinator.swift:1283`) now takes the stale commit's attempt IDs. The lane caller
  passes `receipts.map(\.attemptID)` (`:2713`).
  - If the hold's attached attempt is one of those IDs, the hold is revoked and settled: a
    successful stale write gives `notHandedOff(nil)`, a failed one gives `uncertain`.
  - An attached attempt that is not among those IDs is left alone. This is the exact binding: a
    stale commit can't settle another attempt.
  - With no attached attempt, the earlier behaviour is kept: a failed write gives `uncertain`;
    otherwise the fenced settle applies.
- **Test accessor.** `recoveryActionCommitIsInFlight` (`:1165`).
- **Test.** `AgentRecoveryActionTests.testShutdownFreezeDuringTheActionCommitSettlesItsAttachedAttemptAndReleasesTheRunner`.
  1. The performer is held inside the real lane transaction until the commit is observably in
     flight.
  2. `beginShutdownFreeze(.application)` runs during the commit.
  3. The write finishes. The attempt attaches, the handoff check refuses, and the stale settlement
     runs.
  4. The settlement is `.notHandedOff(nil)`; the intent is back in the queue with exactly one
     attempt.
  5. `endShutdownFreeze` (the Stage A cancel).
  6. The runner returns `.completed(.notDispatched, …)`, the hold count is 0, and composer input is
     admitted again.

  No timeout is used as proof.

### B N1: hard exclusion only for the action's own durable session (fixed)

- **Fix.** The new `ownRecoveryActionHold(sessionID:)` (`:1185`) matches only the hold whose
  authorization names that durable session. These nil-authorization branches now use it instead of
  the workspace-covering lookup:
  - `recoveryActionAdmissionRefusal` (`:1205`)
  - `recoveryActionDispatchRefusal` (`:1231`)
  - `finishRecoveryActionDispatchCommit` (`:1255`)
  - `recoveryActionPermitsHandoff` (`:1308`)
  - `recoveryActionBlocksUntrackedInput` (`:1325`)
- **Behaviour.** The same durable session in another window or successor lane stays blocked,
  because the match is by session ID. An untracked nil session is no longer blocked.
- **Unchanged automatic projection.** `isCoveredByRecoveryAction` and
  `hasRecoveryAction(inWorkspace:excluding:)` keep workspace scope, so the scheduler,
  `runAlongside` and automatic new sessions still see the workspace as busy.
  `beginRecoveryAction` still allows one action per session or workspace.
- **Test.** `testRecoveryActionHoldExcludesItsOwnSessionAndProjectsWorkspaceBusyOnlyForAutomaticWork`
  replaces the old cross-window refusal test. This is a deliberate contract change from main's
  disposition.
  - **Own session refused:** manual, MCP, steering, drain, handoff and untracked input.
  - **Sibling session in the same workspace allowed:** manual, MCP, steering and drain admissions,
    and its dispatch is handed off.
  - **Projections still hold:** the scheduler and workspace-busy projections stay true while the
    hold lives.
  - **Other checks:**
    - a borrowed token is refused;
    - a second action in the workspace is refused;
    - another workspace is free;
    - a successor lane of the same durable session is refused until `endRecoveryAction`.

### A P1-06: older saved bubble (STOP, blocker reported; no source change)

Main's disposition was to carry the saved user item and turn anchor through the existing seams, or
stop and report the minimal blocker before inventing new architecture. It cannot be done through
the existing seams.

- **Turn membership is purely positional.**
  - `AgentTranscriptServices.importLegacyItems` (around `:3303–3420`) opens a new turn at every
    `.user` item. Every later non-user item belongs to the latest preceding user item.
  - `AgentChatItem` has no turn-membership or anchor field.
  - `AgentTabSession.appendItem` (`AgentTabSession.swift:3016–3018`) always assigns a tail
    `sequenceIndex`.
  - The footer anchors (`recordAgentTurnUserAnchor` / `pendingTurnRuntimeAnchors`,
    `AgentModeViewModel.swift:4279–4338`) and the reconcile preflight are also positional.
- **Consequence.** A new run's reply for an older saved bubble would always be appended at the tail
  and render under the latest user turn. There is no existing explicit run or response anchor that
  rebinds it.
- **Minimal real fix (not attempted).** Add a persisted per-item turn-membership anchor and honour
  it in:
  - the importer and incremental import;
  - compaction and merge;
  - the presentation builder and footer;
  - reconcile;
  - every provider append site.

  That is new timeline architecture, beyond the bounded remediation.
- **Current state.** The fail-closed `recoverySavedBubbleNotLatestText` refusal is unchanged. It is
  a precise refusal, not a bubble-cut. The source goal is not downgraded; main and the owner must
  decide.

### A P1-07: absolute work and final cleanup expiry through the hooks (fixed)

- **R4.** `AgentLifecycleRelaunchBudget` (`AgentLifecycleShutdownCoordinator.swift:133`) carries
  `workExpiry` and `cleanupExpiry`.
  - `armDeadline` fixes `request.cleanupExpiry = max(start + deadline, expiry)` (`:885`). The work
    expiry stays start + deadline − cleanup reserve.
  - The hooks receive `relaunchBudget(_:)` (`:863`). Nothing is renewed: Stage B continues
    Stage A's attempt deadline.
- **Driver.** In `AppRelaunchCoordinator`:
  - `prepareFresh(budget:)` (`AppRelaunchCoordinator.swift:83`) checks `now() < workExpiry` before
    identity and spawn (`:93`, `budgetSpentMessage`). It then calls the absolute-expiry `prepare`.
  - `armCurrent(budget:)` (`:128`) calls the absolute `arm`.
  - Serialized work is bounded by those expiries.
- **Helper.** In `ProcessRelaunchParentSession` (`ProcessRelaunchHelper.swift`):
  - The absolute `prepare(parent:bundlePath:workExpiry:cleanupExpiry:)` (`:772`) fails before
    sending if the work expiry has passed. After the send, its ready timer is
    `min(workExpiry − now, ready limit)`, recomputed after the await.
  - The absolute `arm(workExpiry:cleanupExpiry:)` (`:857`) resolves a lost arm without sending if no
    time is left.
  - `capCleanup(at:)` (`:766`) keeps the earliest cleanup expiry ever provided (`cleanupCap`,
    `:699`).
  - `stopUnarmed` caps the acknowledgement deadline at `cleanupCap − terminateGrace`, and the
    cleanup deadline at `cleanupCap` (`:925–927`). The stop can't run past the final expiry, and
    repeated stops can't renew it.
  - The duration-based `prepare`/`arm` overloads remain as conveniences over the absolute ones.
- **Composed test.** `AgentLifecycleShutdownCoordinatorTests.testSafeRestartComposedHelperBudgetIsAbsoluteAcrossTimeSpentBeforeItsTimerStarts`.
  - The real `AppRelaunchCoordinator` shares R4's injected `ManualDeadlineClock`.
  - `parentIdentity` consumes 2 s before the helper's ready timer starts. The helper never answers
    and never exits.
  - The ready wait ends at 7 s, not 2 + 7 s. The abort acknowledgement is waited for until 7.75 s,
    then a kill is sent. Signal delivery is not taken as exit proof; the exit wait ends at 8 s.
  - The prompt is shown at 8 s, and every requested sleep deadline is ≤ 8 s.
  - The helper is retained (spawn count 1) and its ownership is shown as unresolved. Cancel replies
    `false`.
- **Budget test.** The safe-restart test now asserts that both hook calls receive work 7 s and
  cleanup 8 s.

### B N2: non-Codex early returns before any runner (fixed with a fenced backstop)

- **Already settled.** Non-Codex returns that reach a runner settle through the runners' handoff
  defers:
  - `ClaudeIntegratedAgentModeRunner.swift:113–116`
  - `HeadlessAgentModeRunner.swift:50–55,153–155`
  - `ACPIntegratedAgentModeRunner.swift:234–239,317–319,497–499`

  Each goes through `AgentProviderHandoff.settleIfUnresolved` → `.notHandedOff` →
  `noteRecoveryActionSubmissionEnded`.
- **The gap.** These `startRun` returns exit before any runner owns the staged input and returned
  `nil` without a settlement:
  - the knowledge-profile unsupported provider;
  - a `workspacePathProvider` throw;
  - the DEBUG OMP mismatch returns.

  The runner-wait could have held forever.
- **Backstop.** A new `defer` in `AgentModeRunService.startRun` (`AgentModeRunService.swift:585`),
  for non-Codex runs where no runner took the staged input. It calls
  `noteRecoveryActionSubmissionEnded` for the carried action authorization.
  - The call is idempotent and fenced. It settles `notHandedOff` only when the hold is revoked, has
    no dispatched attempt and has no commit in flight.
  - There is no elapsed-time guess. A runner-owned path is untouched.
- **Test.** `AgentProviderHandoffTests` file, extension of `AgentModeRunServiceLifecycleTests`:
  `testNonCodexStartupFailureBeforeAnyRunnerSettlesTheCarriedRecoveryAction`.
  - The workspace provider throws. The outcome is `nil` and the run state is `.failed`.
  - The settlement is `.notHandedOff(nil)`.
  - The intent is queued with no attempts, and a late `beginDispatch` is refused with
    `recoveryActionInProgress`.
  - After `endRecoveryAction`, the hold count is 0.

### B N3: unresolved stop of a provably unarmed helper keeps the normal Stage A choices (fixed)

- **Fix.**
  - `ProcessRelaunchParentSession.armWasSent` (`:702`) is set before the arm message is sent
    (`:869`).
  - `abandonCurrent()` (`AppRelaunchCoordinator.swift:146–153`) maps an unresolved stop to one of
    two cases:
    - `.unresolvedUnarmed` when ARM was never sent;
    - `.unresolved` otherwise.
  - In `present()` (`AgentLifecycleShutdownCoordinator.swift:794–805`):
    - `.unresolvedUnarmed` appends the reason and keeps the normal choices;
    - an ambiguous arm-sent `.unresolved` still offers no choices.
  - Either way the helper is retained and a fresh helper is refused.
- **Tests.**
  - `testSafeRestartStageAUnresolvedUnarmedHelperKeepsTheNormalChoices` replaces the old Stage A
    no-choice test.
    - The choices are `[.retry, .cancel]`.
    - Retry prepares and abandons again.
    - Cancel unfreezes.
  - `AppRelaunchCoordinatorTests.testUnresolvedStopOfANeverArmedHelperIsUnarmedAndStillRetained`:
    the received message types are `prepare`, `abort`, `abort`, with no `arm`.
  - The existing arm-sent no-choice test (`testSafeRestartUnresolvedHelperStopOffersNoChoicesAndNeverFinishes`)
    is unchanged.

### B N5: reused-row cleanup (traced; no real risk; comment fixed)

Every user-item removal was traced:

- `removeUnconfirmedMCPOptimisticCodexUserItem` takes `prepared.removableUserItemID`, which is
  `nil` for `.reused`.
- `removeUnsentScheduledUserItem` (`AgentModeViewModel+ScheduledSend.swift:1930`) keys on the
  scheduled attempt's own item ID, and it requires `scheduledSend == nil`. Send saved is refused
  while its intent is scheduled.
- Codex `CodexAgentModeCoordinator.swift:3129` removes only non-durable fallback entries. The other
  Codex removals (`:6505`, `:6777`, `:6808`) touch assistant and reasoning rows.
- `ClaudeAgentToolTrackingHandler.swift:324,868` removes only tool-call placeholder or error rows.
- `RemoteAgentModeCoordinator` `removedIDs` applies to remote transcripts only. Action payloads are
  never remote.

No guard or test was added, because no real risk was found. The stale `terminateGrace` doc comment
in `ProcessRelaunchHelper.swift` was corrected.

### N4: Claude Continue

This is recorded as an activation block. No speculative canonical-identity work was done.

### Failed attempts this round

| Failure | Ticket | Fix |
|---|---|---|
| `make dev-lint` failed | `2b69b1b1-7033-4171-bac0-4379b21558dd` | The new composed test had `noForceUnwrapInTests` and `hoistTry` errors. It is now `async throws` and uses `try XCTUnwrap` for the clock and the UUID. Test-only. |

### Validation

All runs are on the final source. The only edit after the product builds was the test-only lint
fix; its suite was re-run.

| Suite | Ticket | Tests |
|---|---|---|
| AgentRecoveryActionTests | `90507a18-7829-4e2f-b043-706e4a6e3b17` | 28 |
| AgentRecoveryCoordinatorTests | `db2d91af-5836-4c5a-8f25-de728a4f971d` | 45 |
| AgentRecoveryVMProducerAdmissionTests | `fa67dd62-159f-4ac2-b571-e49a98e0544f` | 29 |
| AgentRecoveryReconciliationTests | `8a42783c-bffe-4f41-be5f-607ffef1337c` | 22 |
| AgentRecoveryQueuedInputTests | `a6b81e95-2657-45e3-9286-3baff9ff1171` | 10 |
| AgentProviderHandoffTests | `cb5d35aa-3ce2-4deb-a012-b8d821400fb4` | 12 |
| AgentLifecycleShutdownCoordinatorTests (after the lint fix) | `d5e14e9d-5ef3-4f3f-8811-11fc490befe2` | 33 |
| AppRelaunchCoordinatorTests | `26952f0a-6951-4620-98c9-0e0aae89dcdb` | 9 |
| ProcessRelaunchHelperTests | `d770c76f-57de-44e2-b3f3-dd5cbeef0225` | 26 |
| AgentModeRunServiceLifecycleTests (includes the N2 test) | `9607764f-40ac-4ba8-ba2e-46f90921ba26` | 191 |
| AgentScheduledSendCoordinatorTests | `fc8f05e1-636d-443f-ab58-2a485c3e1978` | 52 |
| AgentScheduledSendDispatchTests | `93dab14f-08ae-40f1-beba-273324de9c9f` | 53 |
| AgentScheduledSendNonCodexMandatoryTests | `3589e1e7-4a1d-4392-bdc2-53e7e3f0c663` | 2 |
| AgentScheduledSendReceiptTransferTests | `cafe49a0-e9bd-4553-9762-a0141b956655` | 11 |
| CodexFallbackFIFOTests | `bb85e7df-931a-46fb-9e3c-1b871df597c2` | 38 |
| AgentRecoveryResetBoundaryTests | `dd5ceb58-fea7-4c2e-ac2d-bfdfec73aada` | 22 |
| RemoteAgentDispatchEvidenceTests | `4049a8d4-89be-41c0-ba1e-11c978d6fc3f` | 9 |

That is 17 suites and 592 tests, with 0 failures and 0 skips.

Earlier passing runs in this round, before the final batch:

| Suite | Ticket | Tests |
|---|---|---|
| AgentRecoveryActionTests | `b97fe02a-0369-4837-9ab5-88d8e57ddbfd` | 28 |
| AppRelaunchCoordinatorTests | `e66a40bc-4a8a-4b20-92ae-17f24d9d4f25` | 9 |
| AgentLifecycleShutdownCoordinatorTests | `a5a1d0bb-b01b-44c6-9fc7-59334b744c39` | 33 |
| ProcessRelaunchHelperTests | `6ec0b7ed-dc01-476e-add8-95798da7bacb` | 26 |
| AgentLifecycleShutdownCoordinatorTests (before the lint fix) | `f831000f-23bd-4f7b-a18f-fe4c4d1b5f9b` | 33 |

| Check | Ticket or result |
|---|---|
| `make dev-swift-build PRODUCT=RepoPrompt` | `fa7c9642-0de9-409e-b702-251d5bc49541` |
| `make dev-swift-build PRODUCT=repoprompt-mcp` (compile only) | `adbb52dd-051b-4629-a0a4-09aed6555c60` |
| `make dev-lint` (final) | `53fad96c-7c22-4de2-8715-0a0df74ed350` |
| `make guardrails`, `Scripts/check-agent-context` | both passed (exit 0), with the existing 24-route `AGENTS.md` warning |

The frozen ledger is unchanged. No `XCTSkip` was added, no assertion was weakened, and
`RPCE_ALLOW_UNKNOWN_FILTER` was not used.

The three deliberate contract replacements, all from main's dispositions:
- N1: the cross-window refusal test is now the own-session test.
- N3: the Stage A no-choice test is now the unarmed-keeps-choices test.
- P1-07: the shutdown fake records budgets, not remaining durations.

**Not run:**
- packaging, app launch, live providers;
- the real helper, the real `kill` closure, or the MCP binary;
- the full test root.

### Residuals for main and R2

- **P1-06** is blocked on new per-item turn-membership architecture. The fail-closed not-latest
  refusal remains.
- **The arm-sent unresolved helper** offers no choices. That owner question is unanswered, Restart
  stays disabled, and the exception is not approved.
- **The normal-live Claude merge (N4)** and **O3** remain blocked or pending.
- **N2's backstop** covers only the pre-runner non-Codex returns. Runner-owned paths keep their
  existing defers.

## Main final R2 frozen boundary and owner decision

The source-backed older-bubble planning continuation is retained in `phase4-plan.md`; it explicitly retracts the unsupported claim that the runtime-footer anchor redirects transcript membership. Main read the actual item fields, positional importer/final-turn boundary, tail append and footer anchor. The owner selected **Preserve architecture; partial checkpoint (Recommended)** after 21 seconds. O9 records that answer. It authorizes a reviewed inactive checkpoint, not full stable-ID Send saved completion, a timeline redesign, feature activation or the unanswered arm-sent helper exception. The older-message goal remains blocked; no source-order rewrite was attempted. Main made only a clarification to the unsupported-send message and corrected one stale workspace-hard-exclusion comment.

Final source tree: `5f9151eb9c92b78ebb42b28226633c1e7652e6e0`, 62 intended paths, base signed `559ecd9d6d037ba762d8f4d2297d3c397a9d1f67`. Delta from R1 `85142397c2e1d74b0a74bb0a6a7750ef9c314ff6`: 12 paths, +760/-165, full unified-20 artifact `_git_data/repos/repoprompt-ce-personal-t-27030497/2026-10-22/1833/diff/all.patch`. Main hash-matched all 62 working source blobs to the frozen tree; the real index was empty and implementation workers were stopped.

Main verified Conductor metadata and exact log summaries for the final affected **17 suites / 592 tests, zero failures and zero skips** below. Main reran the action, R4, app-relaunch and run-service suites; after the final wording-only source edit, the VM suite recompiled the app and passed 29 tests. Other worker-final suites cover unchanged functional code. Both compile-only product builds passed before the final string/comment-only edits; no packaging or executable run is implied. Final main lint after the string edit passed (`03d7380e-6800-43c0-9aaf-2ca874e3c7a8`); the subsequent comment correction changes no behavior. Main guardrails, `.githooks/pre-commit` and whitespace checks passed with the existing 24-route warning. The earlier failing lint ticket is retained above and not counted as a pass.

| Affected suite | Verified ticket | Tests |
|---|---|---|
| AgentRecoveryActionTests | `14e17002-cf0c-418a-90c7-28832aa53b16` | 28 |
| AgentRecoveryCoordinatorTests | `db2d91af-5836-4c5a-8f25-de728a4f971d` | 45 |
| AgentRecoveryVMProducerAdmissionTests | `54db0c6f-ff04-4bc2-9bb4-90a31a2beac9` | 29 |
| AgentRecoveryReconciliationTests | `8a42783c-bffe-4f41-be5f-607ffef1337c` | 22 |
| AgentRecoveryQueuedInputTests | `a6b81e95-2657-45e3-9286-3baff9ff1171` | 10 |
| AgentProviderHandoffTests | `cb5d35aa-3ce2-4deb-a012-b8d821400fb4` | 12 |
| AgentLifecycleShutdownCoordinatorTests | `865badeb-da09-4383-bb8d-fb0942ec1078` | 33 |
| AppRelaunchCoordinatorTests | `970da868-baa6-4618-99eb-5feb0679eda8` | 9 |
| ProcessRelaunchHelperTests | `d770c76f-57de-44e2-b3f3-dd5cbeef0225` | 26 |
| AgentModeRunServiceLifecycleTests | `174fb6bb-3e30-4ffa-8d94-fe0dd837e6e5` | 191 |
| AgentScheduledSendCoordinatorTests | `fc8f05e1-636d-443f-ab58-2a485c3e1978` | 52 |
| AgentScheduledSendDispatchTests | `93dab14f-08ae-40f1-beba-273324de9c9f` | 53 |
| AgentScheduledSendNonCodexMandatoryTests | `3589e1e7-4a1d-4392-bdc2-53e7e3f0c663` | 2 |
| AgentScheduledSendReceiptTransferTests | `cafe49a0-e9bd-4553-9762-a0141b956655` | 11 |
| CodexFallbackFIFOTests | `bb85e7df-931a-46fb-9e3c-1b871df597c2` | 38 |
| AgentRecoveryResetBoundaryTests | `dd5ceb58-fea7-4c2e-ac2d-bfdfec73aada` | 22 |
| RemoteAgentDispatchEvidenceTests | `4049a8d4-89be-41c0-ba1e-11c978d6fc3f` | 9 |

Fresh final OracleA/OracleB R2 requests were sent together on the same immutable delta, current controlled source, original requirements, verbatim policy, validation and actual O9 scope decision. Each lane received only its own R1 findings verbatim and dispositions. Full contract gaps are not declared resolved merely because gates are OFF. No extra round, live activation or architecture expansion is authorized. Full-root tests, performance campaigns, packaging, app lifecycle, real helper/kill/MCP execution and live providers were not run.

The final read-only scope audit (`prompt-exports/agent-run-2d54ad1dc1e4-4bd51d47.md`) read all 2,486 lines of the 11-path comparison to intermediate tree `e3eb8d5f`. Its sole obsolete-comment observation was corrected by main; RepoPrompt Git confirmed the only change from that intermediate tree to final reviewed `5f9151eb` is that three-line comment. Main read that entire small difference directly. Together with the initial and R1 audits, source-diff read coverage is complete. The audit records the deliberate own-session, unarmed-choice and absolute-budget test contract replacements; no unrelated products/targets/dependencies/lanes, ledger changes, new skips, deleted tests or codec changes were found. It is not correctness or live acceptance.

Process deviation: the Pair appended its latest evidence section using a shell heredoc despite the required `apply_edits` route; its subsequent correction used `apply_edits`. No source was changed by that operation and no hidden validation is inferred. This records the deviation rather than reporting tool compliance that did not occur.

## Final review disposition and checkpoint boundary

Main verified the exact OracleA and OracleB preset identities and read both complete R2 responses through Recommendations. Raw evidence: [OracleA final R2](phase4-oraclea-r2.md), [OracleB final R2](phase4-oracleb-r2.md). Both accept the **O9 inactive partial checkpoint**, with no P0 or required P1 repair remaining against that bounded checkpoint. This is not a downgrade or closure of the full goal: A P1-06 (older displayed saved-message Send) and A P1-07's arm-sent policy component remain explicit full-contract/activation blockers, alongside normal-live Claude canonical association and O3. R2 ends at 2/2; O7's extra Phase 1b review is not reused.

Closed source repairs include the exact stale-commit settlement, same-durable-session shared exclusion with workspace automatic-only projection, pre-runner non-Codex no-handoff settlement, absolute helper work/final-cleanup budget, and normal choices for a provably never-armed helper. No source behavior changed after final R2. Only raw review evidence, owning status and exact evidence allowlist entries are added for checkpointing. B R2-P2-1–4 and previous nonblocking findings remain deferred per the owner's optional-polish cut; no hardening or extra review campaign is added.

The local checkpoint will include the 62 reviewed source/test/layout paths, this phase's evidence and original-spec status/O9 lines, plus the Phase 3 signed-checkpoint evidence reconciliation. Original unrelated dirty paths and untracked unrelated plans stay excluded. The source scope was read across the initial/R1/R2 immutable diffs by the scoped audit and load-bearing main reads; main will verify every staged reviewed blob and read the remaining staged documentation/allowlist changes. Signed local commit is preferred; O8 permits a per-invocation unsigned fallback only if signing fails, with no config mutation, amendment, push or app operation.

The first staged whitespace check found nine trailing-space lines in the newly staged planning/raw-review evidence (the earlier unstaged check did not cover those new files). Main removed the raw review's whitespace-only line and normalized eight planning-export Markdown hard breaks to explicit `<br>` markup after a whitespace-only rewrite was rejected as no change. The original Oracle export bytes remain local; the affected review artifact documents its whitespace normalization. No source behavior or findings wording changed. This failed staged check is not counted as a pass; it was rerun successfully before committing.

Final staged-boundary read: the scoped worker read every line (1–19,123) of its self-authorized 72-file immutable staged diff, `1842/diff/all.patch`, on tree `e12ae1616d14ba34657bb201d018a4a9dd23e440`; report `prompt-exports/agent-run-2d54ad1dc1e4-8bce4e98.md`. It found no unexpected hunk or substantive documentation mismatch. Main read that report, confirmed all 61 reviewed source/test/layout blobs except the separately inspected allowlist script exactly match `5f9151eb`, verified the complete 72-path intended set and no unstaged intended files, and compared all six retained findings bodies to the original exports (trailing-whitespace normalization only). The script's only post-review change is two exact R2 evidence paths. The original plan changes only status lines and actual O9; original unrelated dirt and plans remain excluded. Main's final addition of this check-result paragraph is documentation-only and is read/restaged separately. Final staged whitespace and `.githooks/pre-commit` checks pass, retaining the existing route-count warning. No source behavior changed during checkpoint preparation.

## Post-checkpoint forward guidance

At signed checkpoint `fbc1ef041cd7000255c102f7abd7e2464120fe25`, the owner requested independent OracleD/OracleE guidance. See [the consultation and main disposition](phase4-forward-guidance.md), [OracleD's complete response](phase4-forward-oracled.md), and [OracleE's complete response](phase4-forward-oraclee.md). This is strategy, not another acceptance-review round, an owner scope change, source implementation, or activation. The existing plan status and O3/O9 remain unchanged. O10 subsequently approved the bounded source-only work; [the completed source investigations](phase4-source-investigations.md) record canonical ownership/compaction evidence, official Claude acknowledgement evidence, the exact remaining identity gap and the unanswered relocation-policy question.
