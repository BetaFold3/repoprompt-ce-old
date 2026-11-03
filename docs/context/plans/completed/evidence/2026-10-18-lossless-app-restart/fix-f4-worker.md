# Step 7-F4 worker report
Scope: read when the task touches lossless restart Step 7-F4 (/compact after a cancelled Codex compaction) implementation or review evidence.
Authority: Reference
Last-verified: 2026-10-26

Base `4ce78bde`. Working tree only: nothing staged or committed. Review diff: `prompt-exports/restart-fixes/fix-f4-review.diff` (local only).

## Diagnosis

The spec gave two explanations for the second `/compact` printing "Start a Codex conversation before using /compact." The cancel → `/compact` unit test separates them.

- **(b) "After a cancel-detach, readiness never re-establishes a thread until a normal turn runs": refuted.**
  - Cancel-detach keeps `codexConversationID`/`codexRolloutPath`, marks reconnect, and clears the controller and `runID` (`CodexAgentModeCoordinator.swift:10247` at HEAD; `:10336` now).
  - `/compact` passes the availability check because thread metadata exists (`:1587-1589` at HEAD). It sets `codexNeedsReconnect` and calls `ensureCodexNativeSession`.
  - `ensureCodexNativeSession` creates a fresh controller (`prepareCodexController`, `:5163` now) and resumes the saved thread through `startOrResume`. The real controller's `hasActiveThread` is `threadID != nil` (`CodexNativeSessionController.swift:717-719`), so it is true once the resume applies.
  - `testCancelDetachThenCompactResumesSameThreadAndRequestsCompaction` passed **on the unmodified logic**: the same thread "thread" was resumed on the fresh controller, and `compactThread` ran once.
- **(a) A race with concurrent readiness/admission: supported, and it yields exactly the observed text.**
  - The old post-readiness check (`:1659-1662` at HEAD) reported "Start a Codex conversation" for *any* non-ready result after `ensureCodexNativeSession`, even with the saved thread intact.
  - Pre-fix run (6 tests, 3 failures + 1 hazard):
    - `testControllerReplacedDuringReadiness…`: an MCP-style permission change makes a concurrent `ensureCodexNativeSession` replace the controller while `/compact`'s resume is suspended. `/compact`'s late success is discarded by the existing slot fence (`codexControllerSlotHolds`, `:5304` now). The old check then sees the successor with no thread yet and prints "Start a Codex conversation…".
    - `testFailedReconnect…`: a genuine resume failure also printed "Start a Codex conversation…".
    - `testConcurrentSubmissionDuringReadiness…`: a send admitted while `/compact` waited on the shared resume. The old code **requested compaction over the admitted turn**. It returned `succeeded("Requested Codex context compaction.")`, and the test took 3.4 s against 0.2 s after the fix.
  - This matches the live timing: the second error came 182 ms after the MCP-sent K3 arrived, and K3 started a run on the same session about 1 s later. Which concurrent mutation hit live is still inference. Candidates: an MCP control/permission/task-label change that recycles the controller, or K3's own start.
- **Production-only path not covered by unit tests.** With `shouldManageCodexTooling` (production), idle readiness first acquires the global MCP bootstrap lease (`:5202-5210` now). The controller is created *before* the lease (`:5163`), so a lease that fails to acquire also leaves a thread-less controller and the old misleading text. No test VM enables `shouldManageCodexTooling`, so this sub-path was traced only.

## Fix (`CodexAgentModeCoordinator.swift`)

> **Superseded in part by "Review fixes (round 1)" and "Re-review fixes (round 1)" below.** The supersession check no longer compares `activeRunOwnership` (generation and active run state only). The in-flight mark is now taken at controller installation (covering the lease wait) *and* at the start site. Read those sections for the current design.

