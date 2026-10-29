# 9-live fix 2 (recovery list): OracleA review, round 1

Scope: read when the task touches the recovery list's Continue editor text, refused-continuation row text, the order of surviving-process items, or the composer's send-refusal notice.
Authority: Reference
Last-verified: 2026-10-28
Covers: the OracleA review (round 1) of the recovery-list diff, copied from its export; the fixes are in fix-9live-list-worker.md


# Round-1 review

**Two P1 text-loss paths remain.** The ordinary `importedCompleted` case is repaired, but retaining text in the coordinator dictionary does not preserve accessibility once the card stops offering Continue.

Review is based only on the supplied source and diff. Test results in the worker notes were not independently verified.

## P1 — R1-01: Newer edits survive in memory but become unreachable when the card resolves

**Evidence**
- `AgentModeViewModel+RecoveryList.swift:859–875`: completion handles the submitted `text`, not a different draft created during the await.
- `:923–926`: `removeRecoveryContinuationDraft` intentionally retains a different draft.
- `:224–232`: the draft is exposed as `continuationText` only when the row offers Continue.
- `AgentRecoveryActionModels.swift`, changed `unsentContinuationText(for:)` block: resolving actions suppress recorded unsent text.
- Added `testRecordedContinuationClearsOnlyTheSentDraft`: asserts dictionary retention, not that the retained text remains accessible.

**Failure scenario**
1. Submit continuation X.
2. During the await, an already-open editor writes newer text Y to the shared draft store.
3. The action returns `.completed(.importedCompleted, …)`.
4. X moves to the composer; Y remains in the dictionary.
5. The resolved card no longer offers Continue. Y is inaccessible from every surface.

**The implementer’s noted race is real.** The same accessibility problem applies to a newer draft retained after `.completed(.dispatched, …)`: X was sent, but Y was not, and the resolved card cannot reopen it.

**Smallest fix**

Before completing a choice that removes Continue, transfer any distinct newer draft into an accessible destination too. For `importedCompleted`, preserve both the submitted unsent text and the distinct newer draft; for dispatched results, preserve only the newer draft—**do not restore the already-sent text**. Remove dictionary entries only after the corresponding text has been transferred.

Add regressions that actually resolve the catalog card and assert where Y can be retrieved. Dictionary equality alone is insufficient.

## P1 — R1-02: Composer restoration has no accessible fallback when the originating window loses the session

**Evidence**
- `AgentModeViewModel+RecoveryList.swift:846–854`: only the session ID is captured before the await.
- `:865–873`: restoration requires `recoveryListTabSession(sessionID:)`; there is no fallback when that lookup fails.
- `recoveryListTabSession(sessionID:)` searches only this view model’s sessions and rejects retired lanes.
- `:224–232`: the retained dictionary entry is not exposed without Continue.

**Failure scenario**
1. Submit custom continuation X.
2. While reconciliation awaits, the originating window loses its live session—for example, the session closes or moves.
3. The action finishes with `.completed(.importedCompleted, …)`.
4. The local lookup fails, so nothing reaches a composer.
5. The card resolves, leaving X inaccessible. Reopening the session does not help: the resolved card no longer offers Continue.

This is the original L1 failure under a missing-destination condition; moving the dictionary app-wide does not repair it.

**Smallest fix**

Provide an app-wide, session-keyed pending-restoration fallback that remains visible independently of the resolved card and can be consumed when the correct session opens. Reuse an existing visible held-input mechanism if available; do not silently retarget another session or reset generation.

Add a suspended-completion test that removes/retires the originating local lane, returns `importedCompleted`, and verifies X remains retrievable.

## Round-0 disposition

| Finding | Assessment |
|---|---|
| **L1** | **Partially fixed.** Normal local-session restoration works in the supplied code; the two lifecycle paths above remain. |
| **L2** | **Fixed for ownership.** Draft storage is coordinator-owned, with both surfaces using forwarding accessors. Accessibility after resolution remains separate. |
| **L3** | **Cleanup rule addressed.** Recorded outcomes now clear matching drafts or restore unsent text; newer retained drafts still need accessible ownership. |
| **L4** | **Sheet-order coverage added.** The supplied `recoveryNeedsAttentionRows` preserves catalog order, and the new test asserts survivor-first ordering. The blocker-write audit cannot be independently confirmed because the relevant builder bodies are not supplied. |
| **L5** | **Requested regression added.** It classifies the refusal after `AgentComposerSubmissionLatch.complete`; it does not exercise the upstream producer path. |
| **L7** | **Fixed.** Both draft closures are required. |
| **L9** | **Fixed in the view wiring.** The truncated text receives `hoverTooltip`. |
| **LIST-01** | **Fixed in the view wiring.** Tab changes explicitly clear persistent notices, including identical drafts. No tab-switch regression was added. |
| **LIST-02** | **Requested integration assertions added.** They exercise the continuation wrapper and report plumbing, but the runner override does not resolve the actual record/card. |

## Other checks

- **Release exclusion:** Both `test_recoveryActionResult` and its invocation are inside `#if DEBUG`. No release-hook leak is evident.
- **Disposition table:** Keeping `.joined` and `.priorAction` is appropriate because this invocation need not have recorded its submitted text. Restoring unrecorded unsent outcomes addresses their otherwise-hidden text.
- **`appendAfterBlankLine`:** The supplied code preserves existing text in both the session draft and the mounted editor. No definite double-send is demonstrated. However, the new tests inspect the model/event rather than consuming the SwiftUI event, so exactly-once append behavior remains unverified.
- **Deferred items:** L6, L8, and L10’s hold-lift behavior remain outside this review’s requested remediation scope.

## Recommendations

1. **Fix both P1 paths before approval:** text must remain accessible, not merely retained in a dictionary.
2. Test resolving outcomes with newer edits and with a missing local session; assert actual user-visible recovery.
3. Add an exactly-once composer-restoration check with existing text and a mounted editor.
4. Keep the policy-deferred items deferred; no additional P2/P3 changes are necessary for this round.