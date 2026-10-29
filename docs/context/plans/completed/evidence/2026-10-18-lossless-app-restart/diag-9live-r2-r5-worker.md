# 9-live diagnosis: R2 (Codex turn not identified), R3, R4, R5
Scope: read when the task touches Codex history matching for interrupted turns, a stale running tool row after a kill, the Continue editor's unsent text, or a Continue editor that closes by itself.
Authority: Reference
Last-verified: 2026-10-28
Covers: diagnosis only, no code changes

Build examined: `74edea8b` plus the uncommitted `AgentRecoveryActivation.production = .claudeAndCodex` (the only `Sources/` change in `git status`). Inputs:
- results: `verifier-9live-results.md`
- raw evidence: `.agent-artifacts/lossless-restart-ordinary-acceptance/cycle13/` (`g2-live-process`, `g3-actions`, `g4-p5`)
- live data, read only: `~/Library/Application Support/RepoPrompt CE/AgentRecovery/v1/sessions/*.json`, the workspace `AgentSessions/AgentSession-*.json`, the Codex rollouts and the Claude JSONL

Nothing was edited, launched or signalled. R1 (Claude `dispatching`) is out of scope.

Labels: **Verified** means read in code or data. **Inferred** means reasoned from code but not run.

---

## R2: "The interrupted Codex turn wasn't identified"

### Root cause (verified)

The Codex turn ID is never captured. Reconcile and Continue look it up in only one place, the transcript, and production code never writes it there.

1. **Where the ID comes from.** `performRecoveryResumeAction` derives `codexTurnID` from the transcript (`Sources/RepoPrompt/Features/AgentMode/ViewModels/AgentModeViewModel+RecoveryActions.swift:140-149`):
   ```swift
   codexTurnID = run.turnID.flatMap { turnID in
       session.transcript.turns.first { $0.id == turnID }?.responseSpans.last { $0.providerTurnID != nil }?.providerTurnID
   }
   ```
   It does not come from the recovery record, the run attempt, or the Codex coordinator.
2. **Where the error comes from.** `recoveryHistoryObservation` returns the message when that value is `nil` (`:1370-1373`). The same text is also the mapping for `CodexRecoveryObservationError.missingIdentity` (`:1481-1482`). That second path is not reached here, because the guard at `:1371` fires first.
3. **Nothing sets the field.**
   - `AgentTranscriptProviderResponseSpan.providerTurnID` is declared and coded at `Sources/RepoPromptAgentCore/AgentMode/Models/AgentTranscriptModels.swift:343-407`.
   - The only write outside the model is `AgentTranscriptServices.swift:3034-3035`, which copies the value from an existing span. That is itself never set.
   - A grep of `Sources/` and `Packages/` for `providerTurnID` finds no other producer. No span constructor passes `providerTurnID:`.
4. **The tests seed the field by hand.** `AgentRecoveryReconciliationTests.swift:4094` and `:4168` set `providerTurnID: "turn-c"` directly. The matcher is tested on input that production never produces.
5. **The record has no turn ID either.** `AgentRecoveryRunAttempt` (`AgentRecoveryModels.swift:738-760`) holds `runAttemptID`, `processRunID`, `transcriptTurnID` (a RepoPrompt UUID), `startedAt`, `appInstanceID`, `terminal`, `shutdown` and `extras` (`providerKind`, `runtimeRegistration`). It has no native Codex turn ID.

### Live data (verified)

| | T9 `B03D7B42…` | T14 `FC416780…` |
|---|---|---|
| Run attempt | `56D074CB…` | `B03EF618…` |
| Run-attempt fields | `transcriptTurnID`, `processRunID`, `runtimeRegistration: registry`, `providerKind: codexExec`; no provider turn | same |
| Transcript span keys | `activities, completedAt, id, lastActivityAt, lifecycle, startedAt`. `runID` and `providerTurnID` are absent; lifecycle `cancelled`. | same |
| Rollout `task_started` | `01a181a1-ff33-7e62-ba06-99d2b7ed5ff4` | `01a181a7-1bd3-7f52-a60c-61b8e01e402b` |
| Rollout `turn_aborted` | same ID, `reason: interrupted`, 08:36:46.44Z (the kill) | same ID, `reason: interrupted`, 08:36:46.44Z |
| Recorded actions | one `reconcileOnly`, `notDispatched` | four `reconcileOnly` and one `continueWithText`, all `notDispatched` with this reason |

