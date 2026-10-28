# 9-live fix 5: Codex native turn ID on the run attempt (R2)
Scope: read when the task touches how recovery identifies the interrupted Codex turn, the run attempt's provider turn ID, or the Codex history matcher's text.
Authority: Reference
Last-verified: 2026-10-28
Covers: the Step 5 source and test changes

Implements Step 5 and §5 of [plan-9live-fixes-oracled.md](plan-9live-fixes-oracled.md). Background: [diag-9live-r2-r5-worker.md](diag-9live-r2-r5-worker.md). Nothing was committed or staged.

## Source changes

| File | Change |
|---|---|
| `Sources/RepoPromptAgentCore/AgentMode/Models/AgentRecoveryModels.swift:788-795` | `AgentRecoveryRunAttempt.providerTurnIDExtrasKey = "providerTurnID"` and `recordedProviderTurnID`. It is an extras member, so the schema doesn't change. |
| `Sources/RepoPromptAgentCore/AgentMode/Runtime/Recovery/AgentRecoveryStore.swift:1274` | `recordRunProviderTurn(binding:expectedRevision:ownership:providerTurnID:)`. It needs an existing run attempt (`runAttemptNotFound` otherwise; it never creates one) in the binding's transcript generation (`runAttemptConflict` otherwise). An identical value is `.unchanged`; a different value is rewritten (last-wins). Other extras are kept. |
| `Sources/RepoPromptAgentCore/AgentMode/Runtime/Recovery/AgentRecoveryCoordinator.swift:3075` | `AgentRecoverySessionLane.recordRunProviderTurn(ownership:providerTurnID:)`, which runs inside `transaction` (`performRecoveryTransaction`, retried on a revision conflict). |
| `Sources/RepoPromptAgentCore/AgentMode/Runtime/Codex/CodexAgentModeCoordinator.swift:1918` (helper), `:2001` (steer-mismatch reinstall), `:2016` (fresh authoritative turn) | `recordCodexProviderTurn` runs from `installAuthoritativeCodexTurnForStart` wherever a turn becomes authoritative. It records only when `turnKind == .user`, the session has a non-retired `recoveryLane`, and `activeRunOwnership.attemptID` equals the identity's run attempt. It writes through a `Task { @MainActor }` that event handling never awaits; a failure is only logged. The same-ID repeat path (`current.turnID == turnID`) writes nothing, because that value is already recorded. |
| `Sources/RepoPrompt/Features/AgentMode/ViewModels/AgentModeViewModel+RecoveryActions.swift:142,148,188-192` | `performRecoveryResumeAction` (Continue, Reconcile, Continue in new conversation only): after the record read, `codexTurnID` is the source run attempt's `recordedProviderTurnID`, falling back to the existing span lookup. |
| `Sources/RepoPrompt/Features/AgentMode/ViewModels/AgentModeViewModel+RecoveryActions.swift:1495` | When `historyObservation` returns `nil`, the failure text comes from `CodexRecoveryAdapter.unusableObservationText(observed)`. `isUnconfirmedObservation: true` is unchanged, so Continue still proceeds. |
| `Sources/RepoPromptAgentCore/AgentMode/Runtime/Codex/CodexRecoveryAdapter.swift:98-107` | `noMatchingTurnText` (the old text) is used when the observation has no `turnID`. `unsupportedTurnItemsText` is used when the turn was found but `historyObservation` can't use it: "Codex's record of the interrupted turn contains tool calls that can't be imported; nothing was imported." |

**Cost when activation is off.** The write is the same kind of no-op as the other run-start writes. The coordinator writes nothing without `session.recoveryLane`, and that lane exists only when recovery is composed (`AgentTabSession.recoveryLane`). In that case no task or store access happens. This matches how `AgentProviderHandoff` and `AgentRecoveryDispatchEvidence` gate `lane.ensureRunAttempt`.

## Tests

