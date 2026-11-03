# 9-live fix 2 (recovery list): OracleB review, round 0

Scope: read when the task touches the recovery list's Continue editor text, refused-continuation row text, the order of surviving-process items, or the composer's send-refusal notice.
Authority: Reference
Last-verified: 2026-10-28
Covers: the OracleB review (round 0) of the recovery-list diff, copied from its export; the fixes are in fix-9live-list-worker.md




# Review: 9-live Step 2, recovery list fixes (`9fix-list.diff` only)

**Summary.** The diff makes four fixes:

- **R4b + R5:** a per-row, in-memory Continue draft is written on every keystroke. The editor opens with the draft, then the record's unsent text (`unsentContinuationText`), then the default. The draft is cleared only on a `.dispatched` result whose text equals the draft.
- **R4a:** a run card's refusal shows "note + reason". The line limit is 2 in the banner and 4 in the sheet.
- **R7:** `addRuntimeRestrictions()` now runs first in the catalog build.
- **V1:** admission refusals become a persistent composer notice, recognised by a classifier that matches against the same string constants as the refusal mapping. The notice clears on the next attempt or text change.

The core fixes look right:

- The `unsentContinuationText` refactor keeps `hasUnsentContinuation` exactly as it was.
- Drafts don't leak across sessions. Run-card row IDs carry the card key plus the turn or attempt UUID, and the only prefixed (paused) row never offers Continue.
- The notice state machine (`AgentComposerSubmitNotice`, plus the revision guard) handles a transient notice replacing a persistent one and the reverse, and older timers can't clear newer notices.

The remaining risks are three gaps around the lost-text rule:

- a Continue result that closes the card without sending;
- the draft living in one window's view model;
- the draft outranking the record after the record already knows where the text went.

Everything below comes from reading the diff and the reports. No code was run and nothing was checked live.

---

## P1

### L1: A Continue that finds the turn already finished hides the typed text everywhere
- **Failure scenario.**
  1. A Claude process survives the app (the V1 scenario) and finishes its turn while RepoPrompt is closed.
  2. After relaunch, the user opens Continue…, replaces the default with their own message, and presses Send.
  3. The resume action reconciles history first, imports the completed turn, and returns `.completed(.importedCompleted, _)`. The text is not dispatched.
  4. Because `recoveryContinuationWasHandedOff` is false, the draft is kept. But the card is now `resolvedByAction`, so it becomes informational and no longer offers Continue. `unsentContinuationText` is `nil` because a resolving action exists.
- **Impact.** The user's typed message was never sent, and no surface shows it any more: not the banner, not the sheet, not the composer. Only the record's action JSON still holds it. That is the plan's hard-fail class. The worker's deviation 3 calls this "unreachable but harmless", but the draft is unreachable precisely because the text was dropped.
- **Evidence.**
  - `AgentModeViewModel+RecoveryList.swift` ~`:852-855`: the clear and keep branch.
  - `:860-869`: `recoveryContinuationWasHandedOff`.
  - `AgentRecoveryStartupCompositionTests` `testContinuationDraftClearsOnlyWhenTheTextWasHandedOff` lists `.completed(.importedCompleted, …)` as "kept", with no further handling.
  - `AgentRecoveryActionModels.swift:340-347`: a resolving action makes `unsentContinuationText` `nil`.
- **Smallest fix.** In `performRecoveryListContinuation`, when the result resolves the card without dispatch (`.completed(.importedCompleted, _)`) and the text differs from `recoveryContinueDefaultText`, choose one:
  - put the text into that session's composer draft when the composer is empty; or
  - add "Your message wasn't sent; it's in the composer" to the result.

  Add one row test for this case.

---

## P2

### L2: Drafts live in one window's view model, so closing the window or moving the session loses them
- **Failure scenario.**
  1. The user types into the Continue editor, and it self-closes (R5). The draft is now in window A's `AgentModeViewModel`.
  2. The user either closes window A, or opens the session in window B, where Continue is offered for the active session.
  3. Window B shows the record's unsent text or the default. Window A's draft is gone with its view model, or orphaned.
