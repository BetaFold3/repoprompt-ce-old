# Step 5a worker evidence: durable pending apply_edits proposals

Scope: read when the task touches lossless-restart Step 5a (ordinary pending `apply_edits` reviews of recovery-tracked Agent Mode sessions), its source contract, validation evidence or remaining limits.
Authority: Reference
Last-verified: 2026-10-23

## Boundary

The baseline is 9e508587, and this is a worker report. The main agent owns the plan, owner decisions, Oracle reviews, staging and commit. I made no plan, staging or commit changes, and I ran no Oracle review, `ask_user`, `context_builder` review/plan, or other agents. Production Phase 3/4 gates stay OFF, and live acceptance O3 is still pending.

What I did not do: live verification, `dev-build`, `dev-run`, packaging, app launch or stop, provider/helper/MCP executable runtime, runtime-data/home/credential inspection, or process signalling.

Out of scope: worktree merge preservation (Step 5c; the merge engine is unchanged), and retention and deferred polish.

Unrelated dirt was left untouched:
- `.gitignore`, `AGENTS.md`, `CodemapSeamTestSupport.swift`;
- the code-mode measurement doc and plan;
- the untracked turn-checkpoint spec and completed codemap plan.

These working-tree edits belong to the main agent, not this worker:
- the lossless-restart spec;
- `pre-live-work.md`;
- `phase5a-edit-reviews.md`;
- the `Scripts/source_layout_guardrails.sh` allowlist lines.

## Source contract as implemented

### Review identity
`ApplyEditsApprovalStore.beginReview(scope:)` issues an `ApplyEditsReviewTicket { scope, reviewID }` before anything is persisted, and cancels a pending review in the same scope (as `requestReview` already did).

`awaitReview(ticket, path:, unifiedDiff:, timeoutSeconds:)` behaves as follows:
- It publishes under exactly `ticket.reviewID`.
- It returns `.cancelled` when the ticket is no longer the scope's latest (`latestReviewIDByScope`).
- Its task-cancellation handler cancels only that review ID.

Every scope cleanup (tab, window, and window scopes found in the latest map) removes the latest entry, so a stale ticket can never publish. The public `cancelPendingReview(scope:reason:)` also removes it (pre-review fix below). That method serves explicit lifecycle/replacement cancellation: `cancelPendingApplyEditsReview` at turn end and other lifecycle points, plus `beginReview`'s replacement. It removes the entry even when no review is pending any more (already accepted). The ID-scoped private variant used by a cancelled waiter never touches the latest entry, so it never expires a newer ticket. `requestReview` is now a `beginReview` + `awaitReview` wrapper and is otherwise unchanged. There is no generation counter, so a re-subscribe cannot spuriously cancel a review.

### Admission
`MCPApplyEditsToolProvider`, review branch only (Agent run, tab scope, auto-edit off):
1. It captures `requireTargetWindow().agentModeViewModel` once.
2. It takes the ticket.
3. It calls `mcpAdmitApplyEditsReviewProposal(tabID:reviewID:input:)` with the exact preview values:
   - `effectivePath`, `displayPath`, the displayed `reviewUnifiedDiff`;
   - `previewResult.updatedText`;
   - `preview.exists ? preview.originalText : nil`.

Admission returns nil, and behavior stays exactly legacy, when the tab has no session or the session lacks durable recovery admission (`requiresDurableRecoveryAdmission`).

Admission throws, showing and writing nothing, when:
- the session is shutdown-frozen; or
- the lane is missing, not valid for handoff, not owned by the session, or belongs to another session.

The admission (`ApplyEditsReviewRecoveryAdmission`) freezes:
- the tab and session ID;
- the session (weak) and the exact lane (weak);
- `lane.binding` (session, incarnation, reset generation);
- `ownerIdentity`, the existing `MCPDelegatedChildIdentity(session)` from Step 5b: tab, owner object, `persistentSessionBindingIdentity`, `bindingTransitionGeneration`, `persistenceState`, lane, parent.

Admission also requires that no binding transition is in progress, and that `persistenceState` carries the lane binding's incarnation and reset generation.

### Proposal record
The parent recovery record gains the additive member `editProposals: [AgentRecoveryEditProposal]`. Each proposal holds:
- `reviewID`, `runAttemptID?`, `transcriptResetGeneration`, `appInstanceID`, `proposedAt`;
- `physicalPath`, `displayPath`, `unifiedDiff`, `proposedText`;
- `base`, `state` (`pending` | `applicationStarted`), `applicationStartedAt?`;
- extras.