| Suite | Test | What it pins |
|---|---|---|
| `CodexAgentModeCoordinatorLivenessTests` | `testAuthoritativeUserTurnRecordsItsNativeTurnIDOnTheRunAttempt` (new, `:2221`) | Runs `test_handleCodexNativeEvent(.turnStarted …)` against a session bound to a `RecoveryLaneFixture` lane whose run attempt exists in a temp store. A compaction turn start writes nothing (checked for 0.3 s). A user turn start writes `user-turn-1`. A steer-accepted mismatch (`codexPendingSteerLifecycleReconciliation`, then `turnStarted("user-turn-2")`) overwrites it with `user-turn-2`. |
| `AgentRecoveryStoreTests` | `testRunProviderTurnIsRecordedLastWinsOnAnExistingRunAttempt` (new, `:722`) | A missing attempt gives `runAttemptNotFound`. An identical repeat is `.unchanged`. A different ID is committed and wins. `providerKind` is kept. The value survives a reload by another instance. |
| `AgentRecoveryReconciliationTests` | `testCheckReportsAConfirmedAndSavedCodexCompletionAsResolved` (rewritten, `:4532`) | The span no longer carries `providerTurnID`; the turn is recorded with `lane.recordRunProviderTurn`. Check resolves only through the new record lookup in `performRecoveryResumeAction`. Without it, the result would be "wasn't identified". |
| same | `testCodexOverlappingCanonicalOutputImportsZeroRowsAndKeepsCompletion` (`:4581`) | The hand-seeded span `providerTurnID` was dropped. This test calls `reconcileRecoveryHistory` with `codexTurnID` directly, so it doesn't use the lookup; the overlap check never read the span ID. |
| same | `testColdCodexReconcileObservesThroughATemporaryControllerAndJoinsItsCleanup`, row `interrupted-unsupported-items` (`:4487`) | Contract change: a found interrupted turn with unusable items now gives the new text, still `.nothingImported` (unconfirmed, not `.blocked`). The `missing-turn` row keeps the old text. |
| same | `testCodexAdapterTellsAFoundTurnWithToolItemsFromAMissingTurn` (new, `:44`) | A real `CodexNativeSessionController.recoveryObservation` parse of an interrupted turn with a `commandExecution` item: found, `historyObservation == nil`, new text. A different expected ID gives the old text. |

## Validation (all exit 0)

| Command | Ticket | Result |
|---|---|---|
| `make dev-test FILTER=AgentRecoveryStoreTests` | `ba7d7de3-db51-4be8-9942-d9ed3a80b615` | 25 tests, 0 failures |
| `make dev-test FILTER=AgentRecoveryReconciliationTests` | `4c6c7cc6-5ad5-439c-98f7-a92b0fdedccc` | 73 tests, 0 failures |
| `make dev-test FILTER=CodexAgentModeCoordinatorLivenessTests` | `9635ec27-b573-4edc-8010-b3477f77c44b` | 62 tests, 0 failures |
| `make dev-test FILTER=CodexFallbackFIFOTests` | `50fc0d51-28f7-45f3-b6be-0aa041c0a05d` | 38 tests, 0 failures |
| `make dev-test FILTER=CodexSteerAckTrackerTests` | `ab167bc7-669b-481f-9aad-2e5067e289da` | 17 tests, 0 failures |
| `make dev-lint` | `a51a96ee-aadb-481b-aa7a-bea540b61e9c` | clean |

The "Test failures" block in the conductor summaries lists only existing compiler warnings from other test files.

Not run: the full suite, `AgentRecoveryActionTests` and `AgentRecoveryActivationTests` (another worker is editing them in parallel), and any live check.

## Deviations from the plan

- **Write seam.** The Codex coordinator has no host-protocol method for run-start record writes. The 9-activation-a provider-kind capture is written through the session's recovery lane (`session.recoveryLane.ensureRunAttempt`, called from `AgentProviderHandoff` and `AgentRecoveryDispatchEvidence`). The new write uses the same lane directly (`lane.recordRunProviderTurn`), following the coordinator's existing fire-and-forget lane writes (`holdDurableCodexFallbackInput`).
- **Revision.** `expectedRevision: nil` would fail against an existing record: `requireRevision` compares `nil` with the current revision. The lane therefore passes `store.currentRevision(...)` inside the gate, as its sibling methods do. That is an unconditioned fill under the gate, as the plan intended.
- **Matcher shape.** `historyObservation` keeps its `Optional` signature. The distinction is a sibling, `unusableObservationText(_:)`, which the view model's single caller uses. This is smaller than changing the return type.
- **Test line numbers.** The plan's `:4094`/`:4168` are now `:4532`/`:4581`, moved by earlier steps.

## Unresolved

- **"Found" includes turns with no usable items.** `recoveryItems` returns `nil` both for unsupported item types and for a missing or empty `items` array. A found interrupted turn with no items listed therefore also gets the "contains tool calls" text. Telling the two apart needs a flag on `CodexRecoveryObservation`. That was not done, to keep the step small. Worth a reviewer's call.
- **Ordering of two quick writes.** The first-turn write and a later steer-mismatch write are separate main-actor tasks entering the lane's gate. In practice they are far apart (the steer follows a live turn), and each write is last-wins. No ordering token was added.
- **Kills before the event.** A kill between `turn/start` and `turnStarted` leaves no ID, and Reconcile says "wasn't identified", as the plan accepts. The same applies to runs from before this change.
- **Uncovered paths.** Turns whose kind is `.unknown` (no pending kind, for example a turn a resumed thread reports without a RepoPrompt dispatch) and `.review` turns are never recorded, per "skip non-user kinds".
- The transcript span `providerTurnID` stays unwritten (plan §8 cut).