- **Second case: the draft shadows newer text.** If the session later returns to A after the user typed and sent Y in B (refused), A's stale draft X outranks the record's newer Y.
- **Impact.**
  - Typed text is lost when the window closes.
  - The wrong text is shown after a window move.
  - These are uncommon paths, but this is the hard-fail class.
- **Evidence.**
  - `AgentModeViewModel.swift:688-692`: `recoveryContinuationDraftsByRowID` is per view model.
  - `AgentInputBar.swift:356-359` and `AgentRecoveryNeedsAttentionSheet.swift:45-48` both wire to the window's `agentModeVM`.
  - By contrast, `catalogActionStates` already lives on the app-wide coordinator.
- **Smallest fix.**
  - Move the dictionary next to `catalogActionStates` on the recovery coordinator (app-wide, still in memory and unpublished).
  - Keep the two view-model accessors as thin forwarders, so call sites don't change.

### L3: The draft can outrank the record after the record has already taken the text
- **Failure scenario (plausible, not traced).**
  1. A continuation is recorded, and its text is adopted by a saved intent (`plannedUserItemID` is in `intents`). The record then correctly reports no unsent text, and a held-input row with Send appears.
  2. The result is still not `.dispatched`, so the draft is kept.
  3. Continue… reopens with the same text. The user can send it twice: once through Continue, once through the held row's Send.
- **The same rule makes the draft stale whenever the record is newer.** For any result where the action was recorded, the record is the authoritative copy (unsent text, intent, or resolution). The draft is only needed for refusals that happen before anything is recorded.
- **Evidence.**
  - Draft-first precedence: `AgentModeViewModel+RecoveryList.swift:143-147` and `AgentRecoveryListBanner.swift:140-144`.
  - The clear rule considers only `.dispatched`.
  - `unsentContinuationText` returns `nil` when an intent carries the text (`AgentRecoveryActionModels.swift:343-345`).
- **Smallest fix.** Clear the draft whenever `report.result` shows the action was recorded (any `.completed` or `.outcomeUnrecorded`), still only when the draft equals the sent text. Keep it for `nil`, `.refused` and `.disabled`. The editor then falls back to `unsentContinuationText`, which is the same text for `notDispatched` and the correct nothing for intent-carried or resolved text. Combine this with L1, which covers the resolved case.

### L4: R7 is proven for the catalog order, not for the sheet, and the blocker semantics weren't checked
- **Sheet order.** The new tests assert `catalog.items.first`, but the live check is the sheet's first "Needs action" row. If `recoveryNeedsAttentionRows` groups, sorts or filters (for example by session or workspace), the reorder changes nothing on screen.
- **Blocker order.** `addRuntimeRestrictions` used to run last, so anything it wrote into `builder.blockers` won. If any later builder assigns `blockers[key] = …` rather than merging, a runtime blocker can now be overwritten. Automatic work, such as scheduled sends, could then run while a process is alive. The worker checked the `records`/`bindings` dependencies but not `blockers`.
- **Evidence.**
  - `AgentRecoveryCatalog.swift:309-311`: the reorder.
  - `AgentRecoveryRuntimeOwnershipTests.swift:282, :306`: both tests assert only on `catalog.items`.
- **Smallest fix.**
  - Grep `Builder` for `blockers[` assignments and confirm every write merges.
  - Add one assertion that the first row of `recoveryNeedsAttentionRows(includeDismissed: false, …)` is the survivor.

### L5: V1's persistence is tested on the classifier, not on the message the composer actually gets
- **Failure scenario.** The classifier relies on exact string equality. If the send or schedule completion wraps, prefixes or trims the refusal before it becomes `effects.blockedMessage`, `isRecoveryAdmissionRefusalNotice` returns false. The notice then silently falls back to 3 seconds, which is the V1 failure the step exists to fix, and no test catches it.
- **Evidence.**
  - `AgentInputBar.swift:2410-2416` and `:2486-2493` classify `blockedMessage`.
  - `AgentRecoveryVMProducerAdmissionTests.swift:1542` tests only the mapping's output.
