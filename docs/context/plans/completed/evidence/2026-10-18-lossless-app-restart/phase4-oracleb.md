# Phase 4 bounded partial-source — OracleB initial review

Scope: read when the task touches lossless restart Phase 4 initial review findings for frozen tree `e876de21cca35adeda4d007930080f8ee9cb199b`.
Authority: Reference
Date: 2026-10-22

Exact explicit preset identity verified: OracleB, `7CDD523E-1D7C-47EA-98FE-D5FEA24D2D8C`. Chat `lossless-restart-phase-4-678E22`. Text-only review; reported validation was not rerun by this lane.

# Oracle Review



# Phase 4 bounded partial-source checkpoint: independent review

## Summary

The delta adds the Phase 4 source paths, all behind gates that are OFF in production:

- **Recovery actions.** Durable, idempotent action reservations with prior-launch join and supersession, plus a runner that does gate → reserve → reconcile → stop-on-verified-completion → one normal dispatch → recorded outcome.
- **History ledger and fences.** A session-v7 history ledger and import receipt with a stale-snapshot fence in `AgentSessionDataService`. A recovery-record history cursor advanced by compare-and-swap after the session commit.
- **Claude history.** A strict built-in Claude JSONL subset reader. A pre-byte dispatch baseline producer wired into the Claude write admission. A typed association preflight that, as disclosed, refuses every normal-live Claude canonical merge.
- **Cold Codex observation.** A coordinator-owned transaction that borrows the live controller or creates a temporary one, starts transport before capturing its generation, and joins cleanup.
- **Restart safely.** Hooks into the existing R4 coordinator, plus a private `repoprompt-mcp --rpce-private-relaunch-v1` helper with a closed v1 protocol.

Defaults look non-regressive:
- A plain quit or window close goes straight through `runRelaunchStep`.
- `providerHistoryRecovery` is absent when empty.
- Production qualification blocks history reads, factory creation and row actions.

The findings below are on the paths enabled behind those gates. The main ones are:
- Codex history import can duplicate rows already in the transcript.
- A verified Codex completion can still lead to a dispatch.
- Recovery actions are not connected to busy aggregation or item resolution.

I did not run any tools. Everything below comes from the supplied patch and context. Items marked **PLAUSIBLE** depend on code that was not supplied and need a quick check.

---

## P1 (should fix)

### F1: Codex history import duplicates output that is already in the transcript (CONFIRMED)

**Failure scenario**
1. The user quits during a Codex turn. Partial `agentMessage` text has already streamed and been saved under the live projector's item IDs.
2. After relaunch the user chooses Continue or Check provider history.
3. `observeRecovery` returns the expected turn with `items: [userMessage, agentMessage(partial)]`.
4. `CodexRecoveryAdapter.historyObservation` gives the agent message an ID in the new namespace `rpce-codex-history-row-v1`. The live row's ID is unrelated, so they never match.
5. `reconcileRecoveryHistory` runs `AgentProviderHistoryAssociationPreflight.check` only when `session.selectedAgent == .claudeCode`. Codex goes straight to `AgentProviderHistoryImportPlanner.plan`, which deduplicates only against its own ledger keys and deterministic IDs.

**Impact:** the transcript gets a second copy of the assistant text, labelled "Recovered from provider history". This breaks the "no identity guessing/duplicates" acceptance item. The planner's own header comment calls out this exact hazard ("it cannot recognise live rows persisted under unrelated IDs"). It happens in the most common Codex resume case, quit mid-turn.

**Evidence:** `AgentModeViewModel+RecoveryActions.swift`, `reconcileRecoveryHistory`: the Claude-only preflight block sits before `AgentProviderHistoryImportPlanner.plan(...)`. `CodexRecoveryAdapter.swift`, `historyObservation`, builds the deterministic agent-message ID.

**Smallest fix:** run the canonical-output part of the preflight for Codex too. When provider output for that turn already exists without an explicit association, import zero rows but keep `completionConfirmed`, so verified completion still suppresses dispatch.

### F2: A verified Codex completion is lost if the row commit is not confirmed, and the continuation is sent anyway (CONFIRMED)

