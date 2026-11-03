# Step 4d7 — OracleB planning

Scope: read when the task touches prospective Claude agreement proof retention, safe refusal and remaining pre-live closure for lossless restart Step 4d7.
Authority: Reference
Last-verified: 2026-10-24

Independent fresh planning; exact preset identity verified and complete reply read by main. Response follows.

## Continuation after safety audit

# Oracle Plan



# Step 4d7: can the minimal retention contract land?

## Verdict

**Yes, it can land.** I tried to construct a case where a fresh reader passes and the kept agreed proof still causes a wrong import or a wrong dispatch. I couldn't find one. The reason is that a kept proof does one thing only: it marks a native entry as already shown, so the reader doesn't import it again. Two independent checks re-verify that claim at use time, and neither depends on how ownership was tracked. No new state is needed. One read-only check (MV1 below) must hold before landing.

## Why keeping the proof can't cause a wrong import or dispatch

A kept proof is a ledger row: key, localItemID and digest. It has an effect only through three consumers, and each one already fails closed:

1. **`ledgerConflict` (reader, lines 525–550).** It checks every known entry of this provider and session, across the whole capture and not only after the frontier. The entry must be present, with exactly the same set of keys, and every key must carry the same digest as the observed native entry.
   - If the native entry changed, was removed, was duplicated with different content (`conflictingDuplicate`), or carries retraction or supersede markers (`semanticMarkers`, parse failure), the reconcile rejects before any suppression happens.
2. **`canonicalPayloadRefusal` (import, around lines 477–565).** It runs on every applicable ledger item that has a `localItemID`.
   - It needs the native key in `validationRows`, an `expected.id == localItemID` match, and exactly one complete copy of the payload in the canonical transcript. Otherwise it refuses with `canonicalPayloadUnavailable` or `canonicalPayloadMismatch`.
   - So a kept proof can't hide native content that the local row doesn't actually show.
3. **Completion and dispatch.** MC1 found that no completion signal is derived from the ledger, and Claude completion stays `.unconfirmed`.
   - The ordinary baseline reads with `ledger: nil`. Its only ledger input is `claudeBaselineFences` → `hasImportedHistory`.
   - Before this change, refusal cleared digests but kept the keys, so `hasImportedHistory` was already true. Keeping proofs doesn't change the baseline fence or receipt behaviour. The "live keys without a receipt" condition is neither new nor made worse by this change.

**Scenarios checked:**

| After an agreed exchange | Before (revoke) | After (keep) | Wrong import or dispatch? |
|---|---|---|---|
| Native unchanged | Digest nil → `ledgerConflict` blocks the whole conversation | Reader and preflight pass; the entry is deduplicated | No. Only a false block is removed. |
| Native entry changed or rewritten | Blocked | `ledgerConflict` on the digest | No. |
| Retracted or superseded in native | Blocked | Unsupported marker or graph failure | No. |
| Same-key live mismatch while native keeps the old envelope | Blocked | Old entry deduplicated; the new output stays unidentified; the producer is refused | No. Native is what `--resume` sees. |
| Ledger replaced by hydration with a different non-nil digest | Blocked or revoked | Reader or preflight re-verifies the proof against native | No. |
| A turn left incomplete or open after agreement | Revoked | Still revoked (keys still owned) | Unchanged. |

**What revocation actually buys.** Getting consumption wrong, whether too broad or too narrow, changes only which proofs a later refusal revokes. That is a policy choice for safety margin, not a correctness requirement. This is why the agreement check only needs to be honest, not cryptographically bound.

## MC2: is a typed CompleteText carrier necessary?

**No.** A carrier would add one thing: binding the agreed envelope's digest to the ledger row. That binding is exactly what the fresh reader checks, against the authority that matters (the native file at use time). Checking it at agreement time would be a second check that adds no authority.

The local ID is deterministic: `deterministicUUID("rpce-claude-history-row-v1", [providerRaw, nativeSessionID, entryUUID, kind, ordinal])`. So the ledger row's own fields, re-derived, bind `localItemID` to its identity without any carrier.

