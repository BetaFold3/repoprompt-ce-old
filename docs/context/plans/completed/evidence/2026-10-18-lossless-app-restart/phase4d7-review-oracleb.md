# Step 4d7 — OracleB initial review

Scope: read when the task touches source review findings for lossless restart Step 4d7 agreement-proof retention.
Authority: Reference
Last-verified: 2026-10-24

Independent fresh review on eight-file staged tree `fb60e9de8f535c0a63b2752a8f1e53f4fc44f2ab` (+600/-42), with main-verified 349 tests, compile and style evidence. Exact preset identity verified; full response read by main.

# Oracle Review



# Step 4d7 source review: exact agreement ends live revocation ownership

## Summary

The diff makes two runtime changes and one wording change:

- **Read chain agreement.** When a whole Read chain agrees exactly, the producer stops owning the chain's three ledger keys. The check that decides whether the chain is still held is unchanged.
- **Single-text agreement.** The old check only looked for any Claude ledger entry with a non-nil digest and a suffix row with matching text. It is replaced by a full projection comparison, `claudeLiveTranscriptTextAgreementKey`:
  - exactly one Claude ledger entry for the local ID, and its key is unique;
  - the conversation matches when one is known;
  - `ClaudeLiveTranscriptCompleteText.projecting(...)`, which reuses the reader's `singleTextAssistantRow`, rebuilds the expected entry, and it must equal the stored entry in full (identity, kind, ordinal, local ID, digest);
  - the canonical view (persisted turns plus suffix) holds exactly one complete copy, via `holdsClaudeLiveTranscriptRow`.

  If this check passes, only the keys this producer owns are removed and nothing is saved. If it fails, the existing refusal path runs.
- **Refusal wording.** The three action-scoped Claude refusal strings (changed, unproven, unsupported) now end "Nothing was imported or sent." The unsupported one moves into a shared constant. The baseline warnings and `recoveryHistoryText` are untouched.

I traced the paths below against the contract and found no bypass, no consumption of a key the producer doesn't own, and no identity or canonical-view error:

- **Consumption is a strict subset.** `consumeClaudeLiveTranscriptOwnership` uses guard → `subtract` → remove-if-empty and only touches `claudeLiveTranscriptOwnedKeys[producer]`. It cannot gain or move a key. It doesn't change the ledger, rows, dirty flag or save.
- **No healing after refusal.** `claudeLiveTranscriptTextAgreementKey` checks the refusal latch first. The Read branch's `agrees` also checks it. So an agreement after a refusal always refuses again, which is idempotent and never consumes.
- **The digest now depends on the text.** The rebuilt `expected.ledgerItem == stored` comparison means another non-nil digest, or another agreed text under the same entry, fails. That closes the old "any non-nil digest" weakness.
- **Unowned keys are untouched.** Agreement on an imported row, another producer's row, or a duplicate passes the hold check and is a no-op for ownership.
- **`refuseClaudeLiveTranscript` is unchanged.** It latches, then invalidates whatever keys are still owned. Agreed keys are simply no longer in that set, so earlier agreed proofs survive a later refusal and digests that were already cleared stay cleared.
- **Recovery still checks everything.** The reader still compares every applicable ledger entry against the full projected `rows` before the frontier filter (`ledgerConflict` runs before `newRows`), after the fence, graph and semantic-marker checks. A kept proof whose native entry is changed, missing, retracted or proofless therefore still refuses. The new reader test and the relaunch test cover the changed and missing cases on the real `importAfter` path.
- **Refusals still stop the send.** `stopBeforeDispatch` maps `.blocked` to `.notDispatched` unconditionally, so the reworded refusals still stop before dispatch.

## P2 — Consider

### F1 — A refused producer whose keys all agreed no longer blocks later launches in the conversation (intent not pinned by a test)

- **Scenario:** Producer P inserts a text, its result agrees exactly (ownership ends), and then a later payload refuses P. Before 4d7, that refusal cleared P's proof. `hasProoflessClaudeItem(nativeSessionID:)` then refused every later producer in the conversation, so effectively any refusal after an insert blocked the conversation. Now nothing is cleared, nothing is proofless, and the next launch Q can qualify and insert identified rows again.
- **Evidence:**
  - `refuseClaudeLiveTranscript`: `guard !ownedKeys.isEmpty … else { return }`.
  - `applyClaudeLiveTranscriptCompleteText` and `applyClaudeLiveTranscriptToolRow`: the `hasProoflessClaudeItem` guards.
  - The rewritten test `testClaudeLiveCompleteTextInsertsCanonicalRowOnceAndConflictsInvalidateProofs` ("A new producer never heals…") still passes only because the unagreed `a2` was made proofless. No test pins what happens when every key agreed.