- **Distinct text and diagnostics for each source.**
  - Availability (no thread metadata) keeps "Start a Codex conversation before using /compact."
  - The post-readiness source now returns one of:
    - `compactReconnectFailedMessage`: saved thread kept, reconnect didn't complete. Covers a start failure, a quiet cancellation, a startup gate that refused, or no controller.
    - `compactReconnectInProgressMessage`: the slot's controller has a native start/resume in flight for another owner.
  - Every refusal logs a fixed reason through an always-on `Logger(subsystem: "com.repoprompt.agents", category: "CodexSlashCommand")` at `.notice`, with tab and agent-session IDs only and no user content. Reasons: `no_conversation`, `run_active`, `not_codex`, `turn_started_during_readiness`, `session_changed_during_readiness`, `<availability>_after_readiness`, `reconnect_in_progress`, `reconnect_failed_no_controller`, `reconnect_failed_no_thread`.
- **Readiness coordinated at the session/controller authority. No sleeps, no retries.**
  - Before the first suspension, `/compact` captures `runAttemptGeneration`, `activeRunOwnership` and `activeAgentSessionID`.
  - After `ensureCodexNativeSession` it rechecks, in order:
    1. Generation, ownership or an active run state changed → refuse with `compactTurnStartedDuringReconnectMessage`.
    2. The agent session changed → `compactSessionChangedDuringReconnectMessage`.
    3. Eligibility: the full availability check again (agent, profile, metadata, run state).
    4. Controller and thread readiness.
  - From the last check to `beginCodexCompaction` there is no suspension, so a later submission sees `runState == .running` and the compact turn kind. Compaction can't overlap a newly admitted turn.
- **"Reconnect in progress" authority.** A counted `codexStartsInFlight: [ObjectIdentifier: Int]` is marked/cleared (`defer`) around the attempt's own `startCodexNativeSession` and the managed-auth recovered start. It only feeds the `/compact` refusal classification; no other behaviour reads it.
- **Unchanged:**
  - reconnect metadata retention;
  - the cancel-detach teardown;
  - the start-attempt cancellation, late-success and ownership fences;
  - `discardCancelledCodexNativeSessionStart`;
  - the lease path;
  - the Return-vs-Stop composer behaviour (no view or VM changes);
  - the `/compact` start-failure catch block and the "Requested Codex context compaction." wording.

## Tests (new `Tests/RepoPromptTests/AgentMode/Codex/CodexCompactReadinessTests.swift`)

> **Superseded by "Review fixes (round 1)" below.** The suite now has 8 tests. `testCancelDetachThenCompact…` was replaced by `testCancelledCompactionThenCompactResumesSameThreadAndRequestsCompaction`, which cancels a real `/compact` through the view model's Stop path. The table and counts below describe the initial (reviewed) state.

The fake `CompactReadinessController` binds a thread only when `startOrResume` returns, like the real controller. It has an optional multi-waiter resume gate and an optional resume error. Setup reuses `AgentModeViewModel(codexControllerFactory:)`, `test_codexCoordinator`, `test_initializeRunService` and `test_installPersistentSessionBinding`. No new infrastructure.

| Test | Covers | Pre-fix |
|---|---|---|
| `testCancelDetachThenCompactResumesSameThreadAndRequestsCompaction` | cancel → `/compact` | pass (refutes b) |
| `testDelayedReconnectCompactsOnceAfterResume` | persisted thread + detached controller + delayed reconnect | pass |
| `testFailedReconnectReportsReconnectFailureNotMissingConversation` | failed reconnect keeps thread, distinct text | fail (old text) |
| `testControllerReplacedDuringReadinessReportsReconnectInProgress` | controller replacement during readiness; late success can't retake the slot; `/compact` succeeds on the successor once ready | fail (old text; earlier direct-swap variant) |
| `testConcurrentSubmissionDuringReadinessIsNotOverlappedByCompaction` | concurrent submission with `/compact`: turn starts once, no compaction | fail (compacted over the turn) |
| `testNoThreadMetadataKeepsNoConversationMessage` | "no conversation" source unchanged | pass |

- **Mutation check.** I disabled the in-flight classification and the supersession check, ran the suite (2 expected failures: the replacement and concurrent tests), then restored the source from a backup. The concurrent test still fails with only the supersession check removed, because the availability recheck then returns "Wait for the current Codex turn…".
- **Limitation.** The concurrent-submission test uses an untracked direct `sendCodexNativeMessage` (admission `.inactive`), not a durable MCP intent through the run service. The MCP origin only matters for the active-run drain, which doesn't apply to a cold start.

