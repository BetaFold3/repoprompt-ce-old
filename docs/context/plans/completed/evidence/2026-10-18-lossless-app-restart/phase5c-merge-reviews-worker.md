# Phase 5c — worktree-merge review preservation (worker implementation evidence)

Scope: read when the task touches the bounded Step 5c worktree-merge review preservation implementation, its retention copier, or its fixture validation.
Authority: Reference
Last-verified: 2026-10-23

Status: implemented; **source frozen** after the initial-A/B repair pass. The repair delta is unstaged on top of main's staged initial-review snapshot (the index was not touched) and is uncommitted. Base: Step 5a checkpoint `76057942471b1e613871948a270c52108096e8b1`. Frozen-file digest is `24fd0f25d49fb5cf`: the first 16 hex characters of the SHA-256 of the concatenated working-tree contents of the 19 files below, in the listed order. Earlier digests covered 16 files: `b561e80de630e8d3` after the acknowledged-withdrawal pass, and `78e4e9255ff3dacf` before it. No live qualification is claimed.

## Contract implemented

- **Sole authority.** `AgentSessionWorktreeMergeOperation` and its `previewArtifacts` remain the only record of a proposal.
  - There is no new store, lease, generation, CAS, journal, GC or migration.
  - The only addition is an optional `reviewPreservation` marker: `live` or `historical`, plus `endedReason` and `endedAt`.
  - The marker counts only on `.awaitingApproval`; `isHistoricalReview` requires both.
  - Records without it keep their old behavior: cold restore still cancels them.
- **Review ordering** (`reviewAndApplyWorktreeMerge`):
  1. Refuse an artifactless preview before anything happens. Nothing is reserved, saved or shown.
  2. Require the exact expected operation, which must be `previewed`, or no operation for a fresh proposal.
  3. End older reviews. A shown `live` review becomes historical; an unshown reservation is cancelled with its marker cleared.
  4. Reserve `awaitingApproval`.
  5. Capture the owner before the first new await: tab, session ID, binding identity, binding transition generation, persistence state (stamp and reset generation), and not shutdown-frozen. A never-saved session gets one covering save first (`initialPersistence`); if that fails, the review is refused.
  6. Retain the same bundle (`retention`).
  7. Revalidate owner and exact operation.
  8. Install the relocated refs and the `live` marker.
  9. Run the covering written save, `commitRecoverySavedPlacement` (`publicationSave`).
  10. Revalidate, then show the review.

  Any failure before step 10 shows nothing. `refuseUnshownWorktreeMergeReview` then acts on the reservation:
  - **Request for a stored `previewed` operation:** the exact prior operation is put back, with the reason as `lastError`, so explicitly confirmed direct apply stays available (B S5C-04). This is fenced on the exact reservation.
  - **No prior operation:** the reservation is withdrawn (`cancelled`, marker nil).
- **Both initial apply routes** (`runInitialWorktreeMergeApply`, used by review accept and by the explicitly confirmed direct apply):
  1. Set `applying` and clear the marker.
  2. Run `commitRecoverySavedPlacement` (`applyingSave`).
  3. Revalidate, then hand off to VCS.

  If the save does not cover or the owner or operation changed, Git gets 0 calls and the operation returns to its known-unstarted state:
  - review route: a historical review, reason "not started";
  - direct route: `previewed` with `lastError`.

  It is never marked `failed`. A late VCS result or failure updates only the exact `applying` operation of the same owner; a replacement is never retargeted.