The turn IDs were in the rollouts the whole time, so the information was recoverable. Across the workspace's session files, 3 contain the string `providerTurnID`; neither T9 nor T14 is one of them.

### Answers to the three hypotheses

- **"Never recorded": yes (verified).** No span, run attempt or record field ever receives the native turn ID.
- **"Recorded under a different attempt": no (verified).** Nothing is recorded anywhere.
- **"Matcher rejects `turn_aborted`": no for this failure (verified), but there is a second blocker behind it (inferred).**
  - The rejection happens before any read. The matcher (`CodexNativeSessionController.recoveryObservation`, `:1893`) maps an interrupted status to `.interrupted`. It does not reject it.
  - The second blocker: `recoveryItems` (`:1941-1958`) returns `nil` as soon as the turn has any item that isn't a user or agent message (`default: return nil`, `:1955`).
  - For an interrupted turn, `CodexRecoveryAdapter.historyObservation` (`CodexRecoveryAdapter.swift:102-110`) then returns `nil`, which shows as "Codex has no matching record of the interrupted turn."
  - The T9 rollout has 3 `function_call` and 3 `custom_tool_call` items. Once the ID is fixed, Reconcile on such a turn would most likely show that misleading text.
  - Continue would still go ahead. `reconcileRecoveryHistory` turns an `isUnconfirmedObservation` failure into `.nothingImported` (`AgentModeViewModel+RecoveryActions.swift:1211`), which lets a continuation follow.

### Where the ID is available (verified)

`CodexAgentModeCoordinator.installAuthoritativeCodexTurnForStart` (`CodexAgentModeCoordinator.swift:1913-1992`) has everything needed in one place:
- the native `turnID` from the turn-start event;
- `session.activeRunAttemptID`;
- the thread ID.

It stores them on `session.codexAuthoritativeActiveTurn` (`:1974`, `:1988`), which is in-memory only.

---

## R3: T7's Bash row "running dot"

### Root cause (verified): the row is not running

The red dot is the **failure** dot. It is not a running indicator.

1. **How the card picks its look.**
   - `ToolCardContainer.headerLeadingContent` draws `StatusDot(status:)` (`ToolCardContainer.swift:254-269`).
   - `StatusDot` shows a grey `ProgressView` spinner only for `.running`. Every other status is a filled circle in the status color (`ToolCardStatus.swift:66-80`).
   - The card background is `errorBackground` only for `.failure` (`ToolCardContainer.swift:290-297`).
2. **The screenshot matches failure exactly.** Pixels sampled from `cycle13/g2-live-process/shots/F1-T7-banner-before-itstopped.png`:

   | Element | Sampled RGB | Matches |
   |---|---|---|
   | Row | (242, 217, 217) | `BubbleColors.errorBackground` light (0.95, 0.85, 0.85) |
   | Dot | (179, 26, 25) | `errorRed` light (0.7, 0.1, 0.1) |

3. **A truly running row looks different.** The `echo go; sleep 60` row in `g4-p5/shots/sa-esc-with-running-turn-montage-r1-r4.png` is grey with a spinner.
4. **Why the row is failure-red after relaunch.**
   - Cold restore cancels every tool execution left `pending` or `running` in a closed turn. `sanitizeColdRestoredActivity` (`AgentSessionRestoreSupport.swift:683-705`) sets `status = .cancelled`, `toolIsError = true` and a `{"status":"cancelled","reason":"restored_without_live_run",…}` result.
   - `BashResultCard` then resolves to `.failure`, because `toolIsError == true` (`ToolResultStatusResolver.swift:15`).
   - `ToolCardStatus.fromTranscriptStatus` also maps `.cancelled` to `.failure` (`ToolCardStatus.swift:21`).