## Validation

- `make dev-build`: completed successfully, exit 0.
- `make dev-test FILTER="CodexCompactReadinessTests"`: pre-fix 6 tests, 5 assertion failures in 3 tests (diagnosis); post-fix 6/6 pass (run twice, also after the lint fix).
- `make dev-test FILTER="'CodexCompactReadinessTests|AgentModeStopSubmitTargetTests|CodexFallbackFIFOTests|CodexNativeResumeLifecycleTests|CodexAgentModeCoordinatorLivenessTests|CodexAgentModeCoordinatorHiddenToolBoundaryTests|CodexGoalSupportDefaultTests|ClaudeCompactionRunningStatusTests|AgentModeRunServiceLifecycleTests'"`: 408 tests, 0 failures. Per suite: RunServiceLifecycle 221, StopSubmitTarget 25, ClaudeCompactionRunningStatus 8, HiddenToolBoundary 4, Liveness 55, CompactReadiness 6, FallbackFIFO 38, GoalSupportDefault 20, NativeResumeLifecycle 31.
- `make dev-lint`: first run failed on `redundantThrows` in the new tests; fixed. Second run completed successfully, exit 0.
- `make guardrails`: exit 0. The agent-context check printed its existing AGENTS.md route-count warning.
- `Scripts/check-agent-context` (run after this report was created): 1 error, `[reachability]` orphan for this report. It clears once the spec's Step 7-F4 status line links `evidence/2026-10-18-lossless-app-restart/fix-f4-worker.md`, as was done for F2 and F7. I didn't make that edit because I was told not to touch the spec.

**Not run:**
- full `make dev-test` / `dev-test-parallel`;
- `make dev-format` (deliberately);
- the production lease path (`shouldManageCodexTooling: true`) under test;
- live app or real Codex CLI;
- gitleaks (no push).

## Composer message typed during compaction (report only, not fixed)

Inference from code, not verified against logs:
- While compaction runs, `runState == .running` and `beginNativeSlashControlProgressIfNeeded` applies only to `/goal`. No `AgentInputBar.sendMessage()` guard is specific to compaction.
- Return passes the view guards and claims normally, unless a prior attempt still holds the latch (`local_attempt_latched`). The VM route then goes to `sendCodexNativeMessage` with `wasRunAlreadyActive`. The dispatch plan is `.fallback(.nonSteerableTurn(kind: .compact))`, or `.activeWithoutAuthoritativeIdentity` before `turn/started`, so the message is queued as a Codex fallback.
- The later Stop runs `drainCodexTerminalBuffersForCancellation`, which calls `abandonCodexFallbackQueue(reason: "Codex queued follow-up was cancelled with the active run.")` and restores the manual draft.
- So most likely **no ComposerSubmit guard fired**: the message was accepted as a queued follow-up and then cancelled by the Stop. The alternative is `local_attempt_latched`, if Return was pressed while an earlier attempt was still in flight.
- The new `ComposerSubmit` log plus the fallback-abandon notice in the transcript would tell them apart in a re-run.

## Open questions

- In production, idle `/compact` readiness goes through the lease path. The outer ensure calls `lease.failAndRelease()` because `effectiveRunState` is idle (`:5232` now), so the run's MCP policy is revoked even when the resume succeeded. Compaction doesn't need MCP routing, and the next turn forces a reconnect for the missing route, so this is pre-existing and harmless here. Worth a look if `/compact` should keep the route warm.
- Should "reconnect in progress" wait for the in-flight owner's settlement (single-flight join) instead of refusing? I refused, per "no sleeps, no blind retries". A join would need a settlement signal the coordinator doesn't have today.
- The exact live mutation that replaced or invalidated the controller during the K3 race is not proven. A live re-run with the new `CodexSlashCommand` reasons would name it.

## Review fixes (round 1)

Reviews: [OracleA](fix-f4-review-oraclea.md), [OracleB](fix-f4-review-oracleb.md). Line numbers are the working tree after this round.

