# 9-live fix 2: recovery list (continuation text, refusal note, survivor order, send-refusal notice)
Scope: read when the task touches the recovery list's Continue editor text, refused-continuation row text, the order of surviving-process items, or the composer's send-refusal notice.
Authority: Reference
Last-verified: 2026-10-28
Covers: the step's source and test changes

This report covers Step 2 of `plan-9live-fixes-oracled.md` ("Recovery list: R4a, R4b, R5, R7, V1 notice"). Background is in `diag-9live-r2-r5-worker.md` (R4, R5) and `diag-9live-r1-worker.md` (V1, R7). Nothing was committed or staged. `AgentRecoveryNativePopover.swift` and its tests were not touched; they belong to another worker, and their diff in `git status` is theirs.

## Changes

Line numbers are for the working tree after the change.

### R4b: Continue reopens with the unsent typed text

- `Sources/RepoPromptAgentCore/AgentMode/Models/AgentRecoveryActionModels.swift:329-350`
  - New `unsentContinuationText(for:)`, which holds the existing rule.
  - `hasUnsentContinuation(for:)` is now `unsentContinuationText(for:) != nil`. The two can't disagree: the text comes from the same action the rule selects (the latest action with non-empty text that ended unresolved and is carried by no saved intent, with no later resolving action).
- `Sources/RepoPromptAgentCore/AgentMode/Runtime/Recovery/AgentRecoveryCatalog.swift:207-211, 230, 239`
  - `AgentRecoveryCatalogActionFacts.unsentContinuationText: String?`, plus its init parameter.
- `AgentRecoveryCatalog.swift:470-471`
  - The projection sets `unsentContinuationText` from the record, then sets `hasUnsentContinuation = unsentContinuationText != nil`.

### R4b + R5: the typed text survives the editor closing

- `Sources/RepoPrompt/Features/AgentMode/ViewModels/AgentModeViewModel.swift:688-692`
  - New `recoveryContinuationDraftsByRowID: [String: String]`.
  - It is a plain, unpublished var on the `ObservableObject`, so a keystroke doesn't redraw the composer.
  - It is in memory only and per window.
- `Sources/RepoPrompt/Features/AgentMode/ViewModels/AgentModeViewModel+RecoveryList.swift`
  - `:143-147` `recoveryContinuationOpeningText(draft:unsentText:)` returns `draft ?? unsentText ?? recoveryContinueDefaultText`.
  - `:150-157` `recoveryContinuationDraft(rowID:)` and `updateRecoveryContinuationDraft(rowID:text:)`. Writing a draft doesn't refresh the UI or write to disk.
  - `:223-229` `recoveryListRow` sets `continuationText` from that precedence. It used to be always the default.
  - `:844-856` `performRecoveryListContinuation` passes a `RecoveryResumeActionReport`. It removes the draft only when the text was handed off and the draft still equals the sent text. It keeps the draft on every other result.
  - `:860-869` `recoveryContinuationWasHandedOff(_:)` is true only for `.completed(.dispatched, _)` and `.outcomeUnrecorded(.dispatched, _)`.
- `Sources/RepoPrompt/Features/AgentMode/ViewModels/UI/AgentComposerUIModels.swift:628-631`
  - `AgentRecoveryListActions` gains `continuationDraft(rowID)` (read) and `updateContinuationDraft(rowID, text)` (write). Both default to no-ops.
- `Sources/RepoPrompt/Features/AgentMode/Views/Components/AgentRecoveryListBanner.swift`
  - `:140-144` Continue… opens with `actions.continuationDraft(row.id) ?? row.continuationText`.
  - `:196` and `:217-226` the `TextEditor` binding writes every edit to `continuationDraft` and to `actions.updateContinuationDraft`.
  - Cancel and every other close path keep the draft.
- The closures are wired in two places:
  - `Sources/RepoPrompt/Features/AgentMode/Views/AgentInputBar.swift:356-359` (banner);
  - `Sources/RepoPrompt/Features/AgentMode/Views/Components/AgentRecoveryNeedsAttentionSheet.swift:45-48` (sheet).

### R4a: the refusal shows the unsent note, note first

- `AgentModeViewModel+RecoveryList.swift:136-141` `recoveryListRowError(_:hasUnsentContinuation:)`
  - When the card has unsent typed text, the error is `"The message you typed to continue it was not sent. " + reason`, note first.
  - Otherwise it is the reason alone.
- `AgentModeViewModel+RecoveryList.swift:194-202` `recoveryListRow` uses it for run cards (`turn`, `outcomeTurn`, `recoveryOnlyRun`), the same set that already appends the note to the detail.
- `AgentRecoveryListBanner.swift:96-97, 119` `AgentRecoveryListRow.detailLineLimit` (default 2) replaces the fixed `.lineLimit(2)`.
  - The banner passes 2 (`:31`); its fixed `rowHeight` 52 is unchanged.
  - The sheet passes 4 (`AgentRecoveryNeedsAttentionSheet.swift:249`).

### R7: surviving-process items first

- `AgentRecoveryCatalog.swift:309-311`
  - `addRuntimeRestrictions()`, which emits the `runtime-ownership-unknown` warning and every `runtime-<id>` item, now runs first in `AgentRecoveryCatalogProjection.build`, before every per-session and per-workspace builder.
  - The old call after `addUnavailableScheduleIndexes` is removed.
  - IDs are unchanged.
  - The runtime items have no session, so they don't depend on the `records`/`bindings` maps that later builders fill.
  - `removeDeletedSessions` never removes `.survivingProcess` items.

### V1: the send refusal stays visible

- `Sources/RepoPrompt/Features/AgentMode/ViewModels/AgentModeViewModel+Recovery.swift`
  - `:232-276` `recoveryAdmissionRefusalMessage` now returns named constants (`recoveryRefusal…Message`, plus `recoveryRefusalRestrictedPrefix`/`Suffix` for `.restricted`). The wording is unchanged.
  - `:279-294` `isRecoveryAdmissionRefusalNotice(_:)` is true for exactly the sentences that mapping can return.
