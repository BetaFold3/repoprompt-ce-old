# Lossless restart — Phase 1a evidence (transcript maximum wait and buffered-text draining)

Scope: read when the task touches lossless-restart Phase 1a: the transcript save maximum wait, its mutation observation, ownership and hydration fences, failed-save retries, buffered assistant-text draining before saves and destructive cleanup, or their tests.
Authority: Reference
Last-verified: 2026-10-21

## Signed checkpoint

On 2026-10-21 the owner selected the configured 1Password signer. A normal signed commit retry succeeded as `ebd686f7d4bf198c512e61d0e665deaef0ed2c0f` (`Preserve streaming transcripts with bounded save deadlines`). Main verified the index exactly matched the previously reviewed tree `207a0bdd3eb75b5b194c86f01c8a678e6654b374`, checked the staged diff for whitespace errors, and confirmed the resulting commit contains a signature. No signing configuration was changed, no unsigned bypass used, and nothing pushed. The earlier failed attempts below are historical. Complete quit/window-close preservation remains the next package, not a completed Phase 1a guarantee.

Evidence for step 1a of [the lossless app restart spec](../../2026-10-18-lossless-app-restart-spec.md) under the transcript-only scope assumed in [the Phase 1 scope note](phase1-scope.md). This is fixture and code evidence only; no visible app launch or live acceptance was performed. Sections below retain the investigation chronology; later dispositions supersede earlier open findings. Plan status is maintained by the main agent; Decisions contain owner answers only.

## 1. What 1a does now

It implements only the transcript scheduling and drain subset. Not included:
- lifecycle flushes and window-close preservation;
- UI changes and quit or close ordering;
- durable identity.

### Maximum wait (R3)

| Contract item | Implementation |
|---|---|
| Keep the 1 s debounce | `scheduleSave` still replaces a 1 s debounce. It now sleeps through the save-timer seam until `now + 1 s`, computed when the save is scheduled (VM `:14110`). |
| 10 s maximum wait from the **first** unsaved change, monotonic | `noteTranscriptPersistenceMutation` records `ContinuousClock.now` once (`+TranscriptSaveMaxWait.swift:63`). The timer sleeps **until** `firstUnsavedAt + 10 s` (`:66`), so a timer task that starts late can't extend the deadline. Later changes and save requests never move it. |
| Mutation observation covers dirty-only edits and source edits that fire before the dirty mark | `onSourceItemsChanged` arms the deadline (VM `:4052`); it runs **before** the mutation's `isDirty = true`. A new `onPersistenceMutation` hook fires on every `isDirty = true` (`AgentTabSession.swift:1568`, installed at VM `:4057`). Arming doesn't require `isDirty`. |
| No second writer | Both timers enter the existing `saveSessionDetailed`. |
| Only a successful current receipt clears the obligation | `clearTranscriptSaveMaxWait` is called right after `session.isDirty = false` in the save's clean, current-token path (VM `:14662`). |
| Old snapshots and in-flight saves keep the deadline | A `.written(projectionClean: false)` receipt from this wakeup's own call that **provably covers** the pre-call state rebases the deadline to the pre-call instant (`staleWriteCoversCapture`, `:240`; `rebaseTranscriptSaveMaxWait`, `:261`; proof in §14). Only if that deadline already expired when the write completed (a write of 10 s or more: blocked or unhealthy storage) is the next save floored to completion + 1 s (§16). Any other stale receipt, `.resetAcknowledged`, and `.deferredBehindInFlightSave` (after `awaitInFlightSave`) are followed by an immediate save without a new 10 s window. At most 2 immediate follow-ups happen per wakeup; after that the retry spacing applies. |
| Failures: one coalesced retry at least 1 s apart, no spin | `.notWritten` keeps the dirty state and the deadline. It arms one retry at 1 s, then 2, 4, 8, 16 and 30 s (`:272`). Any durable write resets the backoff. Waiting for authority (no hydration authority, or a reserving removal) retries at the fixed 1 s floor and never escalates. |
| `flushSaveDetailed` doesn't satisfy the obligation falsely | Unchanged. Only the clean current path clears the deadline. |
| Eligibility and owner fencing | Every wakeup checks `sessions[tabID] === session`, the timer generation, and that a deadline is still set (`:103`). See §2 for the eligibility and authority rules. |

### Buffered assistant text

- The producer that arms a buffer timer records its own flush as `session.assistantDeltaDrain`:
  - the VM producer, used by Claude and ACP (VM `:18959`);
  - the Codex coordinator, which uses scope-aware normalization (`CodexAgentModeCoordinator.swift:5481`).
- `AgentTabSession.drainPendingAssistantDelta()` (`:1360`) calls that flush.
- Each flush clears the buffer, bumps the task generation and cancels the timer before applying. The text therefore lands exactly once, and a cancelled timer finds nothing to replay.
- `saveSessionDetailed` drains before it captures any revision, item snapshot or commit token (VM `:14251`). It does so after the stale-reset and completed-removal checks. The entry guard also admits a clean session that has buffered text (`:14223`).

## 2. Eligibility, authority and ownership

**Paired hydration authority.** `hasTranscriptSaveHydrationAuthority` (`+TranscriptSaveMaxWait.swift:144`) is stricter than `hasLoadedPersistedState`. It requires all of:
- `hasLoadedPersistedState`;
- no `persistedLoadTask` in flight;
- no binding transition in progress;
- a `persistedLoadDisposition` of `nil` (a fresh creator), `.applied`, `.noPayload` or `.unbound`.

`.unresolved`, `.failed` and `.suppressed` never qualify. A bound owner without authority isn't saved; the obligation waits and retries at the fixed 1 s floor. The save path's commit-token and persistence-state checks remain authoritative after every suspension.

`authoritativeHydratedBinding` was deliberately **not** used. It is set only when bindings are published for the active tab (VM `setActiveTranscriptBindingsHydrated`, `applySessionToBindings`). Background tabs with a run streaming would never qualify, and they are the main starvation case.

**Nothing left to save** clears the obligation instead of retrying. That applies when:
- persistence is suppressed;
- the tab holds a retained stale-reset view;
- the session isn't dirty and has no buffered text;
- an unbound session has no persistable conversation content. Without this rule, a dirty-only edit on an empty new tab would retry forever.

**Reserving removal parks the obligation.** While `staleResetRemovalAdmission?.blocksScheduledSaves` is true (reserved, final save completed, or committed; `:119`), the wakeup starts no save, keeps the deadline, and retries at the fixed 1 s floor. A committed removal makes the owner obsolete (the identity fence then ends it); an aborted one saves on the next retry.

**Binding replacement.** `beginPersistentBindingTransition` invalidates the timer when it **replaces an existing binding** (`AgentTabSession.swift:1685`). A genuine creator's first binding happens inside its own first save, through `ensureSessionBoundToTab`. That binding keeps the obligation; otherwise a failed first save would lose its deadline.

**Disposal.** The wakeup of an owner that is no longer `sessions[tabID]` is obsolete; the weakly captured task wakes, finds itself stale, and returns.

