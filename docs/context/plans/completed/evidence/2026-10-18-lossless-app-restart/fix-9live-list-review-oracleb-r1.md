# 9-live fix 2 (recovery list): OracleB review, round 1

Scope: read when the task touches the recovery list's Continue editor text, refused-continuation row text, the order of surviving-process items, or the composer's send-refusal notice.
Authority: Reference
Last-verified: 2026-10-28
Covers: the OracleB review (round 1) of the recovery-list diff, copied from its export; the fixes are in fix-9live-list-worker.md


# Re-review, round 1: 9-live Step 2 (recovery list)

I reviewed only the supplied diff, the worker notes, the two round-0 reviews and the full `AgentModeViewModel+RecoveryList.swift`. I ran nothing. Where I rely on code outside these files, I mark it **(verify)**.

## 1. Status of the round-0 findings

| ID | Status | Evidence / remark |
|---|---|---|
| **L1** | **Partly fixed** | `performRecoveryListContinuation` (diff `+RecoveryList.swift` ~:845-875) moves the text to the message box for `.completed(.importedCompleted)` when the session is still open in this window. Three gaps remain. If the tab closed during the await, the draft stays keyed to a card that no longer offers Continue. A Reconcile that resolves the card orphans the draft the same way (new **N1**). The view-side append is not exercised by any test (**N2**). |
| **L2** | Fixed | `AgentRecoveryCoordinator.continuationDraftsByRowID` (diff ~:532). The view model has thin forwarders (~:151-158). There is a cross-window test. |
| **L3** | Fixed | The disposition table clears the draft for every recorded outcome the record holds, and keeps it for `nil`/`.disabled`/`.refused`/`.joined`/`.priorAction`. The `switch` has no `default`, so a new result case won't compile until it is classified. **(Verify)** that `.refused` and `.disabled` are only ever returned before any action or intent is written. Otherwise a kept draft could sit alongside a held intent carrying the same text, which is the original double-send shape. |
| **L4** | Fixed | `testSurvivorIsTheFirstNeedsActionRowOfTheSheet` asserts on `recoveryNeedsAttentionRows`, the sheet's own filter. The blocker analysis (only `.crashHold`; runtime items write none) is the worker's claim; I can't see `Builder`. |
| **L5** | Mostly fixed | The new test proves the latch passes `.blocked(message:)` through unchanged. It builds that message itself, though, so it does not prove the view model's submit path produces the bare refusal sentence. See P3. |
| **L7** | Fixed | `let continuationDraft`, `let updateContinuationDraft` (diff `AgentComposerUIModels.swift` ~:630-632). |
| **L9** | Fixed | `.hoverTooltip(row.error ?? row.detail)` (diff `AgentRecoveryListBanner.swift` ~:122). |
| **LIST-01** | Fixed, untested | `onChange(of: currentTabID)` → `clearPersistentSteeringNotice()` (diff `AgentInputBar.swift` ~:786-788). A related ordering gap is listed under P3. |
| **LIST-02** | Fixed | `testRecordedContinuationClearsOnlyTheSentDraft` covers the matching draft clearing and a newer edit surviving. |
| **DEBUG hook** | OK | The declaration is inside the existing `#if DEBUG` block (`AgentModeViewModel.swift` ~:694-696). The only use is behind `#if DEBUG … #else … #endif` (`+RecoveryActions.swift` ~:251-260). Release builds call `recoveryActionRunner.perform` unconditionally. |

## 2. New findings

### P1

#### N1: A Continue draft is orphaned whenever the card resolves through anything other than this Continue send

**Evidence**
- Drafts survive the editor closing (`continuationDraftBinding`, diff `AgentRecoveryListBanner.swift` ~:220-229).
- Only `performRecoveryListContinuation` ever disposes of a draft (~:858-873).
- `performRecoveryListAction` (`.reconcileHistory`, `.continueInNewConversation` without the editor, and the rest) never looks at drafts.
- The draft can only be read back through `continuationText`, which exists only while the row offers `.continueTurn` or `.continueInNewConversation` (`recoveryListRow`, `continues`).