**Consumption predicate for `resultAgreement`.** Evaluate it only when the existing `agrees` is true:
- Exactly one applicable Claude ledger item has `localItemID == L`.
- Its key is in `owned[producer]`.
- `rowKindRaw == assistantText`, `ordinal == 0`.
- Re-deriving the deterministic ID from its `(nativeSessionID, nativeEntryID, kind, ordinal)` gives `L`.
- `envelopeDigest` is valid SHA-256 hex.
- The expected item, rebuilt from identity plus the agreement text, satisfies `holdsCanonicalPayload` exactly once in the canonical transcript (persisted turns plus suffix).
- If all of the above hold, consume `{key}`. Otherwise consume nothing.

**Refusal behaviour.** Keep the refusal predicate as the existing `agrees` check, unchanged. When the weak check passes but the strong one fails, the result is neither a refusal nor a consumption: the key stays owned and a later refusal can still revoke it. This narrows nothing and broadens nothing in qualification.

**MV2.** Only claim "digest equality" if `singleTextAssistantRow`, or a related helper, can rebuild the expected digest from identity and text. I expect it can't, because the digest covers the whole envelope. In that case the predicate checks digest validity, and the reader does the equality check later.

- Do not write a digest during consumption.

**Read path.** Consume `{call, result, answer}.ledgerKey ∩ owned[producer]` only when the existing `readAgreement` check is true. It already compares each carried `ledgerItem` exactly against `nativeItem(forKey:)`.

**Imported or other-producer rows.** The intersection with owned keys is empty, so nothing is consumed and nothing is acquired.

## Nil-attribution text agreement

Keep the existing classification. Don't require positive attribution for consumption.

- Consumption keeps only an identity proof that will be re-verified. It never asserts completion or freshness.
- So the worst case of a misattributed agreement is that a later refusal doesn't revoke a proof the reader still checks. By the table above, that is not a wrong import.
- Requiring attribution only for consumption would add a second qualification tier, which is a change to the classifier contract.
- Read's stricter rule stays as it is. The asymmetry is acceptable and should be documented in the doc comment.
- Record it as `assumed: text-agreement consumption uses existing classification; identity-only retention`.

## Remaining check (must pass before landing)

**MV1.** Every caller of `ClaudeSessionHistoryReader.decode(mode: .importAfter, ledger:)` must:
- run `canonicalPayloadRefusal` (via `AgentProviderHistoryAssociationPreflight.check`) before planning; and
- check that the ledger is unchanged before applying.

Check this for all callers: reconcile, inactive Resume, history import, and the saved relocation. To check, grep for `importAfter` and `knownEntryIDs`.

If any path suppresses known entries without the canonical preflight, a kept proof could hide native content there. In that case, fix that path's preflight, or exclude it from Step 4d7 and report it. Don't add ownership state to work around it.

## Hydration and copy

- **Hydration.** Accept the trace: there is no normal user trigger. Pin each existing guard (already-loaded return, rebind active-run check, Reload Latest quiescence plus consent) with a test only if a small harness for the real entry point already exists.
  - Record in evidence that the forced `hasLoadedPersistedState = false` fixture still refuses conservatively.
  - Don't add a guard that checks whether a controller is present.
- **Copy.** Change only the three action-scoped strings, and add a regression test asserting zero dispatch for each blocked or `associationUnavailable` path. Leave `recoveryHistoryText` unchanged, because the ordinary baseline path that can send also uses it.

## Tests (fixture and unit; never presented as live)

1. Two agreed single-text turns, then a later refusal for any reason: both proofs are kept and the producer is refused.
2. An agreed Read chain, then a background refusal or `unidentifiedOutbound`: all three proofs are kept.
3. Agreed turn 1, then turn 2's call and result are refused before its answer: only turn 2's keys are revoked.
4. The existing check fails (text changed): revoked, nothing consumed.
5. Agreement carrier dropped, then a refusal: revoked.
6. The weak check passes but the strong one fails: not consumed, not refused, and a later refusal revokes. Cover each case:
   - a second ledger item with the same local ID;
   - an ID that doesn't re-derive;
   - a duplicate canonical row;
   - a row held only while streaming or incomplete.
