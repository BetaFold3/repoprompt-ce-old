# Step 8-attention-1 worker report

Scope: read when the task touches Needs Attention classification, the composer recovery banner rule or the needs-action counts (Step 8-attention-1).
Authority: Reference
Last-verified: 2026-10-26
Covers: worker session 95E02CAD-668C-48A1-826E-D7FAD7756B31 final report (needs-action/informational classification, banner rule, counts, sheet sections).

Step 8-attention-1 is implemented and its validation passes: build, lint, guardrails, and the three touched recovery suites each run on their own (67 tests, 0 failures). Nothing is staged or committed, the app was not launched, and the out-of-bounds files were not touched.

**Files changed (mine only; the other modified files in the tree were already there):**
- `Sources/RepoPromptAgentCore/AgentMode/Runtime/Recovery/AgentRecoveryCatalog.swift`:
  - adds the package enum `AgentRecoveryCatalogAttention` (`needsAction` / `informational`) and the action fact `hasUnfinishedAction`;
  - adds an exhaustive `AgentRecoveryCatalogProjection.attention(for:facts:)` (no `default`, at :264);
  - adds the derived item properties `attention` and `isOpenNeedsAction`, and `catalog.openNeedsActionCount`.
  - Nothing is persisted. The classifier is `nonisolated` because the projection enum is `@MainActor` and the test build rejected the call from a non-isolated context otherwise.
- `AgentModeViewModel+RecoveryList.swift`:
  - the banner keeps only needs-action items; the schedule-domain exclusion, runtime items and paused indicator are unchanged;
  - `otherItemCount` counts needs-action, not-dismissed items elsewhere;
  - sheet rows carry `attention`;
  - `recoveryNeedsAttentionCount` now uses `openNeedsActionCount`.
- `AgentComposerUIModels.swift`:
  - `AgentRecoveryListProps.isEmpty` is now `ready && rows.isEmpty`, so items elsewhere no longer keep the banner up.
  - The "Nothing interrupted in this session. N items elsewhere…" text is gone.
  - `AgentRecoveryNeedsAttentionRow` gains `attention`.
- `AgentRecoveryListBanner.swift`: doc comment only. The Needs Attention button logic is unchanged; it can only appear while the banner exists, which now needs rows of the current session.
- `AgentRecoveryNeedsAttentionSheet.swift`:
  - "Needs action (n)" section, then "Information (m)", collapsed by default behind a disclosure button; both in snapshot order.
  - The "Show dismissed" toggle is unchanged.
  - No workspace sub-grouping.

**Classification table:**

| Payload | Class |
|---|---|
| `turn`, `outcomeTurn`, `recoveryOnlyRun` | informational; needs action if `hasUnfinishedAction` |
| `workspaceFailure`, `nonactionable`, `duplicateDestination`, `noDestination` | needs action |
| `crashHold`, `scheduleTransfer` | needs action |
| `intent`, `question`, `editProposal` | needs action |
| `heldDraft`, `closedSessionDraft` | needs action |
| `composerRestoreFailed`, `unsavedPredecessor`, `composerWriteFailed`, `ownerlessDraft`, `composerPreparationFailed`, `questionSaveFailed` | needs action |
| `scheduleNeedsConfirmation`, `scheduleIndexUnavailable` | needs action |
| `survivingRuntime`, `runtimeOwnershipUnknown` | needs action |

**How an unfinished recovery action is detected:** `AgentRecoveryCatalog.swift:368` sets `facts.hasUnfinishedAction = record.unresolvedAction(for: key) != nil`. That uses the existing accessor at `AgentRecoveryActionModels.swift:274`: the last action for the card key that has no outcome and was not superseded. It is the same check the store uses to refuse a duplicate reservation, so no new accessor was needed. An action still running in this launch also counts as unfinished.

**Counts:** `recoveryNeedsAttentionCount` is used only by the sidebar button (`AgentRecoveryNeedsAttentionSheet.swift`). The View-menu item is a plain "Needs Attention…" with no count, so nothing changed there.

**Tests:**
- Added in `AgentRecoveryCoordinatorTests`:
  - `testCatalogAttentionClassifiesEveryPayload`: all 24 payloads; the unfinished-action flag never makes anything informational; other facts never promote a run note.
  - `testRunCardWithAnUnfinishedRecoveryActionNeedsAction`: informational, then needs-action after a reserve, then informational again after the outcome is recorded; counts follow.