- `AgentComposerUIModels.swift:152-188` `AgentComposerSubmitNotice`, a value type for the notice state:
  - `show(_:persistent:)` returns whether a dismiss timer is needed;
  - `transientTimerFired(for:)` never clears a persistent notice or a newer one;
  - `clearPersistent()` clears only a persistent notice.
- `AgentInputBar.swift`
  - `:480` the state is now `@State steeringNotice`, and `:637-639` makes `steeringUnsupportedMessage` a computed read.
  - `:2508-2538` `showSteeringUnsupportedNotice(_:persistent:)` defaults to `false`, so the 3-second behaviour is unchanged elsewhere. A persistent notice gets no timer.
  - `clearPersistentSteeringNotice()` runs at the start of `sendMessage()` (`:2429`) and `scheduleMessage(…)` (`:2356`), and on every `localInputText` change (`:832`).
  - The two blocked-completion sites pass `persistent: AgentModeViewModel.isRecoveryAdmissionRefusalNotice(blockedMessage)`: `:2410-2416` (schedule) and `:2486-2493` (send).
  - `shouldClearInput: false` is unchanged.

## Deviations from the plan

1. **The draft is keyed by row ID, as OracleD says (OracleA keys it by `AgentRecoveryCardKey`).**
   - OracleA's concern was banner row-ID prefixes.
   - Checked: the only prefix is the crash-hold paused indicator (`recoveryListPausedRowPrefix`), and that row never offers Continue.
   - Continue rows use `item.id` in both the banner and the sheet, so one row ID is one card.
2. **There is an added read closure, `AgentRecoveryListActions.continuationDraft(rowID)`.** The plan names only `updateContinuationDraft`.
   - The dictionary is deliberately not published, so the row's props can predate the latest keystroke.
   - The editor therefore reads the dictionary when it opens, then falls back to the props' text (unsent, then the default).
   - The precedence is the plan's: draft, then unsent text, then default.
