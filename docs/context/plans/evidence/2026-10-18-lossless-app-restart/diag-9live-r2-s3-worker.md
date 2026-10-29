# 9-live round 2, S3: why Codex Reconcile said there was no new history
Scope: read when the task touches Codex Reconcile on an interrupted turn and its history matching.
Authority: Reference
Last-verified: 2026-10-29
Covers: read-only diagnosis of S3 from the round-2 live check

Read-only diagnosis. No source edits, no commits. Code references are to HEAD `1fd160d7`; there are no uncommitted `Sources` changes that affect this path. The finding is S3 in [verifier-9live-r2-results.md](verifier-9live-r2-results.md); the Step 5 change is described in [fix-9live-codex-turn-worker.md](fix-9live-codex-turn-worker.md).

## Short answer

The recorded turn ID **was** used, and Codex **did** find the aborted turn. The recovery read asks `thread/turns/list` without `itemsView`, and the app-server then defaults to a **summary** of each turn. For X2's aborted turn, that summary held only the user message. The summary was parsed as if it were the turn's full item list.

1. `[userMessage]` passes `recoveryItems`, so `historyObservation` is non-nil and the "found, but couldn't be imported" text is never reached.
2. **First click:** the planner recorded the user-message row in the native-item ledger (0 rows shown). The outcome was `importedUnconfirmed`, which shows no inline text, so the verifier saw no change and clicked again.
3. **Second click:** the ledger already held that row, so the "nothing new" guard returned "The provider has no new history for this conversation."

The text came from the second of two Reconciles. The first one silently "imported" a user-message-only summary.

## Trace (Reconcile on a Codex run card)

| Step | Where | What happens for X2 |
|---|---|---|
| 1. Turn ID lookup | `AgentModeViewModel+RecoveryActions.swift:144-151` (span fallback), `:190-194` (record wins) | `.reconcileHistory` sets `readsRecordedProviderTurn = true`. The run attempt `882F8F10…` has the `providerTurnID` key, so `codexTurnID = "01a1837c-a8a3-7c03-a0bb-7697909a0ab6"`. Continue, Reconcile and Continue in new conversation share this branch; Check reaches the same performer through `performRecoveryResumeAction` (report hook). |
| 2. Performer | `:372-392` → `reconcileRecoveryHistory` `:1167` | No Codex baseline or cursor gate runs before the read. The Claude baseline preflight at `:1197-1211` is Claude-only. |
| 3. Observation | `recoveryHistoryObservation` `:1465-1505` → `codexCoordinator.observeRecovery` → `CodexNativeSessionController.observeRecovery` `:1806` | `thread/turns/list` with params `threadId`, `limit: 20`, `sortDirection: "desc"` at `CodexNativeSessionController.swift:1850-1857`. **No `itemsView`.** |
| 4. Parse | `recoveryObservation` `:1893-1938`, `recoveryItems` `:1941-1959` | Exactly one turn matches the ID, so `turnID` is set and `terminal = .interrupted`. `recoveryItems(turn["items"])` gets the summary `[userMessage]`, which is all supported types, so the result is `[Item(userMessage)]` and not `nil`. `turn["itemsView"]` is never read. |
| 5. Adapter | `CodexRecoveryAdapter.historyObservation` `CodexRecoveryAdapter.swift:115-153` | `items` is non-nil, so the adapter returns an observation with one row: `nativeEntryID "<turn>/<userItem>"`, `item nil`. `unusableObservationText` (`:106`) is never called because the `guard let observation … else` at `RecoveryActions.swift:1495-1500` doesn't fire. |
| 6. Overlap preflight | `:1271-1284` | One user row with no chat item doesn't overlap, so it passes. |
| 7. Plan | `AgentProviderHistoryImportPlanner.plan` `AgentProviderHistoryImport.swift:133-170` | The row key is new, so it is appended to `ledger.nativeItems` with no chat item and nothing in `appended`. |
| 8. "Nothing new" guard | `RecoveryActions.swift:1310-1313` | **First click:** the ledger count changed, so the guard passes. The save commits, the cursor commits, and the result is `.imported(.unconfirmed, rowCount: 0)` → runner `AgentRecoveryActionRunner.swift:275-276` → `importedUnconfirmed` → `performRecoveryResumeAction` returns `nil` at `:291` (no inline text). **Second click:** the same row key is already known, so neither appended items nor the ledger count change, and the result is `.nothingImported("The provider has no new history for this conversation.")`. |