**Failure scenario**
1. Codex verifies the expected turn is `completed`, and its items include user and agent messages. The ledger changes, so the code takes the commit path.
2. `_ = await saveSession(for:)` is called once. Then `guard session.committedHistoryImportID == plan.importID else { return .nothingImported(...) }`.
3. If that one save does not commit this receipt (it coalesces behind an in-flight debounced save, the stale fence rejects it, or there is a transient I/O error), reconcile returns `.nothingImported`.
4. `AgentRecoveryActionRunner.finishedBeforeDispatch` only stops on `.imported(confirmed)` or an `importedCompleted` outcome already on record. It therefore dispatches "RepoPrompt restarted during the previous turn…" to a turn that Codex has just proved finished.

The baseline producer's own `commitPendingBaselineReceipt` loops twice, which shows the author already expects one `saveSession` call not to always commit the current snapshot. The "session changed while its history was read" guard has the same weakness.

**Impact:** this breaks R7 step 3 ("verified EXPECTED turn completion suppresses dispatch even with unshowable rows"). The agent can repeat actions it already finished.

**Smallest fix:** decide completion before, and independently of, row persistence. When `observation.completionConfirmed` is set, return a result that carries the confirmed completion even if the rows stay pending, for example `.imported(completion: .confirmed, rowCount: 0)` or a dedicated case.

### F3: Recovery actions are not connected to busy aggregation or item resolution (CONFIRMED absence; part (b) PLAUSIBLE)

**(a) Busy aggregation.**
- R9 and the acceptance list require Resume reservations to block automatic work across shared permits, with no `runAlongsideOtherSessions` bypass.
- Nothing in the delta feeds `record.actions`, or the runner's in-flight set, into busy aggregation, the scheduler gate or the queue pumps. `AgentRecoveryActionRunner.isPerforming` is defined and never used.
- Saved-input and question items are not covered by any interruption block.
- During a cold Codex observation, the temporary runtime reserves the session. A scheduled send that fires in that window is then refused by R6 `overlapsSession` and fails, when it should have been deferred.

**(b) Item resolution.**
- After `.completed(.dispatched)` the VM clears its slot and prior-action caches.
- Nothing writes `interruption.resolution = .resumed`. Neither the catalog nor `recoveryRunActions`/`recoveryQuestionActions` checks `actions` outcomes.
- So the same run or question row keeps offering Continue or "Send answer as message". A second click gets a new action ID and a second dispatch. If unresolved interruptions feed busy aggregation, automatic work on that workspace also stays blocked indefinitely.

**Evidence:** the catalog and aggregation files are untouched. `AgentRecoveryActionRunner.swift` has no consumer of `isPerforming`. `performRecoveryResumeAction`'s `.completed` branch only clears local caches.

**Smallest fix:**
- Count an unresolved action in this launch's record, or `runner.isPerforming`, as busy for its session and workspace.
- After a `dispatched` outcome, hide continuation and answer actions for that item key, or write the existing resolution.

### F4: Continue is offered on finished runs, and the runner ignores the run's own recorded terminal evidence (PLAUSIBLE)

**Failure scenario**
1. The diff adds `recoveryRunActions(...)` to every run row, including `.outcomeTurn` and `.recoveryOnlyRun`. The code comments describe these as runs that already have a recorded outcome ("A finished run (R09) shows its recorded outcome; it holds nothing").
2. For Claude, reconcile never confirms completion.
3. `finishedBeforeDispatch` does not look at the run attempt's terminal evidence in the record.
4. So Continue on a run the record shows as completed dispatches a continuation.

**Impact:** the same R7 step 3 violation as F2. The agent is told to continue a turn that already finished.

**Evidence:** `AgentModeViewModel+RecoveryList.swift`, the `.outcomeTurn` and `.recoveryOnlyRun` cases now prepend `recoveryRunActions(...)`. `AgentRecoveryActionRunner.finishedBeforeDispatch`.

**Related:** `recoveryRunActions` never compares the item key's `transcriptResetGeneration` with `lane.binding`. A run item from before a reset could therefore be continued into the new conversation.

**Smallest fix:**
- Offer continuation actions only for genuinely interrupted, current-generation runs.
- Treat recorded terminal completion for `sourceRunAttemptID` as stop-without-dispatch.

### F5: A recovery continuation may consume the user's composer draft (PLAUSIBLE; verify `consumesComposer`)