- **Cancellation.** `worktreeMergeOwnerIsCurrent` and the initial-persistence guard also fail once the requesting `Task` is cancelled. This was added in this pass to cover "cancel at the new awaits".
- **Typed endings.**
  - Withdrawal (status `cancelled`, marker cleared): `.reject` and `.cancelled` (explicit reviewer decisions), Discard, and refusal before showing.
  - **Acknowledged explicit withdrawal** (`withdrawWorktreeMergeReviewDurably`). Reject, Cancel and Discard of a review the user has seen return a `WorktreeMergeWithdrawalOutcome` (A S5C-02, B S5C-01):
    1. Await point `withdrawalSave` is the **last** await before the write. Afterwards the exact operation and then the owner are revalidated (`worktreeMergeOwnerMatches`: session object, durable session ID, binding, transition generation, persistence state, not frozen). Nothing awaits between that check, the in-memory withdrawal, and the start of the covering save.
    2. **`changed`:** the operation is no longer exact. Nothing is written or restored, and a replacement is never touched.
    3. **`kept` (definitely unwritten):** the owner is invalid before the withdrawal exists in memory. The exact shown proposal stays visible history: Reject/Cancel install it as historical with `worktreeMergeRejectNotSavedText`; Discard leaves it unchanged. Disk still holds the published `.live` (or historical) record, which reloads as history. This fixes the invisible `.live` orphan.
    4. **`withdrawn`:** the existing `commitRecoverySavedPlacement` covering written-save receipt, with the same owner and the exact withdrawn operation.
    5. **Otherwise the withdrawal may be on disk** (this save, or any other). If the exact withdrawn value is still in place in the same tab session, the kept value is installed:
       - With the owner still valid, a **covering compensating save** of that kept value under the same owner, still exact, makes it `kept` (durably restored).
       - If the owner is invalid, or the compensating save doesn't cover, the in-memory history is re-marked `uncertain` and the outcome is `uncertain`. Reject's marker reason then becomes `worktreeMergeRejectUncertainText`. The outcome is never "durably kept".
  - **Messages.** Reject/Cancel throw `reason` / `worktreeMergeRejectNotSavedText` / `worktreeMergeRejectUncertainText` / `worktreeMergeRejectChangedText`. Discard returns `nil` / `worktreeMergeDiscardNotSavedText` / `worktreeMergeDiscardUncertainText` / `worktreeMergeDiscardChangedText`. Git is never touched.
  - Refusal of a review that was never shown still uses the synchronous withdrawal and a scheduled save, because no shown durable proposal is being acknowledged.
  - There is no new writer or framework. `worktreeMergeOwnerIsCurrent` is now `!Task.isCancelled && worktreeMergeOwnerMatches`; the withdrawal acknowledgement uses `worktreeMergeOwnerMatches` without the cancellation term.
  - Historical preservation: `.timeout` and the new `.preserved(reason:)`.
  - `.preserved` is issued only by `cancelPendingWorktreeMergeReview`: run end or terminal commit, reset ("Session reset"), run cancel, and replacement by a newer review. The replacement reason is now neutral: "Ended when another worktree merge review was requested" (B S5C-12), because the newer request may itself still be refused.
  - **Shown/resolving identity** (A S5C-01). `submitWorktreeMergeReviewDecision` records the review's operation ID in the session's in-memory `resolvingWorktreeMergeReviewOperationIDs` before it clears the card and resumes. The waiting request removes the ID (via `defer`) once it has processed the decision.
    - A lifecycle end treats the pending card **plus** every resolving ID as shown. So a timeout, accept or reject followed by a same-turn run end, reset or replacement keeps the `.live` proposal as history instead of withdrawing it.
    - The resumed handler then finds the operation no longer exact and leaves it alone: timeout and accept give no change and "not started"; reject gives `changed`.
- **Cold restore.** `AgentSessionWorktreeMergeReconciler` turns a `live` marker into `historical` with reason "RepoPrompt closed before this merge review was answered."
  - It does not inspect or continue the review.
  - An already-historical review is unchanged.
  - It runs on the existing DataService load paths.
- **Unchanged.** In-flight reconciliation of `applying`, `conflicted` and `awaitingCommit`, and continue/abort.
- **Retention** (`GitWorktreeMergeReviewArtifactRetention`, RepoPromptWorkspace):
  - **Destination and identity.**
    - The root comes from the captured DataService stamp: `worktreeMergeReviewRetentionParent` takes the session gate and checks the stamp, the absence of a tombstone, that the file exists, and that the durable v1 incarnation equals the stamp's. It returns `stamp.fileURL` parent.
    - There is no mutable current root and no temp fallback.
    - The copy goes to `<AgentSessions>/.worktree-merge-reviews/<sessionID>/<op>-<UUID>`, a hidden folder ignored by the scanners.
  - **Copy.** The source tree is copied with no-follow `openat`; symlinks and special files are refused. Files are created with `O_EXCL` and mode 0600, in a hidden `.assembling` sibling.
  - **Validation.** The COPY is validated before publish: required regular files, plus a sidecar identity of operation, snapshot, merge base, both heads and both fingerprints.
  - **Publish.** `renameatx_np(RENAME_EXCL)`; failed assemblies are removed.
  - **Bounds.** 20000 entries, 512 MiB, depth 32, and a 16 MiB sidecar.
  - **Reads.** Historical reads only accept retained bundles (`notRetained` otherwise) and use no-follow component walks.