## Evidence

**Recovery record** (`AgentRecovery/v1/sessions/8F93931E-….json`, excerpt):

```text
actions[0]: kind reconcileOnly, reservedAt 1793209504844, outcome importedUnconfirmed @1793209505807
actions[1]: kind reconcileOnly, reservedAt 1793209550340,
            outcome notDispatched, reason "The provider has no new history for this conversation."
historyCursors: [{provider codex, conversationID 01a18376-008a-…, importID 6D7A4090-…,
                  completeLineOffset 0, committedAt 1793209505757}]
runAttempts[1]: runAttemptID 882F8F10-…, providerKind codexExec,
                providerTurnID 01a1837c-a8a3-7c03-a0bb-7697909a0ab6, no terminal
```

The two actions are about 45 s apart (00:45:04 and 00:45:50 local). This matches the verifier's note in `cycle15/p3b/results.json` (`V4_E9`): "Check provider history clicked … once, then a second time after the first click showed no visible change".

**Session file** (`AgentSession-8F93931E-….json`, `providerHistoryRecovery`):

```text
nativeItems: [{provider codex, rowKind userMessage, nativeSessionID 01a18376-008a-…,
               nativeEntryID "01a1837c-a8a3-7c03-a0bb-7697909a0ab6/01a1837c-af5f-7892-857d-51a327b5ab55"}]
lastImportCommit: {importID 6D7A4090-…, rowCount 0}
```

