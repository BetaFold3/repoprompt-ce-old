# Step 4a initial OracleB review

Scope: read when the task touches this lane's bounded O11 saved-input relocation review findings.
Authority: Reference
Last-verified: 2026-10-22

Preset identity verified: OracleB, `7CDD523E-1D7C-47EA-98FE-D5FEA24D2D8C`, explicit selection. Completed on frozen Git snapshot `2026-10-22/2214` (13 O11 code/test files against `deb4ae5335cab845d61be64d63d992eb3e885bb0`), with controlled source context and review policy verbatim. Original export: `prompt-exports/oracle-review-2026-10-22-222030-o11-saved-relocation-a542.md`. Main read the full response. The response below is preserved independently, not synthesized with another lane. No findings have been disposed or fixed yet; OracleC failed authentication and owner input timed out. This is not review approval.

## Response

# Oracle Review



# O11 Step 4a review: saved-input relocation (delta against `deb4ae53`)

This delta implements Send saved for one conclusively unsent saved input A. A pure transcript function moves A to the end of the conversation in a new clean execution turn E, or rebuilds A there if compaction erased it. A's old turn H keeps its ID, its other activities and its interruption. Before any queue receipt or provider byte, the placement is installed and a covering `.written` owner save must succeed. The state is checked again after each await. The synchronous submit path now refuses to send an authorized saved input unless that preparation exists and is still current. Rebuilds use explicit-ownership reconciliation so H and E survive a full refresh, an incremental refresh and a reload. Run and dispatch joins, and the terminal commit, now resolve to E instead of H.

The ordering, the save-coverage gate, the idempotent reuse and the direct-submit bypass refusal all look correct. Two seams outside the supplied slices could break the acceptance criteria and need checking.

## P1

**P1-1: H's terminal state is probably reset during relocation.**
- **Where:** `AgentTranscriptServices.swift:~3115-3122`. `relocatingSavedInput` calls `finalizeTurn(&turn, …, terminalState: nil, isCompleted: turn.completedAt != nil)` on the full historical turn H.
- **Why it's likely:** the doc comment on `preservingInterruptedTurnEnvelopes` (~2865) says the importer's finalize step applies the supplied run state, which is why cancelled or failed envelopes need restoring after a rebuild. With `nil`, H's `.cancelled` or `.failed` state is most likely overwritten.
- **Realistic failure:**
  1. A was queued or steered while turn T was running, so the importer grouped T's output under turn A.
  2. Cold restore marked turn A as `.cancelled` and stamped an interruption.
  3. Send saved runs and H becomes requestless.
  4. `finalizeTurn` sets H's state to completed or nil.
  5. Every later rebuild keeps that wrong state, because `preservingInterruptedTurnEnvelopes` only preserves turns whose existing state is already cancelled or failed.
- **Impact:** the interrupted turn is shown as completed while still carrying an interruption record. That contradicts the "outcome remains H" criterion and the honest-interruption reporting.
- **Tests miss it:** `testSavedInputRelocationKeepsTheHistoricalEnvelopeThroughRefreshSaveAndRestore` sets only `interruption`, never a cancelled `terminalState`.
- **Smallest fix:** before `finalizeTurn`, snapshot `terminalState`, `completedAt` and span `lifecycle`/`completedAt`, then restore them afterwards. Alternatively, pass `terminalState: turn.terminalState`. Add a test with a cold-cancelled H that runs through relocation, a full rebuild and a JSON round trip.
- **If wrong:** if `finalizeTurn` actually keeps an existing state when given `nil`, downgrade this to a P2 test gap.

**P1-2: Placement now runs before deferred hydration.**
- **Where:** `AgentModeViewModel+RecoveryActions.swift:~664-711`. `dispatchRecoverySavedIntent` reads and changes `session.items` and `session.transcript`, installs through `hydrateSession`, and force-saves, all before `submitUserTurn`.
- **What changed:** the previous code passed straight to `submitUserTurn`. When the session wasn't loaded, that path went through `submitUserTurnAfterHydration` → `prepareSessionForRunStart` (`AgentModeViewModel.swift:~16822`).
- **Realistic failure:** the user clicks Send saved on a tab that has a lane but is not yet loaded (for example, just switched to). Relocation sees empty or partial items, so it rebuilds A into an almost empty transcript and installs it. One of two things then follows:
  - The forced owner save writes that projection, which could drop history. Whether the fencing in `ensurePersistenceState` / `hasTranscriptSaveHydrationAuthority` blocks this can't be seen in these slices.
  - Hydration later replaces the placement, and the gate refuses with "not ready". This is the benign case.
