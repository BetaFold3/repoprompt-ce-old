# 9-live round-3 T1: OracleD plan for the fix
Scope: read when the task touches Claude Reconcile or Continue when live output cannot be matched to Claude history.
Authority: Reference
Last-verified: 2026-10-29
Covers: OracleD plan for the fix



## Summary

Pick **B, bounded** (call it B′): when the claim association is `.associated` and every baseline/fence check passes but canonical live output can't be associated by ID, `AgentProviderHistoryAssociationPreflight.check` compares the *shape* of the unassociated live output with the *shape* of Claude's unassociated projectable rows after the frontier. If the live rows are a prefix of Claude's record, reconcile returns `.nothingImported(text)` and Continue proceeds; the text says precisely whether Claude's record holds steps RepoPrompt couldn't show. If the live rows are *not* a prefix of Claude's record (RepoPrompt shows something Claude's log lacks, order differs, text differs), today's `.canonicalOutputAssociationUnavailable` refusal stays and still blocks. This reuses N's comparison as the honesty engine, but doesn't let a single extra native row (the common post-crash shape) make a conversation uncontinuable forever. Sending risk is unchanged by either option, because the only double-send guard is the claim association, which both options keep intact.

## Current-state analysis

Call chain for Claude Reconcile/Continue (`AgentModeViewModel+RecoveryActions.swift:1180-1320`):

1. `baselineRefusal` → `.associationUnavailable` on missing/mismatched baseline (`:1197-1207`).
2. `recoveryHistoryObservation` reads native history from the attempt's own baseline cursor, fenced by the window's prefix proofs and the record cursor.
3. `AgentProviderHistoryAssociationPreflight.check` (`AgentProviderHistoryImport.swift:328-404`): baseline → `outputItemIDs(after:)` → `claimAssociation` → every baseline user item associated → no unclaimed item-less row → canonical output enumerable → **canonical output ⊆ (ledger `localItemID`s ∪ observation row IDs)** (`:393-397`). The last step fails for any live tool row other than `Read`, because `ClaudeSDKNDJSONTranslator.swift:297-303` replaces `toolu_…` with a random UUID and `ClaudeLiveTranscriptQualification` only gives deterministic IDs to single-text answers and `Read` exchanges.
4. Caller maps any refusal to `.associationUnavailable(refusal, text)` (`:1265-1277`); `AgentRecoveryActionRunner.stopBeforeDispatch` (`:352-353`) turns that into `.notDispatched` for Continue. `.nothingImported` falls through to the record checks and then dispatches.
5. Codex precedent already exists: `codexOverlapRefusal` → `.nothingImported(recoveryCodexOverlapText)` (`:1281-1295`), zero rows, no ledger/cursor movement.

What is reusable: `claimAssociation` (double-send guard, already correct — the diagnosis rules out the warm-up theory), `AgentTranscriptToolNormalizer.normalizedToolName` (used by `comparePayload` at `:638-639`), the `.nothingImported` fallthrough in `stopBeforeDispatch`, the Codex `nothingImported` mapping shape, and the `AgentRecoveryReconciliationTests` harness (`admitClaimedDispatch`, `appendHistory`, `reconcileAction`).

What blocks: the subset check at `:395` is binary. It conflates "the live row *is* this native row, just under a different ID" (safe: nothing to import) with "Claude's record contains rows RepoPrompt never showed" (import would be lossy) with "RepoPrompt shows rows Claude's record lacks" (anomaly).

## Decision: N vs B

| Criterion | N (exact-equality only) | B (any output mismatch proceeds) | **B′ (proceed iff live ⊑ native)** |
|---|---|---|---|
| Duplicate/unrequested send | none (claims exact) | none (claims exact) | none (claims exact) |
| Hidden output | never | possible, disclosed | possible, **disclosed with count/kinds** |
| Anomaly (live shows what Claude lacks) | blocks | proceeds, hard to word honestly | **blocks** |
| Next live round refusing on a K-shape kill | high: any native row the app hadn't persisted at the kill (final text, next `tool_use`, a `tool_result` written after the stream was cut) re-blocks forever | low | low: those shapes are all "native extends live" |
| Code | compare + 1 case + 1 text | 1 case + hedged text (no compare) or same compare as N | compare + 2 cases + 2 texts |
| Contract change vs `:4294` | none | reverses it | see Risks: likely none, else expectation becomes `nothingImported`+disclosure with unchanged-state assertions kept |

N is the safest for transcript completeness but fails the product goal in the most common crash shape after the K fixtures (a fast turn where Claude's log is one row ahead of the saved session), and would need another live round to discover that. Plain B without a comparison can't produce an honest "whether" text. B′ costs the same comparison as N and gives honest, specific texts; its only expansion over N is the append-only direction, which matches how Claude's JSONL grows (the CLI outlived the app by ~20 s in K1, so native ⊇ live is the physically expected relation).

Both N and B′ narrow review A P1-02 ("associationUnavailable blocks every continuation") and need owner sign-off; B′ narrows it slightly more. Blocking remains for: baseline missing/mismatched, any fence failure, claim mismatch or unknown native user entry (`.outboundClaimUnmatched`), unassociated baseline user items, unclaimed item-less rows, non-enumerable canonical output, reader-unsupported records, and any non-prefix shape.

## Design

### Output units (new, in `AgentProviderHistoryImport.swift` next to `AgentProviderHistoryAssociationPreflight`)

```swift
enum AgentProviderHistoryOutputUnit: Equatable {
    case text(String)                         // trimmed whitespace/newlines
    case tool(name: String, hasResult: Bool)  // name = AgentTranscriptToolNormalizer.normalizedToolName
}
```

**Native units** (`units(nativeRows:)`), from observation rows after the frontier with `item != nil`, in file order, **excluding** rows whose item ID is in the associated set (claimed user constituents ∪ ledger `localItemID`s ∪ IDs present in canonical output — the ID-matched `Read` rows):
- assistant text row → `.text`
- `toolCall` row → `.tool(name, hasResult: false)`
- `toolResult` row → must pair by `toolUseID` with a `toolCall` row *in this observation*; sets that unit's `hasResult = true`. No pair in the observation → comparison fails closed (`.canonicalOutputAssociationUnavailable`). This is the second-kill case (resume-written orphan `tool_result` + `<synthetic>` text).
- attachments, operational records, thinking → no unit (they project no rows today).

**Canonical units** (`units(canonical:)`), from canonical output after the boundary minus the associated set, in canonical order:
- assistant / assistantInline item → `.text`
- item with `toolExecution` (or toolCall/toolResult pair sharing an invocation ID) → one `.tool(name, hasResult: execution has a result and is not `summaryOnly`-interrupted)`; thinking items skipped.

**Covers relation**: `n covers c` iff same case, equal text / equal normalized name, and `n.hasResult || !c.hasResult`.

**Rule** (replaces the binary `:395` check when it fails and `claimAssociation` returned `.associated`):

1. `C = units(canonical)`, `N = units(native)`. Invariant: `C` is non-empty here (otherwise `:395` passed).
2. If `N.count < C.count` or any `!N[i].covers(C[i])` for `i < C.count` → return `.canonicalOutputAssociationUnavailable` (unchanged behaviour).
3. Else `extra = N[C.count...]` plus each `i` where `N[i].hasResult && !C[i].hasResult` recorded as `.tool(name, hasResult: true)`.
4. `extra.isEmpty` → return `.liveOutputCoversHistory`; else → return `.historyExtendsLiveOutput(extra)`.

O(|N|+|C|), one pass each. The prefix (not subsequence/multiset) rule is deliberate: it is the only shape the append-only log can produce from a kill, and any other shape is an anomaly that must keep blocking.

### Refusal enum (`AgentProviderHistoryAssociationRefusal`)

Add `.liveOutputCoversHistory` and `.historyExtendsLiveOutput(extra: [AgentProviderHistoryOutputUnit])`. Keep synthesized `Equatable` (the caller uses `refusal == .baselineUnavailable`). These two are "no-import outcomes", not import refusals; they live on the enum only to avoid changing `check`'s return type.

### Caller mapping (`AgentModeViewModel+RecoveryActions.swift:1265-1277`)

After `check` returns a refusal:
- `.liveOutputCoversHistory` / `.historyExtendsLiveOutput` → `return .nothingImported(Self.recoveryAssociationText(refusal))`. Zero rows, `providerHistoryRecovery`, `pendingHistoryImportCommit` and the record cursor untouched (same as the Codex path at `:1292`). Completion is always `.unconfirmed` for Claude, so no `.imported(rowCount: 0)` branch is needed.
- every other case → `.associationUnavailable` as today.

Continue: `stopBeforeDispatch` needs no change — `.nothingImported` already breaks to the record checks (no terminal, interruption, `deliveryUnknown`, same generation → nil → dispatch). Reconcile-only: `completeRecoveryAction(.notDispatched, reason: text)` as today.

**Disclosure on Continue**: `run` currently drops the reconcile text on `.handedOff`. Change: when `reconcileResult` is `.nothingImported(text)` from `.historyExtendsLiveOutput`, carry `text` as `reason` on the `.dispatched` completion (existing 300-char truncation applies), and make `recoveryActionJoinText(.resolved(outcome))` return `outcome.reason` for `.dispatched` too when non-nil. Validate during implementation that no UI treats a non-nil reason on `.dispatched` as an error state; if it does, show the disclosure only for the reconcile-only path and file the Continue disclosure as a follow-up rather than widening scope.

### User-facing texts (`recoveryAssociationText`, `:1649-1650` region)

- `.liveOutputCoversHistory`: "Claude's history for the interrupted turn holds only what this conversation already shows. Nothing new was imported."
- `.historyExtendsLiveOutput(extra)`: "Claude's history for the interrupted turn continues past what this conversation shows (\(summary)). Claude still has those steps, so you can continue, but they won't appear here. Nothing was imported." — `summary` from `extra`: "N more step(s): a reply, Bash, a Bash result" (text → "a reply", tool → display name, result-only gain → "a \(name) result"), capped at 4 kinds then "…".
- Split the shared text (T2): `.nativeUserAssociationUnavailable` → "A message in this conversation for the interrupted run isn't matched to Claude's history, so it can't be matched safely. Nothing was imported." `.canonicalOutputAssociationUnavailable` → "This conversation shows output for the interrupted turn that Claude's history doesn't hold in the same order, so it can't be matched safely. Nothing was imported." (Confirm `.nativeUserAssociationUnavailable`'s exact meaning against `check:372-384` before finalising wording.)

### Concurrency / state

No new state. `check` stays a pure function on the observation snapshot and the main-actor-revalidated session (`:1245-1253`). Nothing is written in the new outcomes.

## File-by-file impact

- `AgentProviderHistoryImport.swift` (home of `AgentProviderHistoryAssociationPreflight`): add `AgentProviderHistoryOutputUnit`, `units(nativeRows:associated:)`, `units(canonical:associated:)`, the covers/prefix comparison; extend the `:393-397` branch; add two enum cases. Depends on nothing else.
- `AgentModeViewModel+RecoveryActions.swift`: map the two new cases to `.nothingImported` at `:1265-1277`; add their texts and split the shared text at `:1649-1650`; `recoveryActionJoinText` surfaces `.dispatched` reasons. Depends on the enum cases (must land together — `switch` exhaustiveness).
- `AgentRecoveryActionRunner.swift`: carry the disclosure text as `reason` on `.dispatched` when the reconcile result was `.nothingImported` from the extends case. Optional; can be dropped if the UI validation fails.
- `Tests/RepoPromptTests/AgentMode/Recovery/AgentRecoveryReconciliationTests.swift`: tests below.
- `docs/context/plans/evidence/2026-10-18-lossless-app-restart/diag-9live-r3-t1-worker.md`: link from a reachable doc (the orphan noted by `check-agent-context`) and record the chosen rule.

## Tests (all in `AgentRecoveryReconciliationTests` with the existing harness)

1. `testClaimedBashTurnWhoseLiveRowCoversHistoryReconcilesAsNothingNewAndContinuesOnce` — exact K1/K3/K4 shape (unsupported warm-up in its own attempt, claimed kill dispatch, native: claimed prompt + `total_tokens_reminder` + `[tool_use Bash]` no result; canonical: `bash` toolExecution, random UUID, `summaryOnly`, `failed`). Expect `.nothingImported` with the "holds only" text; items/ledger/cursor unchanged; Continue dispatches exactly once.
2. `…HistoryExtendsLiveOutputDisclosesAndContinues` — same plus native `tool_result` for the Bash call and a final assistant text. Expect `.nothingImported` with the extends text naming "2 more steps: a Bash result, a reply"; unchanged state; Continue dispatches once.
3. `…LiveOutputNotInHistoryStillRefuses` — canonical has `[tool(edit), tool(bash)]`, native holds only `[tool_use Bash]`. Expect `.associationUnavailable(.canonicalOutputAssociationUnavailable, …)`, Continue blocked.
4. `…OrderMismatchStillRefuses` — native `[text, tool_use]`, canonical `[tool, text]`. Refuses.
5. `…OrphanToolResultAfterContinuationBaselineRefuses` — second-kill shape: resume-written `tool_result` (call before the frontier) + `<synthetic>` text before the continuation's claimed prompt. Refuses.
6. `…TextPrecedingToolMatchesAfterTrim` — native text block with trailing newline vs live text without; covers → nothing imported. (Pins the normalization.)
7. Preflight: unclaimed, unsupported warm-up in another attempt with its prompt before the frontier → `claimAssociation` is `.associated` (pins the ruled-out guess).
8. Texts: the two legacy association refusals and the two new outcomes map to four distinct strings.
9. Runner: a reconcile-only action records `.notDispatched` with the new text; a Continue after the extends outcome records `.dispatched` with the disclosure reason.
10. Re-run `testUnassociatedLiveOutputInALaterPersistedTurnRefusesWithoutChangingAnything` (`:4294`) — see Risks.

## Risks and migration

- **Sending**: unchanged. The continuation is dispatched by the normal path with its own baseline capture, which the K1/K3 "later send" entries proved on this exact 34-line shape. No path sends without `.associated` claims.
- **Transcript honesty**: in the extends case the old turn's extra steps are never imported later (they lie before the continuation's frontier). Accepted and disclosed; the durable fix (persist `toolu_…` on live tool items, translator `:298-303`) is a follow-up that only helps new sessions.
- **`:4294` contract**: if that fixture's unshown reply `a1` precedes the live rows in native order, the prefix rule still refuses and the test is untouched. If it follows them, the expectation changes to `.nothingImported` + disclosure; keep every "unchanged state" assertion. Either way this and the P1-02 narrowing need owner sign-off before merging.
- **Unknowns to validate**: (a) the reader classifies `type: user` entries carrying `tool_result` content as `toolResult` rows, not as native user entries (else claim association, not this rule, blocks the second-kill case); (b) live assistant text items carry the same text as the native text block (one item per content block, no joining) — test 6 covers trimming only; (c) a UI consumer doesn't misread a non-nil reason on `.dispatched`.
- **Rollback**: additive enum cases and texts; no persisted schema changes.

## Implementation order

1. Add `AgentProviderHistoryOutputUnit`, the two unit builders and the covers/prefix comparison; unit-test them in isolation (tests 3, 4, 6 shapes at the preflight level).
2. Extend `check`'s `:393-397` branch and add the two enum cases; update the caller `switch` and texts in `AgentModeViewModel+RecoveryActions.swift` in the same commit (exhaustiveness).
3. Tests 1, 2, 5, 7, 8, 10 at the reconcile level; confirm Continue falls through `stopBeforeDispatch` unchanged.
4. Runner disclosure on `.dispatched` + `recoveryActionJoinText` + test 9, after validating unknown (c).
5. Docs link for the diagnosis; note the P1-02 narrowing and the `:4294` outcome for the owner.
6. Live re-check: V5 tool case (K3), V6 (K4), E2 on a fresh kill; verify "holds only" text on a quiet kill and the extends text on a fast-turn kill.

## Recommendations

- **Choose B′**: proceed with Continue only when the live rows are a prefix of Claude's record (N's comparison reused), block on any other shape. It is as safe for sending as N, honest by construction (the text states exactly what Claude holds that RepoPrompt doesn't), and far less likely than N to refuse on the next live round, where a one-row-ahead native log is the expected crash shape.
- Land the four texts (two new outcomes plus the T2 split) with it; don't ship the hedged "may hold output" wording.
- Get owner sign-off on narrowing review A P1-02 and on the `:4294` expectation before merge; keep the orphan-`tool_result` and order-mismatch cases blocking so "ambiguity still blocks" remains literally true.
- Schedule the durable fix (persist native `tool_use` IDs on live tool rows) separately; it removes the need for shape matching on future sessions but doesn't help the ones already recorded.