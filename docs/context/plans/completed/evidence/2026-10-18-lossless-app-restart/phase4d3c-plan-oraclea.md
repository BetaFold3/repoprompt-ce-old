# Step 4d3c planning — OracleA

Scope: read when the task touches scoped Claude live-proof invalidation planning.
Authority: Reference
Last-verified: 2026-10-24

Main verified the returned preset identity. Response below is verbatim apart from the terminal newline.

# Oracle Plan



## 1. Summary

Make a targeted correction to inactive Step 4d3b: track which ledger rows each producer launch **newly inserted**, and restrict ordinary refusal to invalidating those rows. Preserve imported and unrelated proofs. Separately, a validated contradiction concerning an already-known native entry may invalidate that entry’s proofs—not the whole tab. Keep positive interrupted-output insertion, existing identity/digest projection, legacy display, and activation **OFF**. This closes the all-tab collateral defect, not the remaining live-qualification or durability blockers.

## 2. Current-state analysis

The supplied code establishes this path:

1. `ClaudeLiveTranscriptProducerState` classifies raw stdout and attaches internal evidence carrying `producerLaunchToken`.
2. A qualified assistant envelope produces `.completeText` **before** terminal success; success later produces `.resultAgreement`.
3. `ClaudeIntegratedAgentModeRunner` routes results through active-run or background delivery. Its `backgroundSourceID` is independently generated; it is **not** the producer token.
4. `AgentModeViewModel.applyStreamResult` checks active run/attempt or background provider eligibility, then processes evidence on the main actor.
5. `applyClaudeLiveTranscriptEvidence` inserts the canonical row and ledger proof together. Existing serialized saving persists that snapshot.
6. Every refusal currently calls `invalidateClaudeEnvelopeProofs()`, which removes every Claude proof, including preserved raw proof members.
7. `ClaudeSessionHistoryReader.ledgerConflict` requires all known entries to retain matching proofs. Consequently, unrelated history can become unrecoverable after an unsupported live payload.

Reusable components are the projection helpers, refusal latch, serialized save, existing ledger invalidator, and background-transcript test harness. The missing capability is **runtime provenance of newly inserted proofs**.

**Decision:** use transient insertion bookkeeping. A smaller no-map change cannot both revoke earlier contributions of the refusing producer and preserve other contributions when a refusal carries only a launch token. Never invalidating proofs would retain unsupported evidence; waiting for terminal success would discard the intended interrupted-output capability.

## 3. Design

### A. Tab-owned insertion bookkeeping

Add to `AgentTabSession`:

- **Property:** `claudeLiveTranscriptInsertedLedgerKeysByProducer`
- **Shape:** mutable `[UUID: Set<String>]`, initially empty.
- **Meaning:** producer launch → normalized ledger keys newly inserted by this owner.
- **Isolation:** main actor, alongside transcript and ledger mutation.
- **Persistence:** none; do not add Codable fields, journals, or authority records.

On successful new insertion, update the row, ledger, and ownership set in the same synchronous main-actor operation, before scheduling the save. No suspension may intervene.

Ownership rules:

- Only a **new row plus new ledger entry** grants ownership.
- Matching duplicates, imported entries, hydration, and result agreement never grant ownership.
- Preserve the map across run completion, cancellation, router replacement, and conversation-ID publication.
- Clear it when the canonical transcript/history is explicitly cleared or replaced. Do not clear the existing refused-producer latch merely because a run or transcript resets.
- After refusal, remove that producer’s map entry once its keys have been invalidated; the existing refusal latch prevents reacquisition.

The supplied excerpts omit reset implementations. During implementation, locate assignments clearing/replacing `providerHistoryRecovery` and coordinate this runtime-map reset there; do not introduce a new lifecycle service.

### B. Key-scoped invalidation

Change the ledger interface:

- **Before:** `invalidateClaudeEnvelopeProofs() -> Bool`
- **After:** `invalidateClaudeEnvelopeProofs(forKeys: Set<String>) -> Bool`

Require the argument; provide no “all Claude rows” default.

For each ledger item, clear the typed and preserved raw `envelopeDigest` only when:

- its provider is Claude; and
- its normalized `key` belongs to the supplied set.

Preserve keys, associations, rows, other extras, baselines, and import receipts. Empty or absent keys are a no-op. Continue returning whether persistent state changed.

Modify the private owner refusal interface to accept an optional, default-empty set of **directly contradicted entry keys**. Its invalidation scope is:

> keys owned by the refusing producer ∪ explicitly established contradiction keys