- Added in `AgentRecoveryStartupCompositionTests`:
  - `testBannerHidesInformationalRunNotesAndShowsARunWithAnUnfinishedAction`: banner is nil and count 0 with only a run note; the row is in the Information section; after a reserve the banner shows the run and the count is 1.
- Updated deliberately (old "elsewhere" or count behaviour):
  - `AgentRecoveryListHeaderTextTests.testNoRowsHereButItemsElsewhereUsesNeutralText`, renamed `testNoRowsHereHidesTheBannerEvenWithItemsElsewhere`.
  - `AgentRecoveryStartupCompositionTests.testRecoveryListEditKeepsNewerTypingAndAFailedRemovalKeepsTheRowVisible`: the elsewhere count is needs-action only; the run note is informational.
  - `testRecoveryListRowsResolveSessionsFromTheCatalogAndOpenAcrossWorkspaces`:
    - With no active session the banner is now nil; the 7 undismissed items are split into needs-action and informational, and the badge counts only needs-action.
    - With the dismissed crash hold, the paused indicator still shows; the banner has 2 rows instead of 3 (the session's run note left) and the elsewhere count is 3 instead of 4.
  - `testNeedsAttentionRouteReachesAnyWindowWithoutHydratingAndStaysReachableWhenAllDismissed`: the badge equals the needs-action rows only.

**Validation:**

| Command | Result |
|---|---|
| `make dev-build` | passed (final run) |
| `make dev-lint` | passed |
| `make guardrails` | passed, with one existing warning that AGENTS.md has 24 direct routes (not from this change) |
| `make dev-test FILTER=AgentRecoveryListHeaderTextTests` | 6/6 |
| `make dev-test FILTER=AgentRecoveryCoordinatorTests` | 47/47 |
| `make dev-test FILTER=AgentRecoveryStartupCompositionTests` | 14/14 (the first run failed only on the expected banner counts, fixed above) |

**Not verified:** the sheet's SwiftUI rendering and the collapse/expand in the running app (no launch); the full test suite; other suites that might read sheet or banner props (none found by search). The spec docs were not updated, per your rules; the spec status for 8-attention-1 is yours to update.

**Accessibility IDs for the verifier:**
- New:
  - `agent.recoveryNeedsAttention.section.needsAction`: header text "Needs action (n)".
  - `agent.recoveryNeedsAttention.section.informational`: the disclosure button "Information (m)", with accessibility value `collapsed` / `expanded`.
- Unchanged:
  - `agent.recoveryNeedsAttention.sheet`
  - `agent.recoveryNeedsAttention.showDismissed`
  - `agent.recoveryNeedsAttention.sidebarButton` (label "Needs Attention, N", N = needs-action count)
  - `agent.recoveryList.banner`
  - `agent.recoveryList.status`
  - `agent.recoveryList.needsAttention`
  - `agent.recoveryList.retry`

## Round 1 (review fixes)

I made the round-0 fixes and added tests. The build, all three touched suites and lint pass. `make guardrails` fails, but only on three untracked evidence docs under `docs/` that it calls orphans; I didn't create them and am not allowed to touch `docs/`.

## 1. ATT1-3: can a paused session have no banner row?

**1a. The session's own run card had a gap; now fixed.**
- **The gap:** `beginRecoveryAction` takes the session hold synchronously (`AgentRecoveryActionRunner.swift:175-182`, coordinator `beginRecoveryAction` 1047-1083) before `lane.reserveRecoveryAction` writes the durable action (Runner 217). In that window a run card had no unresolved action, so it was informational.
  - After the reservation, `unresolvedAction(for:)` keeps the card needs-action until the outcome is written. The hold ends only after that write (Runner 199-202).
  - Intent and question cards are needs-action anyway.
- **Fix:** new `AgentRecoveryCoordinator.hasRecoveryActionHold(sessionID:itemKey:)` (about line 1181). `Builder.append` (`AgentRecoveryCatalog.swift:372-378`) now sets `hasUnfinishedAction` from either the live hold or the record.
  - Both `begin` and `end` call `postCoordinatorDidChange` → `invalidateCatalog` (749, 743), so the banner updates.
  - `hasUnfinishedAction` is only read by the classifier (277), so row actions don't change.

**Not changed, your call:** a workspace-sibling gap.
- `coveringRecoveryActionHold` (1196-1204) also pauses automatic work (scheduled sends, automatic new session) of other sessions in the same workspace. Those sessions may have no catalog item, so no banner row.
- Their scheduled-send surface does explain it: "Waiting until this session's recovery is resolved." or "Will send after a recovery action in this workspace finishes." (`AgentComposerUIModels.swift:~266-298`). Manual sends from those sessions aren't refused.
- The old banner never showed holds either, so I didn't add a row.

**1b. Every startup restriction has a needs-action item; no gap.**
- `AgentRecoveryRestrictions.from` (`AgentRecoveryStartupReconciliation.swift:417-428`) combines `restrictionReason` (287-302) with workspace failures. Each cause has a non-dismissible needs-action item:
  - workspace failure → `workspace-<id>`;
  - `nonactionable` / `noDestination` / `duplicateDestination` → `status-<sid>` (Catalog 439-441);
  - held schedule transfer → `transfer-<sid>`, appended exactly while `restrictions.sessionRestriction` is set (Catalog 465-468).
- A held transfer only exists for `.actionable` sessions (`AgentSessionDataService.swift:3821-3839`).

**Pre-existing, not reachable in production, not changed:**
- `addRuntimeRestrictions` returns early without a process registry. In that case `runtimeBlocksAutomaticWork` (`+RuntimeOwnership.swift:62-71`) is also false, so nothing is paused and nothing is listed.
- With a registry, the gate uses `runtimeBlocksAutomaticWork` (which includes tool-only survivors and an unresolved worktree), while the banner uses `runtimeSendRestriction` (82-90). That mismatch can't happen while registration is off.
- The scheduled-send gate uses `session.scheduledSendWorkspaceID ?? persistenceWorkspace?.id` (`+ScheduledSend.swift:1538-1586`); the banner uses `persistenceWorkspace?.id`.

## 2. ATT1-1: can an outcome be recorded when the typed text never became an intent?

**Yes.** Continuation actions with text (`continueWithText`, `continueInNewConversation`, `questionAnswerAsInput`) can be recorded `.notDispatched` with no intent carrying the text:
- `stopBeforeDispatch` (Runner 334-362): blocked, association unavailable, record unreadable, never handed off, not an interruption, or conversation cleared;
- `!lane.isValidForHandoff` (273-275);
- dispatch `.notDispatched` with a `notHandedOff` settlement (276-294), where an intent may or may not have been admitted.

`importedUnconfirmed` comes only from `reconcileOnly`, which carries no text. Refused and disabled actions record nothing.

**Fix:**
- New `AgentRecoveryRecord.hasUnsentContinuation(for:)` (`AgentRecoveryActionModels.swift:319`). It is true when the latest action on the card carries text, its outcome is neither `dispatched` nor `importedCompleted`, and no intent has `userItemID == plannedUserItemID`.
- New fact `hasUnsentContinuation`; the classifier treats it like an unfinished action.
- A later resolving choice without text (for example, a reconcile) decides the card again.

## Files changed
- `AgentRecoveryCatalog.swift`: hold-aware `hasUnfinishedAction`, new fact `hasUnsentContinuation`, classifier and doc comment updated, `openNeedsActionCount` comment fixed (ATT1-8).
- `AgentRecoveryCoordinator.swift`: added `hasRecoveryActionHold(sessionID:itemKey:)`.
- `AgentRecoveryActionModels.swift`: added `hasUnsentContinuation(for:)`.
- `AgentComposerUIModels.swift`: `attention` is now required with no default (ATT1-7); the empty-rows `headerText` branch comment says it is a fallback only. The only construction site (`+RecoveryList.swift:75`) already passed it.
- `AgentRecoveryNeedsAttentionSheet.swift`: section counts use the new `headerCount`, which excludes dismissed rows (ATT1-4).
- `AgentRecoveryListBanner.swift`: doc comment reflowed and now mentions unsent continuations.

## Tests (all passing)
- **`AgentRecoveryCoordinatorTests`** (49 pass):
  - the payload table now also checks that `hasUnsentContinuation` makes every payload needs-action;
  - new `testRunCardNeedsActionWhileARecoveryActionHoldsItsSession`: needs-action under the hold before any reservation, informational after revoke and end;
  - new `testRunCardWithAnUnsentContinuationNeedsAction`: a `.notDispatched` continuation keeps the card needs-action; a later `importedUnconfirmed` reconcile makes it informational again.
- **`AgentRecoveryStartupCompositionTests`** (15 pass):
  - new `testStartupCrashHoldKeepsTheBannerAndAnEarlierLaunchUnfinishedActionNeedsAction` (window 4872). The active session's banner shows exactly its `crash-<sid>` row and no run note. The other session's startup run card is keyed by `binding.incarnationID` and needs action because of an earlier launch's unfinished action.
  - `testFailedComposerPreparation…` now also asserts that the item is needs-action and the tab has no session.
- **`AgentRecoveryListHeaderTextTests`** (7 pass): new `testSheetSectionCountsExcludeDismissedRows`. The file gained `import RepoPromptAgentCore`.
- **Payload-table count:** I kept the hard-coded 24. Swift can't list cases of an enum with associated values without extra machinery, and the production switch is already exhaustive.

## Validation
- `make dev-build`: passed.
- `make dev-test FILTER=` for each of the three suites, run singly: all passed.
- `make dev-lint`: passed after I removed two trailing commas in my new test.
- `make guardrails`: failed. The only errors are three untracked `docs/context/plans/evidence/…/fix-attention1-*.md` files reported as orphan context docs (not linked from anywhere). That needs fixing on your side. There is also a pre-existing warning about the number of routes in AGENTS.md.

## Not verified
- I didn't run other recovery suites. I checked that the only other tests reading banner rows (`AgentRecoveryVMProducerAdmissionTests`, `AgentRecoveryResetBoundaryTests`) look at intent and draft rows, which were already needs-action.
- There's no live UI check of the sheet counts or of the banner during a hold.
- Nothing is staged or committed.

## Round 2 (OracleA re-review 1 fix)

I fixed ATT1-R1-1. A Reconcile that doesn't resolve the card no longer clears an unsent continuation, so the run card keeps asking for a decision. The build, all three suites and lint pass. `make guardrails` fails only on an untracked orphan doc under `docs/` (`fix-attention1-review-oraclea-r1.md`), which isn't mine and I'm not allowed to touch.

## What changed
`Sources/RepoPromptAgentCore/AgentMode/Models/AgentRecoveryActionModels.swift`:

- **New helper (about lines 312-318):** private `resolvesItem(_:)`, meaning the action's outcome is `dispatched` or `importedCompleted`. `resolvingAction(for:)` (about 308-310) now uses it, so both checks share one meaning of "resolved"; its behaviour is unchanged.
- **Rewritten `hasUnsentContinuation(for:)` (about 320-339), documented in place.** It looks at the latest action on the card that carries text. A newer typed choice therefore decides by its own state, which covers your rule (c). That continuation counts as unsent when:
  - it ended without resolving: an outcome other than `dispatched` / `importedCompleted`, or it was replaced by a later choice before it got an outcome. An action that is still open isn't counted here, because `unresolvedAction(for:)` already makes the card needs-action.
- **It clears only when:**
  - (a) a saved intent has `userItemID == plannedUserItemID`, or
  - (b) a later action on the same card resolves it.
- **No longer clears:** later textless actions recorded `notDispatched` or `importedUnconfirmed`.

No other source changed; the classifier and catalog wiring from round 0 already use this fact.

## Tests (`AgentRecoveryCoordinatorTests`)
I added a shared `RunCardFixture` and `makeRunCardFixture()`. Its `perform` waits until the coordinator has adopted the record carrying the outcome, and adoption invalidates the catalog in the same step (`AgentRecoveryCoordinator.swift:577-582`). So "still needs-action" assertions read a fresh catalog rather than passing on a stale one.

- **Changed `testRunCardWithAnUnsentContinuationNeedsAction`:** after the unsent continuation, a Reconcile recorded `.notDispatched` and then one recorded `.importedUnconfirmed` each leave the card needs-action, with `hasUnsentContinuation` still set and an open count of 1. The old predicate would fail this test.
- **New `testUnsentContinuationClearsWhenASavedIntentCarriesItsText`:** committing a queued intent with `userItemID` equal to the planned item (through `lane.transaction`) makes the card informational.
- **New `testUnsentContinuationClearsWhenALaterActionResolvesTheCard`:** a later Reconcile recorded `.importedCompleted` makes the card informational, with `resolvedByAction` set and an open count of 0.
- **New `testRunCardNeedsActionAfterTheOutcomeWriteUntilTheHoldIsReleased`:** with the hold acquired, then the action reserved and its outcome recorded, the card is still needs-action through `hasUnfinishedAction`. After revoke and end it is informational.

## Validation
| Command | Result |
|---|---|
| `make dev-build` | passed |
| `make dev-test FILTER=AgentRecoveryCoordinatorTests` | 52 passed (49 before, plus 3 new) |
| `make dev-test FILTER=AgentRecoveryStartupCompositionTests` | 15 passed |
| `make dev-test FILTER=AgentRecoveryListHeaderTextTests` | 7 passed |
| `make dev-lint` | passed (0 files need formatting; swiftlint clean) |
| `make guardrails` | failed: the one orphan doc above, plus the existing warning about the number of routes in AGENTS.md |

## Not verified
- A continuation replaced by a later textless choice before it had an outcome now counts as unsent. I reasoned this from the store's supersession rules (`AgentRecoveryStore+Actions.swift:15-19`, 44-53), but no test covers it.
- I didn't run other recovery suites or check the banner in the live app.
- Nothing is staged or committed.

## Round 3 (cheap follow-ups after the final review, no further review round)

I applied all four follow-ups. The build, lint and the three suites pass. `make guardrails` fails only on two new untracked orphan docs under `docs/` (`fix-attention1-review-oraclea-r2.md` and `fix-attention1-review-oracleb-r2.md`), which aren't mine and which I'm not allowed to touch.

## Changes
- **`AgentRecoveryActionModels.swift:330` (ATT1-R2-5):** `hasUnsentContinuation(for:)` now only considers actions with `text?.isEmpty == false`, and its doc says "non-empty text".
- **`AgentRecoveryCatalog.swift:165-170` (ATT1-R2-4):** the `hasUnsentContinuation` doc now matches the record-level doc, including what clears it and that a textless Reconcile that doesn't resolve the card never clears it.
- **`AgentModeViewModel+RecoveryList.swift:444-450` (ATT1-R2-3):** new `recoveryListUnsentContinuationNote` ("The message you typed to continue it was not sent.") and a helper `recoveryRunUnsentNote(_:)`.
  - It is appended to the detail of all three run-row kinds (`turn`, `outcomeTurn`, `recoveryOnlyRun`) at lines 230, 244 and 261, before any delegated-children text.
  - It shows whenever the flag is set, not only when it's the sole reason for needs-action. The sentence is true whenever the flag is set, and this keeps the code simpler.

## Tests
**`AgentRecoveryCoordinatorTests`: 55 passed** (52 before, plus 3 new).
- The fixture's `request` helper now takes `supersedesActionID:`, and text requests default to a fresh `plannedUserItemID`.
- **(a) `testSupersededOutcomelessContinuationStaysUnsentAfterAnUnresolvingReconcile` (2107):**
  - The store only allows superseding an open action from a previous launch (`AgentRecoveryStore+Actions.swift:44-47`). So the outcome-less continuation is reserved through a second store instance (a different app instance, same root).
  - This launch's Reconcile supersedes it and ends `.notDispatched`; a further Reconcile ends `.importedUnconfirmed`.
  - After each one, the old continuation is still there with no outcome; `hasUnsentContinuation` is true, `hasUnfinishedAction` is false, and the card is needs-action.
- **(b) `testOpenContinuationNeedsActionOnlyThroughItsUnfinishedAction` (2133):** for an open continuation, `hasUnsentContinuation` is false, `hasUnfinishedAction` is true, and the card is needs-action.
- **(c) `testNewerSentContinuationClearsAnOlderUnsentOne` (2147):** a newer continuation recorded `.dispatched` after an older unsent one clears the flag; `resolvedByAction` is true and the card is informational.
- **Empty text:** `testRunCardWithAnUnsentContinuationNeedsAction` now also checks that a record whose only action is a `.notDispatched` continuation with `text: ""` has no unsent continuation (2101).

**`AgentRecoveryStartupCompositionTests`: 15 passed.** `testBannerHidesInformationalRunNotes…` now checks that the run row's detail has no note while the card is needs-action only through an unfinished action. After a continuation is recorded `.notDispatched`, the banner row's detail ends with the note (line 1253).

**`AgentRecoveryListHeaderTextTests`: 7 passed.**

## Validation
- `make dev-build`: passed.
- `make dev-lint`: passed.
- The three suites, each run singly: passed (results above).
- `make guardrails`: failed on the two orphan docs above, plus the existing warning about the number of routes in AGENTS.md.

Nothing is staged or committed, and I didn't check the new detail text in the live app.