**Retained teardown.**
- `prepareSessionForWindowClose` (VM `:3837`) ends with `clearTranscriptSaveMaxWait` only. A pending debounce is kept as at HEAD: close itself re-dirties the session and reschedules, and that debounce writes the edit (or the teardown state) about 1 s later. After a window close begins (`hasPreparedForWindowClose`), mutation observation no longer arms a deadline. This corrects the round-0 cancellation (§16 F1).
- `prepareWorkspaceSwitchSessionDiscard` (VM `:12802`) ends with `cancelTranscriptSaveTimers`, which cancels the debounce and clears the maximum wait; the discarded owner fails the owner and context checks either way.

 In the workspace-switch path the new index owner is installed before the discard and `sessions.removeAll()` follows, with no pre-discard save, so its drain is memory-only; durability across close and switch remains 1b.

**Hydration.** It installs items silently (`setItemsSilently`) and marks the session dirty only when a migration save is needed. Hydration therefore isn't counted as an unsaved edit.

## 3. Destructive assistant-buffer cleanup inventory

The inventory comes from every write to `pendingAssistantDelta`, `assistantDeltaFlushTask` and `assistantDeltaTaskGeneration`, and every call to `clearPendingAssistantDelta`, `clearPendingAssistantDeltaState`, `cancelEphemeralRuntimeState()` and `clearCodexSessionState` in `Sources/`. VM refers to `AgentModeViewModel.swift`; `+StaleResetRecovery` to `AgentModeViewModel+StaleResetRecovery.swift`.

| Site | Path | Conversation | Action |
|---|---|---|---|
| VM `:3813` `prepareSessionForWindowClose` | window close | retained | **drain added** before `cancelEphemeralRuntimeState()` |
| VM `:12786` `prepareWorkspaceSwitchSessionDiscard` | workspace switch | retained on disk | **drain added** before `cancelEphemeralRuntimeState()` and `clearPendingAssistantDelta` |
| VM `:13560` `prepareComposeTabRemoval` (phase 1) | tab removal before teardown | retained (final save follows) | was a VM-only flush; now a **producer drain** |
| VM `:13631` `prepareComposeTabRemoval` (after the coordinator shutdowns) | tab removal before the final save | retained | **drain added** for text buffered during the shutdown awaits; the existing final save includes it |
| VM `:8305` `invalidateProviderContextForExecutionLocationChange` → Codex `clearCodexSessionState` (`:9085`) | execution-location change (idle) | retained | **drain added** before the Codex state clear |
| `+StaleResetRecovery:266` | stale-reset stop | retained view | was a VM-only flush; now a **producer drain** |
| VM `:20669` `finalizeDeletedAgentSessionReferences`, VM `:20749` `deleteSession` | deletion | deleted | discard **kept** (deletion semantics) |
| VM `clearChat` → Codex `clearCodexSessionState` | transcript reset | reset | discard **kept** |
| `+StaleResetRecovery:424` `prepareSessionForStaleResetRecoveryReplacement` | confirmed reload replaces the retained copy | replaced | discard **kept** |
| VM `:18985`, Codex `:5512`/`:5518` | inside the flush or clear routines themselves | — | apply-after-clear (exactly once) |
| Codex `:5535` | flush with an empty buffer | — | not destructive |
| `AgentModeRunService` hook `clearPendingAssistantDelta` (VM `:3097`) | defined but never called by the run service | — | none |
| `AgentModeViewModel+StressHarnessSupport.swift:91` | DEBUG stress-harness reset | diagnostics | discard **kept** |

**Limits:**
- Window-close and workspace-switch drains only apply text to the in-memory conversation. Phase 1a adds **no** flush before teardown, so whether that text reaches disk is still decided by the existing lifecycle. That work belongs to 1b.
- `cancelEphemeralRuntimeState()` itself still discards the buffer. Its retained callers drain explicitly first; its deletion callers intentionally don't.

## 4. Implementation files changed

| File | Change |
|---|---|
| `Sources/RepoPromptAgentCore/AgentMode/Runtime/Session/AgentTabSession.swift` | `assistantDeltaDrain` and `drainPendingAssistantDelta()`; an `onPersistenceMutation` call in the `isDirty` setter; transient deadline state and `invalidateTranscriptSaveMaxWait()`; invalidation when a binding is replaced |
| `Sources/RepoPromptAgentCore/AgentMode/Runtime/Codex/CodexAgentModeCoordinator.swift` | records its flush as the drain when it arms the buffer timer |
| `Sources/RepoPrompt/Features/AgentMode/ViewModels/AgentModeViewModel+TranscriptSaveMaxWait.swift` (new) | the timer seam, arming, servicing, eligibility, paired authority and retry |
| `Sources/RepoPrompt/Features/AgentMode/ViewModels/AgentModeViewModel.swift` | the observation hooks; the debounce through the seam; `test_saveTimerSleepOverride`; the save-path drain and its entry guard; the clear on a clean receipt; `hasPersistableConversationContent` extracted unchanged; drains at the retained cleanup sites; the VM drain recorded |
| `Sources/RepoPrompt/Features/AgentMode/ViewModels/AgentModeViewModel+StaleResetRecovery.swift` | the stop path uses the producer drain |
| `Tests/RepoPromptTests/AgentMode/Recovery/AgentTranscriptSaveMaxWaitTests.swift` (new) | 13 tests; see §5, §14 and §16 |
| `Tests/RepoPromptTests/AgentMode/AgentModeChatSwitchActivationTests.swift` | the deterministic save-before-catch-up regression and the hydration barrier on the cold-activation test (§13) |

`Tests/RepoPromptTests/Helpers/CodemapSeamTestSupport.swift` and the other dirty files in the checkout are unrelated earlier work and were left untouched.

## 5. Tests (root SwiftPM layer, deterministic)

The suite is `RepoPromptTests.AgentTranscriptSaveMaxWaitTests`. A manual save-timer sleep records every timer request and its absolute deadline. Debounce timers are never fired, so every save observed comes from the maximum wait, an explicit flush, or a follow-up that the maximum wait requested. Writes are held with `test_saveSessionBeforeWriteHook`; failures are injected with a read-only sessions folder. Every test uses its own temporary workspace.