7. Same-key mismatch after agreement: the proof is kept and the producer is refused. Run the reader on two fixtures:
   - native unchanged → dedup with no duplicate rows;
   - native changed before the frontier → `ledgerConflict`.
8. Agreement for an imported or other-producer row consumes nothing; repeating an agreement is idempotent; consumption never calls `scheduleSave` or sets `isDirty`.
9. Save, reload, then reconcile: agreed rows are deduplicated and nothing is imported twice.
10. Copy: each changed message path dispatches nothing.
11. Regression: run the fresh-service fixture twice and the partial-continuation fixture. The assertions on existing 4d3c revocation change only for agreed exchanges, and each changed assertion is listed in evidence.

## Recommendations

- **Land Step 4d7 with the minimal contract** once MV1 passes:
  - consume owned keys only on an exact, strongly checked agreement;
  - leave the refusal latch and invalidator unchanged;
  - no new map, carrier, reason classification, schema, gate or classifier change;
  - no restoration of proofs that were already cleared.
- **If MV1 fails,** fix or exclude the path that lacks the canonical preflight, and report it. Don't compensate with ownership state.
- **Use the strong predicate only for consumption.** Keep the existing `agrees` check for the refusal decision. Record the two `assumed:` lines (no carrier; existing text attribution).
- **Copy change:** the three action-scoped strings plus zero-dispatch tests. Hydration: record in evidence; add a guard pin only if it's cheap.
- **Run OracleA and OracleB** on the diff together with the MV1 and MV2 results. Commit locally, unsigned, once no P0/P1 is open.
- **Keep every final live gate pending:** actual-profile stdout, discovery and markers for every provider pair, `freshSessionID`, hooks, dangling resume, crash cuts. They go into one isolated package. No partial capture ladder, and the plan is not marked complete.

## Initial guidance (superseded where noted)

# Oracle Plan



# Lossless restart closure: keeping proofs of completed exchanges, plus the finite critical path

## 1. Summary

When a Claude producer is refused today, the app clears the proof of every row that producer inserted during its launch, including turns that already finished and agreed. The fix is to separate "this producer can't qualify any more output" from "this producer's earlier proofs are revoked". When an agreement check succeeds (the existing `resultAgreement`/`readAgreement`), the owner stops tracking that exchange's keys as owned by the producer. A later refusal then revokes only what is still unagreed: open or incomplete exchanges and rows whose agreement was dropped. There is no new persisted state, no new journal, no classifier change and no reader change.

The same-launch hydration question is a read-only trace whose result decides the step that comes after this one. The recovery messages become explicit that nothing was sent. Everything else stays pending as one isolated final live qualification package.

## 2. Current-state analysis

**Live owner flow.** `AgentModeViewModel.applyClaudeLiveTranscriptEvidence` runs on the main actor in stream order. Each inserted row goes through `insertClaudeLiveTranscriptRow`. That one step appends the row and its ledger entry and adds the key to the transient `session.claudeLiveTranscriptOwnedKeys[producer]`. That set is never trimmed, so it grows across every dispatch in the launch.

**Refusal is total.** Any refusal calls `refuseClaudeLiveTranscript`. That covers `.disqualified`, a failed agreement, a background refusal, a failed prerequisite hold, a collision, a mismatch on an existing key, and a provider handler consuming the event. It does two things:
- it adds the producer to `claudeLiveTranscriptRefusedProducers`, which is correct;
- it removes the whole owned set and calls `invalidateClaudeEnvelopeProofs(forKeys:)` on it, which is the defect.

**Why one revocation blocks the whole conversation.**
- A nil digest makes `ClaudeSessionHistoryReader.ledgerConflict` fail (`$0.envelopeDigest == entry.digest`). The reconcile returns `.unsupported(.ledgerConflict)` and shows `recoveryHistoryChangedText`.
- `hasProoflessClaudeItem` then refuses all future live inserts for that native session.
- So one later unsupported payload makes a correct, agreed turn N−k unrecoverable for the whole conversation. A cleared digest can't be restored without inventing authority.

