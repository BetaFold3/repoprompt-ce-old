# 9-live fix 2 (recovery list): OracleB review, round 2

Scope: read when the task touches the recovery list's Continue editor text, refused-continuation row text, the order of surviving-process items, or the composer's send-refusal notice.
Authority: Reference
Last-verified: 2026-10-28
Covers: the OracleB review (round 2) of the recovery-list diff, copied from its export; the fixes are in fix-9live-list-worker.md


# Round 2 (final) re-review: 9-live Step 2, recovery list

**Bottom line:** every finding you listed is fixed or has an acceptable residual. The round-1 fixes introduced two new P1s, both narrow and both cheap to fix. One of them sits on the exact path the N3 fix tells the user to take.

I reviewed only `9fix-list-r2.diff`, the worker notes and the current `AgentModeViewModel+RecoveryList.swift`. I ran nothing. Anything that depends on code outside these files is marked **(verify)**. Line numbers are the worker's for `+RecoveryList.swift` and approximate.

## 1. Status of the findings you asked about

| ID | Status | Evidence / remark |
|---|---|---|
| **N1** (orphaned Continue draft) | **Fixed for the main paths** | `rescueOrphanedRecoveryContinuationDrafts` (~:903) runs at the end of `performRecoveryListAction` (~:832) and `performRecoveryListContinuation` (~:891). It decides "card still offers Continue" with the row builder's own `recoveryRunActions` (`recoveryCardOffersContinue`, ~:935). There are real-record tests for Reconcile → `importedCompleted` and for a newer edit after a dispatched send. The new P1-A below is a regression in this helper. |
| **N2** (double append) | **Fixed as stated, but see P1-B** | `appendAfterBlankLine(expectedPrior:)` plus `recoveryComposerAppendResult` make the "store, then event" sequence idempotent; `testComposerAppendIsAppliedOnce` covers it. The handler still computes from the live text, which loses text when two draft events land in one main-actor turn. |
| **N3** (only into a normal box) | **Fixed, untested** | `moveRecoveryContinuationTextToComposer` (~:974) gates on `composerState == .ready` and `unsavedPredecessorInputs.isEmpty`; otherwise it keeps the draft and returns the "busy" text. The exit path it tells the user to take is P1-B. |
| **P3 tab-match** | **Fixed (no code change needed)** | `latch.complete` already drops `blockedMessage` on a tab mismatch. The new assertion (`currentTabID: UUID()` → `blockedMessage == nil`) is evidence, not just a claim. |
| **R1-01** (newer edit orphaned) | **Fixed** | The `.moveToComposer` branch moves `dict[rowID] ?? text`. `.clear` removes only an equal draft, and the helper moves a leftover after the card resolves. Tests cover both the dispatched and the finished case. |
| **R1-02** (originating window lost the session) | **Fixed for another window hosting it; residual when no window does** | `recoveryComposerHost` (~:958) searches the other windows on the same coordinator. This lookup has no test. |

## 2. New P1 findings

### P1-A: The helper acts on rows whose own action is still in flight. It can move already-sent text, move text twice, and clear `.working`

**Evidence**
- The helper looks at every draft of the session (`rowIDs = dict.keys.filter { item.sessionID == sessionID }`).
- It skips a draft only if that card still offers Continue. It never checks `coordinator.catalogActionStates[id]`.
- For other rows it then calls `setCatalogActionState(.failed(message), for: id)`.

**Failure scenario (same window, same session, two rows)**
1. Row B (a run card) is in the await of a Continue with text T. The runner has already written the `dispatched` outcome, so the card is `resolvedByAction`, but the runner hasn't returned yet.
2. The user acts on row A of the same session, for example removing an expired question. A's `performRecoveryListAction` finishes and runs the helper.
3. B's draft T is found, and B's card no longer offers Continue. T is moved into the message box with "…the message you typed for it **wasn't sent**". In fact T was sent.
4. B's state changes from `.working` to `.failed`, so B's working guard is gone.
5. B's own completion then runs `.clear`. The draft is already gone, so nothing happens. The composer now holds sent text labelled "not sent". That invites a second send.