Always latch the producer. Mark dirty and schedule saving only when the ledger actually changes.

### C. Exact evidence rules

| Event | Owner behavior | Proofs cleared or preserved |
|---|---|---|
| Valid new complete text | Keep all existing admission checks; flush/end older run text; insert canonical row, ledger entry, and ownership together. Consume the carried content once. | Preserve all existing proofs. |
| Exact matching duplicate | Keep the existing equality and canonical-payload checks. Consume as a no-op; do not acquire or transfer ownership. | Preserve proofs. Existing ownership, if any, remains. |
| Existing key with a different **valid envelope digest** | After the admission checks below, treat as a direct native-envelope contradiction. Preserve the old row; refuse producer; show incoming content through the legacy path. | Clear producer-owned proofs and proofs for the contradicted native entry only. |
| Existing key with other disagreement | Examples: different local association, missing canonical row, changed local text, or unequal extras without a digest contradiction. Refuse and use legacy display. | Clear producer-owned proofs only. Do not infer that historical native-envelope proof is false. |
| Background complete text | Continue rejecting positive identity and displaying through the background legacy path. Never acquire ownership or establish a historical contradiction from this rejected positive. | Clear only that producer’s owned proofs. |
| Valid result agreement | Require producer ownership as described below. No transcript or ledger mutation. | Preserve proofs. |
| Result-agreement failure | Refuse; metadata-only carrier remains non-textual and non-terminal. | Clear only producer-owned proofs. |
| Producer `.disqualified` | Latch and refuse, regardless of whether its reason sounds semantic or structural. The carrier does not identify a contradicted historical entry. | Clear only producer-owned proofs. |
| Refusal before any insertion | Latch only, unless independently validated direct contradiction keys were established. | Imported/unrelated proofs remain untouched. |
| Delayed old-producer refusal | Use the old token’s recorded set, never the current conversation or router identity. | Preserve newer producers’ and unrelated imported proofs. |

#### Direct contradiction admission

Only classify an existing-key mismatch as an authoritative contradiction after the current positive admission guards succeed:

- active delivery, not background;
- producer not previously refused;
- `complete.matchesProjection`;
- current conversation compatibility;
- existing proofless-conversation guard;
- canonical projection available with the expected ID.

Then require a stored, valid SHA-256 envelope digest different from the incoming projection’s digest.

Invalidate **all ledger keys for that exact `(Claude provider, nativeSessionID, nativeEntryID)`**, because the stored digest proves the complete envelope shared by all of that entry’s rows. Do not invalidate adjacent entries or another conversation.

A malformed projection, conversation-publication mismatch, ID collision without an existing key, unsupported shape, or missing ownership is **not** such a contradiction. Those paths revoke only producer-owned contributions.

This narrow exception is justified: retaining a historical proof after receiving qualified contradictory evidence for the same native envelope would preserve a claim the owner now knows is inconsistent.

#### Result agreement ownership

Strengthen `.resultAgreement(localItemID, text)` to require:

- producer is not refused;
- its insertion set contains a Claude ledger key associated with `localItemID`;
- that ledger item still has a valid envelope proof;
- the corresponding suffix row is a non-streaming assistant with exactly `text`.

Do not let agreement adopt an imported or another producer’s row. An exact duplicate delivered by a non-owner may be suppressed successfully, but its subsequent agreement fails closed: latch that producer without damaging the existing proof.

Keep the current suffix lookup boundary; expanding agreement to compacted history is outside this step.

### D. Routing, lifecycle, and persistence boundaries

**No new router/run/producer binding is required for this bounded fix.**

The existing delivery guard remains before evidence handling. Internal evidence supplies the launch token, and the owner’s map limits that token’s revocation capability. Do not equate the token with `backgroundSourceID`, or infer ownership from the currently active run.

Consequences remain explicit:

- Evidence rejected by the active run/attempt guard still has no effect. This step does not repair dropped evidence.
- Duplicate refusals are idempotent.
- Delayed accepted background refusal reaches the same token-owned set.
- Runtime ownership disappears on restart; persisted ledger contents do not gain reconstructed ownership.
- Save failure or interruption retains existing save/retry behavior. There is no new durability barrier.
- Scans remain linear in ledger size; bookkeeping adds one stored key per live-owned insertion. No retention framework is needed.

### E. Focused validation

Extend `ClaudeNativeBackgroundTranscriptTests.swift`; reuse `makeLiveOwnerSession`, `carried`, `carrier`, and the existing controller/runner harness.