**What already stops a stale or wrong proof from causing harm.** A ledger proof only claims identity: (key, localItemID, digest) for one native entry. Every reader path re-checks it against the native bytes before anything is imported or dispatched: `ledgerConflict`, the prefix fences and the dispatch baseline's rewritten/unproven reasons. Keeping a proof never bypasses that check. If the native file disagrees, the result is still a conservative conflict.

**Imported and other-producer keys.** These are already left untouched on refusal. After agreement, a retained live key gets the same treatment, with the reader as its authority.

**Production exposure.** No production producer attaches evidence: qualification is OFF and the classifier has no production caller. So no real persisted ledger should contain live-inserted keys or revoked digests, and no repair or migration is needed. *Validate:* grep that the injected qualification is enabled only in tests and fixtures.

## 3. Design

### 3.1 Agreed-exchange ownership consumption (Step 4d7)

**Contract (minimum safety statement)**
1. A producer refusal always stops all future qualification for that producer in that tab. No change.
2. A refusal revokes exactly the producer's still-owned keys. Owned means inserted by this producer and not yet consumed by a successful agreement.
3. A key is consumed only when the agreement branch computes `agrees == true`. The keys must still be in `owned[producer]`, and consumption is limited to exactly the agreed exchange:
   - `readAgreement`: `{call.ledgerKey, result.ledgerKey, answer.ledgerKey}` ∩ owned.
   - `resultAgreement(localItemID:text:)`: the keys in `owned[producer]` whose `providerHistoryRecovery.nativeItem(forKey:)?.localItemID == localItemID` and whose provider is Claude. Consume only if exactly one key matches; otherwise consume nothing.
4. Rows from a failed agreement, a dropped agreement carrier, an interrupted chain, or a refusal before agreement stay owned and revocable. This is unchanged and conservative.
5. A consumed key is treated like an imported key. A later mismatch on the same key (`existing != ledgerItem`) refuses the new output, which is shown unidentified. It doesn't revoke the agreed proof; the reader's `ledgerConflict` decides at reconcile time.
6. Consumption is transient and makes no ledger edit, so it never marks the session dirty or schedules a save.

**Why the existing evidence is enough to bound this.** The classifier emits agreement only after attribution, a complete envelope and exact result-text agreement. The owner re-checks that the row is held and the proof is valid. That combination is the only point where a set of keys is affirmatively complete. No disqualification reason has to be classified as benign, because consumption depends only on positive agreement and never on the reason for a later refusal. That also avoids reason-scoped revocation, which would have meant judging which unsupported shapes are "contradicting".

**Why not new transient state (`agreedKeys`).** It would only be needed to revoke agreed keys on a later mismatch of the same key. Parity with imported keys plus the reader re-check already makes that case safe: no import and no dispatch on a real divergence.

**Edge cases**
- Duplicate agreement: consumption is idempotent.
- Agreement for a row inserted by import or another producer: there is nothing to consume.
- Agreement after the producer was refused: `agrees` is false. It is refused, which does nothing new.
- A new launch token is a separate set.
- Quit or relaunch: ownership is lost as today, and open-chain proofs persist valid, which matches the passing partial-continuation fixtures.

**Missing context to confirm during implementation**
- **MC1.** Every read of `NativeItem.envelopeDigest` is either a dedup or identity check or is re-verified against native bytes. None treats a digest as turn-completion evidence (R7 "Completion test"). *Method:* grep `envelopeDigest` and `nativeItems` across AgentCore and the app. If one counts as completion evidence, stop and report it.
- **MC2.** Where `claudeLiveTranscriptOwnedKeys` is declared (expected: `AgentTabSession`). Only its doc comment changes.

### 3.2 Same-launch active-chain hydration (trace now, act afterwards)

The strict live canonical-payload checks are correct and stay unchanged. A scoped read-only worker traces every path that replaces `session.items` or `session.transcript`, or rehydrates the session, while a Claude native turn is in flight in the same launch. Candidates are:
- rehydrating or reloading from disk;
- moving the suffix into persisted turns (lossy representation);
- a transcript reset generation;
- window close or reopen while running (`prepareSessionForWindowClose`);
- tab eviction.