| Test | Contract (plausible defect) and oracle |
|---|---|
| `testFirstUnsavedChangeSetsAbsoluteDeadlineThatContinuousChangesAndRequestsNeverMove` | A stream that keeps replacing the debounce still gets saved (starvation), from an absolute deadline. **Oracle:** the timer's deadline equals `firstUnsavedAt + 10 s`; the generation and first instant don't change across 5 flushes and 5 requests; nothing is bound before the timer fires; after it fires the file holds all chunks and the obligation is cleared. |
| `testSourceMutationArmsBeforeItsDirtyMarkDirtyOnlyEditArmsAndPlainRequestDoesNot` | **Oracles:** with the dirty hook removed, the source callback observes `isDirty == false` and the deadline already armed; a dirty-only run-state edit (source revision unchanged) arms it; a bare `scheduleSave` doesn't. |
| `testCoveringOlderSnapshotRebasesDeadlineToPreCallAndInFlightWriteGetsImmediateSave` | **Older snapshot (rebased, §14):** a change lands during the deadline write; exactly 1 write; the newer text is not on disk and stays owed; the deadline is rebased to an instant between the wakeup and the newer change (`firedAt ≤ rebasedAt ≤ changeAt`), so the new request is ≤ `changeAt + 10 s`; no retry; firing it writes the newer text and clears the obligation. **In-flight:** the deadline fires while a flush is suspended in its write; the flush returns `.written(projectionClean: false)`, the newer text reaches disk without a new 10 s window, and no retry is armed. |
| `testFailedSaveKeepsDirtyAndDeadlineAndRetriesOnceAtLeastOneSecondApart` | **Oracle:** after a failure, the session stays dirty, the deadline is unchanged, and exactly one retry is armed at ≥ 1 s, then ≥ 2 s, measured from the wakeup. After permissions are restored, the next retry writes and clears. The total is 2 retries, with no extras. |
| `testBindingReplacementAndDisposalMakePreviousOwnerTimerObsolete` | **Oracle:** replacing the binding clears the obligation; delivering the obsolete wakeup on purpose writes nothing to the old file and re-arms nothing. A disposed owner's wakeup binds or writes nothing. |
| `testDeadlineNeverSavesBoundOwnerWithoutPairedHydrationAuthority` | A bound owner with `hasLoadedPersistedState == true` but disposition `.unresolved` must not be saved. **Oracle:** `saveRequestGeneration` is unchanged (the save never started); the file is byte-identical; the session stays dirty; one retry is armed. |
| `testSaveSnapshotDrainsBufferedTextOfEitherProducerExactlyOnce` | For the VM and the Codex producer, a flush with unflushed buffered text writes it. **Oracle:** the text is on disk, the buffer is empty, and after the cancelled buffer timer completes the row text appears exactly once. |
| `testSaveOfCleanSessionWritesItsBufferedAssistantText` | A clean session (`isDirty == false`) with buffered text. **Oracle:** `flushSaveDetailed` returns `.written`; the file holds `"Clean partial tail"`; the buffer is empty. |
| `testSaveDrainsScopedCodexBufferIntoItsOwnRowOnly` | A Codex buffer scoped to an earlier streaming row, with a later streaming row after it. **Oracle:** only the scoped row gains the text, once; the trailing row is unchanged in memory and on disk; the cancelled timer never replays it. |
| `testRemovalReservationParksObligationWithFixedOneSecondRetryUntilAborted` | **Oracle:** while reserved, two wakeups start no save (`saveRequestGeneration` unchanged), keep the deadline, and each arm a retry with `deadline − (instant before the wakeup) ≥ 1 s` and `deadline − requestedAt ≤ 1 s` (no escalation); after the admission is cleared the retry writes and clears; exactly 2 retries. |
| `testWindowCloseKeepsPendingDebounceSaveAndWorkspaceDiscardCancelsBothTimers` | **Oracle (window close):** the maximum-wait task and deadline are nil; the obsolete maximum-wait wakeup starts no save (`saveRequestGeneration` unchanged) and the file lacks the edit; the debounce pending after close (rescheduled by teardown) survives, and firing it writes `"Edit before close"` and leaves the session clean, with no deadline re-armed. **Workspace discard:** the debounce, maximum-wait task and deadline are all nil. **Discrimination:** with the round-0 `cancelTranscriptSaveTimers` restored at close, the test fails at the surviving-debounce unwrap (job `09d01ee3`). |
| `testRebasedDeadlineKeepsAnyFutureDeadlineAndFloorsOnlyAnExpiredOne` | Pure helper, synthetic instants. **Oracle:** completion at +5 ms, +9.5 s and +9.999 s keeps `T + 10 s` exactly; completion at +10 s and +25 s gives completion + 1 s. |
| `testWindowCloseCleanupAppliesBufferedTextToRetainedConversation` | **Oracle:** after `prepareForWindowClose()` and completion of the cancelled timer, the retained row reads `"Close partial tail"` exactly once. Before this change, `cancelEphemeralRuntimeState()` discarded it. |

**Discrimination checks:**
- I temporarily reverted the authority predicate to `hasLoadedPersistedState`. The hydration test then **failed**: `saveRequestGeneration` went from 1 to 2, "No save was started". The file stayed untouched, so the existing fail-closed persistence check alone would not have been caught. I then restored the predicate.
- The remaining tests discriminate by construction:
  - a relative timer misses the absolute-deadline match;
  - without the save drain, the file lacks the tail;
  - without the close drain, the tail is lost;
  - without the in-flight follow-up, the newer text never reaches disk;
  - without invalidation, the first unsaved instant stays set.

**Ledger:** the XCTest ledger is frozen and wasn't edited. Conductor reports the suite as "found in sources but not in the curated ledger … running with default deadlines".