- **Smallest fix.** In `AgentComposerSubmissionAttemptTests`, which already computes `effects.blockedMessage`, add one case with an admission refusal. Assert that `isRecoveryAdmissionRefusalNotice(effects.blockedMessage!)` is true.

---

## P3

### L6: The "not sent" note is missing for refusals before the action is recorded
- **Scenario.** "Provider wasn't recorded", stale, or busy refusals happen before the action is recorded, so `hasUnsentContinuation` is false. The row shows only the reason, even though the user's typed text was not sent.
- **Evidence.** The new test asserts exactly this: `AgentRecoveryReconciliationTests.swift:~2221`, "no unsent text recorded, so no note".
- **Impact.** Low. The draft is kept, but it is lost on relaunch because nothing was recorded.
- **Fix.** Pass `hasUnsentContinuation: facts.hasUnsentContinuation || (the refused action was a typed continuation)`. For example, prefix the note in `performRecoveryListContinuation` when the failure came from a continuation and no action was recorded.

### L7: The new draft closures default to no-ops
- **Scenario.** Any other or future `AgentRecoveryListActions` construction silently loses R5: no write-through, and nothing read on open.
- **Evidence.** `AgentComposerUIModels.swift:628-631`.
- **Fix.** Make `continuationDraft` and `updateContinuationDraft` required (no defaults). The compiler then finds every construction site.

### L8: Matching the classifier by text, and its coverage
- `recoveryAdmissionFailedMessage` makes some real save failures persistent too. This is benign: they clear on the next edit, and the draft is kept.
- A new `AgentRecoveryAdmissionRefusal` case with a new sentence isn't added to the classifier array automatically. The test's case list is maintained by hand.
- `recoveryAdmissionStaleMessage` (input held for the next launch) stays at 3 seconds, although it is arguably the notice users most need to read.
- **Fix.** Derive the test's case list from `CaseIterable`, or make the test switch over every case. Decide explicitly about the stale message.

### L9: The banner can drop the reason entirely
- **Scenario.** A run card's buttons can take most of the row width. The note-first error (around 50 characters at 10 pt semibold) can then fill both banner lines, and the reason is cut off. Run rows have no View button.
- **Evidence.** `AgentRecoveryListBanner.swift:116-120`.
- **Fix.** Add `.help(row.error ?? row.detail)` to that `Text`.

### L10: The persistent notice can go stale
- Once the hold is lifted, for example by Check or "It stopped", the crash-held sentence stays until the next edit or attempt.
- On a tab switch to a tab whose draft text is identical, `onChange` doesn't fire, so tab A's notice stays on tab B.
- **Impact.** Cosmetic. Accept or defer.
- **Evidence.** `AgentInputBar.swift:832`.

---

## Recommendations

- **Fix L1 before commit.** It is the remaining path where typed text disappears from every surface. Do it together with L3's "record is authoritative once the action was recorded" clear rule. Between them, the draft covers only pre-record refusals, and every recorded outcome either keeps the text on the card or moves it to the composer.
- **Fix L2 cheaply** by moving the draft dictionary onto the recovery coordinator, beside `catalogActionStates`. This removes the window-close and window-move cases at no cost in design.
- **Before the live re-check,** add the L4 sheet-row assertion with the `blockers` merge check, and the L5 end-to-end `blockedMessage` test. Both are small, and each guards a fix whose live check would otherwise be the first evidence that it works.
- **Take L6–L9 if cheap.** L7 (required closures) and L9 (`.help`) are one-liners. List L8 and L10 as deferred.
- **Keep the live verifier steps as written.** Add one step for L1: a survivor finishes, then Continue with custom text, then check where the text went.