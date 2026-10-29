# Step 4d3c initial OracleB review

Scope: read when the task touches scoped Claude live-proof invalidation review findings.
Authority: Reference
Last-verified: 2026-10-24

Snapshot: staged 2026-10-24/0831. Preset identity verified by main. Verbatim response follows, with a terminal newline.

# Oracle Review



# Review: Step 4d3c, owned-key proof invalidation (snapshot 2026-10-24/0831)

## Summary

Before this change, refusing a Claude live producer cleared every Claude envelope proof in the tab's ledger. Now it clears only the proofs that the refused producer newly inserted. A transient map on `AgentTabSession`, `claudeLiveTranscriptOwnedKeys: [producerLaunchToken: Set<ledgerKey>]`, records ownership. It is written in the same main-actor step that appends the canonical row and its ledger entry. Each refusal removes the producer's entry from the map and passes those keys to the new `invalidateClaudeEnvelopeProofs(forKeys:)`. Ownership is cleared on clear-chat and on persisted hydration; the refused-producer latch is kept in both. Tests were rewritten from the old "clear every proof" assertions to per-producer assertions, and new fixtures cover key-scoped invalidation, multiple producers, imported matches and conflicts, and reset.

I checked the diff against each acceptance item and they all hold:

- **Ownership is acquired only on a new insert.** `insert(ledgerItem.key)` exists only in the new-row branch. The already-recorded duplicate (`existing == ledgerItem`) returns `true` without acquiring anything. `resultAgreement` never writes ownership.
- **Every refusal path releases the producer's keys.** All five call sites go through `refuseClaudeLiveTranscript`: the guard failure, the existing-key mismatch, the ID collision, a disagreeing result, and `.disqualified`. `removeValue` runs before the guard, so a repeated refusal changes nothing.
- **An empty set causes no change.** `guard !ownedKeys.isEmpty` returns before any ledger write, `isDirty`, or `scheduleSave`.
- **Only the owned Claude rows are touched.** Invalidation filters on Claude provider plus exact key and clears both the typed digest and the raw `envelopeDigest` extra. Other extras, keys, local IDs, receipts, baselines, Codex rows, other producers' rows and imported rows are left alone.
- **The delivery guards are unchanged.** The background path uses `evidence.producerLaunchToken`, never the background `sourceID`.
- **No new persisted state.** Ownership is runtime-only.
- **Reconciliation still validates everything.** `ledgerConflict` and the canonical preflight still check every known entry, and there is no exception for contradictions. A side benefit: a background refusal during a reconcile's await no longer changes the ledger unless that producer owns keys, so reconcile is blocked by the "session changed" check less often for no reason.

I found no P0 or P1 issues.

## P2

### F1: Clearing ownership on hydration lets a surviving producer's proof outlive its refusal
- **Evidence:** `AgentModeViewModel.swift` ~5922–5924 (`claudeLiveTranscriptOwnedKeys = [:]` right after the ledger is replaced in `applyPersistedHydration`).
- **Failure scenario:**
  1. Producer P inserts key K, and the ordinary save persists K with its proof.
  2. The tab is re-hydrated from that save while P's launch is still alive. The only plausible path is the stale-reset recovery replacement; cold load runs before any producer exists, and route activation switches to a different session whose ledger has no keys from P's conversation.
  3. Hydration clears ownership, so P's later `.disqualified` or contradicting result changes nothing, and K keeps a proof that would have been revoked without the reload.
- **Impact:** This fails open only relative to the 4d3c policy. K is still re-checked against the native file by `ledgerConflict` before any import, so the outcome is weaker revocation, not wrong output. It requires an inactive feature plus a reload while a producer is still alive, so it is unlikely.
- **Why the reset is otherwise defensible:** Ledger keys are scoped by provider, native session and native entry. Hydrating another session therefore can't collide with stale ownership, and dropping the reset could only over-invalidate entries that the same producer itself inserted.
- **Smallest fix (pick one):**
  - (a) Confirm that `prepareSessionForStaleResetRecoveryReplacement` and route activation detach the Claude controller, using the same `prepareForConversationResetSync` that clear-chat uses. If they do, keep the reset and note why in the comment.
  - (b) If they don't, remove the hydration reset and keep clear-chat as the only one. Over-invalidating a producer's own entries is the conservative direction the plan already accepts.
- **Verdict:** Plausible. I couldn't confirm from the provided context whether the controller is detached.

### F2: The hydration reset and the "kept across cancel / new run" rule have no fixture
- **Evidence:**
  - The hydration reset at ~5924 was checked by reading the source only, as you noted.
  - `testClaudeLiveOwnershipSurvivesRunCompletionAndResetsOnlyWithTheCanonicalHistory` covers completion and clear-chat only.
  - The `AgentTabSession` doc comment promises that ownership survives cancellation and a new run as well.
  - Surviving a merging import is covered indirectly: in `testLiveQualifiedRowRoundTripsAndInvalidationRefusesWithoutHealing`, the refusal after the import still clears `a1`.
- **Impact:** A later change could reset ownership in a run-lifecycle hook, or stop resetting it on hydration, and no test would fail.
- **Smallest fix:**
  - Extend the existing ownership test: call `beginRunAttempt` again, or cancel the run, then assert ownership is unchanged.
  - Add one hydration case through the existing reconciliation harness that asserts owned keys are empty and the refused latch is kept.

## P3

### F3: The key-filter API carries VM semantics and a duplicated guard
- **Evidence:** `AgentSessionProviderHistoryRecovery.swift` ~510–523 and `AgentModeViewModel.swift` ~20204.
- **What's wrong:**
  - The model's doc comment describes `keys` as "the keys a refused producer newly inserted", which ties a pure ledger operation to view-model ownership policy.
  - The `!keys.isEmpty` guard appears both in the model and in `refuseClaudeLiveTranscript`.
  - The provider check is now technically redundant, because the key already encodes the provider. It is harmless and covered by the Codex-key test case.
- **Suggestion:** Describe the model operation neutrally ("clears the proofs of the listed Claude row keys") and keep the producer explanation at the VM call site. Either empty-set guard can go. Cosmetic only.

## Not reviewed / limits (as stated, not re-litigated)

These known limits are unchanged by this diff and match the plan:
- Later unsupported output still revokes this producer's earlier proofs.
- Conversations that already have a proofless row are refused.
- Ownership is not released when an import corroborates the row.
- A refusal does not cascade to other launches.
- There is a crash window before the scheduled save.

The default-off activation and the lack of a production caller limit the impact of all of these. One adjacent observation, outside this diff and not part of the scope you asked for: the conversation check, `providerSessionID.map { … } ?? true`, accepts any conversation while `providerSessionID` is nil.