- **B F4-R1 (stale ownership read as "turn started").**
  - Fixed by dropping the ownership comparison. The supersession check is now `runAttemptGeneration != captured || runState.isActive` (`CodexAgentModeCoordinator.swift:1700`).
  - Why that's enough: `beginRunAttempt` is the only writer of `runAttemptGeneration` (`AgentTabSession.swift:1980`, `&+= 1` on every begin). It's also the only creator of a session ownership (`runLifecycleTracker.begin` at `:1998`). The other `runLifecycleTracker.begin` call is in the ContextBuilder view model's own tracker. So any new attempt advances the generation, and an older attempt merely ending no longer refuses.
  - Reachability by production Stop: **not reachable.** `AgentModeViewModel.cancelAgentRun` (`AgentModeViewModel.swift:20586-20604`) → `AgentModeRunService.cancelRun` → `terminalCommitBarrier.commit`. There, `prepareProviderState` (the Codex detach), `runState = terminalState` and `endRunAttempt(ifCurrent:)` run synchronously with no suspension between them (`AgentRunTerminalCommitBarrier.swift:324-338`). So a Stop never leaves ownership set while the run is idle. The one other attempt-ending site in the coordinator (`:1743`, `/compact` start failure) also ends the attempt before setting idle.
- **B F4-R2 (lease/recovered start touching run identity).**
  - Confirmed by code reading: neither path changes generation, ownership or the bound session. The coordinator's only `beginRunAttempt`/`endRunAttempt` calls are `:1743` (compaction start failure), `:1899` (`beginCodexCompaction`) and `:2869` (fallback successor), all outside `ensureCodexNativeSession`.
  - The lease path (`:5204-5240`) calls `makeCodexRunLease` (`:3996`), which only binds the pending Oracle review context (`AgentModeViewModel+AgentSessionHost.swift:7-8`). It also calls `MCPBootstrapLease.acquire/failAndRelease/releaseWhenRouted` (an actor with no session reference, `MCPBootstrapLease.swift`), `ensureMCPServerEnabledForThreadStart` (MCP server enabler only, `AgentModeViewModel.swift:15255-15257`) and the recursive ensure.
  - The managed-auth recovered start (`:5349-5430`) calls `authRecovery.refreshManagedAccount`, `setRunningStatus`, `invalidateCodexControllerForReconnect(preserveRunID: true)` (`:5386`; the controller slot, reconnect flag and fallback queue only), `prepareCodexController` and `startCodexNativeSession`.
  - None of these set `activeAgentSessionID` or bind a session. `failCodexStartupForWorkspaceResolution` finalizes only when an ownership already exists.
  - Lease-enabled test **not added**. It would need `shouldManageCodexTooling: true`, with the real `MCPBootstrapLease` against the run coordinator, the global connection gate and the MCP server enabler. No test VM uses that today, so it isn't a cheap stub.
- **B F4-R3 (cancel test cancelled no compaction).**
  - Reworked as `testCancelledCompactionThenCompactResumesSameThreadAndRequestsCompaction`. A real `/compact` runs on a resumed thread; the test asserts `codexPendingTurnKind == .compact` and an active run. It then cancels through `viewModel.cancelAgentRun(tabID:cause: .userCancel, completion: .terminalTeardownCompleted)`, the run-service and barrier Stop path. The test asserts no ownership, a detached controller, the reconnect flag and the kept thread. A second `/compact` resumes "thread" on a fresh controller and compacts once.
  - **The diagnosis still holds:** on the HEAD coordinator (pre-fix logic plus only the message constants, swapped in temporarily and restored), this test and the delayed-reconnect test pass (2/2). (b) is refuted for a cancelled compaction too.
- **B F4-R4 (concurrent test reused one controller).**
  - The factory now offers two distinct controllers (`fresh`, `other`) sharing the gate. Assertions: the send started "K3" on `fresh`; `other` was never resumed or started; neither compacted; `fresh` keeps the slot.
  - Code fact: production readiness creates a controller only for an empty slot (`prepareCodexController`, `if session.codexController == nil` at `:5054`). So a concurrent send reuses the slot's controller, as the test shows; the distinct-controller case is the replacement test.
  - Still not routed through the run service as a durable MCP intent (unchanged limitation).