**Failure scenario**
1. The user opens Continue… on a run card and types a long message.
2. They close the editor without sending. R5 promises the text is kept.
3. They click **Check history** (Reconcile), which returns `.completed(.importedCompleted)`, so the card becomes `resolvedByAction` and informational.
4. Continue is no longer offered, so the draft sits in `continuationDraftsByRowID` and no surface shows it.

The same happens when:
- the card is auto-cleared while the draft exists (a survivor's turn completes, then Refresh);
- another window resolves the card;
- this is the worker's deviation 5: during the await of a send that ends `importedCompleted` or `dispatched`, the newer edit survives `removeRecoveryContinuationDraft(ifEqualTo:)` but its card is resolved.

This is the step's hard-fail class: typed text disappears from every surface. Reconcile sits next to Continue on the same row, so this needs no race, just a natural sequence.

**Smallest fix:** one helper, called at the end of both `performRecoveryListAction` (resume and reconcile actions on run rows) and `performRecoveryListContinuation`:

```swift
/// A draft whose card no longer offers Continue moves to the session's message box.
private func rescueOrphanedContinuationDraft(rowID: String, sessionID: UUID?) {
    guard let coordinator = recoveryCoordinator,
          let draft = coordinator.continuationDraftsByRowID[rowID] else { return }
    let item = coordinator.catalog.item(id: rowID)
    let stillContinuable = item.map { $0.attention == .needsAction && !$0.actionFacts.resolvedByAction } ?? false
    guard !stillContinuable else { return }
    coordinator.continuationDraftsByRowID[rowID] = nil
    let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, draft != Self.recoveryContinueDefaultText,
          let session = sessionID.flatMap({ recoveryListTabSession(sessionID: $0) }) else {
        coordinator.continuationDraftsByRowID[rowID] = draft   // keep; nothing safer available
        return
    }
    placeUnsentRecoveryContinuationInComposer(draft, session: session, message: Self.recoveryContinuationFinishedMovedText)
}
```

Use whatever "row still offers Continue" predicate `recoveryRunActions` already uses. That is more precise than the sketch above.

This also answers question 3 (§3). Add one test:
1. Set a draft.
2. Run `performRecoveryListAction(.reconcileHistory)` with `test_recoveryActionResult` returning `.completed(.importedCompleted, …)`.
3. Assert the draft is in `session.draftText` and the dictionary entry is gone.

### P2

#### N2: `appendAfterBlankLine` is applied twice (view model and input bar); possible duplicated text, untested on the view side

**Evidence**
- `placeUnsentRecoveryContinuationInComposer` first writes `storeDraftText(existing + "\n\n" + text)`, then posts a `DraftRestorationEvent(text: text, strategy: .appendAfterBlankLine)`, then calls `syncComposerUIState` (diff ~:931-945).
- The input bar handles the event by appending `event.text` to `localInputText` and calling `storeDraft` (diff `AgentInputBar.swift` ~:858-861).

**Failure scenario (verify):**
1. Something re-reads `session.draftText` into `localInputText` before the event handler runs. Candidates are `syncComposerUIState`, a props-driven sync, or the `isSyncingDraftFromSession` path.
2. The handler then produces `existing\n\ntext\n\ntext` and stores it.

That is duplicated text, not lost text. A user who doesn't notice could send it twice in one message.

The opposite order is safe: the handler computes from the live text, and its `storeDraft` overwrites the view model's write with the same result. The new tests only assert `harness.session.draftText` at the view-model level, so neither order is covered.

**Smallest fix:** make the two writes idempotent. Either:
- for the current tab, skip `storeDraftText` and rely on the event (keeping the store only for non-current tabs); or
- carry the precomputed `combined` text in the event and have the handler apply it only while `localInputText == existing`, and otherwise append.

At minimum, confirm the existing restore strategies use the same view-model-store-plus-event pattern.

#### N3: The text moved into a composer whose recovery state is not normal

**Evidence:** `placeUnsentRecoveryContinuationInComposer` writes into the session's draft without checking `lane.composerState` or `unsavedPredecessorInputs`.

**Failure scenario (verify):** the session's composer is in one of these states:
- `.composerRestoreFailed` ("sending stays paused until it loads");
- a held draft;
- an unsaved predecessor.

Writing the moved text there can either:
- block the existing restore paths, since they require an empty box ("Clear the message box first"); or
- be overwritten by a later successful `retryRecoveryComposerRestore`, if that path replaces the live text.

The second is a text-loss path.

**Smallest fix:** move the text only when the lane's composer state is normal and has no pending predecessor. Otherwise keep the draft and set a row message such as "Your message wasn't sent; resolve the saved draft first". With N1's fix, the draft is rescued later.

### P3 (cheap)

- **LIST-01 ordering variant.** The completion of tab A's send arrives after the user switched to B. `showSteeringUnsupportedNotice(…, persistent: true)` then pins A's refusal on B, unless `AgentComposerSubmissionLatch.complete` already drops `blockedMessage` when `attempt.target.tabID != currentTabID` **(verify)**. Fix: pass `persistent: … && attempt.target.tabID == currentTabID` (`AgentInputBar.swift` ~:2416-2422 and ~:2492-2499).
- **L5 remainder.** Add one view-model-level assertion: a real refused submit, for example with the coordinator not ready, returns a `.blocked` message that `isRecoveryAdmissionRefusalNotice` accepts.
- **Relaunch duplication after `.outcomeUnrecorded(.notDispatched)`.**
  - In this launch the text moves to the composer.
  - After relaunch the open action is superseded, so `unsentContinuationText` (diff `AgentRecoveryActionModels.swift` ~:337-347) returns the same text again, and Continue opens prefilled with it.
  - Both copies are visible, and each send needs a user click, so this is not a hard fail. Mention it in the live-verifier notes.
  - The same rule should be checked for `.outcomeUnrecorded(.dispatched)`. If no adopted intent nullifies it after relaunch, the card would say "was not sent" and prefill text that was already delivered **(verify against the relaunch join)**.
- **No pruning.** `continuationDraftsByRowID` is never pruned for rows that left the catalog. The memory cost is harmless, and N1's helper naturally removes entries.

## 3. Deviation 5: the race on edit during the await

**It is a real text-loss path, but narrow.** It needs a second Continue editor open on the same row while the first send is in flight: another window showing the session, or the banner and sheet. When the choice ends:
- `importedCompleted`: the sent text moves, but the newer edit survives `removeRecoveryContinuationDraft(…, ifEqualTo: text)` and its card is resolved, so it is unreachable.
- `.completed(.dispatched)`: the identical problem, which the notes don't mention. The dispatched result resolves the card, so a surviving newer edit is orphaned too.

**Smallest fix**
- Covered by N1's `rescueOrphanedContinuationDraft` called after the disposition switch.
- If you want only a local patch, in the `.moveToComposer` branch move `coordinator.continuationDraftsByRowID[rowID] ?? text` (the newest revision) and remove the entry unconditionally. In `.clear`, when the result resolves the card and a leftover draft ≠ `text` exists, move that leftover.

## Recommendations

1. **Fix N1 before commit.** Add one helper that moves any leftover Continue draft into the message box once its card stops offering Continue. Call it after every run-row action and after `performRecoveryListContinuation`. It also closes deviation 5 and the dispatched-race variant. Add the Reconcile → `importedCompleted` test.
2. **Resolve N2.** Check whether the input bar can already see the view model's `storeDraftText` before handling the event. If it can, make the append idempotent: carry `combined` plus the expected prior text, or skip the view-model store for the current tab.
3. **Gate the move on a normal composer state (N3)**, falling back to keeping the draft with an explanatory row message.
4. **Take the P3 one-liners if cheap:** the tab-match condition on persistent notices and a view-model-level V1 classifier test. Note the relaunch-duplication behaviour for the live verifier.
5. **Leave unchanged** the disposition table, the coordinator-owned store, the R7 reorder and the DEBUG hook. They look correct, and the hook is release-safe. Keep the worker's added live-verifier step, and add one more: type in Continue, close the editor, click **Check history** on a survivor that finished, and confirm the text lands in the message box.