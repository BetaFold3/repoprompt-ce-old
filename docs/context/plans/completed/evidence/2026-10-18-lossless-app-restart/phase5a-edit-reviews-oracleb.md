# Step 5a initial review — OracleB

Scope: read when the task touches lossless-restart ordinary edit-review preservation or its initial findings.
Authority: Reference
Last-verified: 2026-10-23

Snapshot 2026-10-23/1445, staged20 files/+1957/-25, tree c1d037631854b7d4bd6ef9d2cd5ac64378e4b543. Both independent fresh lanes sent together with the same controlled source/patch, acceptance, verified validation and verbatim policy; no cross-lane findings. Returned explicit preset 7CDD523E-1D7C-47EA-98FE-D5FEA24D2D8C / OracleB matched. Main read the complete result. Raw body below preserves all content with trailing-whitespace normalization only; original export remains local.

# Oracle Review



# Step 5a review: keeping pending `apply_edits` proposals across restarts

## Summary

Before a recovery-tracked Agent Mode session shows an `apply_edits` review card, this change saves the exact proposal to the session's existing recovery record. That covers the proposed text, the displayed diff, the physical and display paths, the owner, and a hash of the original text that was previewed.

- **Ticket ordering.** The approval actor issues the review ticket first, so the saved proposal and the live card share one ID.
- **Accept.** Accept is a guarded handoff: record `applicationStarted`, re-check the exact ticket, then re-check the owner and cancellation synchronously, then do the existing host write, then record the outcome.
- **Typed outcomes.** Reject removes the proposal. Timeout, replacement and every lifecycle cancellation keep it. The provider decides this from the decision's enum cases, not from reason strings.
- **Recovery list.** Kept proposals appear in the recovery catalog with View (a read-only comparison against the current file), Copy and Discard only. Nothing applies them.
- **Storage.** The codec, store mutations and invariants follow the same extras-preserving pattern as delegated child links.

**Verdict: I found no P0 or P1.** The two-commit handoff, the ticket expiry rules and the honest error replies look correct against the acceptance criteria. Several of the P2/P3 items below depend on code that wasn't in the snapshot, so they are marked "verify".

**Checked and correct:**
- The proposal is saved before the card is shown: `beginReview` → `mcpAdmit…` → `awaitReview`. A stale ticket in `awaitReview` returns `.cancelled` and is never shown.
- `applicationStarted` is recorded before the write. Each refusal before the write either reverts to `pending` or leaves the proposal untouched, and never writes the file.
- If the outcome can't be recorded after a successful write, the reply is status `partial` with `recovery_record_failed`, `retryable: false`, and the write is not undone.
- If the withdrawal can't be saved after a reject, that failure is reported to the agent and the proposal stays in history.
- `onCancel` now cancels only its own review ID. The public `cancelPendingReview` and every cleanup path expire the scope's ticket.
- A failed save of the `pending` proposal shows nothing. `isFinished` and `finishLive` always end the live phase, including for a write that throws.
- Unknown members survive in both the proposal and its `base`. Unknown states and duplicate review IDs make the record unreadable. Records without proposals keep their exact bytes (the field is omitted when empty).
- The untracked path (no admission) writes without any ticket check, the same as before.

## P2 findings

### P2-1: An accepted edit is refused if a newer review or a cancellation lands between Accept and the ticket check
- **Scenario:** In a tracked session the user clicks Accept on review A. Before A's `applicationStarted` save and ticket check finish (one recovery-store disk write), either a second `apply_edits` call in the same tab runs `beginReview`, or the run is stopped and the barrier's `cancelPendingApplyEditsReview` runs. A's ticket expires and the write is refused.
- **Before this change:** the accepted write went ahead.
- **Impact:**
  - The user's Accept has no effect, and the agent gets "replaced or closed… Nothing was changed".
  - The history row then reads "Unreviewed edit proposal", which is wrong for an accepted proposal.
  - The refusal is honest and a retry works, so this is a narrow, fail-closed behaviour change limited to tracked sessions.
- **Evidence:**
  - `ApplyEditsApprovalStore.swift:148-153` (`beginReview` expires the previous ticket) and `:235-236`
  - `AgentModeViewModel+EditProposalRecovery.swift:216-219`
  - `AgentRecoveryListRowProps` title at `AgentModeViewModel+RecoveryList.swift:287`
- **Smallest fix:** Keep the semantics, which the spec requires. Optionally make the history text admit the case, e.g. title "Edit proposal not applied" and a detail that covers "accepted, but replaced or stopped before it was written". If not, defer.