5. **A Claude row can't stay "running" through the live-bash path.** Live bash execution state (`agentLiveBashExecutionByItemID`, PID polling) is built only by the Codex coordinator. That is the Step 7-minor path (`rebuildLiveBashExecutionState`, `pollBashLiveness`). The Step 7-minor rule (settle as `finished` only when the current controller owns the execution) therefore never applies to Claude. Claude rows are closed by the cold-restore sanitizer alone. Verified for which files reference live-bash state (grep); inferred that no other Claude path re-arms a row.

So R3 is a misreading of the UI, but it does reveal a UX gap. An interrupted command looks the same as a failed one: a red dot, no "interrupted" wording, and no command subtitle, because the summary-only row kept no `command`.

### Open anomaly (verified data, cause not traced)

T7's session file now stores that Bash activity (`C15E1353…`, execution `6f9ecc28…`) as `{"status":"success","summary_only":true,"summary_text":"bash • success","type":"commandExecution"}`. That file was saved at 16:56, after the g4 P5RUN sends.

- At 15:54 and 15:56 the same row rendered as failure, which means `cancelled`.
- Re-saving a cancelled row should keep `cancelled`: `derivedStatusWord` reads the result's status word (`AgentToolResultPersistencePolicy.swift:1915-1946`).
- Something between 15:56 and 16:56 rewrote the row to `success`. No recovery import ran on T7 (its record has no actions).
- The Claude JSONL has Claude's own synthetic `tool_result` for `toolu_01WD…`, with `is_error: true` ("Tool call interrupted…"), at 08:56:09Z. That would give `failed`, not `success`.
- This looks like the Step 7-minor class of bug (an unowned row settling as success) on another path. It needs a separate trace. I didn't find it in the time available.

---

## R4: refused Continue (verified, both halves)

### (a) The detail lacks "The message you typed to continue it was not sent."

The note is computed correctly but never displayed.

- **The fact is set.** `AgentRecoveryRecord.hasUnsentContinuation(for:)` (`AgentRecoveryActionModels.swift:329-341`) is true for K3 `66827DF5…`, T11 and T14:
  - the latest action with text is `continueWithText` with outcome `notDispatched`;
  - its `plannedUserItemID` is in no intent;
  - no later action resolves it (the later `reconcileOnly` is `notDispatched`).
- **The catalog uses it.** It copies the fact (`AgentRecoveryCatalog.swift:462`), which is why the row moved to Needs action (`:325`).
- **The detail gets the note.** `recoveryListRow` appends it (`AgentModeViewModel+RecoveryList.swift:233`, `:247`, `:264` through `recoveryRunUnsentNote`, `:447-453`).
- **But the error hides it.** The refusal reason is stored as the row's shared action state `.failed(reason)`:
  - `performRecoveryListContinuation` → `setCatalogActionState(failure.map { .failed($0) })` (`AgentModeViewModel+RecoveryList.swift:795-814`; also `performRecoveryListAction`, `:790`);
  - the row shows that as `error` (`:132-134`, `:189`).
- **The row draws one or the other.** `AgentRecoveryListRow` draws `Text(row.error ?? row.detail)` (`AgentRecoveryListBanner.swift:114`). While the error is set, the detail and its note are never drawn.
- **The error stays.** It is only replaced by the next action on that row. A later Reconcile sets a new `.failed` with the same "No history position…" text, so the note stays hidden for the rest of the launch.
- **The detail can't be reached another way.** Run rows have no `text` unless they have delegated children, so they offer no View button and `AgentRecoveryRowViewer` (`:276`) can't show the detail either.
- **Inferred: the note may be cut off even without an error.** The detail is `.lineLimit(2)` at 10 pt (`:117`). The base run detail already fills about two lines in the 620-pt sheet (screenshot `V6C-T11-first-attempt-popover-vanished.png`), so the appended note would probably be truncated.