The `nativeEntryID` prefix is the recorded turn ID. This shows the observation found exactly that turn, and its item list was only the user message (`01a1837c-af5f-…-51a327b5ab55` is the rollout's `UserMessage` item ID). `items` (the suffix) is empty, so no row was shown.

**Rollout** (`~/.codex-auth-switcher/app-server/workers/pro-acc01/sessions/2026/10/29/rollout-…-01a18376-008a-….jsonl`): the aborted turn's persisted items are much richer than what the observation saw:

| Line | Event | Item |
|---|---|---|
| 21 | `item_completed` | `UserMessage` `01a1837c-af5f-…-51a327b5ab55` |
| 22 | `item_completed` | `AgentMessage` (phase `commentary`): "I'll run the requested foreground sleep command now." |
| 28, 34, 48 | `item_completed` | `Reasoning` |
| 24–72 | `custom_tool_call` / `function_call` | `exec` and `wait` calls |
| 75 | `turn_aborted` | reason `interrupted` |
| 76 | `item_completed` | `CommandExecution` `sleep 1200`, status `failed`, exit −1 |

A full item view would include `agentMessage`, `reasoning` and `commandExecution`. `recoveryItems` returns `nil` for the last two, which is exactly the Step 5 path.

**Protocol** (the repo's exported schema, `prompt-exports/openai-pricing-evidence/codex-app-server-schema/v2/ThreadTurnsListParams.json`):
- `itemsView`: "How much item detail to include for each returned turn; **defaults to summary**".
- `TurnItemsView.summary`: "`items` contains only a display summary for this turn".
- `full`: "every ThreadItem available from persisted app-server history".
- `Turn.itemsView` echoes the view in each returned turn.

This is consistent with what was observed: a summary of an aborted turn with no final answer is `[userMessage]`. The live app-server binary wasn't run, per the brief.

The codebase already knows this field. `listNewestTurn` / `requestNewestTurnListing` (`CodexNativeSessionController.swift:1447-1500`) send `itemsView: "notLoaded"` and retry without it on `isTurnsListItemsViewRejection` (`:1620`), memoized as `turnsListRejectsItemsView` (`:653`). The recovery observation added later doesn't use any of this.

## Answers to the brief's questions

- **Is the recorded turn ID used?** Yes, for Continue, Reconcile and Continue in new conversation (`:144-151`, `:190-194`), and therefore also for Check through the same performer. Step 5 worked as designed.
- **Does the history source return the aborted turn?** Yes. One turn has that ID and its status is interrupted. But its `items` is the default summary (`[userMessage]`), not the turn's items.
- **Does a "no new history since the baseline" check run before the turn lookup?** No. For Codex, nothing gates on a baseline or cursor before the read; the Codex cursor (`completeLineOffset 0`) filters nothing. The only "nothing new" check is the post-plan guard at `:1310`. It fired on the second click because the first click had recorded the summary's user-message row in the ledger.
- **Why did the first click show nothing?** `importedUnconfirmed` maps to `nil` inline text (`:291`), even when 0 rows were imported. That is a separate wording gap. It is what made the verifier click a second time.

## Smallest fix

All changes are in `CodexNativeSessionController.swift`. Nothing else needs to change.

1. **Request the full view.** In `observeRecovery`'s `thread/turns/list` params (`:1853-1856`), add `"itemsView": "full"` unless `memo.turnsListRejectsItemsView`. On `isTurnsListItemsViewRejection(error)`, set that memo and retry once without the field, mirroring `listNewestTurn` (`:1456-1475`). A server that rejects the field predates item views and returns full items (`Turn.itemsView` defaults to `full`).
2. **Fail closed on a partial view.** In `recoveryObservation` (`:1893`), pass `nil` items when the matched turn's `itemsView` is present and isn't `"full"`, so that a summary or `notLoaded` view can never be imported as the turn's items:

   ```swift
   let view = (turn["itemsView"] as? String)?.lowercased()
   let items = (view == nil || view == "full") ? recoveryItems(turn["items"]) : nil
   ```

   An interrupted or failed turn then gives `historyObservation == nil` → `unsupportedTurnItemsText`. A completed turn still confirms completion with zero rows (the `terminal == .completed` branch at `CodexRecoveryAdapter.swift:120`).

With (1) alone, X2's full items include `reasoning` / `commandExecution`, so `recoveryItems` returns `nil` and Reconcile says "Codex's record of the interrupted turn was found, but its items couldn't be imported; nothing was imported." (2) is the guard for servers that ignore the request field. `thread/read` (legacy fallback, `:1874-1881`) returns full turns and needs no change.

**Existing state.** X2's session ledger now holds the summary's user-message row. After the fix, the turn's observation is `nil` (unusable), so the planner never runs and that ledger row is harmless. A turn whose full items are only user and agent messages dedupes the user row by the same key.

**Optional, separate.** An `importedUnconfirmed` result with `rowCount == 0` could return short inline text instead of `nil` (`:291`), so a zero-row Reconcile isn't silent. That is a wording choice for the main agent and isn't needed for S3.

## Unit tests that would have caught it

Both belong in `AgentRecoveryReconciliationTests`, next to `testCodexObservationRequiresARegisteredTransportAndOnlyReads` (`:120`) and `testCodexAdapterTellsAFoundTurnWithToolItemsFromAMissingTurn` (`:44`).

1. **Request shape with a server-faithful fake.** Use the `requestExecutor` seam (it already receives `params`). Have it emulate the protocol default: return `items: [["id":"u1","type":"userMessage"]]` and `itemsView: "summary"` unless `params["itemsView"] as? String == "full"`, otherwise return the full list (`userMessage`, `agentMessage`, `reasoning`, `commandExecution`) with `itemsView: "full"`. Assert:
   - the `thread/turns/list` params carry `itemsView == "full"`;
   - `CodexRecoveryAdapter.historyObservation(observation) == nil`;
   - `unusableObservationText` is the "was found, but its items couldn't be imported" text.

   Today this fails: no `itemsView` is sent, the summary comes back, and the observation is non-nil.
2. **Parser guard.** `CodexNativeSessionController.recoveryObservation` on `[["id":"turn-expected","status":"interrupted","itemsView":"summary","items":[["id":"u1","type":"userMessage"]]]]` must give `turnID == "turn-expected"`, `items == nil`, `historyObservation == nil` and the found text. Add a row with `"status":"completed"` (completion still confirmed, zero rows) and one with `"itemsView":"full"` (items parsed as now).

An itemsView-rejection row (reuse the error from `CodexNativeResumeLifecycleTests.swift:1163`) should pin the single retry without the field and the memo. Optionally, an end-to-end Reconcile run twice through `reconcileRecoveryHistory` with the summary-shaped fake should give `.nothingImported(unsupportedTurnItemsText)` both times with the ledger unchanged. That pins that a summary never writes a ledger row.

The existing tests missed it because every Codex fixture hands `recoveryObservation` a hand-built **full** item list (for example `:44-74`), and the request-shape test (`:120-166`) records only method names, never params. No fixture modelled the server's default view.

## Changes

The smallest fix is implemented. Nothing was committed or staged. The zero-row `importedUnconfirmed` text was not changed, as instructed.

**Source: `CodexNativeSessionController.swift` only.**
- `:656`: new memo flag `turnsListRejectsFullItemsView`. It is separate from the newest-turn listing's `turnsListRejectsItemsView`, because a server may reject `notLoaded` yet accept `full`.
- `:1853-1865`: the nested `listTurns(fullItemsView:)` in `observeRecovery` sends `itemsView: "full"` (`:1860`).
- `:1867-1885`: if the request fails with `isTurnsListItemsViewRejection`, the flag is memoized, the rejection is logged, and the request is retried once without the field. Other failures keep the existing unsupported-method fallback to `thread/read`.
- `:1944-1954`: `recoveryObservation` passes `items: nil` when the matched turn's `itemsView` is present and isn't `"full"`. An absent view is still treated as full.

**Tests (`AgentRecoveryReconciliationTests`).**
- `testCodexObservationRequestsTheFullItemViewAndNamesAFoundToolTurn` (`:171`):
  - Its fake answers like the server: `summary` (`[userMessage]`) unless the request asks for `"full"`.
  - It asserts the request carries `itemsView == "full"`, the turn is found and interrupted, `items == nil`, `historyObservation == nil`, and the "was found, but its items couldn't be imported" text.
  - A second fake rejects the field (`unknown field \`itemsView\``). The test asserts one retry without it, items parsed from the full turn, and that the rejection is remembered: requests `["full", nil, nil]` over two observations.
- `testCodexObservationTreatsAPartialItemViewAsUnavailableItems` (`:239`):
  - An interrupted `summary` turn gives `items == nil`, a nil observation and the found text; `notLoaded` gives `nil` items.
  - A completed `summary` turn still confirms completion with zero rows.
  - A `full` view parses as before.
- Helpers: `makeObservationController` (`:277`) and `ReconciliationParamsLog` (`:5024`), which records request params.

**Validation (all exit 0).**

| Command | Ticket | Result |
|---|---|---|
| `make dev-test FILTER=AgentRecoveryReconciliationTests` | `c15312b3-cca1-4d9e-9a5f-ae245e3c19df` | 76 tests, 0 failures; both new tests passed by name |
| `make dev-test FILTER=CodexAppServerRuntimeFenceTests` | `6529f4ae-0dbc-4004-9f52-cb345c204dd0` | 13 tests, 0 failures |
| `make dev-test FILTER=CodexNativeResumeLifecycleTests` | `fd9f2d48-1d5f-413b-99cc-35c79b3673c3` | 31 tests, 0 failures |
| `make dev-lint` | `0558b6ac-4eba-4ae7-853b-624f5f902bf5` | clean |

The first lint run (`4f483a55`) flagged two `docComments` errors on the nested function's comment. They were changed to `///`, a comment-only change made after the test runs.

**Not run:** the full suite and any live check. No mutation check was run.

## Round-0 review: cut by the owner

Review items: B item 6 (`oracle-review-…-465b.md`), B item 10, and A's second P2 (`oracle-review-…-3817.md`). The owner's review policy keeps P0/P1 plus only truly cheap, relevant items. These items are P2/P3 and fail closed today, so they were **dropped**:
- **Retry error handling.** The retry without `itemsView` doesn't get the first attempt's generation check or the `thread/read` fallback.
- **A rejected `full` value.** "unknown variant `full`" isn't classified as an itemsView rejection, so it throws and Reconcile is blocked.
- **The three proposed tests** for these paths.
- **The item-10 check.** It was looked at before the cut. A completed turn returned as `summary` confirms completion and returns `.imported(.confirmed, 0)` before the "no new history" guard (`AgentModeViewModel+RecoveryActions.swift:1311`). Its text is therefore never "no new history".

The partial edits were reverted. Code and tests are as described in "Changes" above.

| Command | Ticket | Result |
|---|---|---|
| `make dev-test FILTER=AgentRecoveryReconciliationTests` | `3db5a39b-e991-424d-ba8b-b5b20b6528e8` | 78 tests, 0 failures |
| `make dev-lint` | `7ae2bb12-ac51-4f50-8089-9878e8841c64` | clean |

The count is 78, not 76, because another worker added Claude tests to the same file (its own hunk near `:1717`).