The `importedCompleted` variant moves the text twice:
- A's helper moves T.
- B's `.moveToComposer` branch then takes `dict[rowID] ?? text`, which falls back to `text`, and moves T again.

The window is narrow (the time between the outcome write and the runner returning), but it answers your question directly: yes, the helper can move sent text and can move it twice.

**Smallest fix:** in the helper's loop, add one line:
```swift
if id != rowID, coordinator.catalogActionStates[id] == .working { continue }  // its own completion disposes of it
```
The `id != rowID` exception matters: the acted row is still `.working` at that point, because the caller clears it after the helper returns.

### P1-B: Two draft events in one main-actor turn lose text. The N3 "resolve first" exit triggers this by design **(verify the two mechanisms below)**

**Evidence**
- The input bar handles `draftRestorationEvent` by computing the result from `localInputText` and then calling `actions.storeDraft(event.tabID, restoredText)` (diff `AgentInputBar.swift` ~:843-861). The worker notes call this an `onChange`.
- `onChange` and props-driven observation coalesce. If two events are set before the view updates, the handler sees only the last one.
- Under N3, the user is told to "Resolve this session's saved draft first". That resolution is a list action, after which the helper runs in the same turn:
  - `resolveRecoveryListDraft(.restoreToComposer)` calls `applyRecoveredComposer(content…)` and returns;
  - then `rescueOrphanedRecoveryContinuationDrafts` calls `placeUnsentRecoveryContinuationInComposer`;
  - there is no `await` in between.