**Closure criteria (either outcome closes it)**
- **(a) Unreachable.** Every replacement path requires an idle turn or no live controller. Add one test that pins this invariant at its guard, and record the result in the evidence. Done.
- **(b) Reachable.** The next step blocks or defers the replacement while `session.claudeLiveTranscriptOwnedKeys[producer]` is non-empty for the in-flight producer. It must not relax the comparison or introduce an import-style stored representation.

**Ordering: 4d7 must land first.** Before consumption, the owned set never empties during a launch, so "owned non-empty" would pin the session forever. After consumption it means exactly "an open exchange exists". Step 4d7 also limits the harm from hydration to the open chain.

### 3.3 Honest unverifiable-history copy

In `AgentModeViewModel+RecoveryActions.swift`, change `recoveryHistoryChangedText`, `recoveryHistoryUnprovenText` and the generic unsupported message from "Nothing was imported." to "Nothing was imported or sent."

- This adds no new action and no fallback. The R7 gates are unchanged, and any already-offered "Continue in a new conversation" stays under its existing gates.
- It is enough for honesty. It does not make the conversation eligible, and it shouldn't.
- **MC3.** Confirm that every runner path showing these strings halted before dispatch, including `continueWithText`, which reconciles first. If any path dispatches after showing one, keep its current text and pass the sent/not-sent fact in instead.

## 4. File-by-file impact

| File | Change | Driver |
|---|---|---|
| `Sources/RepoPrompt/Features/AgentMode/ViewModels/AgentModeViewModel.swift` | Add a private `consumeClaudeLiveTranscriptOwnership(_ keys: Set<String>, producer: UUID, session:)`. It subtracts the keys from `owned[producer]` and removes the dictionary entry when it becomes empty. Call it in the `.readAgreement` and `.resultAgreement` branches only when `agrees` is true. Update the doc comments on `refuseClaudeLiveTranscript`, `insertClaudeLiveTranscriptRow` and `applyClaudeLiveTranscriptEvidence` to state contract items 2, 3 and 5. | §3.1 |
| Declaration of `claudeLiveTranscriptOwnedKeys` (MC2) | Doc only: "keys inserted by a producer and not yet agreed". | §3.1 |
| `AgentModeViewModel+RecoveryActions.swift` | Three string constants. | §3.3; independent |
| Existing 4d3c/4d5 owner tests (locate by grepping `refuseClaudeLiveTranscript` and `claudeLiveTranscriptOwnedKeys` under `Tests/RepoPromptTests/AgentMode/`) | Change only the assertions that expect a later refusal to clear an agreed exchange. Keep the assertions for open and incomplete exchanges. List each changed assertion in the evidence. | §3.1 |
| New tests in the same suite | See below. | §3.1 |
| `ClaudeLiveTranscriptQualification.swift`, `ClaudeSessionHistoryReader.swift`, `AgentProcessRegistrySupport.swift` | **No change.** | — |
| `docs/context/plans/...lossless-app-restart` plan and evidence `phase4d7.md` | Status line, MC1–MC3 results, hydration trace result, Oracle lane findings. | Policy |

**Tests (fixture/unit; never presented as live)**
1. Two agreed single-text turns, then a turn-3 `.disqualified(.unsupportedPayload)`. Turns 1–2 keep their keys and digests, and the producer is refused.
2. An agreed Read chain, then `unidentifiedOutbound` or a background refusal. All three proofs are kept.
3. An agreed turn 1, then turn 2 inserts a Read call and result and is refused before the answer. Turn 2's two keys are revoked and turn 1 is kept.
4. A failed agreement (row text changed). That exchange's keys are revoked and nothing is consumed.
5. A dropped agreement carrier, then a later refusal. The keys are revoked.
6. A mismatch on the same key after agreement. The agreed proof is kept, the new row is unidentified and the producer is refused. Run the reader against two fixtures: one where native matches (clean import of only rows after the frontier, no duplicates) and one where native differs (`ledgerConflict`).
7. Agreement for an imported or other-producer row consumes nothing. A duplicate agreement changes nothing.
8. Consumption never calls `scheduleSave`. A refusal with nothing owned leaves the ledger unchanged and the session not dirty.
9. Regression: rerun the real owner fixtures for the fresh service (twice) and for partial continuation after scenario 1. They must pass unchanged.