### (b) Reopening Continue… shows the default text

- **Every open loads the default.** `recoveryListRow` always sets `continuationText: continues ? Self.recoveryContinueDefaultText : nil` (`AgentModeViewModel+RecoveryList.swift:192`). It never reads the item's last unsent action text.
- **The editor copies that value.** On each Continue… press, the editor copies it into its `@State continuationDraft` (`AgentRecoveryListBanner.swift:138-140`).
- **Where the typed text survives.**
  - Only in the record's action (`actions[].text`, for example K3: `'RPCE_VERIFY_V6T_20261028 continue: reply OK'`).
  - In the in-memory `recoveryActionRequestsBySlot`, but that cache is cleared on every `.completed` and `.refused` result (`AgentModeViewModel+RecoveryActions.swift:257-283`), so it is gone after a refusal.

---

## R5: Continue… editor closed by itself (cause not determined)

### What the editor is (verified)

- **Presentation.** A plain SwiftUI `.popover(isPresented:)` on the Continue… button, inside `ForEach(row.actions, id: \.self)` (`AgentRecoveryListBanner.swift:134-152`). Its binding is `editingContinuation == action`.
- **Text storage.** The text is the row view's `@State continuationDraft` (`:101`).
- **Not the native popover.** The View popover's native code and its monitors (`AgentRecoveryNativePopover.swift:341-358`: local mouse/key monitor, `willResignActive` close) are installed only while a View popover is open. They don't touch this SwiftUI popover.
- **The T11 attempt was in the sheet.** It ran from the Needs Attention sheet (`V6C-T11-first-attempt-popover-vanished.png`). There, rows sit in `LazyVStack` → `ForEach(needsActionRows)` / `ForEach(informationalRows)` (`AgentRecoveryNeedsAttentionSheet.swift:67`, `:85`, `:114`).
- **Every catalog change re-evaluates the sheet.** `.onReceive` of `agentRecoveryCatalogDidChange` and `agentRecoveryCoordinatorDidChange` bumps `revision` (`:150-157`).
- **No timer.** There is no recovery timer: no `Task.sleep` or `Timer` in `Runtime/Recovery` outside the composer and question persistence debouncers. Re-renders are event-driven: action states, record writes, hold changes, runtime-ownership changes.

### Paths that close it without user action

| # | Path | Mechanism | Assessment |
|---|---|---|---|
| 1 | The row changes section | Its attention flips between `informational` and `needsAction` (`AgentRecoveryCatalog.swift:325`). The row moves to the other `ForEach`, its view identity changes, and its `@State` (`editingContinuation`, `continuationDraft`) is destroyed, which removes the popover. A8 showed this move happens while an action holds the item (`hasRecoveryActionHold`). | Verified mechanism. No trigger is evidenced at 16:17 (g3 notes show no other action running). |
| 2 | The Continue… button disappears | `.continueTurn` drops out of `row.actions` and its popover goes with the button. `recoveryRunActions` needs: the session active in this window (`isActive ? activeSession : nil`), `continuable` (`status.isInterruption`, `!resolvedByAction`, `!runNeverHandedOff`, `sameGeneration`) and `recoveryActionRunner.isAvailable`. | Verified mechanism. No trigger is evidenced. |
| 3 | The row ID changes | The ID is stable (`turn-<key>-<turnID>` or `run-<key>-<attemptID>`, `AgentRecoveryCatalog.swift:604-643`; the paused prefix applies only to banner rows). | Unlikely. |
| 4 | The sheet itself is re-presented or dismissed | Not seen: the sheet stayed. | Unlikely. |
| 5 | AppKit's transient popover behavior | SwiftUI's macOS popover is a transient `NSPopover`. It closes on any interaction outside it, which includes the app losing active status (another app or the harness taking focus). The T14 editor survived about 1 min, which fits a harness- or focus-dependent trigger. | Plausible (inferred). |