3. **"Completed" means handed off.**
   - The 9-live refusals ("No history position was saved…") are recorded as action outcome `notDispatched`, which the runner reports as `.completed(.notDispatched, reason)`.
   - Clearing on every `.completed` would lose the text in exactly the A9 case.
   - So the draft is cleared only on `.completed(.dispatched)` or `.outcomeUnrecorded(.dispatched)`.
   - It is also cleared only when the draft still equals the sent text (OracleA's "an older submission never clears newer typing").
   - It is kept for `importedCompleted` too: the card then resolves, so the draft is unreachable but harmless.
4. **The note-first error applies to run cards only.**
   - `hasUnsentContinuation` can also be true on a question card whose "Send answer as message" was refused, because that action carries text too.
   - The note's wording ("to continue it") fits only run cards, which are also the only cards whose detail already carries the note.
5. **How the input bar recognises an admission refusal.**
   - It uses a string classifier built from the same constants as the mapping.
   - Changing `UserTurnSubmissionResult.blocked(message:)` would touch about 62 pattern sites.
   - The classifier includes `recoveryAdmissionFailedMessage`, which the mapping returns for `composerUnavailable`/`untrackedInput`. Other real save failures that reuse that sentence are therefore persistent too.
   - The classifier is applied at both completion sites (send and schedule); the plan names only "the admission-refusal sentences".
6. **The text-change clear fires on any `localInputText` change**, including a tab switch loading another tab's draft. That is intended: the notice belongs to the previous tab's send.
7. **The notice keeps its 2-line limit and fixed box height**, as the plan says (persistent only, no layout change). The crash-held sentence may still be cut off at narrow composer widths. This is not verified.
8. **`AgentRecoveryNeedsAttentionSheet.swift` is changed** even though it isn't in OracleD's file list. It is needed for the sheet's line limit of 4 and the draft closures.
9. **Not done**, all from OracleA's Step B and beyond OracleD's step:
   - removing a draft on session deletion or explicit discard;
   - surviving a store reload (after a relaunch the persisted action text covers this, through `unsentContinuationText`);
   - a separate error/note layout with a shared banner height calculation (OracleD: no banner height change).

## Tests

New or extended (all passed):

- **Projection, `AgentRecoveryCoordinatorTests`:**
  - `unsentContinuationText` equals the typed text in `recordUnsentContinuation` (`:2073`).
  - It survives later textless Reconciles (`notDispatched`, `importedUnconfirmed`, `:2093`).
  - It survives a superseded outcomeless continuation (`:2170`).
  - It is `nil` for an open continuation (`:2186`), a newer sent one (`:2200`), a saved intent carrying the text (`:2225`), a later resolving action (`:2238`), and empty text (`:2134`).
  - New `testUnsentContinuationTextIsTheNewestUnsentTypedText` (`:2138`).
- **Build order, `AgentRecoveryRuntimeOwnershipTests`:**
  - `testRuntimeItemsPrecedeSessionItemsInTheCatalog` (`:282`): a surviving runtime comes before a session schedule item and a workspace schedule-index item, with an unchanged ID.
  - `testRuntimeOwnershipWarningPrecedesSessionItemsInTheCatalog` (`:306`).
- **Row props, `AgentRecoveryStartupCompositionTests`:**
  - `testBannerHidesInformationalRunNotesAndShowsARunWithAnUnfinishedAction` is extended (`:1430-1442`). A `.failed(reason)` state on a run card with unsent text gives `error == note + " " + reason` in the banner and the sheet. The text fact equals the typed text, and clearing the state clears the error.
  - New `testRecoveryRowErrorPutsTheUnsentNoteBeforeTheReason` (`:1446`).
  - New `testContinuationEditorOpeningTextPrecedence` (`:1459`): draft, then unsent text, then default; an empty draft is kept as typed.
  - New `testContinuationDraftClearsOnlyWhenTheTextWasHandedOff` (`:1468`): a result table.
- **Draft retention through the real path, `AgentRecoveryReconciliationTests`:**
  - New `testRefusedContinuationKeepsTheEditorDraftForTheRow` (`:2199`).
  - Continue is offered and opens with the default.
  - After `updateRecoveryContinuationDraft`, the row opens with the draft.
  - The real `performRecoveryListContinuation` is refused before the runner ("provider wasn't recorded"), and the draft is kept.
- **Refusal classifier, `AgentRecoveryVMProducerAdmissionTests`:**
  - `testAdmissionRefusalsDescribeTheirOwnReason` is extended (`:1542`). Every refusal sentence, including `.restricted(reason)`, is persistent.
  - The stale, unadmitted-payload, tab-removal, generic and empty messages are not.
- **Input bar notice, `AgentComposerSubmissionAttemptTests`:**
  - `testPersistentNoticeSurvivesTheTimerAndClearsOnTheNextEditOrAttempt` (`:197`).
  - `testTransientNoticeClearsOnlyOnItsOwnTimer` (`:220`): the 3-second behaviour is unchanged, an edit doesn't clear a transient notice, and an older timer never clears a newer notice.

**Not covered by a test:**
- **Draft cleared after a real dispatch.** No existing harness drives a recovery Continue to dispatch from the view model. It is covered only by the predicate table plus the call site.
- **SwiftUI wiring.** The editor binding, the open-time read, and the input bar's `onChange` and submit-start clears can't be unit tested here (no GUI).

## Commands run

Job logs are under `/Users/tnguyen/Library/Application Support/RepoPrompt CE/Conductor/82430cd62f1cefa34a697069b92288bdf6730d048fa0ae24fa2aa774dd59c311/jobs/<ticket>.log`.

A combined `|` filter was not tried; each suite ran on its own.

| Command | Ticket | Result |
|---|---|---|
| `make dev-test FILTER=AgentComposerSubmissionAttemptTests` | `a05e9f1a-bdb7-4f38-a214-200323c0a6ee` | 10 tests, 0 failures |
| `make dev-test FILTER=AgentRecoveryRuntimeOwnershipTests` | `5835cbf0-176a-4585-ae2c-b7b139e35648` | 15 tests, 0 failures |
| `make dev-test FILTER=AgentRecoveryCoordinatorTests` | `79005702-5ee3-4cc7-9e59-037405878a1a` | 79 tests, 0 failures |
| `make dev-test FILTER=AgentRecoveryStartupCompositionTests` | `db531c78-646d-4eda-b848-57843d53d6ce` | 21 tests, 0 failures |
| `make dev-test FILTER=AgentRecoveryReconciliationTests` | `7225a903-4571-49e2-a2f1-e6d10ac73522` | 60 tests, 0 failures |
| `make dev-test FILTER=AgentRecoveryVMProducerAdmissionTests` | `aaea8096-b6c0-4b69-987a-9eeb615279ac` | 36 tests, 0 failures (logged `mktemp` errors come from existing negative-path fixtures) |
| `make dev-test FILTER=AgentRecoveryCrashHoldProofTests` | `7dfd597a-7f04-49a3-a8f2-e897b96aab16` | 21 tests, 0 failures |
| `make dev-test FILTER=AgentRecoveryEditProposalTests` | `edb60b14-8caa-454b-a414-031d758029cd` | 14 tests, 0 failures |
| `make dev-test FILTER=AgentRecoveryStartupReconciliationTests` | `d7500a05-cd1c-4425-b12b-312d7f84439b` | 21 tests, 0 failures |
| `make dev-test FILTER=CodexAgentModeCoordinatorLivenessTests` | `30a71996-41d8-4e4e-8ca5-7c2a8f7c768a` | 60 tests, 0 failures |
| `make dev-test FILTER=AgentRecoveryActionTests` | `6f49573d-25bb-44b9-8d7b-d768f66ed869` | 33 tests, 0 failures |
| `make dev-test FILTER=AgentRecoveryDelegatedChildLinkTests` | `e5c5b374-3c9d-4927-9c30-9c1dadb564ce` | 13 tests, 0 failures |
| `make dev-lint` (first run) | not captured | failed: 7 SwiftFormat findings in this step's files (3 `indent` in the editor binding, 4 `trailingCommas`), fixed by hand |
| `make dev-lint` | `fcb9cb97-e40f-4c0c-8505-6477d4fb75c7` | passed, 0/2205 files need formatting |
| `make dev-test FILTER=AgentRecoveryStartupCompositionTests` (after the lint fixes) | `76d0ed72-8ef7-4c19-9ad6-97583340530b` | 21 tests, 0 failures |
| `make dev-test FILTER=AgentRecoveryVMProducerAdmissionTests` (after) | `a6ce9a57-19f7-4b36-b9bd-696757b3f7bd` | 36 tests, 0 failures |
| `make dev-test FILTER=AgentRecoveryReconciliationTests` (after) | `215a285d-0c5c-4f9c-8da9-67d199d72027` | 60 tests, 0 failures |
| `make dev-test FILTER=AgentComposerSubmissionAttemptTests` (after) | `1bcc504f-f6b0-4507-9ef0-bbc20e5e6430` | 10 tests, 0 failures |

The logs show every new or extended method by name as passed.

`Scripts/check-agent-context` reports this report as an orphan. The other new 9-live evidence files get the same error. It clears when the main agent links the evidence from the spec.

**Not run:**
- the full `make dev-test`;
- `make guardrails` (no source files were added or moved);
- the native-popover suites (another worker's files);
- any live check.

## Live-verifier steps

For the activated candidate. Each step needs the owner's approval for app launch and for the kill.

### A9: refused continuation note, and Continue reopens with the typed text

1. Use a Claude or Codex session with an interrupted run card that is still refused today ("No history position was saved…"): K3/T11/T14-style.
2. Open Continue…, replace the default with a marker such as `RPCE_VERIFY_A9_<date> continue`, and press Send.
3. Expected, in the banner row: the error starts with "The message you typed to continue it was not sent." and is followed by the reason, within 2 lines. The banner height is unchanged.
4. Expected, in the Needs Attention sheet: the same row shows the same text, within up to 4 lines.
5. Press Continue… again. Expected: the editor shows the marker text, not the default ("RepoPrompt restarted during the previous turn. Check the current state before repeating any action, then continue.").
6. Quit and relaunch, then open Continue… on that row. Expected: the marker text again, now from the record (`unsentContinuationText`), since the in-memory draft is gone.

### R5: the draft survives the editor closing

1. On a row offering Continue…, open the editor and type a marker without sending.
2. Close it each of these ways, reopening Continue… after each:
   - press Cancel;
   - click outside the popover;
   - switch to another app and back;
   - close and reopen the Needs Attention sheet;
   - open the same row from the banner instead of the sheet.
3. Expected: every reopen shows the exact typed text.
4. Edit it once more, then Send.
   - On a refusal, reopen: it still shows the text.
   - On a successful send, reopen: it shows the default (the draft is cleared only on hand-off).

### V1: refusal while a process lives

1. Use the V1 fixture: a surviving writer from the earlier launch, for example a Bash `sleep 900` turn killed with the app. After relaunch, open its session.
2. Type a message and press Send. Expected: the notice under the composer shows the refusal sentence (the crash-hold one first by code order, or "This message was not sent: … Review it in the recovery banner. Your draft is kept.") and is still there after 10 seconds or more. The typed text stays in the composer.
3. Take the screenshot now. Then type one character. Expected: the notice disappears.
4. Press Send again. Expected: the notice disappears at the attempt and then reappears.
5. Check that an unrelated transient notice (for example a stale-target or provider-unavailable message, if reachable) still clears after about 3 seconds.

### R7: survivor first in the sheet

1. With the V1 survivor alive, open Needs Attention without opening the survivor's session.
2. Expected: "An agent process is still running" (or "…may still be running") is the first row of "Needs action", above the crash-hold rows, without scrolling.
3. Use Refresh or Let it finish on it to confirm its ID and actions are unchanged.

## Review fixes (round 0)

Fixes for the two reviews of this step: `prompt-exports/oracle-review-2026-10-28-195858-9fix-2-list-review-o-6d69.md` (A: LIST-01, LIST-02) and `prompt-exports/oracle-review-2026-10-28-195858-9fix-2-list-review-o-8aa6.md` (B: L1–L10). Nothing was committed or staged. `AgentRecoveryNativePopover.swift`, its tests, and the ledger were not touched. Deferred as instructed: B L6, L8, and the hold-lift half of L10.

This section supersedes two statements above:
- the draft dictionary is no longer on `AgentModeViewModel` (it is app-wide, item 2);
- the draft is no longer cleared only on `.dispatched` (item 1), so deviation 3 no longer holds.

Line numbers are for the working tree after these fixes.

### 1. B L1 + L3: the draft follows what the record holds

- `AgentModeViewModel+RecoveryList.swift:833-875` `performRecoveryListContinuation`. It captures the row's session ID before the await, then switches on the new disposition (`:859`):
  - `.keep` for `nil`, `.disabled`, `.refused`, `.joined`, `.priorAction` (this choice recorded nothing).
  - `.clear` for `.completed(.dispatched)`, `.completed(.notDispatched)`, `.completed(.importedUnconfirmed)`, `.outcomeUnrecorded(.dispatched)`. The record holds the text: it was sent, or the card shows it again as `unsentContinuationText`, or a saved intent carries it (L3).
  - `.moveToComposer` for every recorded result that neither sent the text nor leaves it on the card:
    - `.completed(.importedCompleted)` (the card resolves; the L1 case);
    - `.outcomeUnrecorded(.importedCompleted)`, `.outcomeUnrecorded(.notDispatched)`, `.outcomeUnrecorded(.importedUnconfirmed)`.
  - `.completed(.importedUnconfirmed)` is listed for completeness; a continuation never produces it (the runner gives it only to Reconcile).
- Every removal goes through `removeRecoveryContinuationDraft(rowID:ifEqualTo:)` (`:923`): an edit made during the await is newer and survives.
- `.moveToComposer` (`:866-873`):
  - With the default continue text: the draft is removed, nothing moves, and the row keeps the runner's reason.
  - Otherwise, with the session open in this window: `placeUnsentRecoveryContinuationInComposer` (`:931`) sets the session's draft to the text when it is empty (whitespace only counts as empty), or to current text + blank line + text. The row's message becomes:
    - `recoveryContinuationFinishedMovedText` (`:907`): "The interrupted turn had already finished, so your message wasn't sent. It's now in the message box."
    - or, for an unrecorded unsent outcome, `recoveryContinuationUnrecordedMovedText`: "Nothing was sent, but that couldn't be recorded. Your message is now in the message box."
  - For the current tab, the same message also shows under the composer, through the existing `draftRestorationEvent` with a new strategy, `DraftRestorationStrategy.appendAfterBlankLine` (`AgentModeRunService.swift:177`). The input bar applies it to its live text (`AgentInputBar.swift:858-861`), so typing that isn't stored yet is never replaced.
  - If the session is no longer open in this window, the draft is kept and nothing moves.
- The draft disposition is `RecoveryContinuationDraftDisposition` (`:879`) and `recoveryContinuationDraftDisposition(_:)` (`:894`). It replaces `recoveryContinuationWasHandedOff`.

### 2. B L2: drafts are app-wide

- `AgentRecoveryCoordinator.swift:532` `continuationDraftsByRowID`, next to `catalogActionStates`. It is a plain stored property of a non-observable class: in memory, not observed.
- The VM's dictionary is removed. `recoveryContinuationDraft(rowID:)` and `updateRecoveryContinuationDraft(rowID:text:)` (`AgentModeViewModel+RecoveryList.swift:151, :156`) are thin forwarders. The row's opening text uses the forwarder (`:227`).

### 3. B L4: blocker writes and sheet order

- The `blockers[` writes in `AgentRecoveryCatalog.swift`'s `Builder`:
  - `addResolution` writes `= .crashHold` (`:571`);
  - `removeDeletedSessions` writes `= nil` for deleted sessions (`:517`). It still runs last.
- `addRuntimeRestrictions` writes no blocker, and `AgentRecoveryCatalogBlocker` has only `.crashHold`. Runtime restrictions block through `coordinator.restrictions` and `runtimeBlocksAutomaticWork`, not through catalog blockers.
- So the reorder changes no blocker. No fix was needed.
- New `AgentRecoveryRuntimeOwnershipTests.testSurvivorIsTheFirstNeedsActionRowOfTheSheet` (`:329`):
  - It uses a real `AgentModeViewModel` on the coordinator, with a surviving writer plus a startup workspace failure. Under the old order, the workspace failure was built first.
  - It asserts the needs-action rows of `recoveryNeedsAttentionRows(includeDismissed: false, activeSession: nil)` (the sheet's own filter) are exactly `[runtime-<id>, workspace-<id>]`.
  - `startedCoordinator` gained a `reconciliation:` parameter (`:41`).

### 4. B L5: classifier on the real blocked message

- New `AgentComposerSubmissionAttemptTests.testAdmissionRefusalBlockedMessageIsClassifiedAsPersistent` (`:197`).
- For `.startupNotReady`, `.restricted(reason)` and `.untrackedInput`, the refusal sentence goes through `AgentComposerSubmissionLatch.complete(… .blocked(message:) …)`. The test asserts `isRecoveryAdmissionRefusalNotice(effects.blockedMessage!)` and that the input is not cleared.
- A stale-target block is not classified as persistent.

### 5. A LIST-01: tab change clears a persistent notice

- `AgentInputBar.swift:786-788` `.onChange(of: currentTabID)` calls `clearPersistentSteeringNotice()`. Its doc comment now names the tab change (`:2538`).
- **Not tested:** this is SwiftUI `onChange` wiring in the view, and no test seam drives it. The notice state itself (`AgentComposerSubmitNotice.clearPersistent`) is already covered.

### 6. A LIST-02: integration through `performRecoveryListContinuation`

- New DEBUG seam `test_recoveryActionResult` (`AgentModeViewModel.swift:696`, used at `AgentModeViewModel+RecoveryActions.swift:253`).
  - It replaces only the runner's result.
  - The request is still built, provider-gated and slot-cached, and the failure text is mapped as usual.
  - Production never sets it.
- New `AgentRecoveryReconciliationTests.testRecordedContinuationClearsOnlyTheSentDraft` (`:2237`), for `.completed(.dispatched)`, `.outcomeUnrecorded(.dispatched)` and `.completed(.notDispatched)`:
  - the request carries the exact text;
  - a matching draft clears;
  - a different draft written inside the runner's await survives;
  - the message box is untouched.
- New `testContinuationThatFindsTheTurnFinishedMovesTheTypedTextToTheMessageBox` (`:2272`), the item 1 case:
  - `.completed(.importedCompleted)` with typed text into an empty box gives exactly that text. The draft clears, the row shows the "already finished" message, and the event uses `.appendAfterBlankLine` for the current tab.
  - With an existing draft, the box holds `"my own text\n\nsecond"`.
  - The default text is not moved; the row keeps the runner's reason.
  - `.outcomeUnrecorded(.notDispatched)` appends too, with the "couldn't be recorded" message.
- `testRefusedContinuationKeepsTheEditorDraftForTheRow` is extended (`:2221-2231`): the draft is on the coordinator, and a second window's VM on the same coordinator reads it (L2).
- `AgentRecoveryStartupCompositionTests.testContinuationDraftClearsOnlyWhenTheTextWasHandedOff` is replaced by `testContinuationDraftDispositionFollowsWhatTheRecordHolds` (`:1470`). It is a full table over every result shape, plus both moved-text messages.

### 7. B L7 + L9

- L7: `AgentRecoveryListActions.continuationDraft` and `updateContinuationDraft` are now `let` without defaults (`AgentComposerUIModels.swift:630, :632`). Both construction sites, `AgentInputBar.swift` and `AgentRecoveryNeedsAttentionSheet.swift`, already pass them, so neither needed a change.
- L9: `AgentRecoveryListBanner.swift:122`.
  - The project's SwiftLint rule `no_swiftui_help_modifier` rejects `.help(...)`.
  - So the truncated detail/error `Text` uses the project's equivalent `.hoverTooltip(row.error ?? row.detail)`, and the file now imports `RepoPromptUI`.

### Deviations

1. **`.outcomeUnrecorded` with an unsent outcome moves the text to the message box rather than only clearing the draft.**
   - When the outcome write fails, the action stays open in the record, so `unsentContinuationText` is `nil`.
   - Clearing alone would drop the text from every surface: the same hard-fail class as L1.
   - So these results are treated like `.completed(.importedCompleted)`, with their own message.
   - `.outcomeUnrecorded(.dispatched)` clears, as instructed.
2. **`.joined` and `.priorAction` keep the draft.** The instruction lists only nil / `.refused` / `.disabled`, but these two also record nothing new for this choice.
3. **The row's wording says "message box", not "composer".** That is the term the existing recovery-list messages use ("Clear the message box first.").
4. **L9 uses `.hoverTooltip` instead of `.help`**, because of the lint rule.
5. **The moved text is the sent text.** If the user edited the draft during the await of an `importedCompleted` choice, that newer draft is kept but its card is resolved, so it is unreachable; the sent text still moves to the box. This is a narrow race and not covered.

### Validation

Logs are under `…/Conductor/82430cd62f1cefa34a697069b92288bdf6730d048fa0ae24fa2aa774dd59c311/jobs/<ticket>.log`.

| Command | Ticket | Result |
|---|---|---|
| `make dev-test FILTER=AgentComposerSubmissionAttemptTests` | `51ebd736-d037-4eb3-8129-cf351ee248f3` | 11 tests, 0 failures |
| `make dev-test FILTER=AgentRecoveryReconciliationTests` | `f1d05b12-7f79-4299-aa2b-5e70253deacc` | 62 tests, 0 failures |
| `make dev-test FILTER=AgentRecoveryRuntimeOwnershipTests` | `9e8037d6-bca8-4e57-8644-10543c5bc7bf` | 16 tests, 0 failures |
| `make dev-test FILTER=AgentRecoveryStartupCompositionTests` | `e132b52b-ad98-405c-9d23-0b4f79a4f0de` | 21 tests, 0 failures |
| `make dev-test FILTER=AgentRecoveryVMProducerAdmissionTests` | `9bf7bfcc-8268-4094-8fec-76e3d040651b` | 36 tests, 0 failures |
| `make dev-test FILTER=AgentRecoveryCoordinatorTests` | `34e0e5b9-cce2-4139-90ff-2326a1cb1169` | 79 tests, 0 failures |
| `make dev-lint` (first) | not captured | failed: `no_swiftui_help_modifier` at the new `.help`; replaced with `.hoverTooltip` |
| `make dev-lint` | `50512f47-c33d-4e9f-bc62-74a88d51f041` | passed, 0/2205 files need formatting, SwiftLint strict clean |
| `make dev-test FILTER=AgentRecoveryStartupCompositionTests` (after the lint fix) | `9737512b-f598-411b-a886-dd011fcd7722` | 21 tests, 0 failures |

- The logs show every new or changed test by name as passed.
- No new compiler warnings in the touched files.
- `Scripts/check-agent-context` still reports only this report's known orphan error and the existing route-count warning.

**Not run:**
- the full `make dev-test`;
- `make guardrails` (no files were added or moved);
- the native-popover suites;
- any live check.

**Live-verifier addition (B):**
1. Have a survivor finish its turn while RepoPrompt is closed.
2. After relaunch, open Continue… on its card, type a marker, and Send.
3. Expected:
   - the marker appears in that session's message box (after a blank line if the box had text);
   - the row and the composer notice say the turn had already finished and the message is in the message box;
   - nothing is sent.

## Review fixes (round 1)

Fixes for `prompt-exports/oracle-chat-2026-10-28-201910-9fix-2-list-review-r-0ed8.md` (A: R1-01, R1-02) and `prompt-exports/oracle-chat-2026-10-28-201910-9fix-2-list-review-r-024d.md` (B: N1–N3, P3). Nothing was committed or staged. The popover files and the ledger were not touched.

**Not done, as instructed:**
- the L5 view-model-level test;
- pruning;
- relaunch duplication after `.outcomeUnrecorded(.notDispatched)`. For the live check, look for a text in the message box that also comes back as the card's prefilled Continue text after a relaunch.

All line numbers are in `AgentModeViewModel+RecoveryList.swift` unless a file is named.

### 1. B N1 + A R1-01 (and round-0 deviation 5): a leftover Continue draft is moved, not orphaned

`rescueOrphanedRecoveryContinuationDrafts(sessionID:rowID:)` (`:903`) is the single helper. It looks at every Continue draft of the session, plus the acted row's draft (whose item may have left the catalog).

- **Draft kept** when any of these holds:
  - its card still offers Continue: `recoveryCardOffersContinue` (`:935`) calls the row builder's own `recoveryRunActions` for the card's run status;
  - no window hosts the session (item 2);
  - the message box is not in a normal state (item 4).
- **Draft dropped** when it is blank or the unchanged default (`isRecoveryContinuationDraftDisposable`, `:952`).
- **Otherwise moved** into the message box through `moveRecoveryContinuationTextToComposer` (`:974`), which uses the round-0 placement path. The acted row gets the message; any other row of the session gets it as its own row state.

Where it runs:
- At the end of `performRecoveryListAction` (`:797` captures the session, `:832` calls it).
  - It runs for every action on an item with a session, not only run-row actions. This is wider than asked.
  - The point is that a draft held back by item 4 moves after the user resolves the saved draft, since that resolution is also a list action.
- At the end of `performRecoveryListContinuation` (`:891`).

The `.moveToComposer` branch (`:874`) now moves the newest revision, `continuationDraftsByRowID[rowID] ?? text`, and only that one.
- For a dispatched result, the sent text is cleared only if it equals the draft (unchanged).
- A newer edit left behind is moved by the helper once the card has resolved. The sent text is never moved.

**Message (deviation).** The rescued text gets a new message, `recoveryContinuationLeftoverMovedText` (`:1024`): "This card no longer offers Continue, so the message you typed for it wasn't sent. It's now in the message box."
- The `importedCompleted` sentence says the turn had finished. That is false after a dispatched send, an automatic clear, or a resolution in another window.
- The `.moveToComposer` branch itself still uses the `importedCompleted` / unrecorded messages.

**Tests, in `AgentRecoveryReconciliationTests`.** Each one resolves the card for real: the runner seam writes the reservation and outcome through `lane.reserveRecoveryAction` / `completeRecoveryAction` (helper `recordAction`, `:2311`). Each asserts what lands in `session.draftText`.
- (a) `testReconcileThatResolvesTheCardMovesTheLeftoverContinueDraftToTheMessageBox` (`:2324`): draft set, editor closed, then Reconcile → `importedCompleted`. The card is `resolvedByAction`, the text is in the message box, the entry is gone, and the row shows the leftover message.
- (b) `testNewerEditDuringADispatchedContinueMovesToTheMessageBoxNotTheSentText` (`:2347`): only the newer edit lands in the message box.
- `testNewerEditDuringAFinishedContinueMovesTheNewestRevision` (`:2372`): `importedCompleted` with a newer edit during the await. The message box gets `"newest"` only, with the "already finished" message.

### 2. A R1-02: the session isn't open in this window

`recoveryComposerHost(sessionID:)` (`:958`) looks in this window first. If the session isn't there, it checks every other window on the same recovery coordinator, through the existing `WindowStatesManager.shared.allWindows[].agentModeViewModel`. The text is placed by the window that hosts the session.

**Not covered: a session no window hosts.** The only persisted composer is the recovery record's, and it is written through a live lane. A closed session has none. No existing cheap API sets a closed session's composer. So:
- the text is kept in `continuationDraftsByRowID` (`:887`), never dropped;
- once the card has resolved, nothing shows it;
- it moves once a window hosts the session and the next list action runs on that session.

The owner decides whether to downgrade. Nothing is tested for this case: no harness closes a session during the await, and the multi-window lookup has no test either.

### 3. B N2: the append can't happen twice

- The existing strategies have the view model store the event text, and the input bar computes the result from its live text. The input bar reads the session's draft only on appear and on tab change (`loadDraftFromSession`), so a double append needed an appear between the store and the event. That is unlikely, but it wasn't excluded.
- `DraftRestorationStrategy.appendAfterBlankLine` now carries `expectedPrior` (`AgentModeRunService.swift:179`): the text the view model appended to.
- The input bar uses `recoveryComposerAppendResult(live:text:expectedPrior:)` (`:1073`, called at `AgentInputBar.swift:858`).
  - If the live text already equals the view model's stored result, it is kept unchanged.
  - Otherwise the text is appended once to the live text.
- The view model stores `recoveryComposerAppending(text, to: existing)` (`:1066`).
- Test: `AgentRecoveryStartupCompositionTests.testComposerAppendIsAppliedOnce` (`:1502`) covers:
  - an empty box, and whitespace counting as empty;
  - an append to an existing draft;
  - the stored result already shown, which leaves the text unchanged;
  - newer live text, which gets the text appended once.

  The SwiftUI `onChange` itself has no seam.

### 4. B N3: only into a normal message box

- `moveRecoveryContinuationTextToComposer` (`:974`) moves the text only when the lane is live and `composerState == .ready`, with no `unsavedPredecessorInputs`.
- Otherwise it stores the text as the row's draft and returns `recoveryContinuationComposerBusyText` (`:1026`): "Your message wasn't sent. Resolve this session's saved draft first; your message is kept and then moves to the message box."
- After that, the next list action on the session moves it (item 1).
- **Not tested:** `composerState` and `unsavedPredecessorInputs` are `private(set)` on the lane, and no cheap fixture puts a lane in held, failed or predecessor state. The passing placement tests show the gate admits a normal (`.ready`) lane.

### 5. B P3: the notice of another tab's attempt

- No change was needed. `AgentComposerSubmissionLatch.complete` already publishes `blockedMessage` only when `inputStillMatches`, which requires `currentTabID == attempt.sourceTabID`. A completion that arrives after a tab switch therefore yields no notice, persistent or not.
- Test: an assertion added to `AgentComposerSubmissionAttemptTests.testAdmissionRefusalBlockedMessageIsClassifiedAsPersistent` (`:229`).

### Validation

Logs are under `…/Conductor/82430cd62f1cefa34a697069b92288bdf6730d048fa0ae24fa2aa774dd59c311/jobs/<ticket>.log`.

| Command | Ticket | Result |
|---|---|---|
| `make dev-test FILTER=AgentRecoveryReconciliationTests` | `55226271-8c3d-4dad-a421-d913296db35d` | 65 tests, 0 failures |
| `make dev-test FILTER=AgentComposerSubmissionAttemptTests` | `4acce35e-93fa-49f1-8584-58320b991f8c` | 11 tests, 0 failures |
| `make dev-test FILTER=AgentRecoveryStartupCompositionTests` | `10e635fa-8e65-43f9-beaa-82efbd1e0b7d` | 22 tests, 0 failures |
| `make dev-test FILTER=AgentRecoveryRuntimeOwnershipTests` | `0a894413-c549-417c-8da8-937480d1faa1` | 16 tests, 0 failures |
| `make dev-test FILTER=AgentRecoveryVMProducerAdmissionTests` | `35d8a4ab-58cb-4c64-b26c-088a8163a1c5` | 36 tests, 0 failures |
| `make dev-test FILTER=AgentRecoveryCoordinatorTests` | `c8168b2e-735d-4d50-b306-5df8f02b7418` | 79 tests, 0 failures |
| `make dev-lint` | `6beb1479-0048-45d3-bdf9-3a0c9315fcbd` | passed, 0/2205 files need formatting, SwiftLint strict clean |

**Not run:**
- the full `make dev-test`;
- `make guardrails` (no files were added or moved);
- the native-popover suites;
- any live check.

**Live-verifier additions:**
1. On a survivor whose turn finished, type in Continue…, close the editor, and click Check history. Expected: the text lands in the message box, with the "no longer offers Continue" message.
2. After an `.outcomeUnrecorded(.notDispatched)`, relaunch. The text may appear both in the message box and as the card's prefilled Continue text. This is a known duplicate.

## Review fixes (round 2, main-agent checked)

Fixes for `prompt-exports/oracle-chat-2026-10-28-203333-9fix-2-list-review-r-c494.md` (A) and `prompt-exports/oracle-chat-2026-10-28-203224-9fix-2-list-review-r-ac0a.md` (B), scoped by the main agent.

Nothing was committed or staged. The popover files and the ledger were not touched. `make dev-format` was not run.

**Not done, as instructed:**
- B's P3s;
- A's session-keyed fallback surface;
- extra multi-window tests.

All line numbers are in `AgentModeViewModel+RecoveryList.swift` unless a file is named.

### 1. In-flight rows (A R2-02 = B P1-A)

`rescueOrphanedRecoveryContinuationDrafts` skips any other row whose action state is `.working` (`:916`). The acted row stays eligible.

Test: `AgentRecoveryReconciliationTests.testActionOnAnotherRowLeavesAnInFlightContinueDraftAlone` (`:2396`).
- Two run cards in one session.
- Row B's Continue is suspended in the runner seam (`RecoveryGateLatch`) after its `dispatched` outcome was written, so its card is `resolvedByAction`.
- `.copyProposal` runs on row A. On a run card it returns early, so it is a side-effect-free list action that runs the helper.
- Asserts:
  - B's draft is kept;
  - B is still `.working`;
  - the message box is empty;
  - after release, B's own `.clear` removes the sent draft, and nothing reaches the message box.

### 2. Coalesced events (A R2-01 = B P1-B)

**Verified first:** the restore paths store `session.draftText` synchronously, before the helper runs in the same turn.
- `applyRecoveredComposer` (`AgentModeViewModel+Recovery.swift:1094`):
  - for the current tab, it calls `restoreComposerDraft`, which calls `storeDraftText` synchronously and then posts its own `.replaceIfEmpty` event;
  - for any other tab, it sets `session.draftText` directly.
- Held-draft Restore (`resolveHeldRecoveryComposer`, `:1060`) and the unsaved-predecessor Restore (`resolveRecoveryListDraft`) call it after their await, synchronously.
- Retry load (`retryRecoveryComposerRestore`, `:1084`) goes through `applyRecoveryRestoreOutcome`, which calls the same function.

So a result computed from `session.draftText` already includes R.

**Change:**
- `DraftRestorationStrategy.appendAfterBlankLine(result:)` (`AgentModeRunService.swift:179`) carries the full text the view model just stored.
- `placeUnsentRecoveryContinuationInComposer` (`:1070`) computes `result` from `session.draftText`, stores it, and posts it (`:1083`).
- The input bar (`AgentInputBar.swift:858`) applies `recoveryComposerAppendUpdate(live:result:)` (`:1096`):
  - it shows `result`;
  - if the live text already equals `result`, nothing changes, but the message is still shown.
- `recoveryComposerAppendResult(live:text:expectedPrior:)` was removed.

**Tests:**
- `AgentRecoveryStartupCompositionTests.testComposerAppendIsAppliedOnce` (`:1504`) was updated. It covers:
  - the append rule;
  - a no-op on a repeat;
  - the coalesced N3 Restore case: R restored, then T placed; the bar sees only the second event on an empty box and shows `R\n\nT`.
- `AgentRecoveryReconciliationTests.testTwoPlacementsInOneTurnKeepBothTexts` (`:2434`). Two resolved cards with drafts are moved by one helper pass, i.e. two placements in one main-actor turn. Asserts:
  - the stored draft holds both texts;
  - the last event's `result` holds both;
  - the bar's update from an empty box is that result.

**Not tested: the N3 Restore through the real view model.**
- The only fixture that holds a composer is in `AgentRecoveryResetBoundaryTests` (Clear Chat), which is not one of the six suites and has no run card to carry a held-back draft.
- No fixture creates `unsavedPredecessorInputs` at the view-model level.
- The coalescing itself is covered by the unit assertion above.

### 3. A R1-01 remainder

The `.moveToComposer` branch (`:871`) moves `recoveryUnsentContinuationText(submitted:newer:)` (`:965`):
- the submitted X, then a differing newer Y, after a blank line, as one placement;
- blank and default texts are left out, and duplicates are removed.

Dispatched results are unchanged: `.clear` removes X only while it is unchanged, and a differing Y moves through the helper.

Tests:
- `testNewerEditDuringAFinishedContinueMovesTheSubmittedTextThenTheNewerEdit` (`:2372`, renamed): the message box gets `older\n\nnewest`, as one event.
- `testComposerAppendIsAppliedOnce` covers dedup, default and blank.

### 4. The session isn't open in any window (now P2)

In the no-host branch, the row message is now `recoveryContinuationOpenSessionText` (`:1046`): "Your message wasn't sent. Open this session to get it back in the message box." The text is still kept in `continuationDraftsByRowID`.

**Confirmed:** the row's Open is a list action. `performRecoveryListAction(.open)` captures the session ID before the await and runs the helper after `openRecoveryListSession` returns.

**Caveats, not fixed (out of scope):**
- **The lane may not be ready yet.** The opened session's lane restores its composer in an unstructured eager `Task` (`AgentModeViewModel+Recovery.swift:771`).
  - The helper runs right after `ensureHydrated`, so it can find the lane not yet `.ready`.
  - The N3 gate then keeps the text and shows the "Resolve this session's saved draft first" message, which is misleading here.
  - The text moves on the next list action on that session.
- **The message is easy to miss.** A resolved card is automatically cleared. Its row, with this message and Open, is listed only under Needs Attention's "Show dismissed and cleared".
- **It is lost on quit.** The kept text lives only in memory.

No test was added: no harness has a session without a host.

### 5. The editor's Send passes the exact text

Verified, no change needed:
- `AgentRecoveryListBanner.continuationEditor` sends `continuationDraft`, the same `@State` the binding writes. The binding's setter stores the same string through `updateRecoveryContinuationDraft`, without normalising it.
- Both `performContinuation` closures (input bar, Needs Attention sheet) pass `text` through to `performRecoveryListContinuation`, which passes it to the request unchanged.
- Trimming happens only in Send's `.disabled` check. So `removeRecoveryContinuationDraft(ifEqualTo:)` compares the same string.

### Validation (final tickets, after the lint fixes)

Logs are under `…/Conductor/82430cd62f1cefa34a697069b92288bdf6730d048fa0ae24fa2aa774dd59c311/jobs/<ticket>.log`.

| Command | Ticket | Result |
|---|---|---|
| `make dev-test FILTER=AgentRecoveryReconciliationTests` | `8d7fcc10-2412-4f04-bfbb-bcda3c408916` | 67 tests, 0 failures |
| `make dev-test FILTER=AgentRecoveryStartupCompositionTests` | `551a5584-519c-4805-85bc-2b1b09ffa8c1` | 22 tests, 0 failures |
| `make dev-test FILTER=AgentComposerSubmissionAttemptTests` | `8d6036ee-b205-4625-b9ca-05374c1f8aca` | 11 tests, 0 failures |
| `make dev-test FILTER=AgentRecoveryRuntimeOwnershipTests` | `e7ea7aeb-37bc-44e2-8a09-5e71fe4353e6` | 16 tests, 0 failures |
| `make dev-test FILTER=AgentRecoveryVMProducerAdmissionTests` | `dddcc25b-1301-4a05-a8d8-8ba9b8776887` | 36 tests, 0 failures |
| `make dev-test FILTER=AgentRecoveryCoordinatorTests` | `a0085c7c-c66a-47a3-9ea7-c852b969fe6e` | 79 tests, 0 failures |
| `make dev-lint` | `6fe1134d-f887-4b63-b050-d45aa87a034f` | passed |

The first lint run (`31585603-…`) flagged two issues, both fixed before the final runs:
- `preferKeyPath`: changed to `compactMap(\.self)`;
- `docComments`: the nested test helper now has a `///` comment.

An earlier full pass of all six suites, before those two edits, was also green (Reconciliation `ff72ea22-…`). The new tests were confirmed passing by name.

**Not run:**
- the full `make dev-test`;
- `make guardrails`;
- the popover suites;
- any live check.

**Live-verifier additions:**
1. Leave a draft held back by N3, click Restore on the saved draft, and confirm both texts are in the message box.
2. In the closed-session case, click Open and check whether the text arrives or the misleading "resolve the saved draft" message appears (the eager-restore caveat in item 4).