## 5. Risks

- **Semantics change from 4d3c.** A producer's later misconduct no longer revokes completed prefixes. This is safe only if MC1 holds. If MC1 fails, stop: don't land 4d7, and report it to the owner.
- **No rollback concern.** The change is transient and has no production producer.

## 6. Implementation order

1. Answer MC1 and MC2 (read-only).
2. Step 4d7: consumption plus updated and new tests, then OracleA and OracleB review, then a local unsigned commit. Atomic: the code change and the updated 4d3c assertions land together.
3. The copy step (after MC3). It can land with 4d7 or on its own, and needs no review beyond the policy's docs/status rule.
4. Hydration trace, then closure (a), or the block-replacement step (b) with its own review.
5. Mark the source closure complete. All live gates stay `todo`.

---

## Answers

**1) Next source step.** Step 4d7 as specified in §3.1. Acceptance: tests 1–9 pass, MC1 is confirmed, and both Oracle lanes have no open P0/P1. Missing context: MC1–MC3, plus the hydration trace.

**2) Remaining blockers.**
- **Source blockers:** 4d7; hydration closure (a) or (b); the copy change. Nothing else should go into source before the final package.
- **Final live acceptance gates (stay pending, never marked true):**
  - marker propagation through both shims and both providers' tools;
  - complete discovery for every family/provider pair in `supportedPairs`: every Claude variant, native, compatible and headless, both Codex families, and every ACP backend;
  - `--session-id` through the shim (the separate `freshSessionID` gate);
  - startup hooks;
  - `--resume` with a dangling `tool_use`;
  - output from the actual app profile: stdio permission control, the write-capable RepoPrompt MCP server, initialize and set-permission controls;
  - Cmd-Q latency;
  - the crash cuts that need O3.

  The whole plan is not complete.

**3) A capture of the actual profile before final verification.** It can't close a prerequisite:
- `activatesRegistration` needs every pair, so one Claude capture flips nothing.
- **Unknown to check in that package:** whether the controller sends initialize or permission `control_*` stdout lines through `classify`. If it does, they hit `default:` → `.unsupportedPayload`, so the actual profile disqualifies safely, which loses proofs but loses no data.
- Widening the allowlist for those lines is a reviewed source change that belongs inside the one isolated live qualification package, together with its evidence. So defer it.
- Don't build another partial capture ladder or harness.

**4) Owner-only decisions.**
- **None blocks 4d7.** It is reversible, local and inside the existing contract. Record it as `assumed: agreed-exchange proofs survive later same-launch refusal; reader re-verification is the authority`.
- **One material owner decision before the final package:** keep the coupled every-pair activation (recommended, since it is the current contract and shouldn't be reopened), or narrow the supported launch set. Narrowing would be a product-visible change.
- **Running the final live package is an owner manual action:** real profile, isolated instance, credentials.

## Recommendations

- **Do now:** MC1, then Step 4d7 (consumption on successful agreement only, revocation limited to open keys, no classifier, reader or schema change), then OracleA and OracleB review, then a local commit.
- **Do now:** the copy change "Nothing was imported or sent.", only after MC3 shows each path halted before dispatch. No new action or fallback.
- **Do next:** the read-only hydration trace. Close it with an invariant test if the path is unreachable, or block replacement while an open exchange is owned if it is reachable. Never relax the canonical comparison.
- **Cut:** reason-scoped revocation, an `agreedKeys` state, repairing digests, healing from summaries, and more partial captures.
- **Defer to one isolated live qualification package:** the allowlist for the actual-profile stdout, every-pair discovery and markers, `freshSessionID`, hooks, dangling resume, and the crash cuts. All gates stay OFF and the plan status stays "final live verification pending".