- **Historical UI.** `AgentWorktreeMergeHistoricalReviewCard` offers **View / Copy patch / Discard** only. There is no Merge button, RPC or continuation.
  - **View** loads the saved `diff/all.patch`, capped at 1 MiB; oversized patches show as unavailable and are never truncated.
  - **Past prediction** is the sidecar's recorded `conflictPrediction`, labelled as past metadata.
  - **"Now:" line** is one transient, read-only fingerprint inspection, fenced by the exact operation. It reads "unavailable" on error or race, and never regenerates or mutates anything.
  - **Copy** places the full saved patch on the pasteboard, capped at 64 MiB.
  - **View and Copy decode strictly** (B S5C-07): invalid UTF-8 yields `.unavailable` ("isn't valid UTF-8…"), and nothing lossy is shown or copied.
  - **Card wording** (B S5C-05): `historicalWorktreeMergeReviewEndedText(reason:)` says "approved, but it wasn't started" for the not-started reason and "rejected, but…" for the reject not-saved and uncertain reasons. Only the other (lifecycle) reasons say "ended without a decision (reason)".
  - **Discard** is async (`discardHistoricalWorktreeMergeReview(tabID:operationID:) async -> String?`): `nil` only after an acknowledged withdrawal, otherwise a message. It is refused while shutdown is frozen.
  - **Discard progress and failure are session-owned** (A S5C-03). They live in the in-memory `AgentTabSession.worktreeMergeReviewDiscard` (`AgentWorktreeMergeReviewDiscardState`: the starting review, `isDiscarding`, `message`), not in card `@State`, and reach the card through `AgentRunInteractionUISnapshot.historicalWorktreeMergeReviewDiscard`.
    - While discarding, `historicalWorktreeMergeReviewOperation(for:)` keeps returning the review Discard started from, even though the operation is `cancelled` in memory. The card stays mounted as "Discarding…" with every action disabled.
    - Afterwards, any message stays attached to that operation ID, so a removed and recreated card still shows it. A second Discard while one is in flight is refused.
  - **Attention.** Attention gains a `.historicalReview` kind; the summary DTO gains `isHistoricalReview`. There are no MCP wire, schema or status changes.
    - **Ranking** (B S5C-02): every non-historical candidate (conflicted, awaitingCommit, live awaitingApproval) outranks every historical review, and the newest wins within each class. This applies in both the live selector (`sidebarAttention(in:)`, used by session rows and root capsules) and the closed/restored summary selectors (`sidebarAttention(inSummaries:)` / `primarySummary(in:)`, used by the sidebar builder and the archived HUD merge label).
    - The closed-summary path now filters to the attention statuses before ranking, matching the live path.
  - **Status** (B S5C-03): the implicit (no `operation_id`) `statusWorktreeMerge` active set excludes historical reviews. Explicit lookup returns them unchanged.

## Files (exact)

The digest order is source first, then tests, as listed. `[R]` marks a file changed by the initial-A/B repair pass, which is unstaged on top of main's staged snapshot. `[R, new to set]` marks one of the 3 files not in the staged snapshot at all.

Source:
- `Sources/RepoPromptAgentCore/AgentMode/Runtime/AgentSessionWorktreeMergeOperation.swift` [R]: marker, `isHistoricalReview`, summary flag, reconciler, and `AgentWorktreeMergeReviewDiscardState`.
- `Sources/RepoPromptAgentCore/AgentMode/Runtime/Session/AgentWorktreeMergeReviewRecords.swift`: `.preserved(reason:)`.
- `Sources/RepoPromptAgentCore/AgentMode/Runtime/AgentSessionDataService.swift`: `worktreeMergeReviewRetentionParent(for:)`.
- `Sources/RepoPromptWorkspace/VCS/GitWorktreeMergeReviewArtifactRetention.swift` (new).
- `Sources/RepoPromptAgentCore/AgentMode/Runtime/Session/AgentTabSession.swift` [R, new to set]: two in-memory fields, `resolvingWorktreeMergeReviewOperationIDs` and `worktreeMergeReviewDiscard`.
- `Sources/RepoPrompt/Features/AgentMode/ViewModels/AgentModeViewModel+WorktreeMerge.swift` [R]: flows, historical API, helpers, types.
- `Sources/RepoPrompt/Features/AgentMode/ViewModels/AgentModeViewModel.swift`: three DEBUG seams only.
- `Sources/RepoPrompt/Features/AgentMode/ViewModels/AgentModeViewModel+RunInteractionUI.swift` [R].
- `Sources/RepoPrompt/Features/AgentMode/ViewModels/UI/AgentRunInteractionUIStore.swift` [R].
- `Sources/RepoPrompt/Features/AgentMode/ViewModels/AgentModeSidebarSessionBuilder.swift` [R, new to set]: closed-summary attention uses the shared ranking.
- `Sources/RepoPrompt/Features/AgentMode/ViewModels/UI/AgentNavigationHUDModels.swift` [R, new to set]: the archived merge label uses the shared ranking.
- `Sources/RepoPrompt/Features/AgentMode/Views/AgentModeView.swift` [R].
- `Sources/RepoPrompt/Features/AgentMode/Views/ToolCards/AgentWorktreeMergeReviewCard.swift` [R].
- `Sources/RepoPrompt/Features/AgentMode/Views/Components/AgentSessionRows.swift`.
- `Sources/RepoPrompt/Features/AgentMode/Views/Components/AgentWorkspaceRootsSectionView.swift`.