- **A F4-R1 (guards not tested independently).** Added:
  - `testRunStartedAndFinishedDuringReadinessRefusesCompaction`: a run attempt begins and ends while the reconnect is suspended, so the run is idle again. Result: "turn started" refusal, zero compactions.
  - `testAgentSessionRebindDuringReadinessRefusesCompaction`: `test_installPersistentSessionBinding` rebinds to another agent session mid-readiness. Result: "session changed" refusal, zero compactions.
  - Mutation (generation check reduced to `runState.isActive`, session check disabled; restored afterwards): both tests fail, 4 assertion failures. The first compacted; the second succeeded.
- **B F4-R5 (in-progress mark missed the lease wait).**
  - The mark is now taken in `ensureCodexNativeSession` right after `prepareCodexController`, whenever a transport start is required (`:5168`). It is cleared by a function-scope `defer`, so it covers the startup lease wait, the recursive policy-installed pass and the start itself on every exit path. The redundant start-site mark was removed. The managed-auth recovered-controller mark stays (`:5393`).
  - The mark token now holds its controller strongly, so the `ObjectIdentifier` can't be reused if that controller is invalidated and released while the mark is live (for example, via the missing-route recursion).
  - `ensureCodexNativeSession` is the only caller of the session-scoped `startCodexNativeSession`, so no other start site is uncovered.
  - Not covered by a lease-path test (see R2).
- **B F4-R6 (retry after failed reconnect).**
  - The failed-reconnect test now retries: the fake fails its first resume and succeeds on the next. The second `/compact` succeeds, and the same controller resumes "thread" twice.
  - Code fact: a `.other` start failure only marks reconnect and leaves the controller in the slot, so the retry reuses that controller rather than a new factory one.
- **Deferred:**
  - B F4-R7: duplicated availability-reason mapping.
  - B F4-R8: second logging channel; kept the always-on `Logger` plus the debug `logCodex`.
  - B F4-R9: link this report from the spec's Step 7-F4 status line; this is the main agent's spec edit.

**Validation (round 1):**
- `make dev-build`: completed successfully, exit 0.
- `make dev-test FILTER="CodexCompactReadinessTests"`: 8/8 pass.
- The same 9-suite focused filter as above: 410 tests, 0 failures. CompactReadiness 8, RunServiceLifecycle 221, StopSubmitTarget 25, ClaudeCompactionRunningStatus 8, HiddenToolBoundary 4, Liveness 55, FallbackFIFO 38, GoalSupportDefault 20, NativeResumeLifecycle 31.
- `make dev-lint`: completed successfully, exit 0.
- Not run: full test lane, a lease-enabled test, live app.

## Re-review fixes (round 1)

Re-review: [OracleB r1](fix-f4-review-oracleb-r1.md). No P0/P1 remained after re-review.

- **F4-RR1.** Restored the start-site mark on the attempt's own `startController` (`markCodexStartInFlight(startController)` plus `defer`, just before the `startCodexNativeSession` `do`). It sits alongside the pass-entry mark taken after `prepareCodexController`. Marks are counted, so marking the same controller twice is harmless, and the controller actually started is always marked.
- **F4-RR2.** Closed with no code change: teardown never relies on `deinit`.
  - `invalidateCodexControllerForReconnect` calls `retireCodexController(controllerToShutdown, session:)` (`CodexAgentModeCoordinator.swift:4706`), which calls `shutdown()` explicitly (`:4840` unstructured, or `:4844` via `retainRuntimeRetirement`).
  - Stop's teardown closure from `prepareCodexCancellationTeardown` calls `await controller.shutdown()` (`:10385`), and `shutdownCodexSession` does too (`:10433`).
  - So keeping a released controller alive in the strong mark only delays its deallocation, not its process or stream teardown. The strong reference stays.
- **F4-RR3.** Marked the original "Fix" and "Tests" sections as superseded by the review sections.
- **Deferred:** F4-RR4 (the R6 retry test can't tell a reused controller from a new one) and F4-RR5.

**Validation (re-review round 1):** `make dev-build`; `make dev-test FILTER="CodexCompactReadinessTests"`; the same 9-suite focused filter; `make dev-lint`. All three passed: dev-build OK; `CodexCompactReadinessTests` 8/8; 9-suite filter 410 tests, 0 failures; lint OK.
