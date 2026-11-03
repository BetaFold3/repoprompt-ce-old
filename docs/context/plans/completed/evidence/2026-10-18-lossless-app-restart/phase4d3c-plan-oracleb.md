# Step 4d3c planning — OracleB

Scope: read when the task touches scoped Claude live-proof invalidation planning.
Authority: Reference
Last-verified: 2026-10-24

Main verified the returned preset identity. Response below is verbatim apart from the terminal newline.

# Oracle Plan



# Plan: Step 4d3c — limit live-identity refusal to the proofs that producer inserted

## 1. Summary

Today, when the inactive Step 4d3b live owner refuses a producer for any reason, `refuseClaudeLiveTranscript` calls `AgentSessionProviderHistoryRecovery.invalidateClaudeEnvelopeProofs()`. That clears the proof on every Claude row in the tab's ledger: rows from earlier imports, rows from other conversations, and rows from other launches. `ClaudeSessionHistoryReader.ledgerConflict` requires every known entry to carry a matching digest. So once this is enabled, one ordinary tool, thinking or status payload would make all later recovery for that tab refuse.

The fix adds one transient record owned by the tab: `producerLaunchToken → Set<ledger key>`. A key is added only in the same main-actor block that appends a brand-new canonical row and its ledger entry. A refusal now does two things:
- it latches the producer, as before;
- it clears the proofs of only the keys that producer inserted.

Nothing new is persisted. There is no journal, no normalization, no change to tool IDs, and no change to how the classifier, reader, digest, identity or native matching work. A row and proof inserted before the terminal success is still kept until that same launch is refused, so the interrupted-output goal is unchanged. Rows, keys and local item associations are always kept, and unknown output still goes through the legacy display path.

## 2. Current-state analysis

**Producer side** (`ClaudeLiveTranscriptQualification.swift`): `ClaudeLiveTranscriptProducerState` is one per launch (`launchToken`). Its disqualification latch is monotonic. Evidence is built internally from the exact stdout bytes. It is never MCP or external input.

**Owner side** (`AgentModeViewModel.applyClaudeLiveTranscriptEvidence`, main actor, called after the delivery guard in `applyStreamResult`). There are three cases:
- **`completeText`**:
  - Refuse if any guard fails (background, refused token, projection mismatch, conversation mismatch with `providerSessionID`, proofless row in the same conversation, or canonical ID mismatch).
  - If the key exists: return true when the item, row and text match exactly; otherwise refuse.
  - If the deterministic ID collides with a row in the canonical view: refuse.
  - Otherwise: flush and end the segment, append the ledger item and the row, mark dirty, schedule a save.
- **`resultAgreement`**: checks that the token is not refused, that some Claude ledger item with that `localItemID` has a non-nil digest, and that the row has that text. Success changes nothing. A mismatch refuses.
- **`disqualified`**: refuses.

**Refusal** (`refuseClaudeLiveTranscript`): inserts the token into `session.claudeLiveTranscriptRefusedProducers`, then calls the all-ledger `invalidateClaudeEnvelopeProofs()`, marks dirty and saves. **This is the defect.**

**Recovery** (`AgentModeViewModel+RecoveryActions.swift`, `ClaudeSessionHistoryReader`): an import only commits when `providerHistoryRecovery == ledgerAtStart` and no run is active. `ledgerConflict` refuses any known entry whose digest is nil or differs from the observed one. So a cleared proof means a permanent refusal for that entry, and also means no new live qualification in that conversation (`hasProoflessClaudeItem`).

**Routing**: the background router's `backgroundSourceID` is a fresh UUID, not the launch token, and there is no mapping between them. The active-run path checks `runID`/`activeRunAttemptID` before evidence is processed.

**What is reusable:** the refused-producer set (transient, main actor), the producer token already carried on every evidence value, and the row-level invalidation logic in `invalidateClaudeEnvelopeProofs` (clears both the typed value and the raw `extras["envelopeDigest"]`).

**What is blocking:** the ledger has no per-row provenance, so without new state the owner cannot tell which proofs a given launch created.

## 3. Design

### Q1 — Is the transient map the smallest remedy?

Yes. The alternatives without a map either drop a reviewed safety property or do not fix the defect:

| Alternative | Why rejected |
|---|---|
| Latch only, never invalidate | The reader's digest check catches content mismatches but not misattribution or misplacement of a row the refused launch inserted. Retracting that launch's own claims is the reviewed safety policy, so removing it is a policy change, not a fix. |
| Clear by conversation (`nativeSessionID`) | Still clears earlier imports of the same conversation, which is the main collateral case. It also picks scope from payload fields, which the existing comment deliberately avoids. |
| Identify rows "not covered by the last import receipt" | Ledger rows carry no receipt ID. This would need new persisted authority, which is out of scope. |
| Infer ownership from run or turn position | Needs a new run/producer binding and a heuristic. Out of scope. |