Tests (existing suites only; no new suite class; the frozen ledger is untouched):
- `Tests/RepoPromptTests/AgentMode/WorktreeMergeReviewStateTests.swift` [R]: 13 new view-model flow tests using the Step 5a coordinator harness and real temp bundles: 6 initial, 2 from the acknowledged-withdrawal pass, and 5 from the repair pass.
- `Tests/RepoPromptTests/AgentMode/AgentSessionWorktreeMergePersistenceTests.swift`: 3 new.
- `Tests/RepoPromptTests/AgentMode/AgentWorktreeMergeAttentionTests.swift` [R]: 2 new (1 from the repair pass).
- `Tests/RepoPromptTests/Services/VCS/GitWorktreeMergePreviewPublisherTests.swift`: 2 new, using a real git worktree fixture.

## Test coverage map

- **Retained copy outlives the original**, keeping snapshot identity: `testRetainedReviewBundleSurvivesOriginalDeletionAndKeepsItsIdentity`.
  - The original is refused as `notRetained`.
  - Exactly one published copy exists and no assembly is left.
  - The patch bytes are identical after the original is deleted.
  - The past prediction reads back; the wrong operation, the size limit and `..` escape are refused.
- **Refusals without publishing**: `testRetentionRefusesMissingEscapingSymlinkAndMismatchedBundlesWithoutPublishing`.
  - Covers a missing bundle, an outside reference, a `..` escape, an operation, target HEAD or snapshot mismatch, a symlinked bundle directory, a symlink entry and a missing MAP.
  - After each refusal there is no published entry and no leftover assembly.
- **Publication barrier, then apply from the copy**: `testPreservedReviewIsDurableBeforeItIsShownAndAppliesFromTheRetainedCopy`.
  - The covering save happens while the card is hidden, and the session file on disk carries the `live` marker and relocated refs before showing.
  - After the original is deleted, accept runs save(applying) then exactly one apply, using the retained refs.
- **Artifactless refusal**: `testArtifactlessReviewIsRefusedBeforeAnythingIsReservedShownOrSaved`. Both the preview route and the stored-operation route refuse; there are 0 saves and 0 applies, and the previewed operation is unchanged.
- **Non-covering publication save**: `testNonCoveringPublicationSaveRefusesAndWithdrawsWithoutShowingOrGit`. `.notWritten`, `.suppressed` and `.resetAcknowledged` each lead to withdrawal, never showing, and 0 VCS calls.
- **Both pre-apply barriers**: `testFailedApplyingSaveNeverRunsGitAndKeepsTheKnownUnstartedState`.
  - Review route: a historical "not started" review with retained refs kept, and 0 VCS calls.
  - Direct route: back to `previewed` with 0 VCS calls; artifactless direct apply then succeeds (1 apply, nil artifacts).
- **Owner, operation and cancellation changes at each new await**: `testOwnerChangeOrCancellationAtEachNewAwaitPublishesAndAppliesNothing`.
  - 3 points (`retention`, `publicationSave`, `applyingSave`) × 5 changes (reset, binding transition in progress, binding rebound, operation replaced, task cancelled).
  - Every case: 0 VCS calls and no live card.
  - Never shown: withdrawn.
  - Accepted but unstarted: historical.
  - A replaced operation is left untouched.
- **Typed endings**: `testExplicitRejectWithdrawsButTimeoutLifecycleAndReplacementPreserveHistory`.
  - Reject leads to `cancelled` with no marker.
  - Timeout, lifecycle and replacement lead to historical, each with its typed reason; the newer review stays live while the older one is history.
  - The durable file matches after the save.
- **Withdrawal without a covering receipt**: `testRejectOrDiscardWithoutCoveringSaveKeepsHistoryAndNeverClaimsWithdrawal`.
  - Reject under `.notWritten`, `.suppressed`, `.resetAcknowledged` and `.deferredBehindInFlightSave`, plus Cancel under `.notWritten`: the withdrawal save is attempted, then the call throws the truthful not-saved message and the review is kept as historical with retained refs.
  - Discard under the same receipt returns the not-saved message and keeps the history.
  - Repair pass: the immediate durable record is historical, not cancelled, with **no extra flush**, because the compensating covering save wrote it. The old manual flush was removed; it returned false only because that save had already left the session clean.
  - A later covering Discard returns `nil` and is durably `cancelled`. 0 VCS calls.
- **Owner or operation change at the last await before the withdrawal write**: `testOwnerOrOperationChangeAtWithdrawalSaveNeverClaimsWithdrawal`.
  - Covers Reject and Discard × reset, binding transition in progress, binding rebound, and operation replaced.
  - Every case gives a truthful failure, no Git, and **no withdrawal save** (revalidated before the write).
  - Binding changes: `kept` (exact not-saved texts), history in memory, and a recoverable record in an immediate cold read.
  - A replacement is left untouched and stays `awaitingApproval`. This is a deliberate contract update: the stale request now never writes the withdrawal at all, where it used to leave the replacement `cancelled`. The texts are the exact `changed` ones.
  - After a reset, anything kept is history.