The first, third and fourth items above are superseded by the review fixes below.

## Review fixes (round 0)

Applies five items from reviews [A](../../../../../prompt-exports/oracle-chat-2026-10-28-220108-9fix-5-codex-turn-re-3aab.md) and [B](../../../../../prompt-exports/oracle-chat-2026-10-28-220108-9fix-5-codex-turn-re-d0fb.md). Nothing else was changed.

### 1. Writes commit in install order (A P1 = B F3)

- **Chain.** `AgentTabSession.codexProviderTurnWriteTask` (`AgentTabSession.swift:738`) is the tail of the session's provider-turn writes. `recordCodexProviderTurn` (`CodexAgentModeCoordinator.swift:1925`, task at `:1939`) captures the previous tail and synchronously installs a new `Task { @MainActor }` as the tail. That task awaits the previous one before entering the lane. Event handling still never awaits it.
- **Test seam.** A DEBUG-only `testProviderTurnWriteWillEnterLane` (`:1916`) is awaited after the predecessor and before the lane write.
- **Regression.** `testProviderTurnWritesCommitInAuthoritativeInstallOrder` (`CodexAgentModeCoordinatorLivenessTests.swift:2271`, hold helper `ProviderTurnWriteHold` at `:3090`):
  - T1's write is held at the seam while a steer mismatch makes T2 authoritative.
  - T2 hasn't started toward the lane while T1 is held.
  - Release, then await both write tasks.
  - T2 entered the lane only after T1 committed, and the reloaded record names T2.
  - No sleeps: the test uses the hold, `Task.yield` and awaited task handles.
- **Mutation check.** With `await previous?.value` removed, the test failed: T2 entered the lane while the store still held nothing (ticket `94d5f344`). The chain was then restored.

### 2. Non-user authoritative turns clear the record (B F1)

- **Store and lane.** `recordRunProviderTurn` takes `providerTurnID: String?` (`AgentRecoveryStore.swift:1279`, lane `AgentRecoveryCoordinator.swift:3078`). `nil` removes the extras member. Clearing an absent value is `.unchanged`.
- **Coordinator.** It now writes for every authoritative turn on the active run attempt: the ID for `.user`, `nil` for compaction, review and unknown, through the same chain. A clear on a run attempt that was never recorded (a compaction-only run) gets `runAttemptNotFound`. That case isn't logged.
- **Tests.**
  - The coordinator test gains the row "user turn, then compaction turn → record cleared". It now drains the chain instead of using the 0.3 s window.
  - The store test pins clear (committed), clear again (unchanged), and that `providerKind` is kept.

### 3. Neutral wording (A P2 = B F2)

- `CodexRecoveryAdapter.unsupportedTurnItemsText` (`:101`) is now "Codex's record of the interrupted turn was found, but its items couldn't be imported; nothing was imported."
- Two test strings in `AgentRecoveryReconciliationTests` were updated.
- There is no three-way result.

### 4. Is the run attempt committed before `turn/start`? (B F4, read only, no change)

Every Codex path that hands durable input to `turn/start` or `turn/steer` awaits `ensureRunAttempt` first:

| Path | How it awaits |
|---|---|
| `sendCodexNativeMessage`: start, steer, and the steer-mismatch retry | Through `beginCodexDispatch` → `AgentRecoveryDispatchEvidence.beginUnderActiveRun` → `begin(…ownership:…)` → `await lane.ensureRunAttempt`, before re-planning and the handoff. |
| Fallback-queue drain (`dispatchClaimedCodexFallback`) | The same `await beginCodexDispatch` before `startUserTurn`. This covers fallback heads bound to resumed threads (`bindResumedThreadFallbacks` feeds this drain) and a steer rejected into the fallback queue. |
| Managed-auth replay (`startUserTurn` around `:4614`) | Replays a turn of the same run whose dispatch already committed the run attempt. |

Untracked input (admission inactive) writes nothing, by design. A turn-ID write for such a run gets `runAttemptNotFound` and is logged; no record exists to identify anyway.

### 5. Record wins over span (B F5)

- **Check test.** `testCheckReportsAConfirmedAndSavedCodexCompletionAsResolved` (`AgentRecoveryReconciliationTests.swift:4533`) now runs two rows: a span without an ID, and a span naming `turn-old` with `turn-c` recorded. Both assert the observer was asked for `turn-c` and Check resolves.
- **Fake.** `LifecycleNoopCodexController` gains `observedExpectedTurnIDs` (`AgentModeRunServiceLifecycleTests.swift:8562`, `:8780`).