The map has to be keyed by token, not a single per-tab set, so that a delayed refusal from an old launch clears only that launch's keys.

### New state

On `AgentTabSession`, next to `claudeLiveTranscriptRefusedProducers`:

```swift
/// Step 4d3c (inactive): ledger keys whose row AND entry a producer's evidence newly inserted
/// (only those). Not persisted; mutated on the main actor with the insert/refusal.
package var claudeLiveTranscriptOwnedKeys: [UUID: Set<String>] = [:]
```

- **Lifecycle:** it starts empty with each `AgentTabSession`, so a hydrated session after restart has no ownership, and a relaunched producer has a new token anyway. Reset it to `[:]` wherever a chat clear sets `providerHistoryRecovery` to nil. This stops a delayed old refusal from clearing a key that a later import re-adds. Do not change when `claudeLiveTranscriptRefusedProducers` is reset.
- **Concurrency:** it is mutated only inside `applyClaudeLiveTranscriptEvidence` and `refuseClaudeLiveTranscript`, both synchronous main-actor code, so there are no awaits between the ledger append and the ownership write.

### Model API change

In `AgentSessionProviderHistoryRecovery`:

- Before: `mutating func invalidateClaudeEnvelopeProofs() -> Bool` (every Claude row).
- After: `mutating func invalidateClaudeEnvelopeProofs(forKeys keys: Set<String>) -> Bool`.
  - It touches only rows where `providerRaw == claude` and `key ∈ keys`.
  - The per-row transform is the same as today: clear the typed digest and the raw `extras["envelopeDigest"]`; keep the key, `localItemID` and other extras.
  - It returns whether anything changed.
  - An empty `keys` returns false.
- Remove the no-argument variant so there is only one code path. Grep for every caller first (see "Other callers" below).

### Q2 — Exact owner rules

The **unknown-shape** and **authoritative-contradiction** paths now differ in scope only through ownership. In both, the refused producer's own keys are the only proofs cleared. A proof the producer did not insert (from an import, a legacy row, or another launch) is never cleared by that producer's refusal. If such a proof is actually wrong, the reader's digest comparison against the native file at recovery time still fails closed.

| Event | Ledger / row effect | Ownership effect | Proofs cleared |
|---|---|---|---|
| **New insert** (all guards pass, key absent, no ID collision) | Append ledger item + canonical row (unchanged) | `owned[token].insert(complete.ledgerKey)` in the same block | none |
| **Matching duplicate** (existing item == `ledgerItem`, row matches) | none; return true | none, so the producer does not gain ownership of an imported key or another launch's key | none |
| **Conflicting existing key** (different digest, local ID or row text, or a nil-digest existing item) — authoritative contradiction | Existing item and row kept; incoming text shown unidentified | token latched; `owned[token]` removed | only `owned[token]`. If the conflicting key is the producer's own (self-contradiction), it is in that set and is cleared. An imported key, another launch's key, or a legacy key is **kept** |
| **ID collision** (canonical row holds the ID, no ledger entry) | Old row kept; text shown unidentified | latch + remove | only `owned[token]` |
| **Guard failures** (projection, conversation/`providerSessionID` mismatch, proofless conversation, refused token) | Text shown unidentified | latch + remove | only `owned[token]` |
| **Background `completeText`** | Shown as background output (legacy) | latch + remove | only `owned[token]`. It stays a refusal because there is no binding between `sourceID` and the token, and none will be invented |
| **`resultAgreement` agrees** | none | none | none. The predicate is unchanged; ownership is not required, because success changes nothing and requiring ownership would only add refusals for matching duplicates |
| **`resultAgreement` mismatch** | none | latch + remove | only `owned[token]` |
| **`disqualified`** (unknown or unsupported shape, malformed line, EOF-tail contradiction) — unknown shape | none | latch + remove | only `owned[token]` |
| **Refusal before any insert** | none; **not** dirty, no save | latch only | none (today this clears everything) |
| **Refusal after inserts** | proofs of the owned keys cleared; dirty + `scheduleSave` only if something changed | remove entry | the owned keys |
| **Delayed old refusal** (token A while launch B is active) | same as above for A | A removed; B untouched | only A's keys. A key B matched as a duplicate of A's key stays owned by A and is cleared (fails closed) |
| **Imported rows** (history-only merge) | unchanged import path | imports never write the map. A key a live insert created and an import later matched stays owned by that launch | imported-only keys: never by a live refusal |