- **Same-turn race after a submitted decision** (A S5C-01): `testSubmittedDecisionStaysShownForSameTurnLifecycleOrReplacement`.
  - Cases: timeout then lifecycle, timeout then replacement, and accept then lifecycle.
  - The decision is submitted and the lifecycle end (or the newer request's synchronous start) runs in the **same MainActor job**, before the waiting request resumes.
  - Result: still `awaitingApproval` historical with the lifecycle's own reason (proving the lifecycle reached it first), retained refs, resolving IDs cleared, 0 VCS calls, and a matching durable record.
- **Reject with the owner already invalid** (B S5C-01): `testRejectAfterOwnerAlreadyChangedKeepsTheShownProposalAsHistory`.
  - The binding transition begins before the decision.
  - Reject throws the not-saved text, no withdrawal save happens, and the review is visible history (selector and `.historicalReview` attention), not a `.live` orphan.
  - The immediate cold read is recoverable.
  - Also checks the B05 wording and the neutral B12 reason.
- **Written withdrawal, then immediate cold reload** (A S5C-02): `testWrittenWithdrawalIsRestoredUnderValidOwnerOrReportedUncertainOnImmediateColdReload`.
  - Covers Reject and Discard × {non-covering receipt, owner changed}.
  - The save override performs a **real** `flushSaveDetailed` write of the withdrawal, and the test verifies on disk that `.cancelled` is written. It then returns `.notWritten`, or begins a binding transition and returns the real receipt.
  - The session file is then reloaded immediately, with no extra flush.
  - Non-covering: the exact not-saved text, and the durable record is historical, restored by the compensating covering save.
  - Owner changed: the exact uncertain text, no not-saved ("kept") claim, history in memory, and disk holding the written withdrawal (or a later history save).
  - Discard's session-owned message equals the returned text.
- **Discard progress and failure survive card removal** (A S5C-03): `testDiscardProgressAndFailureAreSessionOwnedAcrossCardRemoval`.
  - The withdrawal save is suspended on a gate.
  - While suspended, the operation is `cancelled`, yet the snapshot (and the UI store) still shows the review with `isDiscarding`.
  - A concurrent Discard is refused. The save then fails, and the snapshot shows the history plus the session-owned not-saved message.
  - A covering Discard then clears both. No SwiftUI harness is used.
- **Pre-show refusal on the stored-operation route** (B S5C-04): `testPreShowRefusalOnTheStoredOperationRouteRestoresThePreviewedOperation`.
  - Covers publication-save and retention failures.
  - The same `previewed` operation comes back (original artifacts and `createdAt`, no marker, `lastError` set) with no show and no Git.
  - Explicitly confirmed direct apply then completes (1 apply).
- **Historical View/Copy/Discard**: `testHistoricalViewCopyAndDiscardNeverRunGitAndCannotBeApplied` (Discard is now awaited; returns `nil`; durable `cancelled` is checked).
  - Covers the saved patch after original deletion, the oversized-patch fallback, the past prediction, and the four current-state outcomes (unchanged, changed, error, race).
  - Copy places the exact patch.
  - Repair pass: implicit status excludes history and an explicit lookup returns it (B S5C-03). Invalid UTF-8 bytes in the retained patch make View `.unavailable` and Copy return that message without writing anything (B S5C-07).
  - All three initial routes refuse the historical operation; Discard withdraws it; 0 VCS calls.
- **Cold restore**:
  - `testReconciliationKeepsPreservedReviewAsHistoryWithoutContinuationOrInspection`: live becomes historical and is never inspected; idempotent.
  - `testColdLoadRewritesPreservedReviewAsDiscoverableHistory`: the isolated DataService load rewrites the marker, and stub and metadata summaries carry `isHistoricalReview`.
  - `testPreservationMarkerRoundTripsAndLegacyOperationsDecodeWithoutIt`.
  - The existing `testReconciliationCancelsAwaitingApproval` still covers a nil marker.
- **Attention**:
  - `testHistoricalReviewIsDistinctReadOnlyAttentionAndNeverAConflictBlocker`: deliberately updated for B S5C-02. A newer historical review no longer outranks a live one; history alone is still surfaced as `.historicalReview`.
  - `testActiveConflictAndAwaitingCommitOutrankNewerHistoryInLiveAndSummarySelectors` (repair pass): conflicted and awaitingCommit outrank a newer history in both the live and the closed-summary selectors.

## Validation (coordinated only)

| Ticket | Operation | Result |
|---|---|---|
| `0638c609-f86c-4305-9345-15d0ce97d9c1` | `make dev-swift-build PRODUCT=RepoPrompt` | exit 0. One new isolation warning (default-argument limits), fixed with `nonisolated static let`. |
| `12576d9b-ebd3-44eb-8534-b42df103863e` | `make dev-swift-build PRODUCT=RepoPrompt` | exit 0. No warnings in changed files. |
| `63cfa1c2-2940-4dae-b5f9-7554c020e3ec` | `dev-test FILTER=WorktreeMergeReviewStateTests` | Test compile failed: a local `operation` shadowed the helper. Fixed by renaming. |
| `3e8a8aef-2104-4cfd-8fab-b165bc6cf1f8` | `dev-test FILTER=WorktreeMergeReviewStateTests` | 12 tests, 2 failures. The test helper matched the wrong session filename (`AgentSession-<uuid>.json`); fixed in the helper, not the assertions. |
| `48a87520-8a5e-48c5-80e6-59eb7618e304` | `dev-test FILTER=WorktreeMergeReviewStateTests` | **12/12 pass**. See note 1. |
| `b8a7f6e6-a99b-4f55-9856-1b24bd3b2bd2` | `dev-test FILTER=AgentSessionWorktreeMergePersistenceTests` | **15/15 pass** |
| `2ec46257-f42c-443c-b50e-c07bdef62f81` | `dev-test FILTER=AgentWorktreeMergeAttentionTests` | 13/13 pass. Before the format fix; superseded. |
| `d445439e-9091-4816-b084-39e4b55f6555` | `dev-test FILTER=GitWorktreeMergePreviewPublisherTests` | 3/3 pass. Before the format fix; superseded. |
| `6614ac28-faa3-42ad-9fa4-666934e01843` | `make dev-swift-build PRODUCT=RepoPrompt` | exit 0 (after the cancellation fence) |
| `fe435f5a-bdd9-4311-8dfe-ff7ea0985b42` | `make dev-format-check` | Failed: 5 findings (`hoistTry`, `wrapFunctionBodies`) in 2 test files. Fixed by hand; `dev-format` was not run. |
| `20f14a81-55f8-4d32-b3ea-790718b99bb7` | `make dev-format-check` | **0/2175 files require formatting** |
| `cf23f108-95d2-4601-9369-e830e2289767` | `make dev-lint` | **exit 0** |
| `89eddf49-4243-4338-8377-54f91f561584` | `dev-test FILTER=AgentWorktreeMergeAttentionTests` | **13/13 pass** on frozen source |
| `9e669b21-2fbf-4a19-9553-3297995281ec` | `dev-test FILTER=GitWorktreeMergePreviewPublisherTests` | **3/3 pass** on frozen source |
| `8c76c303-f2d0-4d45-b4d5-75a275738f65` | `dev-test FILTER=WorktreeMergeReviewStateTests` (single filter, final frozen source) | **12/12 pass**, 0 failures |
| `1962c158-614c-4890-b5c6-8fdf238185c7` | `dev-test FILTER=AgentSessionWorktreeMergePersistenceTests` (single filter, final frozen source) | **15/15 pass**, 0 failures |
| **Acknowledged-withdrawal pass** | | |
| `89d98309-ca99-4813-94e2-02af343438ed` | `make dev-swift-build PRODUCT=RepoPrompt` (compile-only) | exit 0. No new warnings; all source edits are final at this ticket. |
| `650f37ba-7cf1-4d3d-9442-847042f106d7` | `dev-test FILTER=WorktreeMergeReviewStateTests` | 14 tests, 1 failure. The existing typed-endings test asserted that a second `flushSave` after Reject returns true, but the acknowledged Reject had already written and left the session clean. The test now skips that redundant flush for Reject and still asserts the durable `cancelled` record from the file. Test-only change; no assertion on behaviour was weakened. |
| `cf624c93-12a3-417d-8aeb-5b7850cb4058` | `dev-test FILTER=WorktreeMergeReviewStateTests` | **14/14 pass** (final tree) |
| `e58eb0d3-e6ba-4297-9311-04c91c74f290` | `dev-test FILTER=AgentSessionWorktreeMergePersistenceTests` | **15/15 pass** (final tree) |
| `ebfcfba5-adf2-437b-b8a6-d6c423253da6` | `dev-test FILTER=AgentWorktreeMergeAttentionTests` | **13/13 pass** (final tree) |
| `844309fe-c90b-46ea-9fba-0772a1b46a1f` | `dev-test FILTER=GitWorktreeMergePreviewPublisherTests` | **3/3 pass** (final tree) |
| `07ed03ee-8c4b-4bb3-a281-d3a389c14f13` | `make dev-format-check` | **0/2175 files require formatting** (final tree) |
| `f1e3df14-131d-4d4f-aec9-c07db93da1c1` | `make dev-lint` | **exit 0** (final tree) |
| **Initial-A/B repair pass** | | |
| `4f4ebe3f-ffc6-4946-9d34-aa6cdbc1c92f` | `make dev-swift-build PRODUCT=RepoPrompt` (compile-only) | exit 0. The one warning in a touched file (`AgentSessionWorktreeMergeOperation.swift`, `fileManager` Sendable capture) predates this work and is outside the Step 5c diff. Superseded by `be8e630a` after the format fixes. |
| `ba8a22fd-558c-4cf9-b5b9-267a022ddda7` | `dev-test FILTER=WorktreeMergeReviewStateTests` | Test compile failed: `reloaded??.status` after an already-flattening `try?`. Fixed in the test. |
| `63fa8562-1bb7-4c66-8ece-1f0279174a46` | `dev-test FILTER=WorktreeMergeReviewStateTests` | 19 tests, 6 failures, both test-only. (a) Five cases: the old manual `flushSave` after a kept Discard returned false because the new compensating covering save had already left the session clean. The flush was removed, and the durable-history assertion now runs immediately, which is stronger. (b) One case: my new "no kept claim" check matched the substring "is kept" inside the uncertain text. It now checks for the exact not-saved texts. No assertion on behaviour was weakened. |
| `99cee46d-5ec9-4f9e-8b32-d5d0444752b3` | `dev-test FILTER=WorktreeMergeReviewStateTests` | 19/19 pass. Before the format fix; superseded. |
| `7b385000-33f7-42ea-bf2b-ba2b0011a24f` / `36d6f075-d688-48f1-a994-131d26ace872` / `2b888255-eec4-45b0-acf1-05a9ccaed3eb` | Persistence / Attention / Publisher, single filters | 15/0, 14/0, 3/0. Before the format fix; superseded. |
| `53a9aa05-d809-4b43-b398-b095a2c90102` | `make dev-format-check` | Failed: 3 findings, `redundantNilInit` (snapshot field) and `redundantStaticSelf` (wording helper). Fixed by hand; `dev-format` was not run. |
| `4bed1328-56c3-436d-b9b9-601576e91d8e` | `make dev-format-check` | **0/2175 files require formatting** (final tree) |
| `82c07311-b782-4df3-8965-4b42d0aef3fe` | `make dev-lint` | **exit 0** (final tree) |
| `be8e630a-cd3f-4801-83c8-1d46ba5b1a2a` | `make dev-swift-build PRODUCT=RepoPrompt` (compile-only) | **exit 0** (final tree) |
| `44971751-3c45-4ae5-b432-1c163cfecf81` | `dev-test FILTER=WorktreeMergeReviewStateTests` | **19/19 pass** (final tree) |
| `45ef20b6-ad9b-4948-9292-9894252ffc44` | `dev-test FILTER=AgentSessionWorktreeMergePersistenceTests` | **15/15 pass** (final tree) |
| `43bdafec-e763-41d5-a1ec-0d3048911705` | `dev-test FILTER=AgentWorktreeMergeAttentionTests` | **14/14 pass** (final tree) |
| `65df34c8-5cbc-486b-86e9-97f988a47291` | `dev-test FILTER=GitWorktreeMergePreviewPublisherTests` | **3/3 pass** (final tree) |

Notes:
1. Ticket `48a87520` was launched by an unquoted multi-suite `FILTER` (`A|B|C|D`). The shell split it at the pipes, so only `WorktreeMergeReviewStateTests` ran; the other words failed as commands (make Error 127). The job itself was healthy, and the other suites were then run singly. That ticket and `b8a7f6e6` predate the final test-file format fixes, so they are superseded.
2. Two earlier sets of frozen-source evidence are **superseded**:
   - digest `78e4e9255ff3dacf` (`8c76c303` 12/0, `1962c158` 15/0, `89eddf49` 13/0, `9e669b21` 3/0; 43/0);
   - digest `b561e80de630e8d3` (`cf624c93` 14/0, `e58eb0d3` 15/0, `ebfcfba5` 13/0, `844309fe` 3/0; 45/0; build `89d98309`; format `07ed03ee`; lint `f1e3df14`).
3. **Final frozen-source evidence** (digest `24fd0f25d49fb5cf`, computed after the last run with no edits since) uses one single-filter command per suite, all on the same final tree:
   - `44971751` WorktreeMergeReviewStateTests: 19/0
   - `45ef20b6` AgentSessionWorktreeMergePersistenceTests: 15/0
   - `43bdafec` AgentWorktreeMergeAttentionTests: 14/0
   - `65df34c8` GitWorktreeMergePreviewPublisherTests: 3/0

   Total: **51 tests, 0 failures**. On the same tree: compile-only build `be8e630a` exit 0, format-check `4bed1328` 0/2175, and lint `82c07311` exit 0.
4. Conductor after the final runs: no active lanes, 0 queued.

## Initial A/B finding dispositions (repair pass)

| Finding | Disposition |
|---|---|
| A S5C-01 (P1) timeout then same-turn lifecycle/replacement | **Fixed.** Session-owned resolving IDs are treated as shown until the decision is processed. Tested deterministically in one MainActor job, including replacement. |
| A S5C-02 (P1) a written withdrawal can leave a durable cancellation | **Fixed within existing primitives.** Revalidation after the last await and before the write; typed outcome; compensating covering `commitRecoverySavedPlacement` while the owner is valid; otherwise explicit `uncertain`; never over a replacement. Real written save, then immediate cold reload, with no extra flush. See the limits below. |
| A S5C-03 (P2) Discard feedback is lost with the card | **Fixed.** Session-owned `worktreeMergeReviewDiscard` keeps the review visible while discarding and keeps the message. Tested with a suspended, then failing, save. |
| B S5C-01 (P2) invisible `.live` orphan when the owner is invalid at entry | **Fixed.** `kept` is installed as visible history; there was definitely no write. Tested with the binding transition before the decision. |
| B S5C-02 (P2) history outranks a conflict in sidebar/capsule attention | **Fixed** in the live and closed-summary selectors (plus the archived HUD label). |
| B S5C-03 (P2) implicit status treats history as active | **Fixed.** History is excluded from the implicit active set; explicit lookup, wire and schema are unchanged. |
| B S5C-04 (P2) a pre-show failure destroys a prior previewed operation | **Fixed.** The exact prior `previewed` is restored with `lastError`; with no prior operation it is still cancelled. Stored-operation route fixture for publication and retention failures. |
| B S5C-05 (P3) "without a decision" wording | **Fixed** for rejected and not-started histories. |
| B S5C-07 (P3) lossy UTF-8 | **Fixed.** Strict decoding; View and Copy are unavailable on invalid UTF-8. |
| B S5C-12 (P3) misleading replacement reason | **Fixed.** Neutral reason. |
| B S5C-06, 08, 09, 10, 11 | **Deferred** as instructed: publication/applying covered-then-owner-change memory/disk divergence, View display size, per-appearance inspection cost, root-tamper policy, and error type. |
| B S5C-13 (P3) test gaps | **Partly closed.** S5C-01, S5C-02 and S5C-04 now have the fixtures listed above. The `.initialPersistence` await point is still unexercised (deferred optional coverage). |
| B "diffExcerptProvider" check | Not investigated (no source change in this pass; optional). |

## Not run

- `make dev-build`, packaging, `dev-run`, any app lifecycle, provider, helper or MCP executable, user data, home or credentials.
- Full `dev-test` or `dev-test-parallel`, and `make guardrails`, `Scripts/check-agent-context` (main owns routing and links).
- No live qualification. Card rendering (SwiftUI) is compile-checked only. Real `VCSService` apply after a retained review is not exercised; the apply seam counts handoffs.

## Limits and deferred items

- **Withdrawal uncertainty limits** (A S5C-02). These are the narrowest distinctions the existing APIs allow; there is no new writer, journal or read-back:
  - **"Definitely unwritten"** is claimed only when the withdrawal never existed in memory: the owner was invalid, or the operation was not exact, at the revalidation after the last await.
  - **Once the withdrawal is in memory, any save may have written it:** this save, a scheduled save, or a save under a new authority. A non-`.written` receipt from `commitRecoverySavedPlacement` therefore does not prove it unwritten, and only a covering compensating save under the same valid owner earns `kept`.
  - **`uncertain` is reported when no such save is possible.** Disk then holds either the written withdrawal or a later save of the in-memory history. On relaunch the review is gone in the first case and kept as history in the second; the message says it "may be gone".
  - **Not distinguished:** `.suppressed` (persistence suppressed for the launch, so nothing is ever written) is not separated from other non-covering receipts, because `commitRecoverySavedPlacement` returns only `Bool`. A suppressed launch therefore restores in memory, and its compensating save is also `.suppressed`, so the outcome is reported `uncertain` rather than `kept`. It is conservative, not false. This follows from reading the code; no fixture covers a launch-wide suppressed persistence.
- **Resolving identity is in memory only.** It needs no persistence: a relaunch already turns a `.live` record into history through the reconciler.
- **Durability scope.** This plan's contract is an app-process crash while the OS keeps running. The commit point is the atomic no-replace rename (`renameatx_np(RENAME_EXCL)`) of a fully assembled and validated copy. A crash before it leaves only a hidden `.assembling` sibling and an operation that was never shown; after it, the complete bundle is published. The session-file save stays the authority that references it, so no fsync is needed for this contract. The missing fsync only excludes **power-loss or OS-crash** durability, not app-process crashes; no fsync framework was added.
- **Orphans are not collected.** Copies stay behind after withdraw, Discard or session deletion; cleanup and retention policy are deferred by design.
- **Stale index summaries.** Closed, never-reopened sessions keep their index summary as `awaiting approval` until loaded and reconciled. Pre-5c behavior had the same staleness.
- **MCP projection.** `activeWorktreeMerges` reports historical operations as `awaiting_approval` (main's choice: no MCP, HUD or remote filters).
- **Cancelled callers.** An accept that arrives after the requesting task was cancelled now preserves the review as historical "not started" instead of applying.
- **Shutdown freeze.** While shutdown is frozen, publication, both initial applies and Discard are refused.
- **Artifactless reviews.** A review with no published artifacts is refused; `manage_worktree preview` with `publish_artifacts` is required. Direct confirmed apply stays artifactless-capable.