**What the code does**
- `dispatchRecoveryContinuation` calls `submitUserTurnAdmittingRecoveryInput(text:, origin: .followUp, ...)`.
- Inside, `consumesComposer` controls whether composer attachments, tagged files and `interviewFirst` are used. The non-MCP branch also uses `session.selectedWorkflow`.
- By contrast, `dispatchRecoverySavedIntent` passes `consumesComposer: false` explicitly.

**Failure scenario (if `.followUp` counts as composer-originated)**
1. The user has an unrelated draft (text, images, tagged files) in the composer.
2. They click Continue.
3. The continuation picks up the draft's attachments and workflow, and the composer is cleared. The draft's text is replaced by the continuation text, so it is lost.

**Impact:** loss of the draft text and wrong content sent to the agent. `questionAnswerAsInput` goes through the same path.

**Smallest fix:** submit continuations as non-composer input with explicit text only (`consumesComposer: false`, no composer workflow). Add one VM-level test showing the composer survives a Continue.

---

## P2 (consider)

### R4 and relaunch helper

- **`stopUnarmed` waits up to 16 s before falling back to `terminate`.**
  - `abandon` runs before every prompt, and `prepare` failures also call `stopUnarmed`. With an unresponsive helper, the Stage A or B prompt appears roughly 8 + 16 s after the quit, while the app is frozen with no feedback.
  - Only `aborted` or the exact child's verified exit prove the helper is not armed, and an exited child cannot open anything. So the wait can be short: about 1 s for `aborted`, then `terminate()` and await the exit.
  - Evidence: `ProcessRelaunchHelper.swift`, `stopUnarmed`, `limits.parentExit + .seconds(1)`.
- **Stale `pendingShutdownReason` (PLAUSIBLE).**
  - `requestSafeRestart` sets `.safeRestart` and calls `NSApp.terminate`. `AppDelegate` resets the reason only at lines ~265–266.
  - If an earlier part of `applicationShouldTerminate` returns first (a cancelled quit confirmation, or a `quitRequestPhase` guard while a quit is already in Stage A), `.safeRestart` stays set. The next ordinary Cmd-Q, or a logout, would then relaunch the app.
  - Fix: consume the reason at the very top of `applicationShouldTerminate`, or reset it on every path that does not start a request.
- **Possible SIGPIPE when writing to an exited helper (verify).**
  - After the helper rejects `prepare`, it sends `failed` and exits. `stopUnarmed` then sends `abort` through `writer.write(contentsOf:)`.
  - If the app does not ignore SIGPIPE, or set `F_SETNOSIGPIPE` on this pipe, the app is killed during Stage A.
  - Evidence: `AppRelaunchCoordinator.swift`, the `AppRelaunchHelperProcess.spawn` send closure.
- **Misleading timeout message after the clean write.** If the deadline expires during `verifyAllStopped` or `arm` after the clean write, `finalizationFinished` shows `cleanExitAcknowledgementMessage` ("every session was stopped"), which was not proven. Use a restart-specific message.
- **The helper checks the app's main executable, not its own path.** In the helper, `ownExecutablePath` is `Bundle.main.executableURL`. For a tool inside `Contents/MacOS`, `Bundle.main` is the enclosing `.app`, so this returns the app's main executable. The bundle check still holds, but `proc_pidpath(getpid())` would check the helper itself as the plan specified.
- **A ready helper has no deadline.** The 8 s deadline only applies to `.awaitingPrepare`. This is safe because the helper never opens unless armed, but it deviates from "an unarmed helper expires within eight seconds" and should be documented.

### Cold Codex observation

- **Observation failures are not typed, and stale context does not stop the continuation.**
  - `staleContext`, `staleTransportGeneration` and the other observation errors all become `.nothingImported`, which never blocks a dispatch.
  - `recoveryActionStillCurrent` does not check the permission profile or workspace. So a policy change during observation is followed by a continuation, despite "Target/policy replacement → zero import or continuation".
  - There is also no cleanup-pending result: `await cleanup.value` is unbounded (disclosed).