### P2-2: View's comparison uses a different root scope than the live write, so worktree-bound sessions get a wrong message
- **Scenario:**
  - The live write resolves `effectivePath` with `lookupContext.rootScope`, which for a binding projection or worktree points at a physical path outside the visible roots.
  - `inspectRecoveryEditProposal` builds `WorkspaceFileEditHost(store:, lookupRootScope: .visibleWorkspace)` and calls `fileExists(proposal.physicalPath)`.
  - If that lookup misses, the user is told "The target file wasn't found in this workspace (it may have been deleted or moved)". For a proposal that created a new file, they are told "The target file still doesn't exist; the proposal would have created it", even though the file exists.
- **Impact:** Only the advisory text is wrong; View and Copy still work. It could lead a user to recreate or re-apply a file by hand.
- **Evidence:**
  - `AgentModeViewModel+EditProposalRecovery.swift:385-394` and `:406-409`
  - Live write scope: `MCPApplyEditsToolProvider.swift` `WorkspaceFileEditHost(... lookupRootScope: lookupContext.rootScope ...)`
- **Smallest fix:** Make the not-found message neutral: "The target file couldn't be located from this window, so it can't be compared." That avoids both "deleted" and "still doesn't exist". Verify how `exactExistingFile` handles absolute worktree paths under `.visibleWorkspace` before deciding whether more is needed.

### P2-3: Kept proposals accumulate, can't be dismissed, and some can't be removed at all
- **Scenario:**
  - Every Stop during a pending review, every timeout and every replacement now leaves an undismissable item.
  - Each one needs Open, then Discard, then a confirmation.
  - For a session whose catalog item has no `composeTabID`, `openAction` is empty. The `addHeldInputOfUnlistedSessions` path can leave it nil via `knownComposeTabID`. Discard only appears when the session is active, so that item has no Open, no Discard and no Dismiss. It stays in Needs Attention permanently.
- **Impact:**
  - Needs Attention and banner noise in normal use.
  - Rarely, a stuck item that can never be cleared.
- **Evidence:**
  - `AgentModeViewModel+RecoveryList.swift:289`: `[.copyProposal] + (isActive ? [.discardProposal] : openAction)`
  - `openAction` defined near `:150`
  - `AgentRecoveryCatalog.swift:669-681`, which adds no acknowledgement
- **Smallest fix:** Verify that every session holding a proposal resolves a `composeTabID`. If one can't, offer Discard through that session's existing lane when there is one, or accept the case and record it under "deferred". A retention or bulk-discard feature is out of scope.

### P2-4: The record grows without bound and every save of that session pays for it
- **Scenario:**
  - Each kept proposal stores the full `proposedText` plus the diff. For a large file in rewrite mode that is MBs.
  - Every later write to that session's record (composer autosave, intents, run attempts) pretty-prints the whole JSON again. Every read decodes it, re-encodes it and compares, through `writableRecord` and the round-trip check.
  - On every catalog or banner refresh, `recoveryListRow` builds the full viewer string (`full.count` is a character count over all of it), and the `Equatable` props and catalog compare full strings.
- **Impact:**
  - Gradual slowdown and UI jank for sessions with a few large kept proposals.
  - No correctness loss.
- **Evidence:**
  - `AgentRecoveryRecordCodec.swift` `encode` (`.prettyPrinted`) and the round-trip guard in `decode`
  - `AgentRecoveryStore.swift` `replace` (~2115-2152)
  - `AgentModeViewModel+EditProposalRecovery.swift:315-329`
- **Smallest fix:** Retention is an agreed scope cut, so defer the storage side. The UI side is cheap to fix now; see P3-5.

### P2-5 (verify): Proposals may be silently dropped by record writers that don't go through `replace`
- **Scenario:** `AgentRecoveryRecord.init` defaults `editProposals: []`. Any existing store path that builds a record directly would erase stored proposals without any error. Candidates are reset or incarnation handling and the R9 receipt-transfer repair.
- **Test gap:** nothing asserts that proposals survive `clearChatPreservingRecovery`. In the `.reset` case of `testResetOrCancellationAtEachNewAwaitWritesNothing`, the stored contents are only checked under `if lane.isValidForHandoff`.
- **Evidence:**
  - `AgentRecoveryModels.swift:~988` (default parameter)
  - `AgentRecoveryStore.swift:2115-2152` (`replace` carries proposals forward correctly)
