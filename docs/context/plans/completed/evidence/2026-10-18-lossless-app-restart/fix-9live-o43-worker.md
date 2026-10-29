# 9-live fix 3: Check settles delivery-uncertain messages of a proven-exited run (O43)
Scope: read when the task touches the crash-hold acknowledgement write, Check's exit proof, "It stopped", or delivery-unknown recovery rows.
Authority: Reference
Last-verified: 2026-10-28
Covers: the Step 3 source and test changes

Implements Step 3 of [plan-9live-fixes-oracled.md](plan-9live-fixes-oracled.md) under owner decisions O43 and O46 (OracleD's version: the proof and "It stopped" settle the same way; the row becomes informational with View, Edit, Remove and Dismiss, never a resend; the text is kept). Nothing is committed or staged.

## Unknowns checked first

- **Does `AgentRecoveryAttempt` carry a run-attempt reference?** Yes: `runAttemptID: UUID?` (`AgentRecoveryModels.swift`, the `AgentRecoveryAttempt` struct). Production fills it before handoff: the Claude runner calls `AgentProviderHandoff.attachRunAttempt` → `lane.attachDeliveryAttempt` for every durable attempt before the provider is invoked (`ClaudeIntegratedAgentModeRunner.swift:139-157`, `AgentProviderHandoff.swift:273-325`), and steering dispatches pass `runAttemptID` in `AgentRecoveryAttemptStart` (`AgentRecoveryQueuedInput.swift:244`). Scope did not grow.
- **How do `addIntents`/`needsDecision` treat intents an acknowledgement already lists?** They ignore the acknowledgement: every earlier-launch `dispatching`/`deliveryUnknown` intent was listed as needs-action. The new `settledByExitProof` fact is the only reader.

## Source changes

- `AgentRecoveryModels.swift`
  - `AgentRecoveryAttemptOutcome.deliveryUnknownMessageExtrasKey` (`"message"`, line ~566). `.deliveryUnknown` has no message slot; the explanation travels as a forward-compatible extras member. The codec keeps it (round-trip asserted).
  - New `AgentRecoveryCrashHoldIntentSettlement` (lines ~862-886): `.everyIntent` (Check: refuse the whole write if a listed intent doesn't qualify) and `.qualifyingIntents` ("It stopped": settle the ones that qualify, acknowledge the rest only). Each mode has its own attempt message.
  - `AgentRecoveryRecord` (lines ~1080-1118): `intentAttemptsAreOnExitedRuns`, `crashHoldSettlementQualifies` (the plan's rule: intent `dispatching`/`deliveryUnknown`; the intent and every attempt are earlier-launch; at least one attempt; every attempt has a run-attempt reference that is in the exited set or has recorded terminal evidence), and `isSettledByCrashHoldExitProof` (the stored acknowledgement, same incarnation, lists the intent; the intent is `deliveryUnknown`; its attempts are on the acknowledged or finished runs).
  - The `AgentRecoveryCrashHoldAcknowledgement` doc comment no longer says it never changes delivery certainty.
- `AgentRecoveryStore.swift` `recordCrashHoldAcknowledgement` (lines ~1582-1690): new `settlement:` parameter (default `nil` keeps acknowledgement-only). The settle is computed from the current record inside the same actor call and committed in the one existing `replace(...)` write together with the acknowledgement. Each qualifying `dispatching` intent becomes `deliveryUnknown`; an already-`deliveryUnknown` one stays so; each open attempt (`outcome == nil`) gets `.deliveryUnknown` with the message; closed attempts and payloads are untouched. Under `.everyIntent` a non-qualifying intent throws `.intentConflict(intentID)` before anything is written. The 9-activation-b card-freshness check still runs first, and `requireRevision(expectedRevision)` still guards the write. The "identical acknowledgement is unchanged" early return now applies only when nothing is left to settle.
- `AgentRecoveryCoordinator+CrashHoldProof.swift`
  - Header (b) rewritten.
  - New `AgentRecoveryCrashHoldCheckText.messageNotOnProvenRun` = "a saved message's attempt isn't tied to a proven run" (line ~47).
  - The (b) guard (lines ~73-86) still needs run attempts and no legacy turn (`notOnlyRuns`, kept for that case). It now accepts uncertain intents when each qualifies against `hold.uncertainRunAttemptIDs` (pre-checked on the reconciliation record before the registry query). Otherwise it refuses the whole hold with the new reason.
  - Both commit paths pass `settlement: .everyIntent` (lines ~241, ~274). The store's in-write refusal maps to the same reason (line ~154).
- `AgentRecoveryCoordinator.swift`: the lane's `recordCrashHoldAcknowledgement(_:)` ("It stopped", via `confirmCrashHold`) passes `settlement: .qualifyingIntents` (line ~3118). The doc comments are updated (lines ~1620, ~3105).
- `AgentRecoveryCatalog.swift`
  - `AgentRecoveryCatalogActionFacts.settledByExitProof` (line ~225, plus the init).
  - `attention(for:facts:)`: `.intent` is informational when settled and no action on it is unfinished (line ~345).
  - `Builder.append` sets the fact for saved-input cards from `record.isSettledByCrashHoldExitProof` (line ~482).
- `AgentModeViewModel+RecoveryList.swift`
  - `.intent` row (lines ~307-330): the title is unchanged ("Message may have been delivered"). The detail is `recoveryListSettledByExitProofDetail` = "Every process of its run exited before the provider confirmed it. It won't be sent again." (line ~642).
  - `recoveryListIntentActions` (now internal, line ~646) offers `[.edit, .remove]` for a settled `deliveryUnknown` message in the same generation. It never returns Send saved.
  - `editRecoveredIntent` accepts a settled `deliveryUnknown` message (line ~1522). It moves the text into the message box and withdraws the intent, as for `queued`/`failed`. The user decides whether to send it.
  - Dismiss was already offered (intent cards have a card key).

## Tests

- `AgentRecoveryStoreTests`
  - `testCrashHoldAcknowledgementSettlesUncertainIntentsOfTheExitedRun` (:1441): `dispatching`, `deliveryUnknown` and a T4-style retry on a terminal run are settled, with the message on the open attempt; the closed attempt's outcome is kept; payloads are kept; `queued` and `providerAccepted` are untouched; the acknowledgement lists the intents; no run is closed; a reread round-trips; an identical repeat is `.unchanged`.
  - `testCrashHoldSettlementRefusesUncoveredAttemptsForCheckAndSkipsThemForItStopped` (:1506): an uncovered run attempt or an untied attempt → `.intentConflict` and nothing written; "It stopped" settles the qualifying intent (its own message) and leaves the untied one `dispatching` but listed.
  - `testCrashHoldSettlementRefusesCurrentLaunchInputAndRevisionConflicts` (:1578).
- `AgentRecoveryCrashHoldProofTests`
  - `testHoldWithUncertainInputIsNotConfirmed` → `testHoldWithUncertainInputNotTiedToTheRunIsNotConfirmed` (:273). Deliberate contract change: the expected reason is now `messageNotOnProvenRun`, and the intent stays `dispatching`.
  - New: `testClaudeShapedHoldWithADispatchingMessageIsConfirmedAndSettled` (:294; confirmed, hold lifted, intent `deliveryUnknown`, text kept, card informational, still informational at the next launch); `testDispatchingMessageOfARunWithALiveProcessIsNotSettled` (:330); `testQueuedMessageBesideTheSettledOneIsUntouched` (:353); `testItStoppedSettlesTheRunsDispatchingMessageInTheSameWrite` (:384).
- `AgentRecoveryCoordinatorTests`
  - `testPreviousInstanceOpenEvidenceHoldsAdmissionUntilExplicitConfirmation`: the "It stopped keeps `dispatching`" assertion is updated to the O46 contract (`deliveryUnknown`, payload kept, still one attempt so nothing was resent). Deliberate contract change.
  - `testCatalogAttentionClassifiesEveryPayload` gains the settled-fact rows (only `.intent` becomes informational; settled with an unfinished action still needs action).
- `AgentRecoveryReconciliationTests.testSettledMessageRowIsInformationalAndNeverOffersSendSaved` (:2299): the real `recoveryListRow` for a synthetic settled card gives the unchanged title, the new detail, the kept text (View), and actions exactly `[.edit, .remove, .dismiss]`, informational and not counted. The unsettled card gives `[.remove, .dismiss]`. `recoveryListIntentActions` never returns Send saved for any state or flag, and `recoveryIntentActions` gives none for the settled message.

## Validation (coordinated, with tickets)

| Check | Ticket | Result |
|---|---|---|
| `make dev-test FILTER=AgentRecoveryCrashHoldProofTests` | 9cbd732b-72a3-451f-88e7-7c7135ad5cbd | 25 tests, 0 failures |
| `make dev-test FILTER=AgentRecoveryStoreTests` | 861086dc-7bfb-428b-8b4d-51b4e46061f3 | 24 tests, 0 failures |
| `make dev-test FILTER=AgentRecoveryCoordinatorTests` | b812e1f3-8b70-464d-80ce-eba421111d61 | 79 tests, 0 failures (the first run, f969fc03, failed only on the updated O46 assertion) |
| `make dev-test FILTER=AgentRecoveryReconciliationTests` | 2f6caabe-2a13-4a4b-a086-a5d5f767e082 | 71 tests, 0 failures |
| `make dev-test FILTER=AgentRecoveryStartupReconciliationTests` | 65c81f47-4a78-4f8a-862a-c40e32c34ced | 21 tests, 0 failures |
| `make dev-test FILTER=AgentRecoveryStartupCompositionTests` | 8ab593f5-6023-4808-a271-847193b296ee | 22 tests, 0 failures |
| `make dev-lint` | a3fa8e86-b1d9-4770-a7a8-8c63e53100a5 | clean (0/2207 need formatting; swiftlint strict clean) |

Not run: the full test suite, the live check, a release build.

## Deviations and judgement calls

- **"It stopped" with a non-qualifying message.** It is never refused (refusing would leave no way to lift the hold). It settles the qualifying messages and acknowledges the rest as before; those keep their needs-action row. Check refuses the whole hold instead, as the plan says.
- **Attempt message per path.** Check records the plan's text. "It stopped" records "You confirmed the run stopped before the provider confirmed the message.", because no process records were consulted. The row detail is one text for both paths (O46: one row state).
- **"Settled" fact is stricter than "acknowledgement lists the intent".** The fact also requires `deliveryUnknown` and attempts on the acknowledged or finished runs. Otherwise an untied message that "It stopped" only acknowledged, or an older acknowledgement-only record, would read "every process of its run exited" without that being shown.
- **Qualification needs at least one attempt** (a message with no attempt isn't tied to any run). Every attempt counts, including closed ones, as the plan says. So a message with an earlier pre-handoff failure that was never attached to a run (`runAttemptID == nil`) refuses Check. That is conservative; "It stopped" still lifts the hold.
- **Edit on a settled row** needed a small widening of `editRecoveredIntent`'s state guard, read from the catalog fact. The store's `withdraw` already accepted `deliveryUnknown`.
- **Intents-only holds** (no open run attempt) still refuse with `notOnlyRuns`. The plan's "terminal commit" case is covered when the hold also has an open run.
- Re-validation inside the write: the store evaluates qualification on the record it is about to replace, under the actor and with `expectedRevision`. A non-qualifying intent is `.intentConflict` (reported as the new reason), not a revision conflict, so it isn't retried pointlessly.

## Unresolved / for the main agent

- The spec status line and any routed document are not updated (main agent's call). Nothing in `docs/context/` other than this report was touched.
- The working tree also has the parallel Step 4 worker's changes (`AgentProcessRegistry*`, `AgentModeViewModel+RecoveryActions.swift`, `AgentModeViewModel.swift`, `AgentProcessRegistryTests.swift`, `ClaudeHistoryLocator*`), plus unrelated pre-existing edits (for example `CodemapSeamTestSupport.swift`). This step touched none of them. One build hit "ClaudeHistoryLocatorTests.swift was modified during the build"; the rerun was clean.

## Review fixes (round 0, cut down by the owner)

Reviews: `prompt-exports/oracle-chat-2026-10-28-212109-9fix-3-o43-review-a-eb6b.md` (A) and `...-review-b-6de0.md` (B). The owner cut the scope to two fixes. Every other round-0 edit was reverted to the round-before state. Reverted:
- the stricter settled fact (`currentInstanceID` qualification and the remote guard);
- the `settledByCrashHold` rename;
- the Edit test pair;
- the `runNeverHandedOff` assertion;
- the P3 rule tests.

Kept:
- **A P2 / B P2-1 (1a), row detail text.** `AgentModeViewModel.recoveryListSettledByExitProofDetail` now reads "Its run stopped before the provider confirmed it. It won't be sent again." It is accurate for both Check's process proof and "It stopped".
- **B P2-3, `covers`.** Finding: `AgentRecoveryCrashHoldAcknowledgement.covers` was strict equality. Removing the settled message narrows the next launch's hold: the run is still open, but no message is uncertain any more. Under equality that narrower hold paused sending again. It now accepts a subset hold: same incarnation and reset generation, and run, intent and turn IDs each a subset of the acknowledged ones. A widened hold is still not covered; the existing `AgentRecoveryCoordinatorTests` assertion still passes. Both callers use the new rule: startup's `isCovered(by:)` and the store's idempotent early return.
  - Test: `AgentRecoveryCrashHoldProofTests.testRemovingTheSettledMessageKeepsTheNarrowerHoldAcknowledgedOnTheNextLaunch`. Check confirms, then Remove withdraws the message. On relaunch the hold names only the run, and nothing blocks.

Validation (all passed):

| Check | Ticket | Result |
|---|---|---|
| `AgentRecoveryCrashHoldProofTests` | `483c533f-714e-4021-ba54-0172ebe43926` | 26/0 |
| `AgentRecoveryReconciliationTests` | `b23f14a9-c626-40d4-97dc-7b373ee1f1f4` | 72/0 |
| `AgentRecoveryCoordinatorTests` | `6d979ab3-9f5d-4e7c-9f6a-9c1b5ee34feb` | 79/0 |
| `AgentRecoveryStoreTests` | `9a670b77-8bbc-49b9-a00b-3ecd4ba98adb` | 24/0 |
| `make dev-lint` | `a8795755-d7d5-4473-b0bf-273c5faad792` | exit 0 |

Not run: the startup reconciliation and composition suites.

Left open by the cut:
- A P2 / B P2-1 (b): `isSettledByCrashHoldExitProof` still doesn't re-apply the earlier-launch rule. An intent the acknowledgement lists but the write skipped, for example a current-instance attempt, can still project as settled. A's regression test was not added.
- B P2-2: the Edit pair.
- B P2-4: the `runNeverHandedOff` check.
- The P3 rule tests.
- `isRemote` (read-only finding): it means the session executes on an authoritative remote host (persisted execution binding, F-3). `deriveCrashHolds` already gives such sessions no hold, so nothing settles them. No change was kept.