- **No generation-bound request.** `performRequest` → `client.request` was not changed to refuse a transport restart. A transport that dies mid-observation may be respawned, under the recovery scope and on a borrowed controller's client. The generation check still discards the result, but the plan item is open.
- **Run-ID side effects unchecked.** `actionID` is used as the factory `runID`. Its effect on expected-PID and MCP attribution was not verified (disclosed). The same goes for "no connection policy installed".

### Persistence and compatibility

- **Whole-session decode failure.** A malformed `nativeItems` or `lastImportCommit` makes the entire `AgentSession` fail to decode, so the transcript cannot be opened. Only `dispatchBaselines` decode element by element. Apply the same verbatim-preserve treatment to the other members.
- **64-bit precision (verify).**
  - Dispatch baselines are decoded through an `AgentScheduledSendJSONValue` re-encode.
  - If that type stores numbers as `Double`, `fileInode` or `fileDevice` above 2^53 lose precision. The baseline's file identity then no longer matches, causing a spurious rescan or `baselineLost`.
  - The round-trip test uses `1 << 60`, an exact power of two, which hides this.
- **Nested unknown members make the whole record unreadable.** The record codec rejects unknown members inside action `item` and cursor `file`, so the whole recovery record becomes preserved/unreadable. That falls short of "unknown members are preserved". Keep extras there, or document the strictness.
- **Receipt and cursor drift.** The baseline overwrites `ledger.lastImportCommit`. The cursor is seeded only if none exists, so after the first import the cursor no longer equals the session receipt, contrary to its doc comment. Harmless today, but the comment or the behaviour should change.

### Actions and UI

- **An unrecorded outcome blocks the item for the rest of the launch.** After `.outcomeUnrecorded`, the VM clears the cached request. The next click gets a new action ID and hits `actionConflict`, because this launch's open action still holds the item until relaunch. Nothing retries the outcome write.
- **New-conversation path detaches early.** `continueInNewConversation` clears `providerSessionID` and the unavailable marker before admission. If submission is then blocked, the explicit choice disappears from the row.
- **Imported rows are appended at the end of the suffix.** They land after any turns sent since the restart, out of chronological order.
- **`readClaudeHistory` relies on a `nonisolated async` hop to get off the main actor.** Under `NonisolatedNonsendingByDefault` it would parse up to 64 MB on the main actor before every enabled Claude send. Consider `@concurrent` or a detached task.
- **Test gap.**
  - The runner tests inject the performers, so `dispatchRecoverySavedIntent` and `dispatchRecoveryContinuation` (normal dispatch, attachments, composer effects, Claude fallback suppression) are untested.
  - This leaves the "saved constituents/attachments dispatch once" acceptance item unverified at VM level.
  - `dispatchRecoverySavedIntent` also refuses when the bubble is already shown. Check this against R1a ("Send reuses that item ID").

---

## Recommendations

- **P0 verdict: none.** I found no realistic data-loss or security failure in the default-OFF configuration. Plain quit, window close and session v7 bytes are unchanged when the gates are off.
- **P1 verdict: 5 open, so I do not recommend committing this step yet.**
  - **Confirmed from the code shown:**
    - F1: Codex history import duplicates rows already in the transcript.
    - F2: a verified Codex completion can be lost before dispatch, so the continuation is sent anyway.
    - F3: recovery actions are not connected to busy aggregation or item resolution. Part (a) is a confirmed absence; part (b) is plausible.
  - **Plausible, need a short check of code not supplied:**
    - F4: Continue offered on finished runs, and recorded terminal evidence ignored.
    - F5: a continuation may consume the composer draft.
- **Smallest closure:**
  - Codex: apply canonical-output association with zero rows while preserving completion; return confirmed completion regardless of whether the row commit lands.
  - Count unresolved or in-flight actions as busy, and hide re-dispatching actions once an outcome is `dispatched`.
  - Restrict continuation actions to interrupted, current-generation runs, and stop on recorded terminal completion.
  - Submit continuations as non-composer input.
- **P2 items are cheap and worth taking where possible:** the 16 s abandon wait, consuming `pendingShutdownReason` early, SIGPIPE hardening, typed observation failures, and session-member decode tolerance. Otherwise list them as deferred.
- **Out of scope here:** the disclosed blocked portion (normal-live Claude canonical merge) is correctly refused, not faked, and is not a finding. Live qualification, performance, and O3 remain out of scope and pending.