**Failure scenario**
1. A leftover draft T is held back by N3 because there is an unsaved predecessor R.
2. The user clicks **Restore** on R.
3. `applyRecoveredComposer` stores R and posts its own restore event (**verify**: the notes say the bar reads the session's draft only on appear and tab change, so the restore paths must push through an event).
4. The helper immediately stores `R\n\nT` and posts `append(T, expectedPrior: R)`.
5. The bar sees only the second event. The live text is `""`, which is not `R\n\nT`, so the handler produces `T`.
6. `storeDraft(T)` overwrites the session's draft and is forwarded to the lane. R, the draft that was just resolved out of `unsavedPredecessorInputs`, is now gone from every surface.

The same applies to:
- **Restore** on a held draft;
- **Retry load** on `composerRestoreFailed`;
- any single pass that moves two drafts, i.e. the `.moveToComposer` branch plus the helper for another row, or the helper for two rows.

View-model tests can't catch this, because `session.draftText` is correct at the view-model level. The overwrite happens in the bar.

**Smallest fix:** make the append event carry the result the view model stored, and have the handler apply that result instead of recomputing from the live text:
- Change the event to `.appendAfterBlankLine(result: String)`, where `result` is the text the view model just stored.
- In the handler, set `restoredText = result` (skip it if `live == result`).

This is safe because:
- the bar writes every keystroke to the session draft, so the session draft is never older than the live text;
- the view model computes `result` from the session draft after any earlier store in the same turn.

It also keeps the original N2 fix: applying `result` again changes nothing. **Verify** that `applyRecoveredComposer`, `resolveHeldRecoveryComposer` and `retryRecoveryComposerRestore` store `session.draftText` synchronously. If they do, `result` already includes R.

### Your specific questions

- **Move text that was already sent?** Only through P1-A. There is one more condition to **verify**: the editor's Send button must pass exactly the binding text. If it trims, `removeRecoveryContinuationDraft(ifEqualTo:)` misses after a dispatched send, and the helper moves the sent text with the "wasn't sent" note.
- **Move text twice?** Only through P1-A. Within one action the paths don't repeat:
  - the branch clears the entry before the helper runs;
  - the busy path re-stores the same text idempotently;
  - the main actor serialises helpers.
- **Move into the wrong session?** No.
  - The session ID is captured before the await from the acted row's own item.
  - Other rows are filtered by `item.sessionID == sessionID`.
  - The host is found with a live, non-retired lane on that session ID, and the move goes through the host view model, so the right window's `currentTabID` and `storeDraftText` are used.

## 3. The known residual: no window hosts the session

**I agree it is P2**, with two caveats you should accept explicitly:

1. **It's invisible, and it is lost when the app quits.** `continuationDraftsByRowID` lives in memory. After `importedCompleted`, the record's copy of the text no longer appears anywhere, because `unsentContinuationText` returns `nil` for a resolved card. If the user quits before reopening the session, the text is gone from every surface.
   - It stays P2 because the only way to reach it is to close the session's tab or window during the await.
2. **The row doesn't say the text is being held.** In the no-host `else` branch, `failure` stays as the runner's reason, for example the "verified completion" sentence, and nothing mentions the user's text.
   - Cheap fix: in that branch, set `failure = "Your message wasn't sent. Open this session to get it back in the message box."`.
   - This works with the existing code: the row's **Open** is a list action, so after the open completes the helper finds the new host and moves the text.

## 4. P2/P3 (brief)

- **P2: no tests** for the N3 gate (held, failed, predecessor) or for the cross-window host lookup. At minimum, add a view-model test where an unsaved predecessor plus a leftover draft, followed by **Restore**, ends with `session.draftText == R\n\nT`.
- **P3: wording for `.joined` / `.priorAction`.** These results keep the draft, and the helper may then move it with "wasn't sent" while the joined or prior action's delivery is unknown. It's misleading but needs the user to act. Either use a neutral message or skip the acted row for these results.
- **P3: drafts on dismissed or auto-cleared cards are kept.** `recoveryCardOffersContinue` ignores attention and dismissal, so the draft stays on a hidden card. It can still be reached through "show dismissed".
- **P3: drafts whose item left the catalog** (other than the acted row) are never moved or pruned.
- **P3 (verify): `window.agentModeViewModel` in `recoveryComposerHost`** must not lazily build a view model for windows that have none.
- **P3: appending during an in-flight submit** makes `inputStillMatches` false, so the box isn't cleared and the sent text stays next to the moved text.
- **Carried over, as you deferred:** the L5 view-model-level test, and relaunch duplication after `.outcomeUnrecorded(.notDispatched)`. Both are in the live-verifier notes.

## Recommendations

1. **Fix P1-A before commit.** It's one line: skip other rows whose state is `.working` in `rescueOrphanedRecoveryContinuationDrafts`, keeping the `id != rowID` exception. Add a test:
   - row B is in a seam await, and the seam has already written the `dispatched` outcome;
   - run an action on row A of the same session;
   - assert that B's draft is not moved and B's state is still `.working`.
2. **Fix P1-B before commit.** Change `appendAfterBlankLine` to carry the stored `result`, and have the input bar apply it instead of recomputing from the live text. First verify that the restore paths store `session.draftText` synchronously and post their own event. Update `testComposerAppendIsAppliedOnce` to match, and add the N3 Restore test from §4.
3. **Downgrade the no-host residual to P2**, with the one-line row message from §3, and record the "lost when the app quits" caveat in the ledger.
4. **Verify the Send button passes the exact editor text** (no trimming). If it trims, P1-A's "sent text moved" outcome also happens without any race.
5. **Leave unchanged:** the disposition table, the coordinator-owned store, the `expectedPrior` idea (subsumed by the stored-result fix), the R7 ordering, the persistent notice, and the `#if DEBUG` hook. Add to the live-verifier steps:
   - leave a draft held back by N3, click **Restore** on the saved draft, and confirm both texts are in the box;
   - close the session's tab during a Continue, then use the row's **Open** to bring the text back.