### Validation (all exit 0, 0 failures)

| Suite | Ticket | Tests |
|---|---|---|
| `CodexAgentModeCoordinatorLivenessTests` | `4f56eec3-f25f-4357-90d6-1e3079b3e711` | 63 |
| `AgentRecoveryReconciliationTests` | `9411813c-5ea9-4023-9b1e-83d6a06c9e5c` | 73 |
| `AgentRecoveryStoreTests` | `056c676a-2e96-40b4-965a-91e8c2d83e86` | 25 |
| `AgentRecoveryActionTests` | `0b8c714d-6978-4e15-941a-8a35ea2660ee` | 34 |
| `AgentModeRunServiceLifecycleTests` (fake changed) | `4e27956a-821f-43a6-8f74-59b77c860915` | 237 |
| `CodexFallbackFIFOTests` | `1c891ae7-d25d-4ce3-85d3-46ca29896a28` | 38 |
| `CodexSteerAckTrackerTests` | `61001c00-7c88-4122-a78d-b9ef42f44b42` | 17 |
| `make dev-lint` | `f64889b1-e107-4f61-9772-7a1980fec5c8` | clean |

Not run: `AgentRecoveryActivationTests` (owned by the parallel worker), the full suite, and any live check. B's other F5 negatives (ownership-mismatch and no-lane guards) were not requested and were not added.

## Review fixes (round 1)

The round-1 reviews are [02ea](../../../../../prompt-exports/oracle-chat-2026-10-28-221148-9fix-5-codex-turn-re-02ea.md) (new P1) and [6543](../../../../../prompt-exports/oracle-chat-2026-10-28-221202-9fix-5-codex-turn-re-6543.md) (the same issue at P3).

**Problem.** A clear removed the `providerTurnID` key. The lookup then fell back to a transcript span, so a span naming an older user turn could be observed again.

**Fix.**
- **Clear marker.** A clear is now stored as an explicit JSON `null`, so the key stays present.
  - The store compares the stored JSON value, not the decoded ID. Clearing an attempt whose key is absent therefore still writes the marker; clearing again is `.unchanged` (`AgentRecoveryStore.swift:1290`).
  - Run-attempt extras keep unknown members verbatim, so `null` survives the codec. The store test reloads it through a second store instance.
- **Model.** New `AgentRecoveryRunAttempt.hasProviderTurnRecord` (`AgentRecoveryModels.swift:801`) is true when the key is present, whether it holds an ID or the marker. `recordedProviderTurnID` is still `nil` for the marker.
- **Lookup.** `performRecoveryResumeAction` (`AgentModeViewModel+RecoveryActions.swift:188-194`) uses the record whenever `hasProviderTurnRecord` is true, which gives the ID or `nil`. A `nil` there means "wasn't identified". It falls back to the span only when the key is absent (legacy or unrecorded attempts).

**Tests.**
- **New regression.** `testCheckNeverObservesTheSpanTurnAfterTheRecordedTurnWasCleared` (`AgentRecoveryReconciliationTests.swift:4584`) sets up a span naming `turn-old`, a recorded clear, terminal evidence, then runs Check. Codex is never asked for any turn (`observedExpectedTurnIDs == []`), the run isn't reported resolved, nothing is imported and nothing is sent.
- **Mutation check.** I temporarily changed the lookup back to "record only when the ID is non-nil". The regression then failed three assertions: it observed `turn-old`, resolved the run and imported (ticket `d38691b5`). The lookup was then restored.
- **Store test.** It now also pins:
  - the marker is `.null` and survives a reload;
  - `hasProviderTurnRecord` is false on a new attempt;
  - clearing an attempt that never recorded a turn writes the marker (committed), with `recordedProviderTurnID` still `nil`.

**Validation (all exit 0, 0 failures).**

| Suite | Ticket | Tests |
|---|---|---|
| `AgentRecoveryStoreTests` | `9be26045-7055-4115-a8dd-be71d182a6a7` | 25 |
| `AgentRecoveryReconciliationTests` (after restoring the lookup) | `18ddf1d5-0caf-4250-b4b6-3d23d0bbe94e` | 74 |
| `CodexAgentModeCoordinatorLivenessTests` | `81414e8e-71bb-422b-9764-b949938d322e` | 63 |
| `AgentRecoveryActionTests` | `5b3e6f6d-b02e-49de-95bb-561ba2025d30` | 34 |
| `make dev-lint` | `2fd657e7-e19e-4e91-9500-e8b2c4293061` | clean |

Source files were edited only after the conductor showed release job `54b7d611` completed with no active lanes.

Not run: `AgentRecoveryActivationTests`, the full suite, and any live check.