Refusal pseudocode, to pin down the ordering:

```
refuse(producer):
  refusedProducers.insert(producer)
  keys = ownedKeys.removeValue(forKey: producer) ?? []
  guard !keys.isEmpty, var ledger = providerHistoryRecovery,
        ledger.invalidateClaudeEnvelopeProofs(forKeys: keys) else { return }
  providerHistoryRecovery = ledger; isDirty = true; scheduleSave(tabID)
```

After a refusal, the conversations where the producer had owned rows now hold proofless rows. `hasProoflessClaudeItem` then blocks new live qualification in those conversations only. This is the existing "never healed" rule, now no longer applied to the whole tab.

**Other callers.** Grep `invalidateClaudeEnvelopeProofs` and `refuseClaudeLiveTranscript`. The "conversationID publication mismatch" path the owner described is assumed to be the `providerSessionID` guard inside `completeText`, which carries a token and therefore follows the rule above. If grep finds a caller with no token (for example a session-level conversation change), it clears the union of all owned keys across tokens, latches those tokens and clears the map. It never touches imported proofs. Record which case applied in the evidence doc.

### Q3 — Is a new binding needed?

No. The existing protections are enough:
- The active-path guard (`runID`/`activeRunAttemptID`) and the background refusal already limit where a positive can land.
- Evidence and its token are produced internally.
- Ownership only needs the token the evidence carries.

There are no changes to `ClaudeIntegratedAgentModeRunner`, the router, the run service or the producer.

**Focused tests** (existing harness `makeLiveOwnerSession` and the existing end-to-end test; no new harness):

1. Rework `testClaudeLiveRefusalsInvalidateProofsAndRefusedProducersNeverRequalify`. A producer with no inserts is disqualified; then check:
   - `proven`, `malformed` (raw extras) and `codex` are all unchanged;
   - `isDirty` stays false;
   - the token is latched;
   - the later `FRESH` text is still unidentified.

   Keep the background, collision and agreement-mismatch subcases, and assert that the seeded proven proof survives each one.
2. Add an ownership-scope test (conv-1, seeded imported proven item in conv-0):
   - P inserts `a1`, then Q inserts `q1`;
   - a delayed P disqualification clears only `a1`, keeping `q1`, the imported item and the Codex item;
   - Q's agreement on `q1` still agrees;
   - then Q's refusal clears `q1`.
3. Conflict against an imported key: seed a ledger item with the live key but another valid digest. The producer, which owns a previously inserted key `x`, is refused; `x` is cleared and the imported proof is **kept**.
4. Matching duplicate of an imported row: seed the exact `ledgerItem` plus a matching row. The complete text returns accepted and adds no ownership; then disqualify and check the imported proof is kept.
5. The existing changed-text and end-to-end tests keep their assertions unchanged, because the cleared row is the producer's own. That confirms the interrupted-output path still retracts on its own launch's refusal.
6. Model test: `invalidateClaudeEnvelopeProofs(forKeys:)` touches only the listed Claude keys (typed and raw), ignores a Codex row even if its key is listed, and returns false for an empty set. Update any existing test of the old method.
7. If the chat-clear site is easy to drive from the existing harness, assert the map resets; otherwise just do the code change.

### Q4 — What stays explicit, and does this close the defect?

It closes the **all-tab collateral** defect. A refusal can no longer clear proofs of earlier imports, unrelated conversations, or other launches. These remain explicit and open:

- **Scheduled-save crash window** (unchanged, inactive). The insert or the invalidation lives only in memory until the serialized save. A crash after a refusal but before its save leaves the refused launch's proof persisted.
- **Same-launch retraction from later unsupported output.**
  - Any later tool, thinking, multi-block, steering or status payload refuses the launch and clears that launch's earlier live proofs. Those entries then refuse at recovery and the conversation stops qualifying. This fails closed and loses no rows.
  - Narrowing this (for example, retiring ownership after a turn's agreement) is a policy change and needs owner and A/B approval.
  - Supporting broader shapes needs new captures or prompts, which are not authorized here, and must not be extrapolated from fixtures.
- **A key both live-inserted and later import-matched in the same process** stays owned by its launch. Accepted, fail-closed, P3 deferred.
- **Profile qualification**: launch eligibility is not installed-profile qualification. Activation stays OFF and final acceptance is pending.

## 4. File-by-file impact

| File | Change | Depends on |
|---|---|---|
| `Sources/RepoPromptAgentCore/AgentMode/Models/AgentSessionProviderHistoryRecovery.swift` | Replace `invalidateClaudeEnvelopeProofs()` with `invalidateClaudeEnvelopeProofs(forKeys:)`; rewrite the doc comment (scope = given Claude keys; replaces the "conservative every row" rationale) | — |
| `Sources/RepoPromptAgentCore/AgentMode/Runtime/Session/AgentTabSession.swift` | Add `claudeLiveTranscriptOwnedKeys`; update the `providerHistoryRecovery` doc ("live owner (insert and owned-proof invalidation)") | — |
| `Sources/RepoPrompt/Features/AgentMode/ViewModels/AgentModeViewModel.swift` | In `applyClaudeLiveTranscriptEvidence`, record ownership on a new insert only. Scope `refuseClaudeLiveTranscript` to owned keys as in the pseudocode; don't mark dirty when nothing changed. Update doc comments | both above (land together with the model change) |
| Chat-clear site (grep `providerHistoryRecovery = nil`) | Reset `claudeLiveTranscriptOwnedKeys` | session property |
| Any other `invalidateClaudeEnvelopeProofs` caller (grep) | Migrate per the "Other callers" rule | model change |
| `Sources/RepoPromptAgentCore/AI/Providers/ClaudeCode/SDK/ClaudeLiveTranscriptQualification.swift` | Comment only: "the owner then invalidates the proofs that producer's evidence inserted" | — |
| `Tests/RepoPromptTests/AgentMode/ClaudeCompatible/ClaudeNativeBackgroundTranscriptTests.swift` | Tests 1–5 and 7 | VM change |
| Ledger model tests (grep the old method name under `Tests/RepoPromptTests`) | Test 6 | model change |
| `docs/context/plans/evidence/2026-10-18-lossless-app-restart/phase4d3.md` + plan status line | Scope change, residuals from Q4, the "Other callers" grep outcome | — |

Not changed: the runner, router, reader, recovery actions, producer state machine and persistence schema.

## 5. Risks and migration

- There is no schema change. Old and new builds read the same ledger.
- The behavior change is a narrowing: fewer proofs are cleared.
- The only new exposure is that a proof the refused launch did not create can now survive. Its correctness is still enforced at recovery by `ledgerConflict` against the native file, which fails closed.

## 6. Implementation order

1. **Atomic:** the model method replacement, the session property, the view-model ownership and refusal changes, the chat-clear reset, and migration of any other callers. It doesn't compile partially.
2. Tests 1–7. Run the focused `ClaudeNativeBackgroundTranscriptTests` and the ledger model tests, plus the existing `AgentMode/Recovery` tests as a no-regression check (reader and import are untouched).
3. Comment and doc updates, then the status line `Step 4d3c — …`.
4. One A/B review round on the diff with the test results. Rigor: product behavior that is inactive and fails closed. Skip extra tooling, live captures and new harnesses.

## Recommendations

1. **Use the transient per-token ownership map.** It is the smallest fix that keeps capability. Every no-map option either drops the retraction of a refused launch's own rows or still clears same-conversation imports.
2. **One rule for every refusal:** latch the token and clear only the proofs it newly inserted. Never clear imported, legacy or other-launch proofs on a producer's refusal, even for a direct key contradiction. The reader's native-file digest check is the fail-closed backstop.
3. **Leave `resultAgreement` unchanged** (no ownership requirement), and keep background positives as refusals. Add no router, run or producer binding.
4. **Status claim:** the all-tab collateral defect is closed. Keep these explicit: the crash window, same-launch retraction caused by later unsupported output, profile qualification, activation OFF and final acceptance pending.
5. **Defer**, as P3 or for owner approval: retiring ownership after agreement, import-corroborated release of ownership, and any broader shape support.
6. **Keep review proportional:** one A/B round with the focused tests, no extra harness or tooling.

## Targeted scope continuation

The same lane retained its preset; main verified the inherited identity. This continuation supersedes conflicting initial suggestions.

# Oracle Plan

# Step 4d3c review: the narrower ownership contract has no P0/P1 counterexample

**Verdict:** I found no realistic P0 or P1 in either the current inactive scope or the intended future recovery path. You can accept this as the implementation contract for Step 4d3c.

## Why no counterexample gets past the existing checks

I went through each case where the narrower contract keeps a proof that the earlier plan would have cleared:

1. **A live text conflicts with an imported key** (different digest, local item ID or text).
   - The imported item and its row are left as they are, and the live text is shown unidentified.
   - At recovery, `ledgerConflict` compares every known key against the native file. If the native file agrees with the import, the kept proof is correct. If it agrees with the live text, the digests differ and recovery refuses.
   - Either way the live text is never accepted under the imported identity, and no row is rewritten. So keeping the imported proof cannot produce a wrong answer.
2. **A live text exactly duplicates an imported row, or a result agrees with one.**
   - The live side makes no new claim, so there is nothing to retract.
   - Clearing the proof would only turn a proof already checked against the native file into a permanent refusal.
3. **A launch's own rows** are still retracted when that launch is refused. That includes a contradiction with itself, because those keys are in its owned set.
4. **A delayed refusal from an old launch** clears only that launch's keys. Resetting the ownership map when the canonical history is reset stops it from reaching keys that a later import re-adds.
5. **Outgoing resume** still depends on the existing preflight, which requires a valid digest for every known key. Persisted data that is wrong still fails closed at native import.

## Residuals: fail closed, P2/P3, not blocking

- **Cascade between launches (P3).**
  - **Scenario:** launch B matches a key that launch A inserted. When A is refused, that proof is cleared, B's next agreement on it fails, and B is refused too.
  - **Scope:** only rows in that conversation. Nothing is lost, and recovery refuses (fails closed).
- **Imported proof re-owned by a launch (P3).** In the same process, a key that a live launch inserted and a later import confirmed stays owned by that launch. If the launch is later refused, the proof is cleared. This fails closed.
- **Same-launch retraction caused by later unsupported output.** This is existing policy, not something the narrower contract introduces.
  - **Scenario:** ordinary tool or thinking output later in the same launch refuses it. That clears the launch's earlier live proofs, so recovery refuses for that conversation.
  - **Status:** it does not block this step, but it is a real future workflow limit. It must stay explicit in the status line and must not be described as closed.
- **Scheduled-save crash window.** Unchanged and inactive.

## Ownership reset rules (agreed)

- **Reset to `[:]`** only where the canonical history is actually reset or replaced. That means the chat-clear path, and any replacement that sets or rebuilds `providerHistoryRecovery` from scratch.
- **Do not reset** on:
  - run completion or terminal success;
  - an import that merges history without replacing it;
  - hydration, which already starts with an empty map.
- **Keep `claudeLiveTranscriptRefusedProducers` as it is.** Don't add a reset for it here. A refused token must never qualify again.

## Implementation contract

- **Session state:** add `claudeLiveTranscriptOwnedKeys: [UUID: Set<String>]` to the session. It is not persisted, and it is only changed on the main actor.
- **Recording ownership:** add the key only in the same synchronous block that appends the new ledger item and its canonical row. Matching duplicates, agreements and imports never add ownership.
- **Refusal (one rule for every path):**
  1. Latch the token.
  2. Remove that token's owned keys from the map.
  3. Call `invalidateClaudeEnvelopeProofs(forKeys:)`, which only touches Claude rows and clears both the typed digest and the raw `extras["envelopeDigest"]`.
  4. Only if something changed: mark the session dirty and schedule a save.
- **Kept unchanged:** no exception for contradictions, no ownership check in `resultAgreement`, and the background positive is still a refusal. There is no new router, run or producer binding.
- **Removed:** the no-argument all-tab invalidation method. Grep for every caller. Any caller without a token clears the union of all owned keys, latches those tokens and empties the map; it never touches imported proofs.

**Focused tests, using the existing harness:**
1. A refusal before any insert keeps every proof, does not mark the session dirty, and latches the token.
2. A delayed old refusal clears only that launch's keys. The later launch, the imported item and the Codex row survive.
3. A conflict with an imported key keeps the imported proof and clears the producer's own key.
4. A matching duplicate of an imported row gets no ownership, and its proof survives a refusal.
5. The existing changed-text and end-to-end tests keep their assertions unchanged.
6. Model test for `forKeys:`: only listed Claude keys are touched, and an empty set returns false.
7. The chat-clear reset empties the map and keeps the refused latch.

## Recommendations

1. **Accept the narrower contract as it is.** No P0 or P1 counterexample gets past `ledgerConflict` or the resume preflight.
2. **Use one refusal rule:** clear only the producer's own newly inserted keys, and never revoke a proof it did not create.
3. **Reset ownership only on canonical history reset or replacement.** Never reset it on run completion or a merging import, and keep the refused latch.
4. **Defer** the cascade between launches and import-corroborated ownership release (both P3), plus any rule that adds agreement or contradiction checks. Those need owner or A/B approval.
5. **Status claim:** the all-tab collateral defect is closed. Keep these explicit:
   - same-launch retraction caused by later unsupported output;
   - the crash window;
   - profile qualification;
   - activation OFF and final acceptance pending.
6. **One A/B review round** with the focused tests above. No new harness, captures or tooling.