Required cases:

1. **Ownership and duplicates:** new insertion records ownership; duplicate delivery does not acquire ownership for another token.
2. **Mixed ledger:** seed imported Claude rows from the same and another conversation, Codex rows, and two producers’ live insertions. Refusing one producer clears only its keys.
3. **Before insertion:** refusal preserves all imported proofs and does not dirty an otherwise unchanged session.
4. **Direct contradiction:** qualified same-key/different-digest input invalidates only that native entry plus the refusing producer’s contributions; old rows and unrelated proofs survive.
5. **Non-authoritative rejection:** conversation mismatch, malformed projection, local collision, and background positive preserve historical proofs.
6. **Agreement:** owned agreement passes; imported/non-owner agreement refuses without clearing that row’s proof.
7. **Delayed refusal:** after a newer producer inserts, an older producer’s background refusal leaves the newer proof intact.
8. **Lifecycle and persistence:** explicit transcript clear removes insertion bookkeeping; row/proof encoding remains unchanged; scoped invalidation removes targeted raw proof extras but preserves untargeted extras.
9. **Existing end-to-end test:** retain undecodable-line and EOF-tail coverage; add an unrelated imported proof and assert it survives.

Retain existing interrupted-output and “invalidated proofs never heal” assertions. Use existing reader/history tests to verify that an untouched imported ledger remains acceptable. Do not add a controller framework, live capture, schema fixture, benchmark, or app action.

## 4. File-by-file impact

Paths below are relative to the repository root.

| File | Changes and dependencies |
|---|---|
| `Sources/RepoPromptAgentCore/AgentMode/Runtime/Session/AgentTabSession.swift` | Add transient producer→inserted-key map and document lifecycle. Coordinate existing transcript/history reset ownership here where applicable. |
| `Sources/RepoPromptAgentCore/AgentMode/Models/AgentSessionProviderHistoryRecovery.swift` | Replace global invalidator with mandatory key-scoped invalidation; update comments. No serialization changes. |
| `Sources/RepoPrompt/Features/AgentMode/ViewModels/AgentModeViewModel.swift` | Record insertion ownership; strengthen agreement; distinguish digest contradiction from other refusal; scope invalidation and consume ownership on refusal. Update existing reset path if located here. Depends on the preceding two changes. |
| `Tests/RepoPromptTests/AgentMode/ClaudeCompatible/ClaudeNativeBackgroundTranscriptTests.swift` | Replace all-tab-invalidating expectations and add the focused cases above using existing helpers. |
| Existing active step plan and its evidence directory | Record this bounded step, validation, A/B findings, unresolved activation blockers, and assumptions. Exact filenames were not supplied; use the existing documents associated with `bf793f9d`, not a parallel planning system. |

No behavioral edits are needed in `ClaudeLiveTranscriptQualification.swift`, `ClaudeSessionHistoryReader.swift`, `ClaudeIntegratedAgentModeRunner.swift`, or `AgentModeViewModel+RecoveryActions.swift`.

Before changing the invalidator signature, find all repository references; the supplied production caller is `refuseClaudeLiveTranscript`. Update any additional direct test callers atomically. This is a source-validation task, not an unresolved design choice.

## 5. Implementation order

1. **Record scope and assumptions.** Activation stays OFF; no provider calls, captures, or app actions. This plan performs no source work.
2. **Land the source changes atomically:** session bookkeeping, required-key invalidator, owner behavior, and affected reset/call sites. Keep default-off qualification unchanged.
3. **Update and run focused tests**, then existing affected history/recovery tests and required repository checks. Report harness evidence as synthetic, not live.
4. **Use scoped source workers under the main agent’s coordination.** Main obtains independent Oracle A/B reviews of the same snapshot and validation, attaching the supplied review policy verbatim. Follow its bounded re-review rules; no extra review rounds for deferred polish.
5. **Commit only after required checks/reviews permit it**, staging this step alone. Update the existing status line with actual rounds and findings; do not mark final acceptance complete.

## Recommendations

- **Proceed with transient insertion ownership plus exact-entry contradiction invalidation.** This is the smallest capability-preserving fix.
- **Close only the all-tab collateral defect:** unsupported output can no longer invalidate unrelated imported or other-producer proofs.
- Keep explicit blockers: the scheduled-save crash window; later unsupported output still revoking that producer’s earlier live proofs; existing proofless-conversation refusal; and unestablished installed-profile qualification.
- Do not claim pre-live completeness from this step alone. Broader tools, thinking, multiblock, and resume qualification still require renewed approval. Keep **activation OFF / final acceptance pending**, and defer retention, routing refactors, and optional tooling.

