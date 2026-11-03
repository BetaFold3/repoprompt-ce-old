# Step 4d3a initial review: OracleB (verbatim)

Scope: read when the task touches the Step 4d3a initial OracleB review of the canonical payload and order check, or its F1-F5 findings.
Authority: Reference
Last-verified: 2026-10-23

Raw OracleB response to main's initial Step 4d3a review (snapshot 2226), saved verbatim below the rule from `prompt-exports/oracle-review-2026-10-23-223114-step4d3a-canonical-p-a0e9.md`. Main verified the preset identity. Main's selected disposition and the repairs are in [phase4d3a-worker.md](phase4d3a-worker.md#initial-review-repairs).

---

# Oracle Review



# Review: Step 4d3a, canonical payload and order preflight (snapshot 2026-10-23/2226)

## Summary

The change keeps the whole validated Claude projection in memory as `validationRows`, before ledger and frontier suppression. It adds `canonicalPayloadRefusal`, which runs after the existing association checks. For every ledger-mapped Claude output row, and every new row whose deterministic ID is already canonical, it compares kind, text and exact tool fields across persisted turns plus the mutable suffix. The suffix owns overlapping rows, and an ambiguous placement refuses. User text is never compared: ledger-mapped user items and the current attempt's claimed constituents are used only to check relative order.

Claude now deduplicates against every canonical ID, while Codex still uses only the suffix. Claude-associated local items are also protected from extension or rewrite by live and background deltas and by `final_content`.

Most of the work matches the bounded goal:
- Refusals happen before any mutation.
- The suffix-ownership and ambiguity rules match the documented merge in `transcriptByReplacingWorkingTurns`.
- Codex is unchanged.
- `Dictionary(uniqueKeysWithValues:)` is safe, because `claimAssociation` already proved the claimed IDs are unique.

I found one material problem: the importer creates a transcript order that its own new order check then rejects.

---

## P1

### F1: After a steered attempt is imported, the next reconcile of that attempt always fails the order check

**Scenario.** Attempt R has two dispatches, `first` (claim c1) and a steer (claim c2). The app crashes before any live output is saved, so `items = [first, steer]`. Claude's history is `c1, a1, c2, a2`.

1. **First reconcile.** The claims match exactly. `a1` and `a2` are new and not yet canonical, so they aren't compared. The only anchors are `first` (index 0) and `steer` (index 2), which are in order, so the import succeeds. The planner appends `[label, a1, a2]` at the end of the suffix: `AgentModeViewModel+RecoveryActions.swift`, `for item in plan.appendedItems { session.appendItem(item) }`. The canonical order is now `first, steer, label, a1, a2`.
2. **Any later reconcile of R.** This includes a replay after a lost cursor CAS, which the design says is a no-op, and the case where Claude wrote more after the import. `claimAssociation` still matches c1 and c2, so both anchors are added again. The ledger maps `a1` at validation index 1. In `canonicalPayloadRefusal`, sorted by `(index, rank)`, the sequence is `first(p0) → a1(p3) → steer(p1)`. Then `payload.position > previousPosition` fails and the result is `.canonicalPayloadMismatch`.

**Impact.**
- The user sees "Messages already matched to Claude's history no longer match it or its order" when nothing has changed.
- New output for that attempt can never be imported.
- The lost-CAS replay now refuses instead of returning "no new history".
- It fails closed and loses no data, but it breaks the reconcile workflow for a steered attempt that is fixture-qualified.

**Evidence.**
- `AgentProviderHistoryImport.swift`, `canonicalPayloadRefusal`: the claimed-constituent loop adds anchors at native indices, and the ordering loop then compares those anchors against ledger rows.
- The new test `testClaimedUserConstituentsAnchorTheRelativeOrderOfNativeOutput` treats `[first, replyItem, steer]` as valid and `[first, steer, replyItem]` as a mismatch. The importer never produces the first order; it always produces the second. The test fixture encodes a canonical state the real pipeline can't reach.
- The positive control in `testUnassociatedLiveOutputInALaterPersistedTurnRefusesWithoutChangingAnything` imports `["Done.", "Also done."]` after both claimed users. Adding a second `reconcileRecoveryHistory` call at the end of that test should reproduce the false mismatch.

**Smallest fix.** Pick one; this needs an owner decision because it changes what the anchor guarantees.
- **(a) Recommended.** Use claimed anchors only to order anchors among themselves; this repeats what `isOrderedSubsequence` already checks. Keep strict relative order among ledger-mapped and already-present output rows, but don't order output rows against current-attempt anchors. Every Claude ledger row was placed by the importer at the end of the suffix, so checking it against native order relative to user rows can't be satisfied once steers interleave. Update `testClaimedUserConstituents…` to match, and add the second-reconcile regression test above.
- **(b)** Refuse the *first* import whenever a new row natively comes before an already-canonical claimed anchor, so the importer never writes an order its own check rejects. This blocks steered imports entirely, which regresses the Step 4d2 positive control.

If the owner rules steered re-reconcile out of qualified scope, this can drop to P2. It should not ship unrecorded, because the step's own test treats the unreachable order as the passing case.

---

## P3

### F2: When `final_content` matches an associated row's text, attention provenance is skipped
`AgentModeViewModel.swift`, the `final_content` branch, protected path. If an active run's selected target is the associated row and the text is equal, nothing happens, including `recordAttentionFinalContentRewrite`. A run whose answer equals the imported text then has no final-content provenance for its notification. This is rare, because a run normally adds its own user row, which stops the backward scan before it reaches imported rows. The owner accepted equal text as a no-op. If notification text matters here, call `recordAttentionFinalContentRewrite` in the equal-text branch too.

### F3: Turn-copy payload comparison only runs against hand-built activities
The comparisons of persisted turn copies in `testPreflightComparesEveryMappedRowsCanonicalPayloadAndOrder` use a local `activity()` helper that gives each call and result its own `toolExecution`. Nothing tests that real `AgentTranscriptIO` builds and `toItem()` reproduce the item's tool fields exactly. For example, if the builder merged a call and its result into one execution, a turn-only `toolCall` copy would carry `toolResultJSON` and give a false `.canonicalPayloadMismatch`. Impact is limited: full turns are rebuilt from the suffix, so turn-only reads happen only for a frozen prefix or a stale transcript, and tool rows aren't live-qualified. When convenient, add one round trip through the real transcript builder for a tool call and result.

### F4: Projection order switches from ancestor order to file order when a fork appears later
`ClaudeSessionHistoryReader.decode` uses `chainOrder(entries) ?? Array(entries.indices)`. If an earlier capture was a direct chain imported in ancestor order (where that differs from file order), and a later capture adds a parallel tool fork, every row's `validationRows` index becomes its file position. Ledger rows imported earlier can then fail the order check. This is contrived today, since forks aren't qualified and real logs append in ancestor order. Note it as a known limit.

### F5: A whitespace-only delta for an associated row is dropped
In `applyAssistantDelta` and `applyBackgroundAssistantDelta`, when the target is associated, the code falls through to the new-row path. That path's `hasDisplayableBody` guard drops a delta like `"\n\n"`. This is unrealistic, because imported rows are never the streaming target (they're appended with `isStreaming == false` and have deterministic, non-live IDs), so the protection is defensive. No change needed unless such rows ever stream.

---

## Recommendations

1. Resolve F1 before marking Step 4d3a done. Get the owner's choice between (a) and (b); I recommend (a). Add a real view-model regression test: a steered attempt is imported, then reconciled again, and the result should be a no-op or a further import, not `.canonicalPayloadMismatch`. Correct `testClaimedUserConstituentsAnchorTheRelativeOrderOfNativeOutput` so it uses an order the importer actually produces.
2. Defer F2–F5. Record F4 as a bounded limit next to the accepted compaction limit.
3. Validation is accurately described as fixture and pure-function only. The full-canonical planner ID wiring was compiled but not exercised through a real view-model fixture. A one-line extension of `testUnassociatedLiveOutputInALaterPersistedTurn…` (a second reconcile) would cover that wiring and F1 together.