### Is the typed text kept anywhere? (verified)

No.
- The draft is view `@State`, which is destroyed with the view (paths 1 to 3). Even when the view survives (path 5), the next Continue… press overwrites it with the default (`:139`).
- Nothing reaches the record before Send. That matches the record: T11 shows no action for the 16:17 attempt.

### What would decide it

The g3 run captured no log stream. The next live run should do two things:
- run `log stream` filtered to the app;
- log in the app (DEBUG diagnostics only) when the row's `editingContinuation` binding is set to nil, and from where: the popover set closure versus view teardown (`onDisappear` of the row).

---

## Fix directions (not implemented)

| Item | Smallest correct direction | Risk |
|---|---|---|
| R2 | In `installAuthoritativeCodexTurnForStart`, when a turn becomes authoritative for `runAttemptID` (`CodexAgentModeCoordinator.swift:1974`, `:1988`), persist the native turn ID as run-start evidence. Two places: (a) a new forward-compatible `extras` member on the run attempt (e.g. `providerTurnID`, written once, the same pattern as `providerKind`); (b) optionally the span's `providerTurnID`. Make `performRecoveryResumeAction` prefer the run attempt's recorded ID (`AgentModeViewModel+RecoveryActions.swift:147`). Add a test that drives the real turn-start path instead of seeding `providerTurnID`. | Low to medium. Steered or compaction turns change the authoritative turn mid-attempt, so record the **last** authoritative user turn (or all of them) and decide which one Reconcile expects. The record write is another await on the turn-start path, so it must not block event handling. Runs from before the fix stay unidentifiable (expected). |
| R2, follow-on | Change the unconfirmed-observation text for a turn that was **found** but has unsupported items (tools) to say so, instead of "no matching record". | Low; text only. Whether tool-bearing interrupted turns should import anything is a separate design question. |
| R3 | No stuck-running defect. Optional UX: show a cold-restore-cancelled row as "interrupted" (a neutral or orange dot plus label) instead of `.failure`, and keep `command` in the summary-only bash row. Separately, trace the 15:56→16:56 rewrite of T7's cancelled row to `success`. | UX change: low (mapping only), but `fromTranscriptStatus(.cancelled)` is shared by user-Stop rows, so scope it to restore-cancelled rows (`reason: restored_without_live_run`). The `success` rewrite is unknown until traced. |
| R4a | In `AgentRecoveryListRow`, show the error **with** the detail (error line plus detail) rather than `error ?? detail`. Or, for a refused continuation, append `recoveryListUnsentContinuationNote` to the failure message. Also relax `lineLimit(2)`, or put the note first, so it isn't truncated. | Low. The same row view is used in the banner, whose rows have a fixed height (`rowHeight` 52, `AgentRecoveryListBanner.swift:16`), so adding a line needs a height check there. |
| R4b | When `hasUnsentContinuation` is true for the item, set `continuationText` to that action's text (`record.actions.last { itemKey == key && text non-empty }.text`) instead of the default at `AgentModeViewModel+RecoveryList.swift:192`. This needs the text in `AgentRecoveryCatalogActionFacts` (e.g. `unsentContinuationText`) or a record read. | Low. The duplicate-send guard is the action-request slot cache, keyed by text; reusing the text yields a new action ID after a refusal (the cache was cleared), which is the intended "new explicit choice". |
| R5 | Make the draft survive the view: keep the editor's text per row ID in the view model (or `@SceneStorage`-like shared state), and have Continue… load it before the default. Do this together with R4b. Instrument the dismissal source before changing presentation. If path 5 is confirmed, present the editor through the existing native popover wrapper (`.applicationDefined` behavior), which closes only on explicit outside clicks. | Low for draft retention. Medium for moving the editor to the native popover: it inherits the P5 key-focus issues (R6), and a text editor needs the popover to take key. |

## Not done

- No R1 work.
- No live repro of R5.
- The cause of the R3 `success` rewrite was not traced.
- No tests run (diagnosis only).