- **Impact:** I don't think this is a safety regression. The fresh recovery reader still checks every ledger entry and every semantic marker. It also already applied whenever a producer was refused before inserting anything. But it is an unstated change in how the existing gate behaves, and a future reader of the "never heals" test could easily assume the opposite.
- **Smallest fix:** add one assertion (or a sentence in the doc comment) saying that a new producer after an all-agreed refusal is allowed to qualify. If that is not intended, say so, and the policy question goes to the owner. No code change is needed if it is intended.

### F2 — The new action test is partly circular for two of the three strings

- **Scenario:** `testClaudeHistoryChangedUnprovenAndUnsupportedRefusalsNeverDispatch` passes a stubbed `.blocked(message)` to the runner. It proves the suffix and the runner's `.blocked` → `.notDispatched` behaviour, but not that `recoveryHistoryObservation` maps `.prefixProofUnavailable` and the generic `.unsupported` to `.blocked` rather than to `isUnconfirmedObservation` / `.nothingImported`.
- **Evidence:** `AgentRecoveryActionTests.swift`, the new test. Only the changed-text mapping is exercised end to end, by `testAnAgreedLiveRowSurvivesALaterRefusal…` (the ALPHA-8 case).
- **Impact:** low. The mapping is a three-line switch and its default for `RecoveryHistoryFailure` is `isUnconfirmedObservation = false`. Still, a future edit that marked these as "unconfirmed" would let a continuation be sent, and this test would not catch it.
- **Smallest fix:** cheap. If reconciliation tests for proofless and unsupported paths already exist, add `XCTAssertEqual(result, .blocked(AgentModeViewModel.recoveryHistoryUnprovenText))` (and the unsupported equivalent) to them. Otherwise defer.

## P3 — Improvements

- **F3 — The projection is computed three ways** (`ClaudeLiveTranscriptQualification.swift`). `projecting(...)`, `matchesProjection` and `canonicalItem` each call `singleTextAssistantRow` separately. `projecting` also checks `kind == .assistantText` and `ordinal == 0`, which `matchesProjection` does not. `matchesProjection` could be `Self.projecting(nativeSessionID:nativeEntryID:text:) == self`. That keeps one definition and gives the existing path the same kind/ordinal checks. Optional; it does change the predicate the 4d3b path uses slightly, so only do it if re-validating is cheap.
- **F4 — Mixed token naming in `applyClaudeLiveTranscriptEvidence`.** The `.disqualified` branch still uses `evidence.producerLaunchToken`, while `.resultAgreement` was switched to the local `producer`. The value is the same; using `producer` everywhere would be consistent.
- **F5 — Read and text agreement now check different things.** Text agreement checks the conversation (`providerSessionID`) and that the local ID and key are unique. The Read agreement keeps its 4d5 checks: hold-only, no explicit conversation check, no local-ID uniqueness check. This matches the contract ("Read existing complete-chain held checks unchanged"). For the Read chain, conversation binding comes indirectly from the deterministic keys. Mention it in the evidence notes so a later step doesn't assume the two checks are the same.
- **F6 — An "ambiguous key" refusal also clears the other entry.** In `testClaudeLiveTextAgreementRequiresTheExactUniqueCompleteProjection`, the "an ambiguous key" case appends a second entry under the owned key. The refusal then invalidates by key, which also clears that second entry's digest. The test only inspects `own`, so it neither shows nor rules this out. This behaviour already existed in `invalidateClaudeEnvelopeProofs(forKeys:)` and the input is contrived. No action is needed beyond being aware of it.

## Recommendations

1. **No P0 or P1 findings.** The consumption is an exact subtraction of keys the producer owns. Agreement now compares the full ledger entry against the reader's projection, plus exactly one complete canonical copy. Refusal is unchanged apart from the smaller set of keys it still owns. The fresh recovery reader still checks every ledger entry before the frontier filter. The step can be committed against this contract once the other lane's review is also done.
2. **F1:** state the intended behaviour for a new producer after a refusal where every key agreed, in the `AgentTabSession` / refusal doc comment or with one test assertion. It costs about one line and removes ambiguity about the old blocking behaviour.
3. **F2:** if fixtures for proofless and unsupported reconciliation already exist, add the two `.blocked(<constant>)` equality assertions. Otherwise defer.
4. **F3–F6:** defer.