The base is `AgentRecoveryEditProposalBase { exists, domain?, digest?, extras }`:
- The domain is `repoprompt.applyEdits.decodedTextUTF8.sha256.v1`, and the digest is the SHA256 hex of the UTF-8 bytes of the SAME preview `originalText`.
- `exists = false` carries neither domain nor digest.
- It observes decoded content only. It is not a raw-byte checksum and cannot prove that an operation executed.
- `matches(decodedText:)` returns nil for an unknown domain.

Codec (`AgentRecoveryRecordCodec`):
- The member is absent when empty; unknown proposal, base and record members are preserved as extras.
- An unknown `state` is `unknownVariant`.
- `applicationStartedAt` is present exactly for `applicationStarted`.
- `domain`/`digest` are present exactly when `exists`.
- A duplicate `reviewID` is malformed (the record is unreadable).
- `replace(...)` preserves `editProposals` by default.

`AgentSessionMetadataIndex.RecordFacts.hasEditProposals` feeds `needsAttention`. There is no hint schema change and session serialization stays v7.

### Store mutations
These are in `AgentRecoveryStore+EditProposals.swift`, inside the lane `transaction` (the foundation gate, with revision-conflict retry and `writableRecord(binding:)` owner validation).

`commitEditProposal(binding:proposal:)`:
- requires `pending` with the binding's reset generation;
- an exact repeat is `.unchanged`;
- another proposal under the same review ID is `editProposalConflict`;
- it creates the record if absent.

`transitionEditProposal(binding:reviewID:transition:)` uses the typed `AgentRecoveryEditProposalTransition`:
- `applicationStarted`: only from `pending`, for the same generation, otherwise `editProposalIneligible`.
- `applicationNotStarted`: reverts to `pending`.
- `applied` / `withdrawn`: remove the exact ID; a missing ID is `.unchanged`.

The lane tracks `liveEditProposalIDs` (empty once the lane is retired) with `noteEditProposalLive` / `endEditProposalLive`. A live proposal is never listed as history.

### Ordering and fences
1. **Pending before publication.** Note live, then commit `pending` (acknowledged), then recheck `Task.isCancelled` and the fence, then return, then `awaitReview` publishes `session.pendingApplyEditsReview`.
   - A commit failure ends live and throws "…could not be saved for crash recovery, so it was not shown".
   - A stale fence after the commit keeps the committed proposal as history and throws.
2. **applicationStarted before the write.** On `.accept` the provider calls `mcpPerformAcceptedApplyEditsReview(recovery, ticketIsCurrent: { await approvalStore.isReviewTicketCurrent(ticket) }, write: { host write })`. That one VM helper is executed by the tests. Its private `mcpBeginApplyEditsReviewApplication` runs these steps:
   1. fence check;
   2. commit `applicationStarted` (acknowledged);
   3. fence and cancellation;
   4. the exact ticket at the approval store (a new await);
   5. synchronously after that actor hop on the main actor, the fence and cancellation again;
   6. the unchanged `host.writeText`.

   Any refusal throws, so nothing is written. After a refusal the record is returned to `pending` (best effort, since the write is known not to have happened) and the live phase always ends, so there is no false live row. Without an admission (legacy) the write runs unchanged with no ticket check.
3. **Outcome.**
   - A completed write leads to `applied` (removal).
   - If the host write throws: `.preserved`. The proposal stays `applicationStarted` (uncertain) and the error is rethrown.
   - If the `applied` commit fails: the tool returns truthful partial success (`status: "partial"`, `errorCode: "recovery_record_failed"`, `retryable: false`, plus `recoveryRecordFailedNote`: "The edit was written to the file … Do not retry this edit; it is already applied …"). It never says "nothing changed".

The fence (`editReviewRecoveryIsCurrent`) is rechecked after every new await. It requires:
- the same session object still in the tab, with the same `activeAgentSessionID`;
- no binding transition in progress;
- `MCPDelegatedChildIdentity(session) == ownerIdentity`;
- the same lane object with the same `binding` and session, valid for handoff and owned;
- `persistenceState` matching the binding;
- the session not shutdown-frozen.

`lane.isOwned(by:)` is object-only, so the identity comparison is what catches a rebind under the same session and lane.

A reset retires the lane through the successor claim, so a reset fails the fence. No replacement is ever silently bound. No lock is held while the user decides; the approval store actor only suspends.

Refusals use `MCPError.invalidParams("apply_edits: <reason>. Nothing was changed. If the proposal was saved, it is listed in Needs Attention; it is never applied automatically.")`.