**Failed attempts and their causes** (all in test code; production behavior didn't change because of them):
1. **Hang until the 180 s deadline in the binding test, twice.**
   - Cause: a timer task registers its sleep only after it starts, which is after the synchronous mutation returns. Picking "the latest pending request" therefore chose the previous, already-invalidated timer. The test then awaited a current timer it never fired.
   - Fix: identify the maximum-wait request by its absolute deadline, and yield, bounded, until it has registered.
2. **Retry lower bound measured from the wrong instant.**
   - `deadline − requestedAt` is short by the task-start latency, because a retry's deadline is fixed when it is armed.
   - The bound is now measured from the wakeup that caused the retry. It is still a strict ≥ 1 s or ≥ 2 s assertion, not weakened.
3. **Pipe characters in `FILTER`.** `make dev-test FILTER='a|b'` reached the shell unquoted, so `|` became a pipe and the job failed (exit 127). It was rerun as `FILTER="'a|b'"`.
4. **One edit applied twice.** A shell-based edit was rejected mid-command after its file write had already run; I deduplicated by hand. All later edits used `apply_edits`.
5. **Weak authority oracle.** The first version of the hydration test only checked the file bytes; the strengthened version is described under the discrimination checks above.
6. **Same measurement mistake in the park test (§14).** Its first version measured `deadline − requestedAt ≥ 1 s` and failed with 0.99997 s, twice: the same skew as attempt 2. The lower bound is now measured from an instant taken before the wakeup that arms each retry (still a strict ≥ 1 s). `requestedAt` is used only for the upper bound (≤ 1 s, no escalation). The 4.09 s duration of that failing run did not recur: the test alone took 0.045 s with a temporary timing trace, which showed no stall between steps, and 0.012 s in the suite. The trace was removed.

## 6. Phase 0 stream report rerun (opt-in, advisory fixture)

`RPCE_RUN_SCALE_TESTS=1 make dev-test FILTER='AgentStaleResetOwnershipTests/testRestartPhase0'` passed: 2 tests in 19.4 s.

| Metric | Phase 0 (run 4) | Phase 1a |
|---|---|---|
| `save.session.invoked` during the stream | 0 | 1 |
| `save.session.written` during the stream | 0 | 1, at 10.45 s |
| Longest unsaved window (sampled about every 100 ms) | 12.02 s | 10.45 s |
| `writtenThroughFinalText` | 1 | 2 |
| Final text on disk after the stream ended | 0.97 s | 0.96 s |

Other figures were unchanged: 114 chunks, 38 schedules and 2,935 bytes.

**Reading:**
- The first unsaved change is the first 250 ms buffer flush.
- The 10.45 s offset stacks that flush, the 10 s deadline, the save, and the about 100 ms sampling interval.
- The report has no threshold assertion; this is advisory fixture evidence, not live acceptance.

Large-session figures from the same run, 1,500 items:
- measured phases 30.1–31.1 ms;
- `vmTotal` 33.4–34.4 ms;
- first save 0.208 s.

## 7. Validation (2026-10-20)

| Command | Result |
|---|---|
| `make dev-build` | Exit 0 |
| `make dev-test FILTER='AgentTranscriptSaveMaxWaitTests'` | 8 tests, 0 failures |
| Affected suites, run as `make dev-test FILTER="'AgentTranscriptSaveMaxWaitTests\|AgentStaleResetOwnershipTests\|AgentModeRunServiceLifecycleTests\|CodexAgentModeCoordinatorLivenessTests\|CodexFallbackFIFOTests\|WorkspaceSwitchCleanupTests\|WindowCloseCoordinatorDecisionTests\|AgentScheduledSendDispatchTests\|AgentTranscriptBackgroundRefreshDeferralTests\|AgentModeViewModelInactiveRefreshTests\|AgentSessionCleanupOriginTests\|AgentModeChatSwitchActivationTests\|AgentModeViewModelDisposalTests\|PromptComposeTabRemovalOwnershipTests\|AgentChatTitlebarSafetyTests'"` | 445 test cases passed, 0 failures; the 2 opt-in Phase 0 reports were skipped |
| `make dev-test FILTER="'WindowCloseCoordinator'"` | Lifecycle 5 and Policy 3: 0 failures |
| `make dev-test FILTER="'AgentTranscriptSaveMaxWaitTests\|AgentRunLocationTests\|AgentRunWorktreeStartTests\|AgentExecutionWorktreeSelectionTests'"` (after the location drain) | 8 + 13 + 41 + 3 tests, 0 failures |
| Opt-in Phase 0 reports (§6) | Passed |
| `make dev-test-list` | Exit 0; lists all 8 new IDs |
| `make dev-lint` | Exit 0 after one blank-line fix (`blankLinesBetweenScopes`) |
| `Scripts/check-agent-context` (after linking this file from `phase1-scope.md`) and `Scripts/test-check-agent-context` | Passed (1 warning that predates 1a: AGENTS.md route count); checker tests 23 passed |
| `make dev-lint` (final) | Exit 0 |
| `make guardrails` | **Failed**, but not because of 1a: "unexpected tracked docs": the spec and `phase0*.md`, tracked since commit `be41cf0b` (Phase 0). Both 1a documents are untracked. Committing `phase1a.md` would need the same allowlist decision. |
| Final affected-suite rerun, the earlier suite set plus `AgentRunLocationTests`, `AgentRunWorktreeStartTests` and `AgentExecutionWorktreeSelectionTests` (job `2b4684b6`) | **Failed**: 512 tests, 2 skipped, 2 failures, all in `AgentModeChatSwitchActivationTests/testColdActivationStampsPersistedProviderAndCatchesUpRunStateOnly` (see §9). Every other suite had 0 failures, including all 8 1a tests. |

## 8. Contradictions, deviations and assumptions

- **Plan text.** The spec's Phasing still lists the lifecycle flush and window-close preservation under 1a. Following the main agent's recorded assumption ([phase1-scope.md](phase1-scope.md)), they are left to 1b and the plan prose is untouched.
- **Binding invalidation.** The contract says binding replacement invalidates the timer. A genuine creator's first binding happens inside its own first save, so invalidation applies only when an existing binding is replaced (§2).
- **Hydration authority.** It is derived from the load outcome, not from `authoritativeHydratedBinding`, which is a UI-presentation fence for the active tab only (§2).
- **Extra choices within the contract:**
  - an exponential retry backoff capped at 30 s;
  - a cap of 2 immediate follow-ups per wakeup;
  - "nothing to save" clearing for unbound sessions without content.
- **Debounce deadline.** It is now computed when `scheduleSave` is called rather than when the debounce task starts. The difference is the task-start latency only.
- **Open validation failure:** see §9.
- **Not done:**
  - window-close or quit flushes;
  - durable input or identity;
  - live or real-app acceptance (O3);
  - exact quiet-write latency;
  - isolated main-actor cost.

## 9. Open validation failure: intermittent cold-activation test (cause not established)

I paused the investigation on the main agent's instruction. The cause is unknown, and the test was not changed or weakened.

### Where it fails

`Tests/RepoPromptTests/AgentMode/AgentModeChatSwitchActivationTests.swift:1712`, `testColdActivationStampsPersistedProviderAndCatchesUpRunStateOnly`.

**Assertions that fail:**
- `:1722` `XCTAssertEqual(observed.catchUps.count, 1)` failed with **actual 0**, expected 1.
- `:1723` `XCTUnwrap(observed.catchUps.first)` failed: nil.

**Timing.** Failing runs take about 7.1–7.5 s; passing runs take about 0.43–0.55 s.

**Helper.** `observeColdActivationCatchUp` (`:1907`–`:2050`) works as follows:
- A separate writer VM persists a 3-turn OpenCode session and calls `flushSave`, which is asserted true.
- An unseeded cold tab is switched to with `switchComposeTab`.
- `AgentTranscriptDebugInstrumentation.refreshAttemptHandler` records a catch-up only when all of these hold:
  - `currentTabID == tabID`;
  - `sessions[tabID]` exists;
  - `target.sourceItemsRevision == metrics.sourceItemsRevision`.
- The helper then polls for up to 20 s until `activeSessionLoadInProgressTabID == nil && hasLoadedPersistedState`.
- The fixture (`:3249`) installs no `test_saveTimerSleepOverride`, so 1a timers use real sleeps here.

### Runs

| Job | What ran | Result |
|---|---|---|
| `2ac8a048` | earlier affected-suite run with 1a in place (before the final blank-line lint fix and the execution-location drain) | passed (0.432 s) |
| `2b4684b6` | final affected-suite run | failed (7.465 s) |
| `54ad000f` | `make dev-test FILTER='AgentModeChatSwitchActivationTests'` | 47 tests, all passed |
| `c141f1f3` | the same suite again | failed (7.131 s) |
| `10787b44` | `FILTER='AgentModeChatSwitchActivationTests/testColdActivationStampsPersistedProviderAndCatchesUpRunStateOnly'` | passed (0.448 s) |
| `4ae14ae2` | the same single test | passed (0.550 s) |
| `20509526` | the same single test | **failed** (7.225 s) |
| `ccd3e01f` | the same single test with a temporary A/B line disabling `noteTranscriptPersistenceMutation` (the line was reverted right after; the rest of the loop was stopped) | passed (0.434 s); a single run, **inconclusive** |

**Reproducibility:** 3 of 7 runs with 1a failed; in isolation, 1 of 3 single-test runs failed. There is no baseline at HEAD without 1a. A search of `docs/` found no record of this test being flaky; the D6 transcript-refresh reviews mention the test but not flakiness.

### Observations (not a cause)

- With an empty assistant buffer, the 1a save path behaves as before: the new drain does nothing, and the new guard repeats the old entry guard.
- The new runtime behaviors in this fixture are:
  - the `onPersistenceMutation` and `onSourceItemsChanged` hooks arming a real 10 s maximum-wait task. The writer's clean `flushSave` clears its own task;
  - the debounce deadline, now computed in `scheduleSave`;
  - invalidation when a binding is replaced.
- A 10 s wakeup from this test's own fixture cannot fire inside a 7 s isolated run; that reasoning is not proof.
- The 7 s failure duration is unexplained. It is shorter than the 20 s polling limit, so the hydration poll ended normally.

The main agent sends the analysis to the independent OracleA/OracleB review.

## 10. Bounded cold-activation diagnosis (after the initial reviews)

The initial reviews are recorded verbatim in [OracleA](phase1a-oraclea-review.md) and [OracleB](phase1a-oracleb-review.md); their R1 and V1 items requested this probe.

**Method.** I added temporary instrumentation to the test file only, marked `TEMP COLDTRACE`, and removed it afterwards; `git diff` of the file is empty again. The probe recorded:
- monotonic timestamps for: fixture initialized, workspace switched, fixture ready, writer flush start and end, `switchComposeTab` start and end, hydration-poll exit, main-queue drain exit, cleanup, and the end of the test;
- the refresh-attempt handler, logged **before** the observation guard, with reason, path, event and target revision, `currentTabID == target`, and whether the target exists and is loaded;
- the fixture VM's `AgentModePerfDiagnostics` save, max-wait and load lines, through `setDebugProcessOverrideEnabled(true)`;
- in the last attempt, the helper's final-state comparisons against the cold reference, printed without asserting.

The budget was at most 3 isolated attempts plus the control. All assertions were left unchanged.

### Traces

| Job | Run | Result | Ordering |
|---|---|---|---|
| `234b6d61` | attempt 1 | **failed**, 8.194 s | Switch from +0.405 to +0.430 s; it returned with the target already hydrated (`targetLoaded=true`, no load in progress). During the switch, the target was scheduled (`save.schedule dirty=true`) and saved (`save.session.innerRefresh`, then `save.session.written`, 12 items, `save.session.complete`). **No refresh attempt reached the handler, filtered or unfiltered.** The poll exited at +0.430 s with disposition `.applied`, run `completed`, dirty, rev 2, and `catchUps=0`. The test threw at +8.18 s. |
| `795dc32b` | attempt 2 | passed, 0.445 s | Switch from +0.403 to +0.411 s; it returned **with the load still in progress**. The switch's save was skipped (`save.session.skipped missingContextOwnerOrClean`). Then one refresh ran (`liveMutation`, `incremental-success:no-frontier`, rev 1, target current), and `catchUps=1`. |
| `21c934ff` | attempt 3, with the final-state prints | passed, 0.452 s | Same ordering as attempt 2. Every final-state comparison was true. |
| `ab48b7e3`, `ae22bc78`, `13744924` | control: the same test with the existing `holdsHydrationUntilSwitchSettles: true`, all assertions unchanged | **3 of 3 passed**, 0.406–0.437 s | The switch returned with `targetLoaded=false` (hydration held). The switch's save was skipped. The catch-up was observed, and every final-state comparison was true. |

### What the trace establishes

- **The 7 s is not a stall.** Setup, writer flush, switch and poll all finish within about 0.43 s in both passing and failing runs. The extra time comes after `drain.exit` and before the failure is thrown, around the failing assertions.
- **Failing runs follow a race-dependent ordering.** When hydration completes inside `switchComposeTab`, the switch's own save writes the dirty hydrated target, and an inner refresh runs. The activation catch-up the test observes then never reaches the refresh handler. When the switch returns first, its save is skipped and the catch-up is observed.
- **No maximum-wait activity.** No `save.maxWait.*` line appears in any trace, consistent with a 10 s deadline that cannot expire in a 0.43 s run.
- **The sibling test already holds hydration for this race.** `testColdActivationCatchUpAcrossPersistedRunStates` uses the barrier and documents that hydration is held "until the switch's own save flush has run, so that save always follows the observation". The completed-state test does not hold it.

### What it does not establish (inconclusive, so I stopped)

- **Production's final state in the race ordering is unverified.** The only failing capture threw at the `XCTUnwrap` at `:1723`, before the final-state checks. The run with final-state prints passed. The failing trace shows only disposition `.applied`, run `completed`, dirty, rev 2, and a successful 12-item write.
- **Whether 1a changes how often the race occurs is unknown.** There is no baseline without 1a.

The test was left unchanged, with no barrier added, as required when the probe is inconclusive.

**Smallest comparison that would settle it.** Do not stash, revert or create a worktree. Instead:
1. Temporarily add a DEBUG-only early return to `noteTranscriptPersistenceMutation` plus the old relative debounce sleep.
2. Run the single test N times with and without that change, comparing failure counts.

Separately, to check production's final state in the race ordering, run the existing test with the same final-state prints until a failure is captured. Each of these needs an explicit budget from the main agent.

## 11. Final-state capture in the race ordering (stopped: final state not proven correct)

**Budget and method.** The main agent allowed at most 3 more isolated attempts, stopping at the first failure. The temporary instrumentation was the same as in §10, plus `persistedAgent` and `persistedRun`. The helper prints its final-state comparisons **before it returns**, so they run before the test's count and unwrap assertions. All assertions were kept. The instrumentation was removed afterwards; the test file's `git diff` is empty.

### Actual traces (observed)

| Job | Attempt | Result | Ordering and final state |
|---|---|---|---|
| `fa6b5bf9` | 1 | passed, 0.458 s | **The catch-up refresh ran inside the switch** (+0.422 s; `liveMutation`, rev 1, target current), **before** `switch.end` (+0.445 s, `targetLoaded=true`). No save of the target was written during the switch. `itemsEqualPersisted=true`, and every other comparison was true. |
| `064f8683` | 2 | passed, 0.408 s | The switch returned with the load still in progress, and the switch's save of the target was skipped (`missingContextOwnerOrClean`). The catch-up ran at +0.375 s. Every comparison was true. |
| `f6cad1cb` | 3 | **failed**, 8.049 s, at `:1725` and `:1726`, which correspond to the original `:1722` and `:1723` after the instrumentation shifted lines | The switch ran from +0.514 to +0.537 s and returned with the target hydrated. **During the switch the target was saved:** `save.schedule dirty=true`, then `save.session.innerRefresh`, then `save.session.written` (12 items, 8,189 bytes), then `save.session.complete`. No refresh attempt reached the handler at any point. Poll exit: rev **2**, `.applied`, `completed`, dirty. |

**Final state in the failing run.** The helper's comparisons were printed before any assertion ran:

| Check | Result |
|---|---|
| `syncStateMatches` | true |
| `reusable` | true |
| `transcriptEq`, `baseEq`, `fullEq`, `workingEq` | true |
| `countsEq`, `visibleEq`, `analyticsEq` | true |
| agent `openCode`, run `completed`, persisted values `openCode` and `completed` | as expected |
| **`itemsEqualPersisted`** | **false** |
| `beforeCatchUpCaptured` | false |

`itemsEqualPersisted=false` violates the test's integrity contract: `XCTAssertEqual(session.items, observed.persistedItems)`, "the hydrated items are the stored record".

The transcript and projection equalities are not independent evidence. The test's reference is rebuilt from the session's current items, so those checks can't detect an item-level difference.

### Code reading (inference, not traced)

The failing ordering matches the existing save path in `saveSessionDetailed` (VM `:14408`–`:14427`), which predates 1a and which 1a does not change:
1. An active-owned save that can't reuse the presentation rebuilds it, because the run-state catch-up hasn't run yet.
2. If `shouldReconcileWorkingItems` holds, it replaces the hydrated items with `setItemsSilently(trimmedWorkingItems, reason: .retentionCompaction)`. That gives rev 2 and `items != persisted`.
3. It then raises `save.session.innerRefresh`, which only requests a UI refresh.
4. With the stamp already synchronized, the activation catch-up has no delta to import.

What distinguishes the outcomes is **whether the switch's save of the hydrated target runs before the activation catch-up**; whether hydration finishes inside the switch does not decide it, as attempt 1 shows. The existing barrier (`holdsHydrationUntilSwitchSettles`, §10, control 3 of 3) removes this ordering.

### Disposition

- **Stopped; the barrier was not applied.** The trace does not prove the final state correct: the hydrated items no longer equal the stored record, and the save writes the reconciled items. That may be a legitimate normalization or a real defect, and I can't tell which within budget.
- **Possible pre-existing defect for the main agent and Oracle analysis.** A foreground switch's save can reconcile and rewrite a just-hydrated, completed session's items before its activation catch-up. The path is existing save code that 1a does not touch.
- **Unknown:** how often this happens, and whether 1a changes that frequency. There is no baseline.
- **Not started:** none of the cheap review fixes or the coverage-checked rebasing, because they were conditional on establishing a test-only fix.

## 12. Semantic item-diff probe (inconclusive: no failure reproduced in 3 attempts)

**Method.** One bounded probe, from the main agent's Oracle plan of 2026-10-20 22:20. The instrumentation was temporary and test-local, all assertions were kept, and it was removed afterwards; the test file's `git diff` is empty.

The helper captured three states synchronously at poll exit, before any further await:

| Source | What was captured |
|---|---|
| Input | the loaded `persisted.transcript` and `persistedItems` |
| Memory | `session.items` and `session.transcript` |
| Durable | the raw bytes of `persisted.fileURL`, decoded read-only with `AgentSessionDataCodec.decodeSession`, then `workingSourceItems` from that transcript |

It then diffed five pairs over each model's own `Codable` JSON, flattened to exact paths, with sorted keys and default date encoding so no precision is lost:
- items: input → memory, input → durable;
- transcript: input → memory, input → durable, memory → durable.

The budget was 3 isolated attempts, stopping at the first qualifying failure.

### Actual runs (all passed; the save-first ordering never occurred)

| Job | Ordering | Durable file | Items: input→memory, input→durable | Transcript: input→memory, input→durable, memory→durable |
|---|---|---|---|---|
| `6e9e502b` (0.459 s) | Catch-up (+0.418 s) ran before `switch.end` (+0.441 s); no target save | the writer's file: same session ID, `completed`, `openCode`, 8,193 bytes | 0 / 138, 0 / 138 | 12 / 201, 0 / 201, 12 / 201 |
| `c30a3e7e` (0.410 s) | `switch.end` (+0.369 s), then catch-up (+0.370 s); the switch's save skipped the target | the writer's file, 8,197 bytes | 0, 0 | 12, 0, 12 |
| `6260d45a` (0.568 s) | Same ordering as `c30a3e7e` | the writer's file, 8,194 bytes | 0, 0 | 12, 0, 12 |

**The 12 in-memory transcript differences in passing runs** are identical in every run. In each of the three turns, the two bash activities (a `failed` and an `unknown` summary-only command execution) differ in the same way:
- in both `activities[n].text` and `activities[n].toolExecution.resultJSON`, the field `"summary_text":"bash • failed"` (or `"bash • unknown"`) is present in storage and absent in memory;
- the `status`, `summary_only` and `type` fields are unchanged.

The stored file is untouched in passing runs: input and durable are identical.

**This is not evidence about the failing ordering.** These are passing-path observations only, recorded so that a later failing capture can be compared with them. The input record already holds summary-only command payloads (`status: failed` or `unknown`) for tool results the writer created with `{"output":"N"}`. That input-side shape predates the switch, and this probe did not interpret it.

### Disposition

- **Inconclusive by the plan's own rule:** no reproduction within budget. No barrier was added, no production or test change remains, and no more runs were made.
- **Still unknown:** whether the save-first `.retentionCompaction` rewrite (§11) preserves content and identities. The probe is ready to reuse unchanged for one future failing capture if the main agent grants another budget. It would show item ID order and kind, every differing stored field, and durable attribution (file, ID and size) against both the input and the in-memory state.
- **Superseded by §13:** a deterministic regression replaced random reproduction; the review fixes and rebasing followed (§14).

## 13. Deterministic save-before-catch-up regression and the hydration barrier

On the main agent's instruction (scout export, 2026-10-20), random reproduction was abandoned in favour of forcing the failing ordering deterministically.

**Test.** `AgentModeChatSwitchActivationTests/testSaveBeforeActivationCatchUpReconcilesOnlyGeneratedToolSummaries` (window 4492):
- A writer VM persists the 3-turn OpenCode record, marks it `completed`, flushes, and closes.
- A fresh tab is hydrated through the real path (`preparePersistedHydration` then `test_applyPersistedHydration`), with the current tab overridden and all save timers held.
- Precondition: items equal the loaded input, and the run state still differs from the catch-up state, so the save runs **before** activation catch-up.
- A dirty `flushSaveDetailed` must return `.written`, and the before-write hook shows the reconciliation advanced `sourceItemsRevision`.

**Oracles:**
- in memory, input → memory items differ **only** by removal of generated summaries (`summary_only == true` and `summary_text == "<tool> • <status>"` removed, every other field equal); the helper diffs each item's sorted-key `Codable` JSON per field;
- `session.items` after the save equals the captured memory items;
- on disk, the decoded file has the same session ID and `completed`, and its items equal the input **strictly**, with no allowance.

**Runs.**
- Job `3ee95e9b`: passed in 0.421 s.
- Job `fa314b3c-3562-43bf-8f67-927da0caae85` deliberately failed the temporary strict in-memory-equality diagnostic (one assertion failure; diagnostic removed afterward): exactly 12 differences. `.text` and `.toolResultJSON` on the 6 summary-only bash `toolResult` items (2 per turn) drop `"summary_text":"bash • failed"` or `"bash • unknown"`. The durable comparison was strict and passed.

**Activation after the save (round 1, F3).** The test then clears the tab override and runs the real `switchComposeTab(tabID)`. It asserts:
- the same owner is reused;
- the provider is `openCode` and the run state is `completed`;
- the sync stamp equals the catch-up state;
- the items are unchanged from the reconciled memory items.

Transcript, base, full and working projections, projection counts, canonical visible row count and analytics all equal a cold reference built from the **original input items**. Every earlier assertion is kept. The held save-timer sleeps (formerly 86400 s `Task.sleep`) are now `HeldSaveTimers`: the test cancels each owner's timer tasks and then ends every held sleep, so no held debounce save runs late.

**Conversion chain (code reading).** The runtime `genericSummaryObject` omits `summary_text`. The storage path `storageSafeSummaryText` (`AgentToolResultPersistencePolicy.swift`) regenerates it as `"<tool> • <status>"`. The reconciliation therefore loses only a field that storage regenerates, and the file round-trips exactly. These are the same 12 differences that §12 observed in passing runs.

**Barrier.** The final state in the failing ordering is now proven correct, so, as the scout export authorized, `testColdActivationStampsPersistedProviderAndCatchesUpRunStateOnly` passes `holdsHydrationUntilSwitchSettles: true` (the existing sibling barrier). It also gains a doc note pointing to this regression. Every assertion is unchanged. This applies a test-only precondition; **Main-agent disposition:** this resolves the validation blocker by establishing the intended observation precondition and separately covering the save-first ordering against original input. Whether 1a changes the frequency of that ordering is still unknown; no baseline-flake or frequency claim is made.

**Main-agent instruction clarification.** Keep the barrier and the deterministic regression under the later, conditional scout-export authorization. The earlier instruction not to alter the test applied while semantic integrity remained unproven.

## 14. Review fixes and covering-write rebasing

These come from the Oracle A and B reviews ([A](phase1a-oraclea-review.md), [B](phase1a-oracleb-review.md)) and the main agent's rebasing plan.

| Finding | Disposition |
|---|---|
| A R2: the manual timer can strand a task that starts after teardown | Fixed (test). `ManualSaveTimer.cancelAll()` sets `isClosed`; a later `sleep` throws `CancellationError` instead of suspending. |
| A R3: no coverage of a clean but buffered save, or of a scoped Codex drain | Fixed (tests). `testSaveOfCleanSessionWritesItsBufferedAssistantText`, `testSaveDrainsScopedCodexBufferIntoItsOwnRowOnly`. |
| B P2-2: a reserving removal cleared the obligation | Fixed. Parked: `.waitForAuthority` keeps the deadline (§2). |
| B P2-4: waiting for authority escalated the backoff | Fixed. `scheduleTranscriptSaveRetry(escalates: false)` uses the fixed 1 s floor without incrementing the retry count. |
| B P2-3: teardown left timers armed | Window close: **corrected in round 1** (§16 F1); only the maximum wait is cleared, and the debounce is kept. Workspace discard: cancels both. No arming after a window close begins (§2). |
| B P2-1: an older snapshot forced an immediate rewrite even when the write covered every earlier change | Fixed with coverage-checked rebasing (below). |
| P3 items | Deferred. |

**Rebasing contract.** Immediately before the actual `saveSessionDetailed` call, with no suspension between, the servicing loop captures:
- the instant T;
- `sourceItemsRevision` and `persistenceMutationGeneration`;
- the binding and `bindingTransitionGeneration`;
- the persistence context.

It rebases (first-unsaved := T, deadline T + 10 s or, only if that expired by completion, completion + 1 s; retry count reset) **only** when all of these hold:
- this call returned `.written` with `projectionClean == false`;
- the receipt's counters are ≥ the captured ones;
- a current binding matches `activeAgentSessionID`, with no binding transition in progress;
- the captured context is still current;
- hydration authority holds;
- the captured binding and transition generation are unchanged. A nil capture is accepted only for a creator whose first bind happens inside this call.

Deferred, reset-acknowledged, failed, unknown-coverage and otherwise mismatched outcomes keep the old deadline and the immediate follow-on. Current counters are **not** required to equal the receipt; a newer change is exactly the case being rebased.

**Proof of coverage.**
- `saveSessionDetailed` has no `await` before `ensurePersistenceState`. Its synchronous prefix drains buffered text, binds, snapshots working items, repairs pending tools, builds the presentation and payload, and only then creates the commit token from `sourceItemsRevision` and `persistenceMutationGeneration`.
- The receipt reports the token's counters, so the payload reflects every change up to the token.
- Both counters only increase, and T precedes the call. Receipt counters ≥ captured counters therefore mean every change before T is in the written payload. This is the same invariant the clean receipt already relies on to clear `isDirty`.
- Changes after T are the only unsaved ones, and the rebased deadline T + 10 s is at most 10 s after the earliest of them.
- T is captured before the call, never at completion, so a slow write cannot extend the bound.

The test asserts `firedAt ≤ T ≤ changeAt` and a deadline ≤ `changeAt + 10 s`, with 1 write and no retries until the rebased deadline fires. The in-flight half of the same test is unchanged and passes. No main-actor cost is asserted.

## 15. Validation (2026-10-20, after §13–§14)

| Command | Result |
|---|---|
| `make dev-test FILTER='AgentTranscriptSaveMaxWaitTests'` (job `969c4406`) | 12 tests, 0 failures, 0.233 s |
| `make dev-test FILTER="'AgentModeChatSwitchActivationTests\|WorkspaceSwitchCleanup\|WindowCloseCoordinator\|PromptComposeTabRemovalOwnershipTests\|AgentStaleResetOwnershipTests\|AgentModeRunServiceLifecycleTests'"` (job `2b5c9a17`) | 270 tests, 0 failures, 2 skipped (the opt-in Phase 0 reports). Per suite: ChatSwitchActivation 48, RunServiceLifecycle 162, WorkspaceSwitchCleanup 6, StaleResetOwnership 39, PromptComposeTabRemovalOwnership 7, WindowCloseCoordinator Lifecycle 5 and Policy 3. |
| `make dev-lint` | First run: 1 file needed formatting (a trailing comment before a `case` label in `+TranscriptSaveMaxWait.swift`). The comment was moved above its `if`; the rerun was clean (0/2086). |
| `make dev-format-check` | Clean |
| `make guardrails` | Passed (source layout, contributor allowlist, notices) |
| `Scripts/check-agent-context`, `Scripts/test-check-agent-context` | Passed: 1 warning that predates 1a (AGENTS.md route count); checker tests 23 passed |

**Not run:**
- broad suite repetitions, as instructed;
- further cold-activation probes;
- `make dev-build` or packaging;
- live or real-app acceptance.

The last change after the test runs was the comment-only lint fix.

## 16. Round-1 re-review dispositions (A→B delta)

The reviews are [Oracle A r1](phase1a-oraclea-r1.md) and [Oracle B r1](phase1a-oracleb-r1.md). A approved with no P0 or P1 findings and resolved the validation issue. B raised one provisional P1 (F1) and two P2s (F2, F3).

**F1, window close cancelled a debounce save that HEAD would run (P1, confirmed by the main agent).**
- HEAD's `cancelEphemeralRuntimeState` does not cancel the debounce, and the original quit and close paths have no flush.
- The round-0 cancellation, which the review suggested (P2-3), therefore dropped a save HEAD would make.
- Fix: window close now clears only the maximum wait and keeps the debounce; the guard against arming after close stays.
- No lifecycle flush was added; that remains 1b.
- Nothing from round 0 had shipped, so this corrects uncommitted work only.
- The test now **proves** that the debounce pending after close writes the edit. The first rewrite failed because close reschedules, which replaces the pre-close debounce; a one-run perf trace showed `save.schedule replaced=true` during close.
- The workspace-switch discard keeps the reviewed cancellation.

**F2, a write of 10 s or more chains back-to-back rebased writes (P2).**
- Fix: the pure helper `rebasedTranscriptSaveDeadline` arms `T + 10 s` whenever it is still in the future, however close. Only an already-expired deadline becomes completion + 1 s.
- This applies only to blocked or unhealthy storage (a covering write of 10 s or more). Healthy behavior is unchanged, and the rebasing test's exact equality still holds.
- Covered deterministically with synthetic instants; no clock framework.

**F3, the regression stopped at the save (P2).** Extended through real activation against an original-input reference (§13).

**P3.**
- Long test sleeps: fixed (held timers ended explicitly, §13).
- Tautological counter guard, and unbounded 1 s authority polling: deferred. The counter guard is recorded here: what actually guarantees coverage is the synchronous token capture before the first `await` (§14).

**Cold activation.** The main agent keeps the barrier and the deterministic regression. The ordering's frequency is unknown and non-blocking; no baseline-flake claim is made.

### Validation (2026-10-20, round 1)

| Command | Result |
|---|---|
| `make dev-test FILTER='AgentTranscriptSaveMaxWaitTests'` (job `9c358c1c`) | 13 tests, 0 failures |
| Discrimination: old window-close cancellation temporarily restored (job `09d01ee3`) | The window-close test failed as expected; the change was reverted |
| `make dev-test FILTER="'AgentTranscriptSaveMaxWaitTests\|AgentModeChatSwitchActivationTests\|WorkspaceSwitchCleanup\|WindowCloseCoordinator\|PromptComposeTabRemovalOwnershipTests\|AgentStaleResetOwnershipTests\|AgentModeRunServiceLifecycleTests'"` (job `a5fa9074`) | 283 tests, 0 failures, 2 skipped (opt-in Phase 0 reports). MaxWait 13, ChatSwitchActivation 48 (including the extended regression), RunServiceLifecycle 162, WorkspaceSwitchCleanup 6, StaleResetOwnership 39, PromptComposeTabRemovalOwnership 7, WindowCloseCoordinator 5 + 3 |
| `make dev-lint`, `make dev-format-check` | Clean (0/2086) |
| `make guardrails` | Passed |
| `Scripts/check-agent-context`, `Scripts/test-check-agent-context` | Passed after the r1 links were added (1 warning that predates 1a: AGENTS.md route count); checker tests 23 passed |

One intermediate run (job `cae6b0c5`) failed only the first window-close rewrite, which fired the replaced debounce. The F3 extension passed in that run.

## 17. Round-2 final review: P3 test cleanup (N1–N3)

The final reviews are [Oracle A r2](phase1a-oraclea-r2.md) and [Oracle B r2](phase1a-oracleb-r2.md). B r2 closes F1 as fixed and finds no P0 or P1. Its three P3 items were addressed in tests only, with no production change. The lifecycle flush stays deferred to 1b: until then, a close within about 1 s of an edit is only as durable as at HEAD.

| Item | Change (test only) |
|---|---|
| N1: the window-close test picked the post-close debounce by "latest pending", which could pick a replaced, cancelled request and hang | `ManualSaveTimer` now records task cancellation through `withTaskCancellationHandler` and a lock-protected `CancellationRecord`. It still never resumes a cancelled sleep, so obsolete wakeups can still be delivered on purpose. The test picks the debounce whose task is not cancelled, asserts that exactly one debounce is live after close, and asserts that its task handle is not cancelled. |
| N2: "cannot re-arm after close" was only implied by a clean save | After `prepareForWindowClose()` and before the debounce fires, the test asserts that the `onPersistenceMutation` hook is installed, then sets `isDirty = true`. It asserts that the deadline and the maximum-wait task stay nil, and at the end of the test that the count of maximum-wait timer requests is unchanged. |
| N3: the writer view model in the activation regression ran real-clock save timers aimed at the file under test | The writer's save-timer sleeps use the test's `HeldSaveTimers`. After `writer.prepareForWindowClose()`, the test cancels the writer's timers with `cancelTranscriptSaveTimers`, asserts that its debounce and maximum-wait tasks are nil, and clears its override. Its held sleeps end with the others at cleanup. |

### Validation (2026-10-20, round 2 cleanup)

| Command | Result |
|---|---|
| `make dev-test FILTER="'AgentTranscriptSaveMaxWaitTests\|AgentModeChatSwitchActivationTests'"` (job `562755ec`) | 1 failure: my first N2 assertion compared against all maximum-wait requests, including the one armed and cleared before close. That was a test mistake; the assertion was changed to compare request counts from before the post-close mutation to the end of the test. N1, N3 and the other 59 tests passed. |
| The same command (job `0afef997`) | 61 tests, 0 failures: MaxWait 13 (window-close test 0.059 s) and ChatSwitchActivation 48 (save-before-activation regression 0.296 s) |
| `make dev-lint` | Clean (0/2086). No compiler warnings in either test file. |

**Not rerun after this test-only change:**
- the wider teardown suites (job `a5fa9074` covered the unchanged production code);
- packaging, app lifecycle and live acceptance.

## 18. Main-agent pre-commit verification

Both final preset identities were verified and both lanes closed without P0/P1 findings. The main agent checked conductor job `0afef997-af50-4d33-9ec3-fee9f6e17d9e`: source-validating test, completed, exit 0. After staging only this step's files, `make guardrails`, `Scripts/check-agent-context`, and `Scripts/test-check-agent-context` passed (23 checker tests; existing route-count warning). `git diff --cached --check` passed after removing whitespace-only defects in two review exports. The staged source, tests, plan-status change and evidence were inspected. Unrelated checkout changes remain unstaged. No push, live lifecycle operation, full-suite run or release validation was performed.

The first local commit attempt failed at configured 1Password SSH signing (`failed to fill whole buffer`, `failed to write commit object`); no commit was created. Main asked the owner to approve signing, authorize unsigned local commits, or leave commits pending. The staged Phase 1a snapshot is preserved; later Phase 1b edits remain unstaged.

A second signed commit attempt on 2026-10-21 used the same 17-file staged snapshot (2379 insertions, 10 deletions; cached whitespace check passed). The configured `op-ssh-sign` helper ran, then again failed with `failed to fill whole buffer` and `failed to write commit object` (Git exit 128). No commit was created; HEAD remained `be41cf0b`. Main asked again for signing readiness or explicit command-local unsigned authorization. Signing was not disabled and the later integration work was not staged. The follow-up question timed out after 300 seconds without an owner answer; unsigned commits remain unauthorized.

A later third retry during cutover remediation first verified that the staged tree was still exactly `207a0bdd3eb75b5b194c86f01c8a678e6654b374` and that cached whitespace checks passed. The normal signed commit again exited 128 with the same 1Password error. HEAD remains `be41cf0b`, the staged tree is unchanged, and no signing configuration was bypassed. This remains a commit-only blocker; independent implementation continues.