## Targeted scope continuation

The same lane retained its preset; main verified the inherited identity. This continuation supersedes conflicting initial suggestions.

# Oracle Plan

## 1. Summary

**Accept the narrower contract.** Based on the supplied behavior, I cannot identify a realistic P0/P1 counterexample that bypasses the existing native-history, digest, canonical-payload, and outgoing-resume preflight checks. My earlier contradiction exception and ownership requirement for `resultAgreement` were unnecessary expansions; withdraw both. This is a bounded source correction, not approval to activate recovery.

## 2. Current-state analysis

Positive live evidence inserts a row and proof before terminal success, preserving interrupted output. Refusal currently clears all Claude proofs in the receiving tab, damaging unrelated recovery eligibility.

The relevant distinction is **creation ownership**, not whether independent live evidence disagrees with persisted history. Preserving an imported proof does not make contradictory output authoritative: that output remains unidentified, and subsequent recovery must still validate native history against all known keys, digests, and canonical payload.

This assessment relies on the supplied descriptions, not a fresh source inspection. Implementation must confirm that unchanged agreement handling cannot bypass recovery/preflight validation.

## 3. Design

Maintain a transient, tab-owned `producerLaunchToken → Set<newlyInsertedLedgerKey>` on the existing owner isolation context.

| Event | Required behavior |
|---|---|
| New qualified insertion | Insert row, proof, and ownership atomically, without suspension; retain existing scheduled-save behavior. |
| Matching duplicate, including imported row | Existing no-op/suppression behavior; no proof change and no ownership acquisition or transfer. |
| Matching `resultAgreement` | Preserve existing row/proof/text checks; no ownership requirement, acquisition, or proof change. |
| Conflicting existing key | Refuse producer; clear only its owned proofs. Preserve imported/other-producer proofs; conflicting content remains visible through the unidentified legacy path. |
| Agreement mismatch, unsupported shape, conversation mismatch, or any other refusal | Latch producer and clear only its owned proofs. No contradiction exception. |
| Background positive | Preserve existing rejection/legacy-display behavior; grant no ownership; any refusal uses the same rule. |
| Refusal before insertion | Latch only; no persistent mutation. |
| Delayed refusal | Subject to existing delivery guards, affect only the old token’s owned keys—not the current producer’s keys. |
| Canonical-history reset/replacement | Clear ownership atomically with actual history replacement; retain refused-producer latch. Run completion/cancellation does not clear ownership. |

After invalidation, discard that producer’s ownership entry; repeated refusal is idempotent. Remove targeted typed/raw proof fields only, retaining rows, keys, associations, and unrelated metadata.

No persisted schema, authority, journal, normalization, identity, or tool-ID change. No new router binding: retain existing guards and internal carrier; never equate independent router and producer UUIDs.

## 4. File-by-file impact

Using the previously identified paths:

- `Sources/RepoPromptAgentCore/AgentMode/Runtime/Session/AgentTabSession.swift`: transient ownership state and lifecycle.
- `Sources/RepoPromptAgentCore/AgentMode/Models/AgentSessionProviderHistoryRecovery.swift`: mandatory key-scoped proof invalidation.
- `Sources/RepoPrompt/Features/AgentMode/ViewModels/AgentModeViewModel.swift`: atomic ownership recording and uniform refusal scope; leave agreement criteria unchanged.
- Actual canonical-history reset/replacement call sites: coordinate ownership clearing; locate these before editing.
- `Tests/RepoPromptTests/AgentMode/ClaudeCompatible/ClaudeNativeBackgroundTranscriptTests.swift`: extend existing harness only.

## 5. Implementation order

1. Confirm refusal/reset call sites and unchanged recovery gates.
2. Implement state, invalidator, and owner call-site changes atomically.
3. Test imported duplicate/agreement, imported conflict, same-producer conflict, mixed-producer refusal, pre-insertion/background/delayed refusal, reset, and interrupted-output preservation.
4. Run affected checks and required A/B reviews under the supplied policy; no additional harness or live activity.

## Recommendations

Proceed with the uniform ownership rule. It can close **all-tab collateral invalidation**, not pre-live acceptance. Keep scheduled-save crash exposure, later unsupported-output revocation of that producer’s contributions, and profile qualification explicit. **Activation OFF; final acceptance pending.** Defer extra agreement/contradiction policy, retention, and broader provider qualification.