### Lifecycle versus withdrawal
The decision maps to `ApplyEditsReviewDecision.recoveryDisposition` (`.apply` / `.withdraw` / `.preserve`); there is no reason-string inference.
- `reject` → `.withdrawn`. If that withdrawal fails to save, the provider returns `rejectionNotRecordedNote(reason:)`: the file was not changed, the rejection could not be saved, and the proposal remains listed in Needs Attention. It sets `errorCode: "recovery_record_failed"` and `retryable: false`, and never claims a durable reject.
- `timeout` and every `cancelled` (tab/window cleanup, replacement, transport/task cancellation, stale ticket) → `.preserved`.

There is no old RPC continuation, no permission revival, and no implicit application after a crash.

### Recovery presentation
The catalog kind is `.pendingEditReview` with payload `.editProposal(proposal, isCurrentLaunch:)`. `addEditProposals` runs after `addQuestions` at both catalog sites (startup/closed-session resolution, and this launch's unlisted sessions), so proposals of closed tabs/windows are discovered. Live IDs are filtered out. The row ID is `proposal-<session>-<review>`.

Row (`AgentModeViewModel+RecoveryList.swift`):
- **Title:** "Unreviewed edit proposal", or "Edit may have been applied" for `applicationStarted`.
- **Detail:** the original request expired / "Nothing was applied automatically, and the agent can't receive a result for it". For `applicationStarted`: "whether the file changed is uncertain, even if the file now matches it".
- **Actions:** View (existing popover, `inspectsOnView`) and Copy proposal. Discard proposal… (confirmation, destructive) appears when the session is open; otherwise the existing Open action is shown. There is no Apply and no Dismiss.

What the actions do:
- **Copy:** exactly the stored `proposedText` to the pasteboard (DEBUG writer seam in tests).
- **Discard:** withdraws exactly the parsed review ID through the session's lane. It is refused while live and never touches the file.
- **View:**
  - It shows the stored target, file, diff and content (capped at 20000 characters with a note).
  - It runs a transient comparison using `WorkspaceFileEditHost(store: workspaceFileContextStore, lookupRootScope: .visibleWorkspace)`, the same decoding host as the preview.
  - It is identity-fenced: the stored proposal must still `hasSameProposal(as:)` the displayed one after the read.
  - A missing or unreadable file yields a message and never blocks View or Copy. Another workspace says "Open that workspace to compare".
  - A match says "doesn't prove this proposal was applied", and `applicationStarted` stays uncertain.

No proposed bytes are ever written from history.

## Files

### Source (new)
- `Sources/RepoPromptAgentCore/AgentMode/Models/AgentRecoveryEditProposal.swift`: proposal, base, state and the typed transition.
- `Sources/RepoPromptAgentCore/AgentMode/Runtime/Recovery/AgentRecoveryStore+EditProposals.swift`: store mutations and lane wrappers.
- `Sources/RepoPrompt/Features/AgentMode/ViewModels/AgentModeViewModel+EditProposalRecovery.swift`: admission, begin/finish, fence, refusal, and the recovery-list Copy/Discard/View helpers.

### Source (modified)
- `Sources/RepoPromptAgentCore/AgentMode/Models/AgentRecoveryModels.swift`: record `editProposals` (init default `[]`), `editProposal(reviewID:)`.
- `Sources/RepoPromptAgentCore/AgentMode/Runtime/Recovery/AgentRecoveryStore.swift`: `editProposalConflict` / `editProposalIneligible` errors; `replace(..., editProposals:)`.
- `Sources/RepoPromptAgentCore/AgentMode/Runtime/Recovery/AgentRecoveryRecordCodec.swift`: decode/encode/validation as above.
- `Sources/RepoPromptAgentCore/AgentMode/Runtime/Recovery/AgentRecoveryCoordinator.swift`: lane live-ID tracking.
- `Sources/RepoPromptAgentCore/AgentMode/Runtime/Recovery/AgentRecoveryCatalog.swift`: kind, payload, `addEditProposals`, `editProposalItemID`.
- `Sources/RepoPromptAgentCore/AgentMode/Runtime/AgentSessionMetadataIndex.swift`: `hasEditProposals` fact.
- `Sources/RepoPromptAgentCore/AgentMode/Runtime/Session/PendingApplyEditsReview.swift`: `ApplyEditsApprovalScope.tabID` widened to `package`.
- `Sources/RepoPrompt/Infrastructure/MCP/ApplyEdits/ApplyEditsApprovalStore.swift`: recovery disposition, ticket, `beginReview` / `awaitReview` / `isReviewTicketCurrent`, latest-ID cleanup, ID-scoped cancellation.
- `Sources/RepoPrompt/Infrastructure/MCP/WindowTools/MCPApplyEditsToolProvider.swift`: review-branch ordering, partial-success summary, `editSummary(errorMessage:errorCode:retryable:)`, `recoveryRecordFailedNote`.
- `Sources/RepoPrompt/Features/AgentMode/ViewModels/AgentModeViewModel.swift`: DEBUG seams `test_editProposalRecoveryAwaitHook` and `test_recoveryListPasteboardWriter`.
- `Sources/RepoPrompt/Features/AgentMode/ViewModels/AgentModeViewModel+RecoveryList.swift`: the `.editProposal` row and action handling.
- `Sources/RepoPrompt/Features/AgentMode/ViewModels/UI/AgentComposerUIModels.swift`: `.copyProposal` / `.discardProposal`, `inspectsOnView`, `AgentRecoveryListActions.inspect`.
- `Sources/RepoPrompt/Features/AgentMode/Views/Components/AgentRecoveryListBanner.swift`: confirmation, destructive styling, and inspection in the existing viewer.
- `Sources/RepoPrompt/Features/AgentMode/Views/AgentInputBar.swift` and `.../Components/AgentRecoveryNeedsAttentionSheet.swift`: `inspect` wiring.

### Tests
`Tests/RepoPromptTests/AgentMode/Recovery/AgentRecoveryEditProposalTests.swift` is a new suite of 11 tests (9 originally, plus 2 from the pre-review fix). It is not in the frozen ledger, which was not modified. Its own harness has a FailSwitch `FileOperations`, a private approval store and a no-op Codex controller. The 9 tests:
- `testProposalIsDurableBeforeLiveReviewAndApplicationStartedBeforeWrite`: exact stored fields and owner; durable at publication under the same ID; accept alone records nothing. The executed helper's write observes `applicationStarted` durable, and runs exactly once with the real store ticket. Applied removes.
- `testProviderCommitsBeforePublicationAndBeforeWrite`: source-order guard on the provider wiring (ticket → admit → await; the accepted helper with the exact `isReviewTicketCurrent(ticket)`; partial; reject `guard withdrawn`).
- `testFailedPendingCommitShowsNothingAndWritesNothing`.
- `testFailedApplicationStartedCommitRefusesTheWrite`.
- `testFailedAppliedCommitReportsFailureAndKeepsPossiblyApplied`.
- `testTimeoutAndCleanupPreserveButExplicitRejectWithdraws`.
- `testHistoricalCopyAndDiscardNeverTouchTheFileAndViewCompares`.
- `testResetOrCancellationAtEachNewAwaitWritesNothing`: tries every change at every await point, 15 cases in all.
  - Changes: reset, lane replaced, binding transition in progress, binding rebound (same session and lane, generation moved), cancellation.
  - Await points: pending commit, `applicationStarted` commit, review-ticket check.
  - Each case asserts 0 writes, no live entry, and no live card. When the lane is still owned, the record is back to pending.
- `testStaleTicketAtHeldApplicationStartedWritesNothing` (new): an accepted review's ticket goes stale while `applicationStarted` is held, either before the commit or after it and before the ticket check.
  - Endings: scope cleanup, window cleanup, an explicit lifecycle cancel via public `cancelPendingReview` with nothing pending, and a newer review.
  - 8 cases. Each asserts 0 writes, the record back to pending, no live entry, and the row listed as "Unreviewed edit proposal".
- `testFailedWithdrawalOnRejectIsReportedAndKeepsTheProposal` (new): the withdrawal fails to save, so the finish returns false, the proposal stays stored pending and listed, and the note wording is checked.
- `testSessionWithoutDurableAdmissionIsUnchanged`.

`AgentRecoveryStartupReconciliationTests.swift` gains `testEditProposalCommittedBeforeReviewIsDiscoveredExactlyAfterRestart`. It covers:
- join and conflict;
- cold exact discovery after a fresh launch;
- unknown proposal, base and record members surviving a later write;
- an unknown state and a duplicate review ID being unreadable.

## Validation and failure history

All runs used the coordinated conductor (no global-wait):

| # | Ticket | Command | Result |
|---|---|---|---|
| 1 | 5cbd3a38 | `make dev-swift-build PRODUCT=RepoPrompt` | Passed, after the earlier compile fixes: `ApplyEditsApprovalScope.tabID` widened to `package`, and the view model captured once before the awaits. |
| 2 | 082366c6 | `make dev-test FILTER=AgentRecoveryEditProposalTests` | Passed, 9/9. Test-compile fixes before it: `await` hoisted out of XCTAssert autoclosures, `try await` moved out of a ternary, a captured `var` replaced, and a `CopiedTexts` box. A Swift 6 isolation warning was then fixed with `private nonisolated static let`. |
| 3 | 5bb93c2f | `make dev-test FILTER=AgentRecoveryStartupReconciliationTests` | Passed, 21/21. |
| 4 | 3f2bda3e | `make dev-test FILTER=AgentRecoveryStoreTests` | Passed, 21/21. |
| 5 | 5c44bf54 | `make dev-test FILTER=AgentRecoveryQuestionPersistenceTests` | Passed, 14/14. |
| 6 | bfe1bbd9 | `make dev-test FILTER=AgentRecoveryCoordinatorTests` | Passed, 45/45. |
| 7 | 70362cca | `make dev-test FILTER=AgentRecoveryDelegatedChildLinkTests` | Passed, 12/12. |
| 8 | 3eda494b | `make dev-test FILTER=AgentModeViewModelDisposalTests` | Passed, 2/2. |
| 9 | 713573f1 | `make dev-test FILTER=AgentSessionMetadataRecordExtensionTests` | Passed, 32/32. |
| 10 | 5ad6109d | `make dev-test FILTER=MCPMutationRetryableFailureTests` | Passed, 14/14. |
| 11 | 2c148830 | `make dev-lint` | **Failed.** `indent` at provider 197–206 (over-indented admission arguments) and `AgentInputBar.swift` 357–359 (`inspect` wiring). Knock-on `indent`/`trailingSpace` reports at provider 33–44 (blank lines inside the untouched tool-description string; no trailing whitespace exists there). `redundantSendable` at `AgentRecoveryEditProposal.swift:132`. `hoistAwait` ×8 and `wrapArguments` ×2 in the new test suite. |
| 12 | 64fcc11e | `make dev-lint` | Passed after the fixes: dedent, `Sendable` removed from the package transition enum, inner `await` removed from `XCTUnwrapAsync(...)`, one call rewrapped. The 33–44 reports disappeared, so they were knock-on. |
| 13 | 4396fd69 | `make dev-format-check` (non-mutating) | Passed, 0/2174 files require formatting. |
| 14 | f60ecd06 | `make dev-swift-build PRODUCT=RepoPrompt` (final, after all edits) | Passed. |
| 15 | dda73668 | `make dev-test FILTER=AgentRecoveryEditProposalTests` (final) | Passed, 9/9. |

The regex OR form (`FILTER="'A|B'"`) was refused by the conductor in this run ("matched no curated ledger entry or source suite"), so the adjacent suites ran one at a time. The ticket ID of that refused attempt was not captured.

## Pre-review fix (2026-10-23, main-identified gaps before initial A/B)

The same scope; no new framework.

1. **Exact ticket before the write.** `mcpPerformAcceptedApplyEditsReview` (new; the provider and tests execute it) and the private `mcpBeginApplyEditsReviewApplication` re-check `isReviewTicketCurrent(ticket)` after the `applicationStarted` await. They then re-check owner and cancellation synchronously on the main actor before the write. Public `cancelPendingReview(scope:reason:)` now expires the scope's latest ticket even when nothing is pending, so an accepted review held at `applicationStarted` is refused after turn-end/lifecycle cancellation too. The ID-scoped waiter cancellation is unchanged and never expires a newer ticket.
2. **Binding fence.** The existing `MCPDelegatedChildIdentity` and the existing binding facts are now captured and checked, as described in Admission and Ordering. `admission.binding` is now used.
3. **Reject.** A failed withdrawal is reported truthfully, as described in Lifecycle versus withdrawal.

The DEBUG hook `test_editProposalRecoveryAwaitHook` now takes a DEBUG `EditProposalRecoveryAwaitPoint` (`pendingCommit`, `applicationStartedCommit`, `reviewTicketCheck`) in place of the transition type.

Files: `AgentModeViewModel+EditProposalRecovery.swift`, `AgentModeViewModel.swift` (hook type), `MCPApplyEditsToolProvider.swift`, `ApplyEditsApprovalStore.swift`, and the test suite.

| # | Ticket | Command | Result |
|---|---|---|---|
| F1 | a169b591 | `make dev-swift-build PRODUCT=RepoPrompt` | Passed (gaps 1–3). |
| F2 | (not issued) | `make dev-test FILTER=AgentRecoveryEditProposalTests` | Interrupted by the main agent before it ran, to add the `cancelPendingReview` follow-through. |
| F3 | d30dccab | `make dev-swift-build PRODUCT=RepoPrompt` | Passed (after the `cancelPendingReview` change). |
| F4 | e75236b6 | `make dev-test FILTER=AgentRecoveryEditProposalTests` | Passed, 11/11. |
| F5 | 48bbd8ea | `make dev-test FILTER=AgentModeViewModelDisposalTests` | Passed, 2/2 (approval-store owner). |
| F6 | 671ada93 | `make dev-test FILTER=ClaudeCompactionRunningStatusTests` | Passed, 8/8 (approval-store owner). |
| F7 | 0f670995 | `make dev-lint` | Passed. |
| F8 | c6344b7a | `make dev-format-check` | Passed, 0/2174 files require formatting. |

No failures occurred in this fix. The adjacent recovery suites #3–#10 were not re-run; the store, codec and catalog are unchanged by this fix.

## Round 3 repair (2026-10-23, main-verified initial review gaps)

The same scope; no new framework. The frozen initial index (20 files, tree `c1d037631854b7d4bd6ef9d2cd5ac64378e4b543`) stays staged. All repairs below are **unstaged**.

1. **Owner frozen before the first new await.**
   - `mcpCaptureApplyEditsReviewOwner(tabID:)` is synchronous. The provider calls it immediately after the approval scope is known, before canonical target resolution, preview, and `beginReview`.
   - It freezes:
     - tab and session ID;
     - session and lane (weak);
     - the existing `MCPDelegatedChildIdentity`, which carries the binding, `bindingTransitionGeneration` and persistence state;
     - the lane binding;
     - incarnation and reset generation.
   - It refuses in these cases: a binding transition is in progress, the lane is invalid, not owned or for another session, persistence does not match, or recovery is frozen.
   - A missing session returns `nil` (untracked) only when admission is not mandatory; otherwise it throws.
   - `mcpAdmitApplyEditsReviewProposal(owner:...)` validates the frozen owner (`editReviewOwnerIsCurrent`) and never adopts a session after an await. A `nil` owner keeps the ordinary untracked path unchanged.
2. **Canonical target.**
   - For tracked reviews, the preview reads `WorkspaceFileEditHost.canonicalExistingFilePath`, which is the existing `exactExistingFile` record's `standardizedFullPath`.
   - `MCPApplyEditsToolProvider.canonicalReviewTarget` binds the proposal and the write to the same absolute file.
   - A create resolves through the new `WorkspaceFileMutationService.resolveCreateDestination`. It uses the same `resolveCreation` that `createFileWithPostcondition` now shares, with the host's root scope, selection and create policy. Behaviour and refusals are unchanged.
   - If the preview disagrees with the resolution, the request fails closed with a precise refusal and nothing is published or written.
   - View (`recoveryListEditProposalInspection`) compares the stored absolute path only when it is under one of the window's `.visibleWorkspace` roots. Otherwise it shows the neutral message "isn't inside this window's loaded workspace roots (for example, it was in a session worktree)".
3. **Store.** The `applicationStarted` transition checks the reset generation before the already-started `.unchanged`, so an older reset's started proposal is refused, not joined.
4. **`clearChatPreservingRecovery`.** The test asserts that the proposal survives against the current store binding (the successor lane), not conditional on the old lane's `isValidForHandoff`.
5. **Presentation.**
   - Discard resolves the row with `recoveryListCatalogItem(rowID)`, then uses `item.sessionID` and `proposal.reviewID` (no row-ID parsing).
   - The banner `.task(id:)` resets `inspection = nil`.
   - Headings:
     - The pending heading is now "Edit proposal not applied".
     - The `applicationStarted` heading is still "Edit may have been applied".
     - The detail mentions that a newer review replaced the request.
   - The unused `recoveryDisposition` and `ApplyEditsReviewRecoveryDisposition` were removed.
6. **Failed `applicationStarted` transition.** A best-effort revert to `applicationNotStarted` runs before live ends, through the same `revertApplicationNotStarted` used for the later refusals.

New fixtures (the suite is now 14 tests):
- `testOwnerChangeDuringTheInitialAwaitsPublishesAndWritesNothing`: reset, rebound, replaced and removed after capture and while held across `beginReview` → admission throws, 0 writes, nothing stored or published. A missing session under mandatory admission makes capture throw.
- `testApplicationStartedFromAnEarlierResetIsRefusedNotJoined`.
- `testReviewTargetIsCanonicalAndHistoryComparesTheSameFileAfterRootsChange`: two temp roots, each with `Sources/A.swift`.
  - Existing and create targets are canonical in A, and an unestablished target is refused.
  - After root B loads, a relative lookup no longer equals A, yet View says exactly "still matches", then "has changed" after A is edited. B is untouched.
  - The frozen create writes into A.
  - A path outside the roots gets the neutral message.
- The reset/fence matrix now reads the current lane and asserts exact expectations per point × change.

Catalog Open was documented, not changed (no router):
- `AgentModeViewModel+RecoveryList.swift` `openRecoveryListSession(rowID:)` needs `item.composeTabID ?? resolution.composeTabID`.
- Another workspace routes via `recoveryListRouteToSession` → `AppDeepLinkRouter.shared.route(agentSession:)`.
- `openRecoveryListTab` switches to or unstashes the tab.
- Otherwise it shows "This session can't be opened from here. Open it from the sidebar."

Changed paths (unstaged, relative to the staged index):
- `Sources/RepoPrompt/Features/AgentMode/ViewModels/AgentModeViewModel+EditProposalRecovery.swift`
- `Sources/RepoPrompt/Features/AgentMode/ViewModels/AgentModeViewModel+RecoveryList.swift` (pending heading)
- `Sources/RepoPrompt/Features/AgentMode/Views/Components/AgentRecoveryListBanner.swift`
- `Sources/RepoPrompt/Infrastructure/MCP/ApplyEdits/ApplyEditsApprovalStore.swift`
- `Sources/RepoPrompt/Infrastructure/MCP/ApplyEdits/WorkspaceFileEditHost.swift`
- `Sources/RepoPrompt/Infrastructure/MCP/WindowTools/MCPApplyEditsToolProvider.swift`
- `Sources/RepoPromptWorkspace/WorkspaceContext/WorkspaceFileMutationService.swift`
- `Sources/RepoPromptAgentCore/AgentMode/Runtime/Recovery/AgentRecoveryStore+EditProposals.swift`
- `Tests/RepoPromptTests/AgentMode/Recovery/AgentRecoveryEditProposalTests.swift`
- this evidence file (untracked)

`AgentModeViewModel.swift` (the DEBUG hook type from the pre-review fix) is already in the staged index and has no unstaged delta.

| # | Ticket | Command | Result |
|---|---|---|---|
| R1 | 83630d01 | `make dev-swift-build PRODUCT=RepoPrompt` | Passed. |
| R2 | 13fd6ae9 | `make dev-test FILTER=AgentRecoveryEditProposalTests` | **Failed**, 14 tests, 1 failure: "Missing ordered source fragment: mcpAdmitApplyEditsReviewProposal(". The source-order needles were in the wrong order (test-only fix). |
| R3 | 76b216d0 | `make dev-test FILTER=AgentRecoveryEditProposalTests` | Passed, 14/14. |
| R4 | 9c67bcfb | `make dev-test FILTER=AgentRecoveryStartupReconciliationTests` | Passed, 21. |
| R5 | d55a7113 | `make dev-test FILTER=AgentRecoveryStoreTests` | Passed, 21. |
| R6 | e7c68e15 | `make dev-test FILTER=AgentRecoveryCoordinatorTests` | Passed, 45. |
| R7 | d2d60f6b | `make dev-test FILTER=AgentRecoveryDelegatedChildLinkTests` | Passed, 12. |
| R8 | 22c8d39f | `make dev-test FILTER=AgentSessionMetadataRecordExtensionTests` | Passed, 32. |
| R9 | 0ba719f3 | `make dev-test FILTER=AgentRecoveryQuestionPersistenceTests` | Passed, 14. |
| R10 | 2932e7d6 | `make dev-test FILTER=AgentModeViewModelDisposalTests` | Passed, 2. |
| R11 | dab804ed | `make dev-test FILTER=ClaudeCompactionRunningStatusTests` | Passed, 8. |
| R12 | 590408ed | `make dev-test FILTER=MCPMutationRetryableFailureTests` | Passed, 14. |
| R13 | 456707f5 | `make dev-test FILTER=WorkspaceFileContextStoreTests` | Passed, 128 (create refactor). |
| R14 | e160a12d | `make dev-lint` | **Failed.** `conditionalAssignment` at provider 201/203/205 (the `existingTarget` and `reviewTargetPath` assignments). Knock-on `indent`/`trailingSpace` reports at 33–44 (same as #11). |
| R15 | 59839426 | `make dev-format-check` | **Failed**, same findings. |
| R16 | 800a77b0 | `make dev-swift-build PRODUCT=RepoPrompt` | Passed (`reviewTargetPath` as an if-expression with `try await`). |
| R17 | e0d5fcea | `make dev-lint` | Passed (both assignments are if-expressions). |
| R18 | 30267a16 | `make dev-format-check` (non-mutating) | Passed. |
| R19 | 55f7fd2f | `make dev-swift-build PRODUCT=RepoPrompt` (final tree) | Passed. |
| R20 | bfb65d7e | `make dev-test FILTER=AgentRecoveryEditProposalTests` (final tree) | Passed, 14/14. |
| R21 | 5cec5c92 | `make dev-test FILTER=MCPMutationRetryableFailureTests` (final tree) | Passed, 14/14. |

R4–R13 ran on the repair tree before the style-only fix of R14 → R17, which only changed two assignments in the provider to if-expressions. The suites that ran on the final tree are R19–R21.

## Not run

- `make dev-build`, `dev-run`, packaging, or app lifecycle (by instruction; no installed app was touched).
- `PRODUCT=repoprompt-mcp`: the tool schema and arguments are unchanged; only the result fields of an existing `EditSummary` (`errorMessage`/`errorCode`/`retryable`, already part of the shape) are used on the new partial path.
- A release-configuration compile. The DEBUG seams are `#if DEBUG`; the release paths are otherwise identical code.
- After the style-only fixes (#11 → #12), only the final build (#14) and the new suite (#15) re-ran. The adjacent suites #3–#10 predate them. The fixes were whitespace, one `Sendable` removal (the compile proves it is still inferred), and the test `await`s.
- `make guardrails` and `Scripts/check-agent-context` (the docs and allowlist are main-owned).
- Full-root `dev-test-parallel`, `dev-core-test`, live/app/provider verification, and any Oracle review (main-owned).

## Remaining limits

- **External file races:** a concurrent writer between the preview and the host write is not solved. The write is the existing live host write, unchanged. Base evidence only describes the decoded preview text.
- **Uncertainty is by design:** `applicationStarted` survives a crash or write error as "may have been applied" even when the file matches. A comparison observes content only.
- **Comparison scope:** View compares the stored canonical absolute path only when it lies under the window's `.visibleWorkspace` roots. A proposal from another workspace is not compared, and the user is told to open that workspace. A path outside the visible roots (for example a session worktree) gets a neutral "can't be compared here" message; a worktree comparison is not implemented.
- **Selection not varied:** the canonical-target fixture does not vary selection. Selection only biases best-effort creates, relative multi-root non-alias creates use `requireUnambiguous`, and the history inspection uses a selection-less host.
- **Catalog Open:** this was documented only (see Round 3); no router was added.
- **Discard requires an open session:** Discard needs the proposal's session open in this window (`recoveryListLane`). Otherwise the row offers the existing Open action, and Copy/View still work.
- **Closed window at review start:** the review branch now calls `requireTargetWindow()`, so a target window that closed before the review started refuses instead of publishing a review to a scope that is already gone. No write happens either way.
- **Best-effort revert:** the `applicationNotStarted` revert after a post-commit refusal is best effort. If it fails (for example a reset already retired the lane), the proposal stays `applicationStarted` (uncertain wording, never applied).
- **Scope-wide cancel:** the public cancel is scope-wide, as before. The existing unstructured-Task call in `cancelPendingApplyEditsReview` can therefore expire a review that started in the same tab after it was issued, just as it could already cancel that review's pending card. That review is refused before any write and kept as history.
- **No dedicated waiter test:** "a cancelled waiter never expires a newer ticket" is shown by code only (the ID-scoped path does not touch the latest map), not by a test.
- **Window between check and write:** the last check is synchronous on the main actor right before `write`. The write itself is the existing host call, and no lock is held across it.
- **Committed but unshown:** a proposal committed but never shown (staleness right after its commit) is kept as history. That is the truthful outcome of an expired request.
- **Retention:** proposals have no retention limit (deferred, as is optional polish). Each stores the full proposed text and diff, and the viewer caps display at 20000 characters.
- **Untested UI paths:** the successful Open path and the real `NSPasteboard` write are not exercised by tests; the DEBUG pasteboard writer stands in.
- **Routed doc:** the lossless-restart spec's Phase 5 apply_edits text may want a pointer to this contract (typed dispositions, decoded-text base domain). That is left to the main agent with the plan/status update.