- **Smallest fix:** Search `Sources/` for `AgentRecoveryRecord(` and confirm every construction passes `editProposals:` or goes through `replace`. Add one assertion that the proposal is still stored after the `.reset` change.

## P3 findings

- **P3-1: Dead code.** `ApplyEditsReviewDecision.recoveryDisposition` and `ApplyEditsReviewRecoveryDisposition` (`ApplyEditsApprovalStore.swift:28-41`) are only used by tests; the provider switches on the decision directly. Either remove them and switch on the decision in the tests too, or have the provider switch on `recoveryDisposition` so the typed mapping lives in one place.
- **P3-2: Spurious "may have been applied".** If the `applicationStarted` save reports failure but the gate threw after the body had already saved, the proposal is left as `applicationStarted` with no revert. This happens at `EditProposalRecovery.swift:203-206`. Fix: call `revertApplicationNotStarted` in that branch too. It is idempotent: it returns `.unchanged` when the proposal is still `pending`.
- **P3-3: Fragile row-ID parsing in Discard.** `discardRecoveryEditProposal` re-parses the row ID with a hardcoded `"proposal-"` prefix and length 73 (`:353-359`), duplicating `editProposalItemID`. Fix: read `sessionID` and `proposal.reviewID` from the catalog item via `recoveryListCatalogItem(rowID)`. That removes the magic numbers and gives the same "no longer available" behaviour.
- **P3-4: Misleading type name.** `MCPDelegatedChildIdentity` is now the generic session-owner identity for edit reviews too (`:59`, `:78`, `:275`). Rename it to something neutral like `AgentSessionOwnershipIdentity`. It's a mechanical change.
- **P3-5: Viewer text built at full size.** `recoveryListEditProposalText` builds the whole string and then counts it. Build it from bounded prefixes of the diff and proposed text (for example by UTF-8 or UTF-16 length) so each refresh costs O(limit) instead of O(file size).
- **P3-6: Stale comparison on reopen.** Reopening View briefly shows the previous comparison because `rowID` still matches (`AgentRecoveryListBanner.swift:227`, `:247-253`). Fix: set `inspection = nil` at the start of the `.task`.
- **P3-7: Status and naming.**
  - The `partial` status already means "some edits didn't match" for `apply_edits`. Here the whole edit was written, so the note carries the real meaning. Acceptable, but worth a comment.
  - The kind name `pendingEditReview` also covers `applicationStarted` items.
  - The current-launch detail text doesn't mention "replaced by a newer edit".
- **P3-8: Brittle source-order test.** `testProviderCommitsBeforePublicationAndBeforeWrite` checks the order of source fragments. It is useful as a guard but breaks on harmless refactors. It is not evidence that the live path works.

## Validation gaps (not findings)
- There is no end-to-end run of the real MCP provider, no live Accept, Reject, Stop or timeout, no real pasteboard, and no successful Open for Step 5a. All results so far are from fixtures and the source-order guard.
- No release-configuration compile has been run. `EditProposalRecoveryAwaitPoint` exists only under `#if DEBUG`. Confirm that `test_editProposalRecoveryAwaitHook` is declared inside the same `#if DEBUG` block; the indentation suggests it is.
- The adjacent-suite results (161/0) were from before the style and pre-review corrections. Rerun the startup, store, coordinator, child-link and metadata suites against the final tree before committing.

## Recommendations
1. **Commit.** Under the review policy nothing blocks it: no P0 or P1 is open. Rerun the adjacent suites on the final tree first.
2. **Cheap fixes to make now:**
   - P3-2: revert in the `applicationStarted` failure branch.
   - P3-1: remove `recoveryDisposition` or use it in the provider.
   - P3-3: parse Discard's IDs from the catalog item.
   - P2-2: neutral not-found wording in View.
   - P3-6: reset the inspection state when View reopens.

   Each is a few lines and reduces code or wrong output.
3. **Verify P2-5** by searching for direct `AgentRecoveryRecord(` constructions. Add the one assertion that a proposal survives a reset. If any writer drops proposals, raise P2-5 to P1 and fix it before committing.
4. **Run a release compile** once.
5. **Defer and record:**
   - P2-1: accept lost to a concurrent replacement or cancel, by design.
   - P2-3: accumulation, after confirming every proposal item can be opened.
   - P2-4: record growth or retention, an agreed scope cut.
   - P3-4, P3-7, P3-8.
6. **Live acceptance** is still needed before Step 5a counts as qualified: one tracked-session Accept, one Reject, one Stop during review, and one quit during review followed by a restart with View, Copy and Discard.
