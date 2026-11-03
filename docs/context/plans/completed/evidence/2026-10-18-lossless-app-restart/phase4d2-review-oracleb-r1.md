# Step4d2 re-review 1 — OracleB

Scope: read when the task touches the Step4d2 re-review 1 of the Claude native history projection and reconciliation repair delta.
Authority: Reference
Last-verified: 2026-10-23

Repair delta `2026-10-23/2130` against staged snapshot `2026-10-23/2057`. Returned preset identity (`OracleB`) verified by main; this lane had no open P0/P1 and checked the delta for regressions. No P0/P1 and no P2; P3-1 to P3-4 are listed as deferred, no action and no further round. Reply below retained verbatim; main dispositions are in phase4-prerequisite-resolution.md.

# Oracle Review



# Step 4d2 re-review 1: regression check of repair delta 2026-10-23/2130

## Summary

The delta makes seven repairs:

1. `outputItemIDs` now carries the "first user item already passed" state across persisted turns. Every later turn's output counts as canonical output to associate. The turn that holds the first user item still filters out output before it.
2. The rule that a forked tool result must name its source now counts only message-bearing children, so an attachment-only sibling no longer creates a fork.
3. A same-attempt dispatch recorded `unsupported` now yields `.legacy` (no claim association) instead of a false `baselineTargetMismatch`.
4. Baseline mode now skips `chainOrder`/`project`. All parse, graph and fence validation still runs first.
5. When only the receipt moved during the read and the owner is still current, the baseline is now recorded `unsupported` (no identity) and the normal send proceeds. A genuinely stale owner is still refused.
6. Window prefix fences are limited to this provider and conversation. The proof-missing, history-changed and receipt-moved cases now get separate diagnostic reasons.
7. Test-only: a large non-power-of-two inode check, a positive and a negative real-composition test, and a fixed V1→V2 doc comment.

I traced each change against the code shown. **None of them introduces a P0/P1 regression, and every refusal path still fails closed.**

### Verification notes (no finding)

- **Cross-turn output scan.** `passedInEarlierTurn` is captured before `found` is updated. So the matching turn still starts with `afterUser = requestMatches`, and only later turns count in full.
  - The compaction flag (`enumerable = false`) still applies to every turn from the match onward.
  - The suffix logic is unchanged and was already seeded from `found`.
  - For Claude, the new strictness is redundant with what already happens: later attempts' native user entries are unclaimed, so they would hit `outboundClaimUnmatched` or `nativeUserAssociationUnavailable` anyway.
- **Fork predicate.**
  - A genuine parallel fork (call entry with a continuation plus an associated result) still requires `sourceToolAssistantUUID`.
  - An attachment child whose subtree contains a message is still message-bearing, so it still counts as both a fork and a continuation.
  - `forkLeaves`, tip counting and `chainOrder` already skipped non-bearing children, so the newly accepted sequential shape projects in ancestor order (`u1, a1, r1, a2`) as the test asserts.
- **Unsupported steering baseline → `.legacy`.**
  - The boundary itself must still be `.captured` (checked in `baselineRefusal`).
  - With `.legacy`, the observation's native user rows (`item == nil`) are no longer consumed by a claim, so `check` still refuses with `nativeUserAssociationUnavailable`. It fails closed as intended.
  - The identity checks (provider, conversation, attempt, generation) still run before the status check, so a foreign dispatch still reports `baselineTargetMismatch`.
- **Baseline skips projection.** `chainOrder`/`project` don't validate anything; validation lives in `parseEntry`, `validateGraph` and `verifyFences`. `ledgerConflict` was already inside the import branch only. Nothing a baseline previously rejected is now accepted.
- **Receipt-only race.**
  - The one await between the post-read `stillCurrent` check and the receipt comparison is `admitRecorded()`. It only suspends when this dispatch already has a pending baseline, and in that case it returns early.
  - The pending-save branch re-checks `stillCurrent`, and saving a pending receipt does not change `lastImportCommit` in memory. So no false "receipt moved" result can come from this admission's own flush.
  - `recordUnsupported` re-reads `session.providerHistoryRecovery` and appends without touching `lastImportCommit`. A concurrent admission's `commitPendingBaselineReceipt` (which needs its payload to carry exactly its own receipt) and the stale-snapshot fence are therefore unaffected. The scheduled save carries the newer receipt.
  - The result maps to `.admittedWithoutIdentity`: no claim, no UUID, no proof. Reconciliation of that attempt then fails closed:
    - if this was the first dispatch, `baselineRefusal` returns `baselineUnavailable`;
    - if it was a steer, the attempt falls to `.legacy` (repair 3) and the ledger-only checks refuse.
- **Window fence filter.** A foreign-conversation baseline no longer fences this file, and `claimAssociation` still reports `baselineTargetMismatch` because `claudeWindow` is passed as `dispatchWindow`. Same-conversation baselines without a proof still contribute a proofless fence, so legacy proofs are not quietly requalified.
- **Reason strings.** `recoveryBaselineRewrittenReason` is the same literal as before, so no persisted reason or test string changes meaning.

## P2

None.

## P3 (listed only, no further round needed)

**P3-1: Codex overlap is now stricter after any later turn.**
- File: `AgentProviderHistoryImport.swift` (`outputItemIDs`, used by `codexOverlapRefusal`).
- Scenario: a Codex turn is interrupted, the user runs another turn that produces output, then chooses Reconcile. The rows of the expected turn are now always withheld (completion is still reported honestly).
- Why it's minor: those later items come from different Codex turns, so they can't duplicate the expected turn's items. Importing would also append them out of order after the later turns, so withholding is the safer result. It is intended and tested.
- Impact: `recoveryCodexOverlapText` ("overlaps output already shown") slightly misdescribes this case.
- Smallest fix: none needed. Optionally reword the text later ("…or later output already shown").

**P3-2: an unsupported same-attempt steer with `conversationID == nil` reports the wrong refusal.**
- File: `AgentProviderHistoryImport.swift`, `claimAssociation` window guard.
- Scenario: such a steer would get `baselineTargetMismatch` instead of `.legacy`, because identity is checked before status.
- Why it's minor: it needs `providerSessionID` to vanish mid-attempt, which is contrived. Both outcomes refuse, so only the diagnostic text differs.
- Smallest fix: none needed.

**P3-3: the receipt-moved path has no view-model test.**
- File: `AgentModeViewModel+RecoveryActions.swift`, the `lastImportCommit == fencedReceipt` guard.
- I inspected this path by hand (see "Receipt-only race" above); the reasoning holds. A future cheap seam would be a test hook just before the guard that swaps in a different `lastImportCommit`, asserting `.unsupported(recoveryBaselineReceiptMovedReason)` → `.admittedWithoutIdentity`, with no claim and the receipt unchanged.
- Deferred coverage, as you noted.

**P3-4: the large-inode exactness test depends on the Foundation version.**
- File: `AgentRecoveryReconciliationTests.swift` (`largeInode` assertions).
- Exactness for `(1 << 60) + 3` relies on the current `JSONDecoder`/`JSONEncoder` handling `Decimal` from the raw number text. Older Foundation went through `Double`.
- The new test pins this on the host, which is enough to catch a regression if the deployment target or toolchain moves.
- No action needed.

## Contest

You had no open P0/P1 from the initial review, so there is nothing to contest.