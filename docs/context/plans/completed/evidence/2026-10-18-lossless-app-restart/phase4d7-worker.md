# Lossless restart Step 4d7 — worker implementation report

Scope: read when the task touches review of the Step 4d7 implementation (exact agreement ending live-producer revocation ownership), its tests, or its validation tickets.
Authority: Reference
Last-verified: 2026-10-24

Worker evidence for [main's settled contract](phase4d7.md). Gates stay OFF; there was no provider prompt, app launch, staging or commit. Raw private captures were not inspected. Unrelated dirty files were left alone.

## Safety audit anchors (MC1–MC3, MV1)

**MC1: one recovery consumer, which never trusts a digest alone.** `recoveryHistoryObservation` (`AgentModeViewModel+RecoveryActions.swift:1289`) is the one production `.importAfter` read (`:1341`). Its success then flows through `reconcileRecoveryHistory` (`:1068`) in this order:
1. A failed observation becomes `.blocked`. Only `isUnconfirmedObservation` becomes `.nothingImported` (`:1141`).
2. The main-actor unchanged-session/ledger fence (`:1153-1159`, `session.providerHistoryRecovery == ledgerAtStart`).
3. The Claude `AgentProviderHistoryAssociationPreflight.check` (`:1167`), which also runs `canonicalPayloadRefusal` (`AgentProviderHistoryImport.swift:398`).
4. The plan, the save, and only then the cursor (`:1236`).

The reader (`ClaudeSessionHistoryReader.swift`) works through these steps before the known-entry and frontier filter:
1. parse, including semantic markers;
2. `validateGraph` (`:416`);
3. `verifyFences` (`:425`);
4. project every entry;
5. `ledgerConflict` over all rows (`:453`, `:527`).

So an agreed key stays a known key that later reads validate even before the cursor.

**MC2: a strong single-text predicate.** `ClaudeSessionHistoryReader.singleTextAssistantRow` (`:1050`) uses the same `project`/`envelopeDigest` as a read. The new test `testALiveAgreedEntryBeforeTheFrontierDeduplicatesOnlyWhileUnchanged` pins that the live projection equals the import planner's ledger entry for a full O19 turn.

**MC3: three message branches, none of which dispatches.**
- `recoveryHistoryChangedText` covers `.ledgerConflict` and `.rewrittenHistory` (`:1350-1351`).
- `recoveryHistoryUnprovenText` covers `.prefixProofUnavailable` (`:1352-1353`).
- `recoveryHistoryUnsupportedText` covers other `.unsupported` results (`:1354-1355`).

Each is a `RecoveryHistoryFailure` with `isUnconfirmedObservation == false`, so it becomes `.blocked`. In `AgentRecoveryActionRunner.swift:248-266`, a `.reconcileOnly` turns `.blocked` into `.notDispatched`. A continuation stops in `stopBeforeDispatch` before `performers.dispatch` (`:271`).

**MV1: one verified path.** The only production path is importAfter → unchanged-ledger fence → association and canonical preflight → plan. A successful agreement adds no consumer, so nothing else can read a kept digest as completion or authorization.

## Receipt correction (from the follow-up)

The earlier MC1 consumer trace treated a live key without a receipt as a normal shape. It is not. A real qualified outbound always commits a zero-row baseline receipt with a valid target before it returns the outbound UUID:
- `+RecoveryActions.swift:986-1023` commits the receipt, moves the cursor at `:1018`, and returns `.committedWithOutboundUserMessage` at `:1023`.
- The caller consumes it at `:845-852`.
- The controller passes on only that UUID (`ClaudeNativeProcessSessionController.swift:966-996`).
- An unidentified admission disqualifies the producer (`ClaudeLiveTranscriptQualification.swift:376-398`, `unidentifiedOutbound`).

A live key without a receipt therefore only arises in synthetic, legacy or failure conditions. It stays conservatively refused, and no repair was added.

## Source delta

- **`ClaudeLiveTranscriptQualification.swift`:** new `ClaudeLiveTranscriptCompleteText.projecting(nativeSessionID:nativeEntryID:text:)`. It is the reader's exact single-text projection (ID and digest), used for comparison only and never stored. It mirrors `ClaudeLiveTranscriptToolRow.projecting`.
- **`AgentModeViewModel.swift`, owner:**
  - **`resultAgreement`.** It now calls `claudeLiveTranscriptTextAgreementKey`, which requires:
    - the producer is not refused;
    - exactly one Claude ledger entry exists for the `localItemID`, in the tab's conversation when that is known;
    - that entry's key is unique;
    - the entry equals the projection of the agreed text in full (identity, kind, ordinal, local ID and digest);
    - `holdsClaudeLiveTranscriptRow` passes (a valid digest, plus exactly one complete, non-streaming canonical copy across persisted turns and suffix).

    If the predicate holds, `consumeClaudeLiveTranscriptOwnership` runs on that key; otherwise the existing `refuseClaudeLiveTranscript` does.
  - **`readAgreement`.** On success it consumes the chain's three keys. Failure is unchanged.
  - **Consumption.** It subtracts only owned keys and removes an emptied entry. A key the producer doesn't own is a no-op. It never touches the ledger, rows, digest, receipt, cursor, dirty flag or save.
  - **Unchanged.** Refusal still latches the producer and invalidates the remaining owned keys. Nil-attribution text classification is untouched.
  - **Docs.** The doc comments on the owner, the refusal and the helpers were updated.
- **`AgentTabSession.swift`:** the `claudeLiveTranscriptOwnedKeys` doc now covers Step 4d7.
- **`AgentModeViewModel+RecoveryActions.swift`:**
  - `recoveryHistoryChangedText` and `recoveryHistoryUnprovenText` now end "Nothing was imported or sent."
  - The inline unsupported text is lifted, with no behavior change, into `recoveryHistoryUnsupportedText` with the same suffix, so tests can reference it.
  - `recoveryHistoryText`, the baseline warnings and the `recoveryBaseline*Reason` strings are unchanged.

There is no new carrier, map, reason, classifier, schema, receipt, cursor, save or gate change.

## Test delta

All method names are unchanged; the frozen ledger is untouched.

**Intentionally changed expectations** (each marked "Step 4d7 (intentionally changed expectation …)" in the source):
1. `testClaudeLiveCompleteTextInsertsCanonicalRowOnceAndConflictsInvalidateProofs`:
   - After the exact agreement, ownership is empty, where it used to show "no ownership change"; nothing is marked dirty.
   - The same producer's later changed text still refuses and shows unidentified, but keeps the agreed proof instead of invalidating it.
   - To keep the old self-conflict coverage, a second, unagreed producer now inserts `a2` and conflicts on it: its proof is invalidated, and the key and local item are kept.
   - A third producer still never heals: `nativeItems.count` is 2, up from 1.
2. `testClaudeLiveEvidenceReachesTheOwnerThroughTheRunServiceAndLaterRefusalsInvalidateProofs` (real controller and run service):
   - Ownership is empty after the agreed turn.
   - The later undecodable-line or EOF refusal latches the producer and keeps the agreed proof, where it used to invalidate it.
3. `testClaudeLiveReadChainInsertsThreeCanonicalRowsAccountsOnceAndDuplicatesAreNoOps`: ownership is empty after the whole-chain agreement, where it used to keep all three keys owned.

The unagreed-revocation tests keep their assertions unchanged:
- `…RefusalsInvalidateProofsAndRefusedProducersNeverRequalify`
- `…RefusalClearsOnlyTheRefusedProducersOwnNewProofs`
- `…ImportedMatchesNeverAcquireOwnership…`
- `…OwnershipSurvivesRunCompletion…`
- the Read-chain refusals
- `testLiveQualifiedRowRoundTripsAndInvalidationRefusesWithoutHealing`
- `testPersistedHydrationKeepsLiveOwnershipSoALaterRefusalStillRevokesItsProof`
- the save-ordering test

**Added assertion:** the real-run Read chain test checks that the agreed chain is no longer owned.

**New tests:**
- **`AgentModeRunServiceLifecycleTests` (in `ClaudeNativeBackgroundTranscriptTests.swift`):**
  - **`testClaudeLiveAgreedPrefixesSurviveALaterRefusalWhichRevokesOnlyUnagreedKeys`.** An agreed two-text prefix and an agreed Read chain, then an unagreed text and an incomplete call/result pair, then either an unsupported-payload refusal or a background refusal. The five agreed proofs are kept, and only the three later keys are revoked.
  - **`testClaudeLiveFailedDroppedAndPostRefusalAgreementsProtectNothing`.** Covers a failed agreement, a dropped one, an exact agreement after refusal, and a chain agreement after refusal.
  - **`testClaudeLiveTextAgreementRequiresTheExactUniqueCompleteProjection`.** Two positive controls consume the key with no dirty mark and no ledger change: the exact exchange, and the row held only in a persisted turn (which shows agreement reads persisted turns plus suffix). Every negative refuses and invalidates its owned proof:
    - another agreed text;
    - another non-nil ledger digest;
    - a nil ledger digest;
    - an ambiguous local ID (the other entry, which it never owned, keeps its proof);
    - an ambiguous key;
    - a duplicate canonical copy, built as two persisted turns holding the ID;
    - a streaming copy;
    - an incomplete copy;
    - no canonical copy;
    - another conversation.

    The copy cases assert their held/not-held precondition first. A second suffix copy can't be formed, because `items.didSet` repairs duplicate suffix IDs; the first run's precondition caught this, and the fixture was moved to persisted turns.
  - **`testClaudeLiveAgreementsOnRowsTheProducerDoesNotOwnAreNoOps`.** Agreements on an imported row, on another producer's text and on another producer's whole Read chain each leave rows, ledger, accounting, dirty state, refusals and ownership unchanged. The producer's own agreement removes its emptied entry, and a repeat is a no-op. Later refusals revoke only the remaining keys of the producer that owns them.
- **`ClaudeSessionHistoryReaderTests.testALiveAgreedEntryBeforeTheFrontierDeduplicatesOnlyWhileUnchanged`.** It first checks that the live projection equals the planner's entry. With the cursor past the agreed entry:
  - unchanged history is suppressed (dedup);
  - a changed entry gives `ledgerConflict("a1")`;
  - a missing one gives `ledgerConflict("gone")`;
  - a retracted one (`supersedes`) gives `semanticMarker`;
  - a proofless one gives `ledgerConflict("a1")`.
- **`AgentRecoveryReconciliationTests`:**
  - **`testAnAgreedLiveRowSurvivesALaterRefusalAndDeduplicatesOnlyUnchangedHistoryAfterRelaunch`.** Agreed, then refused, then saved: the proof is kept on disk. A relaunched composition hydrates it from disk. An unchanged native reply gives `.imported(rowCount: 0)` with no duplicate. A changed reply gives `.blocked(recoveryHistoryChangedText)` with rows, ledger and cursor unchanged.
  - **`testAnAlreadyLoadedLoadKeepsLiveOwnershipForTheTurnsLaterAgreement`.** This is the single hydration regression, through the existing `loadSessionFromDisk` entrypoint. It is not forced unloaded: the already-loaded return leaves rows, ledger and ownership unchanged, and a later agreement still consumes.
- **`AgentRecoveryActionTests.testClaudeHistoryChangedUnprovenAndUnsupportedRefusalsNeverDispatch`.** Each of the three texts ends "Nothing was imported or sent." and, as `.blocked`, a continuation never dispatches (`dispatch == 0`). The file now imports `RepoPromptApp` to reference the constants.

The existing real-read two-cycle and partial-continuation tests in `AgentRecoveryReconciliationTests` are unchanged and were run.

## Tickets

All checks ran through conductor on the final tree. Product sources are unchanged since the compile; only one test line changed after it.

- **Focused tests:** ticket `a7ceac58-009b-4370-a0e5-a7627d048e80`, exit 0. Filter: `AgentModeRunServiceLifecycleTests|ClaudeSessionHistoryReaderTests|AgentRecoveryReconciliationTests|AgentRecoveryActionTests|ClaudeLiveTranscriptQualificationTests`.
  - **Earlier run `fb11996c-45ba-4607-abc0-570f188e87ae`:** 349 tests, 0 failures. Every new and changed test was confirmed passed by name. The two-cycle tests `testLiveReadChainSurvivesRepeatedSaveAndHydrationAndItsImportIsANoOp` and `testImportedReadRowsSurviveRepeatedSaveAndHydrationAndReimportAsANoOp` passed unchanged.
  - **First run `ab21d499-2146-4aba-b228-07e0f4791c4e`:** failed only on the impossible suffix-duplicate fixture, which has since been fixed.
- **Product compile** (`make dev-swift-build PRODUCT=RepoPrompt`): `713d19ab-3745-4a4d-83b0-e45e79c0f86c` (the earlier production-only compile was `b43709a8-f4c3-4329-8ed3-d510a4226ff7`).
- **Lint** (`make dev-lint`): `f181243e-872b-41fd-8ae5-6ea6a7f02ef5`. An earlier `preferKeyPath` finding in a test was fixed with `.joined()`.
- **Format check** (`make dev-format-check`): `e000545f-65f7-4891-abeb-6a7b8fc632f3`.
- **`git diff --check`:** clean.
- **`Scripts/check-agent-context`:** passed; the only warning is the pre-existing `AGENTS.md` route-count warning.
- **Frozen ledger** (`Scripts/Fixtures/test-suite-contract-ledger.tsv`): unchanged.
- **Not run:** the full suite, dev-build/package/run, and any provider or app action.

## Limitations

- **Gates and acceptance.** Gates stay OFF and live acceptance is still pending. This doesn't qualify Claude's production format or the MCP/permission/spawn path.
- **Agreement is not completion.** An agreement is not Claude completion or recovery authorization. Later recovery is still decided by the fresh native, whole-ledger and canonical validation.
- **Already-cleared proofs.** A proof cleared before agreement is never restored or healed.
- **Forced hydration.** It is still conservative: the existing forced-unloaded mid-chain fixture refuses. The single hydration regression covers only the already-loaded entrypoint, and it found no new normal trigger.
- **Keys without a receipt.** Live keys without a receipt stay refused, with no repair.
- **Save not observed directly.** The tests use `isDirty == false` as the proxy for "no save requested" on consumption; `scheduleSave` isn't observed directly.