- **Tests miss it:** every test asserts `hasLoadedPersistedState == true`, so this path is never exercised.
- **Smallest fix:** add `guard session.hasLoadedPersistedState else { return Self.recoverySavedNotReadyText }` to `stillCurrent()`. Alternatively, await `prepareSessionForRunStart` before preparing, then revalidate.

## P2

**P2-1: E's ownership depends on its span shape.**
- **Where:** `AgentTranscriptServices.swift:~2930-2944`. `isExplicitWorkingTurn` requires `isImportShapedWorkingTurn`, even when `request.id != turn.id`.
- **Failure:** if any non-importer path ever gives E a second span or a non-deterministic span, the next full rebuild no longer treats E as explicit. A then reopens a turn under its own ID, `transcriptByReplacingWorkingTurns` places it in E's slot, and the result has two turns with ID A (H and the rebuilt one).
- **Impact:** `executionTurnID(forUserItemID:)` resolves to A again, so joins and the terminal commit land on H's ID. This is exactly what O11 forbids.
- **Likelihood:** low today, because live transcripts appear to be importer-built only.
- **Smallest fix:** always record a request whose ID differs from its turn ID in `turnIDByItemID`/`requestItemIDs`, regardless of shape. Keep the shape requirement only for requestless envelopes.

**P2-2: The incremental refresh path now does whole-transcript work on every update.**
- **Where:** `AgentTranscriptServices.swift:~3323-3325`. `incrementallyUpdatedTranscriptForFinalTurnWithDiagnostics` now runs `workingDetailTranscript` (a copy) plus `explicitWorkingTurnOwnership` (sorting `allActivities` for every full turn) on each live update.
- **Impact:** ordinary long sessions pay an O(n log n) cost per streamed refresh, on a path that existed to be O(suffix). This is advisory, since timing on this host is noisy.
- **Smallest fix:** compute ownership from the final full working turn only. Suffix items can only belong to that turn, because the suffix starts at the last user item.

**P2-3: Older binaries need a pre-activation note about re-saving.**
- **Where:** `AgentTranscriptServices.swift:~3714-3735` (ownership in `importLegacyItems`).
- **Failure:** a pre-O11 binary that loads and re-saves a relocated session does a plain import and positional merge:
  - H's activities fold into the previous turn.
  - A's ID-keyed turn takes H's slot.
  - E keeps request A.
- **Impact:** A appears twice and H's evidence is reassigned to the wrong turn.
- **Fix:** no compatibility layer. Record in the plan, before activation, that downgrading after any Send saved relocation is unsupported.

## Known boundary (other non-import-shaped full turns)

This is not a new regression. Before this delta, a full rebuild already flattened any multi-span or legacy-shaped full turn by matching IDs and falling back to position. Adding H and E doesn't change that for turns elsewhere: their rebuilt and existing orders line up, and the explicit branch only drops an explicit turn that has no rebuilt match. The bounded refusal for the moved item's own envelope, and for a full turn retained under A's ID, is the right smallest remedy. No wider guard is required.

Ordinary sessions only change behavior when they already contain an import-shaped requestless turn that isn't the leading working turn, such as one left by a finalized scheduled-send removal. That turn is now kept as its own turn instead of being regrouped into the turn before it. This is more faithful, not a regression.

## Verdict

**Not ready to commit.** P1-1 and P1-2 must be resolved, or each shown to be inapplicable from source with a test. Everything else in scope looks sound.

## Validation gaps

- `finalizeTurn` and the session load/hydration fencing were not in the supplied slices. P1-1 and P1-2 depend on them.
- There is no test for a cancelled or failed H, an unloaded session, or relocation out of a frozen durable-frontier prefix. The last case matters because it could invalidate the frontier and trigger `recomputeAll` retiering, which "no retiering" forbids.
- The cancelled full-root run (`bdd68376…`) left other-suite failures that nobody triaged. The ordinary-session regression check therefore rests only on the 5 filtered suites.
- Nothing ran live; the gates are OFF and O3 live acceptance is still pending.
