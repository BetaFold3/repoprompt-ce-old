# Step 4d3a re-review 1: OracleB (verbatim)

Scope: read when the task touches the Step 4d3a OracleB re-review 1 of the option (a) order repair, the turn-copy tool-name comparison, or its deferred P3 notes.
Authority: Reference
Last-verified: 2026-10-23

Raw OracleB response to main's Step 4d3a re-review 1 (repair delta 2241), saved verbatim below the rule from `prompt-exports/oracle-review-2026-10-23-224359-step4d3a-re-review1-64bf.md`. Main verified the preset identity. The initial review is [phase4d3a-review-oracleb.md](phase4d3a-review-oracleb.md); the repairs and completion are in [phase4d3a-worker.md](phase4d3a-worker.md#initial-review-repairs).

---

# Oracle Review



# Step 4d3a re-review 1: snapshot `2026-10-23/2241`

## Summary

The delta fixes my open finding F1 by splitting the single order check in `canonicalPayloadRefusal` into two independent sequences: `previousOutputPosition` covers compared provider output, and `previousAnchorPosition` covers user anchors. Output is no longer ordered against user anchors. These checks are unchanged:

- payload equality
- availability and `isComplete`
- ambiguity
- validation-index identity
- claim and source window, and claim association
- digests and prefix fences
- full canonical-ID dedup

The delta also adds a narrow tool-name exception: a turn copy may carry `AgentTranscriptToolNormalizer.normalizedToolName(expected.toolName)`. The builder stores that value (`toolExecution` at lines 1765–1840 writes `normalizedToolName.isEmpty ? item.toolName : normalizedToolName`). Suffix copies must still match exactly. The tests now use the order the importer actually produces. The real view-model positive control now covers four cases:

- the first import
- an unchanged second reconcile, which is a no-op
- a replay after a lost cursor CAS, which is a no-op
- later append-only output, which is imported once

I found no new P0 or P1.

## F1: resolved

**Disposition (option a): accepted. I verified it against the scenario in my original finding.** After the first import, the canonical order is `first(p0), steer(p1), label(p2), a1(p3), a2(p4)`. On the next reconcile, the compared entries sorted by `(index, rank)` are:

| Validation index | Entry | Canonical position | Sequence |
|---|---|---|---|
| 0 | `first` | p0 | anchor |
| 1 | `a1` | p3 | output |
| 2 | `steer` | p1 | anchor |
| 3 | `a2` | p4 | output |

- **Anchors:** p0 < p1, so they pass.
- **Output:** p3 < p4, so it passes.
- **Native user rows:** the planner recorded them with `localItemID == nil`, so the ledger loop skips them and they are not double-anchored.

The lost-CAS replay therefore reaches the planner, finds no new rows, and returns `.nothingImported`. The new end of `testUnassociatedLiveOutputInALaterPersistedTurn…` covers exactly this path.

**Regressions the fix could cause.** I checked whether removing the output-versus-anchor ordering opens a misattribution path that was previously closed:

- **Ledger-mapped user anchors with a non-nil `localItemID`:** Claude production never creates these. Claude user rows have `item == nil`, so the planner records nil. Only fixtures exercise this path, so the earlier-turn test (`testPreflightComparesEveryMappedRowsCanonicalPayloadAndOrder`) losing its cross-order negative case loses no production protection.
- **Live output placed on the wrong side of the dispatch:** `outputItemIDs(after:)` and the association subset check still catch this. They are unchanged.
- **Reconciling an older attempt after a newer attempt was imported:** this would be the same append-at-end problem, but among output rows. It cannot happen. `claimAssociation` requires `observation.nativeUserEntries` to equal the older attempt's claims exactly. `nativeUserEntries` includes ledger-known entries, so the newer attempt's native user entry makes the older reconcile refuse with `.outboundClaimUnmatched` before any order check runs. The output-only order therefore still matches the importer's append order. Within one attempt, imports are append-only in provider order.

## Tool-name delta: no regression

- The exception applies only when `payload.isTurnCopy` is true. Suffix copies are recorded with `isTurnCopy: false`, so a suffix item that also appears in a turn is still compared verbatim.
- It accepts only the exact existing transform of the *expected* name. `"Write"` → `"write"` ≠ `"read"` still mismatches, and the test covers this.
- The invocation ID, arguments, result, and error flag are still compared verbatim, so a normalizer that collapses two names cannot by itself make one tool pass as another.
- The other fields of a turn copy are verbatim in the builder (`argsJSON`, `resultJSON`, `toolIsError`, `invocationID`, `text`, `itemKind`), so the name was the only field the builder changed.

## P3 (optional, no action required)

- **`AgentProviderHistoryImport.swift`, tool-name fallback.** If `normalizedToolName(expected.toolName)` returns `nil`, a turn copy with `toolName == nil` (an activity without a `toolExecution`) also satisfies the fallback. In practice the `toolInvocationID`/`toolArgsJSON` checks already reject this, and the builder never produces a nil name for tool kinds. If you want the guard to say exactly what the comment says, use `|| (payload.isTurnCopy && actual.toolName != nil && actual.toolName == normalizedToolName(expected.toolName))`.
- **Claimed-anchor ordering is now mostly redundant.** Anchors ordered only among themselves repeat `claimAssociation`'s `isOrderedSubsequence`, which is why the reordered-constituents test returns `.outboundClaimUnmatched` rather than `.canonicalPayloadMismatch`. The anchor loop still guards existence and ambiguity, and still orders ledger-mapped user anchors, so keeping it is fine. If you touch it again, update the doc comment to say that the anchor order mainly serves ledger-mapped user rows.

## Validation note

The validation you reported fits the change: reconciliation tests 43/43, compile, format and lint passed, and the negative control without the repairs produced 10 failures before the final pass. Re-running the reader (34/34) and lifecycle (195/195) suites isn't needed, because neither the reader nor the lifecycle code changed. Everything here is fixture-level; live acceptance is still pending, as you stated.

**Lane result: F1 closed; no open P0/P1.**