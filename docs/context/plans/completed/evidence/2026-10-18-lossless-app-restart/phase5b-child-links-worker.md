# Step 5b worker evidence: durable delegated child links before dispatch

Scope: read when the task touches lossless-restart Step 5b (parent → child linkage for routed `agent_run.start`), its source contract, validation evidence or remaining limits.
Authority: Reference
Last-verified: 2026-10-23

## Boundary

The baseline is 8033b458, and this is a worker report. The main agent owns the plan, statuses, reviews, staging and commit. I made no plan, staging or commit changes, and I ran no Oracle review, `ask_user` or other agents. Production Phase 3/4 gates stay OFF. I did no live verification, packaging, app launch/stop, provider/helper/MCP executable runtime, runtime-data/home/credential inspection or process signalling. The original unrelated dirty files are excluded: `.gitignore`, `AGENTS.md`, `CodemapSeamTestSupport.swift`, the code-mode measurement doc and plan, and the untracked turn-checkpoint and completed codemap plans. The main agent's own edits to the lossless-restart plan and `pre-live-work.md` were already in the working tree and are not from this worker.

## Source contract as implemented

### Identity
The link identity is the dispatcher's existing server-side `tools/call` `invocationID`. It is scoped as the TaskLocal `ServerNetworkManager.currentToolInvocationID` over the permit body (the same ID used for denial, observer and tool-card ownership). `captureRequestMetadata()` copies it into `MCPServerViewModel.RequestMetadata.toolInvocationID`; it is not taken from the DEBUG timeline.

It is local execution identity only. It is not provider tool-use correspondence, and it never deduplicates across requests: a new request is a new invocation. No replacement UUID is ever minted, and a tracked parent without the ID fails closed.

### Admission
`AgentRunMCPToolService.start` admits the link right after `admittedCallerProfile`, synchronously with the existing delegation admission and with no await in between. `mcpAdmitDelegatedChildLink` freezes these on the main actor:
- the invocation ID;
- the parent tab and admitted session;
- the full `activeRunOwnership` (attempt, binding, turn epoch) plus the parent `runID`;
- the exact `recoveryLane` (its binding carries incarnation and reset generation);
- the service's existing delegation commit check.

The attempt is captured once and never rebound. This matches the `mcpDelegatedQuestionDeliveryTarget` capture-at-tool-start convention, but with the full ownership rather than the attempt ID alone.

When admission returns nil, behavior is unchanged:
- an independent MCP caller (nil source);
- a parent without durable recovery admission (`requiresDurableRecoveryAdmission` false).

A tracked parent fails closed when it has any of:
- no invocation ID;
- no current attempt for its current binding;
- a mismatched admitted identity;
- a lane that is not valid for handoff, not owned by the session, or for another session.

### Fences
These are existing fences only; there is no new generation or registry:
- the parent tab still holds that session;
- `isCurrentRunAttemptForCurrentBinding(ownership, expectedRunID:)`;
- the same lane object, with `isValidForHandoff` and `isOwned(by:)`;
- the existing `mcpRevalidateDelegationCommit` closure.

The startup gate is not required to still be held. `isCurrentRunAttempt` and `isCurrentRunAttemptForCurrentBinding` were widened from internal to `package` so the app target can reuse them; their logic is unchanged.

The checks run at these points:
1. **Child create:** inside the existing `delegationCommitCheck`.
2. **After worktree preparation:** at the end of the existing do-block, so failure uses the existing cleanup.
3. **Link commit:** before the save, after the child save await, and after the link-commit await.
4. **Starter:** in `AgentExternalMCPRunStarter.start`, before dispatch (also covers the DEBUG dispatch override).
5. **Dispatch entry:** at `mcpDispatchInstruction` entry.
6. **Final predicate:** inside the final `isStillCurrent` passed to `submitUserTurnAdmittingRecoveryInput`, on both the non-Codex and the Codex-driver paths.

The scope is the TaskLocal `MCPDelegatedChildDispatchFence.current`, set only around `startRun` after the link committed. It applies only when the dispatched session is the linked child, so an unrelated dispatch is unchanged. Once linked, every check above (4–6, and a joined repeat of 3) also verifies the child's saved identity (see the bounded repair below). A one-shot release on the admission runs in a `defer` inside the scoped `startRun` closure (DEBUG and release), so `mcpDelegatedChildDispatchFence(for:)` returns nil afterwards; a fence the Codex driver captured explicitly keeps its normal checks.

### Covering child save
Before the link, the child's identity, binding and parent field must be proven durable. This uses the existing Step 4a helper `commitRecoverySavedPlacement`, made non-private (forced dirty, capture, flush, join deferred, `.written` + `staleWriteCoversCapture`). Suppressed, reset-only, deferred and not-written outcomes never qualify. The child must still be the admitted parent's child (`parentSessionID`) before and after the save.

### Link record
The parent recovery record gains additive `delegatedChildLinks`: `{invocationID, parentRunAttemptID, childSessionID, linkedAt}` plus extras.
- It is absent when empty, and unknown fields are preserved by the existing codec.
- A duplicate invocation is unreadable.
- `replace(...)` preserves links by default.

The store mutation `commitDelegatedChildLink` runs in the same lane transaction and lifecycle gate as every other mutation:
- An exact repeat (same invocation, child and attempt) is `unchanged`.
- Another child or attempt for the same invocation is `delegatedChildLinkConflict`.
- The attempt must be recorded, open (no terminal or shutdown) and from the binding's reset generation, otherwise `delegatedChildLinkIneligible`.

The lane wrapper first runs the existing `ensureRunAttempt(... .keepExisting)` for the admitted ownership in the same transaction.

### Ordering and failure
The order is: covering child save → link commit acknowledged → admission rechecked → `linkedChildSessionID` set → `startRun` under the fence.

Any failure or staleness before handoff throws `invalidParams` (or `CancellationError`) with no dispatch. It reuses the existing target cleanup in the neighbouring worktree catch's shape:
- both configurations: instrumentation `.failed` recorded first;
- DEBUG: `performTerminalQualificationCleanup("delegated_child_link" | "cancellation", false, …)`;
- release: `mcpDiscardSessionTarget`.

A committed link whose child was then discarded may remain unused. It is never auto-replayed.

### Recovery presentation
`AgentRecoveryCatalogActionFacts.delegatedChildLinks` carries the links admitted under a run card's attempt (`.turn`, `.outcomeTurn` and `.recoveryOnlyRun` rows). The row adds honest status per link. The child is looked up in the owner-validated index first, then a hydrated live session; nothing is ever created or hydrated:
- **missing:** "can't be found in this workspace";
- **parent mismatch:** uncertain wording;
- **no saved messages:** "may never have started";
- **saved messages:** "open it to check";
- **unknown content:** started-unknown.

Each row ends with "Delegated work is never restarted automatically."

`AgentRecoveryListRowProps.Action` is now `Hashable` with `.openDelegatedSession(UUID)`, offered only for a found child. It switches to or unstashes the existing tab through a helper extracted from `openRecoveryListSession`. A missing child reports "It was not recreated." Resume, continuation, provider permission and RPC revival are untouched, and `agent_run` is never auto-replayed.

## Files

### Source
- `Sources/RepoPrompt/Infrastructure/MCP/MCPConnectionManager.swift`: TaskLocal `currentToolInvocationID`; `withConnectionID(_:toolInvocationID:lifecycleCorrelation:operation:)`; the CallTool permit body passes `invocationID`.
- `Sources/RepoPrompt/Infrastructure/MCP/ViewModels/MCPServerViewModel+TabContext.swift`: `RequestMetadata.toolInvocationID` (init default nil) and its capture.
- `Sources/RepoPrompt/Features/AgentMode/ViewModels/AgentModeViewModel+DelegatedChildLinks.swift` (new): the admission object, the fence TaskLocal, and admit/current/commit/fence functions.
- `Sources/RepoPrompt/Infrastructure/MCP/Agent/AgentRunMCPToolService.swift`: admission capture, extended child-create check, post-worktree recheck, link commit with cleanup, and fence scope around both `startRun` calls.
- `Sources/RepoPrompt/Infrastructure/MCP/Agent/AgentExternalMCPRunStarter.swift`: pre-dispatch fence check.
- `Sources/RepoPrompt/Features/AgentMode/ViewModels/AgentModeViewModel.swift`: fence at `mcpDispatchInstruction` entry and in the final `isStillCurrent` (non-Codex, plus Codex bounded-ack helper and driver).
- `Sources/RepoPrompt/Features/AgentMode/ViewModels/AgentModeViewModel+RecoveryActions.swift`: `commitRecoverySavedPlacement` made non-private.
- `Sources/RepoPrompt/Features/AgentMode/ViewModels/AgentModeViewModel+RecoveryList.swift`: child presentation/lookup, Open action handling, extracted `openRecoveryListTab`.
- `Sources/RepoPrompt/Features/AgentMode/ViewModels/UI/AgentComposerUIModels.swift`: `Action: Hashable`, `.openDelegatedSession(UUID)`.
- `Sources/RepoPrompt/Features/AgentMode/Views/Components/AgentRecoveryListBanner.swift`: button title.
- `Sources/RepoPromptAgentCore/AgentMode/Models/AgentRecoveryModels.swift`: `AgentRecoveryDelegatedChildLink`, the record field and lookups.
- `Sources/RepoPromptAgentCore/AgentMode/Runtime/Recovery/AgentRecoveryRecordCodec.swift`: decode/encode (absent when empty), duplicate-invocation invariant.
- `Sources/RepoPromptAgentCore/AgentMode/Runtime/Recovery/AgentRecoveryStore.swift`: link error cases; `replace(..., delegatedChildLinks:)` preserving by default.
- `Sources/RepoPromptAgentCore/AgentMode/Runtime/Recovery/AgentRecoveryStore+DelegatedChildLinks.swift` (new): store mutation and lane wrapper.
- `Sources/RepoPromptAgentCore/AgentMode/Runtime/Recovery/AgentRecoveryCatalog.swift`: run-card `delegatedChildLinks` fact.
- `Sources/RepoPromptAgentCore/AgentMode/Runtime/Session/AgentTabSession.swift`: the two existing run-attempt predicates widened to `package`.

### Tests
- `Tests/RepoPromptTests/AgentMode/Recovery/AgentRecoveryDelegatedChildLinkTests.swift` (new suite, not in the frozen ledger; it runs with a warning). It has 8 cases:
  - concurrent ingress IDs, nested/unstructured inheritance and the metadata default;
  - independent caller unchanged, and a tracked parent failing closed without invocation identity, attempt or admitted identity;
  - exact-invocation link after a covering child save, persisted child parent, exact repeat joined, fence holds only for the linked child and fails after an attempt change;
  - A→B before admission belongs to B, and an attempt change after admission fails with no link;
  - attempt, lane or delegation change at the child-save await gives no link;
  - `.notWritten` or `.suppressed` child save gives no link and no fence;
  - a failed (conflicting) link commit leaves only the other link and no fence;
  - recovery presentation: Open for the existing child, uncertain on parent mismatch, missing reported, missing Open fails with "not recreated" and nothing created.
- `Tests/RepoPromptTests/AgentMode/Recovery/AgentRecoveryStartupReconciliationTests.swift`: one added case, `testDelegatedChildLinkCommittedBeforeDispatchIsDiscoveredAfterRestart`. It covers missing-attempt ineligible, committed/unchanged/conflict, a crash before dispatch followed by a fresh launch discovering the link under the `.recoveryOnlyRun` card without resolving the child, unknown link members surviving a later write, and a duplicate invocation being unreadable.
- `Tests/RepoPromptTests/MCP/AgentDelegationServiceBoundaryTests.swift`: optional `toolInvocationID` in the fixture metadata and the Knowledge start-service helper. One added case, `testRecoveryTrackedParentStartFailsClosedBeforeCreatingAChild`: a tracked Knowledge root without identity, then with identity but without an attempt, is refused with no target, no session and no `startRun`.

## Validation and failure history

All runs used the coordinated conductor (no global-wait). There were 10 conductor tickets.

| # | Ticket | Command | Result |
|---|---|---|---|
| 1 | fd30a4c1 | `make dev-swift-build PRODUCT=RepoPrompt` | **Failed:** `isCurrentRunAttemptForCurrentBinding` inaccessible (internal in AgentCore). Fixed by widening the two existing predicates to `package`. |
| 2 | 0d4a6a0a | same | Passed (29.6 s). |
| 3 | 9f9b9916 | `make dev-test FILTER=AgentRecoveryDelegatedChildLinkTests` | **Failed (test compile):** unqualified `SessionSaveOutcome`, an `await` inside `XCTUnwrap`, and an `await` inside `XCTAssertEqual`. Fixed in the tests only. |
| 4 | 37f7186c | same | Passed, 8/8. |
| 5 | 33b993d2 | `make dev-test FILTER=A\|B\|…` (unquoted) | The Makefile does not quote `FILTER`, so the shell split the regex (`command not found` for the other names; make exit 127). Conductor still ran only `AgentRecoveryStartupReconciliationTests`: 20/20 passed. Not counted as the multi-suite evidence. |
| 6 | 0d118e1b | `make dev-test FILTER="'AgentRecoveryStartupReconciliationTests\|AgentDelegationServiceBoundaryTests\|AgentRunMCPToolServiceStartDefaultTests\|AgentRecoveryVMProducerAdmissionTests\|AgentRecoveryStoreTests'"` | Passed: 110 tests, 0 failures, all 5 suites. Both added cases passed. |
| 7 | 0b5c0e52 | `make dev-test FILTER="'AgentRecovery\|AgentRunMCP\|AgentExploreMCP\|AgentExternalMCPRunStarter\|AgentModeMCP\|ServerNetworkManager\|MCPConnectionManager'"` | Passed: 411 tests, 22 suites, 0 failures. |
| 8 | 4afc095b | `make dev-lint` | Passed. |
| 9 | dc783e89 | `make dev-format-check` (non-mutating) | Passed. |
| 10 | 7d68d7eb | `make dev-swift-build PRODUCT=RepoPrompt` (final, after all edits) | Passed. |

`make guardrails` passed (direct target, no conductor ticket). Its one warning is the existing `AGENTS.md` route-count, which is excluded dirt.

## Bounded repair (2026-10-23, main-verified source gaps on the staged 19 files)

All repair edits are unstaged on top of the staged initial implementation; main restages after review.

### Delta
1. **Child binding fence.**
   - `MCPDelegatedChildIdentity` captures the child's existing facts:
     - owner object and tab;
     - `persistentSessionBindingIdentity` and `bindingTransitionGeneration`;
     - `persistenceState`, which carries the incarnation and transcript-reset generation;
     - recovery lane identity;
     - `parentSessionID`.
   - Capture happens before and after the covering save. Across the save, only the creator's own first save may acquire persistence state and a lane (`isContinued(bySaved:)`); an existing child must keep everything.
   - The saved identity is re-verified after the link await, stored on the admission with the linked child, and checked in `mcpRequireDelegatedChildLinkAdmissionCurrent`. That one check covers the starter pre-dispatch, `mcpDispatchInstruction` entry, and both final `isStillCurrent` predicates.
   - It requires no binding transition in progress and, when the child has a lane, one that is valid for handoff, owned, and for that session.
   - A recovery reset retires the lane and bumps `persistenceState` while keeping object, session ID and parent, so it is refused. No new generation or registry.
   - `mcpRequireDelegatedChildDispatchFence` now propagates the specific refusal (for example "reset, rebound, or replaced").
   - DEBUG seam `test_delegatedChildLinkAwaitHook` sits inside the link await, next to the existing recovery seams.
   - Production new-child path inspected (`mcpResolveOrCreateSessionTarget` new-tab branch: `mcpCreateBackgroundSessionTab` → `ensureSessionReady` → profile adoption → `ensureSessionBoundToTab` → `commitSpawnParentSessionID`). It does not save, so the child has no persistence state or lane before the link. The test `makeChild` mirrors this and asserts both are nil, so no pre-claim can mask a missing covering save.
2. **Cancellation.** `Task.checkCancellation()` runs at these points:
   - at link-commit entry, after the child-save await, and after the link-commit await;
   - in the service, immediately before the scoped start (inside the link do-block, so cleanup runs);
   - in `mcpRequireDelegatedChildDispatchFence` (starter pre-dispatch and `mcpDispatchInstruction` entry);
   - `!Task.isCancelled` in the non-Codex final `isStillCurrent`, which is evaluated in the caller's task.

   The owned Codex bounded-ack driver's predicate is unchanged: no cancellation check, and the captured fence keeps its state checks. Its documented `operationStarted` semantics are preserved. A delegated child start is idle, so it takes `.startedRun` and never the bounded-ack path; there was no conflict to report.
3. **Recovery row.**
   - Durable links are kept, while status and Open are deduped by `childSessionID`, so there are no duplicate `ForEach` IDs.
   - The full per-child status goes in `row.text`, which the existing View popover shows.
   - Inline detail is one sentence: the child's status for a single child, otherwise a count.
   - A parent card from another workspace (`item.workspaceID != persistenceWorkspace?.id`) is not resolved; it says "open the parent to check" with no Open.
4. **Fence release.**
   - `releaseDispatchFence()` / `isDispatchFenceReleased` runs in a `defer` inside both scoped `startRun` closures.
   - `mcpDelegatedChildDispatchFence(for:)` returns nil once released.
   - `revalidateSpawnDelegation` captures the view model weakly and refuses if it is gone.
5. **Service happy path.** `testRecoveryTrackedParentStartCommitsChildAndLinkBeforeTheScopedStart` runs `makeKnowledgeStartService(toolInvocationID:)` with a real temporary recovery store, mandatory admission, the root's lane claimed by its first VM save, and a current attempt. The custom `startRun` observes:
   - the persisted child's parent;
   - the committed link (exact invocation, attempt, child);
   - the TaskLocal fence armed for that child.

   It asserts exactly 1 start, and that the fence is released afterwards. Fixture note: the WindowState fixture marks nodes loaded without persistence ownership. The test makes the root's first save its initial creation and points session-index ownership at the temporary workspace (`test_setActiveWorkspaceIDForSessionIndex`), never the window's own storage.
6. **Terminal path.** `testLinkEnsuredFirstTurnAttemptReceivesItsNormalTerminal`:
   - the attempt begins before the lane exists and is not recorded;
   - the link transaction records it;
   - the production barrier (`test_terminalCommitBarrier().commit`) records its terminal (same `commitID`, no evidence failure), and the link is kept.

   No defect was found in the existing terminal owner, so it was not changed.
7. **Cleanups.**
   - The link catch now matches the worktree catch: instrumentation is hoisted above `#if` and passes `false`.
   - The store doc says the mutation must run under the existing foundation gate (the lane `transaction`).
   - Cross-workspace wording is as in item 3.
   - Retention optimization and unconfirmed extras are deferred.

### Tests added or changed
- `AgentRecoveryDelegatedChildLinkTests` now has 12 tests:
  - `testChildResetDuringLinkAwaitOrBeforeStartDispatchesNothing`:
    - a real `clearChatPreservingRecovery` reset during the link await commits the link unused, arms no fence, and keeps object/ID/parent;
    - a reset after the link makes the real starter refuse with zero dispatches.
  - `testLinkedChildStartsOnceAndReleasedFenceIsNotArmedAgain`: the real starter makes exactly one dispatch under the fence; after release the TaskLocal is not armed, while the explicit fence still checks.
  - `testCancellationAtEachNewAwaitDispatchesNothing`: cancellation after the child save, during the link await, and at the real starter's last await before dispatch. Each gives `CancellationError` and zero dispatches.
  - `testLinkEnsuredFirstTurnAttemptReceivesItsNormalTerminal`.
  - The presentation test adds dedupe and other-workspace checks; `makeChild` asserts no pre-save and no lane.
- `AgentDelegationServiceBoundaryTests`:
  - adds the service happy path;
  - the `RepoPromptAgentCore` import gains `@_spi(TestSupport)` for the recovery coordinator fixture.

### Repair tickets and failures

| # | Ticket | Command | Result |
|---|---|---|---|
| R1 | 55d9ce22 | `make dev-build` | Passed. Note: `dev-build` also packaged the debug app bundle into `/Applications/RepoPrompt CE Dev.app` (no launch or stop). `dev-swift-build PRODUCT=RepoPrompt` was used for the later compiles. |
| R2 | 51f81a36 | `make dev-test FILTER="'AgentRecoveryDelegatedChildLinkTests\|AgentDelegationServiceBoundaryTests'"` | **Failed, 38 tests, 3 failures.** (a) The reset-after-link case got the generic "run attempt or recovery state changed before the child was started" refusal: `mcpRequireDelegatedChildDispatchFence` swallowed the specific error. Fixed by propagating it. (b) The service happy path's root first save returned `.notWritten`: the fixture root was marked loaded without persistence ownership. |
| R3 | 2b764fa1 | same | **Failed, 38 tests, 2 failures:** the root save was still `.notWritten`. New suite 12/12. |
| R4 | efce75ef | single happy-path test, with diagnostics | **Failed:** the persistence context was not current, because session-index ownership followed the window's active workspace. Fixed with the existing `test_setActiveWorkspaceIDForSessionIndex`. |
| R5 | 31c813cc | same | Passed, 1/1. |
| R6 | b5d3bb6c | `make dev-test FILTER="'AgentRecovery\|AgentRunMCP\|AgentExploreMCP\|AgentExternalMCPRunStarter\|AgentModeMCP\|ServerNetworkManager\|MCPConnectionManager\|AgentDelegationServiceBoundaryTests'"` | Passed: 441 tests, 0 failures. |
| R7 | c60633f7 | `make dev-lint` | **Failed:** `redundantSelf` at the new non-Codex predicate (`self.` after `guard let self`), `hoistAwait` in the reset fixture, plus knock-on `indent`/`trailingSpace` reports on blank lines inside existing multiline strings. Those blank lines are untouched and the reports disappeared with the fix. |
| R8 | b7adc9d0 | `make dev-format-check` | **Failed:** same findings as R7. |
| R9 | aa507e0f | `make dev-swift-build PRODUCT=RepoPrompt` | Passed (before the R7/R8 fixes). |
| R10 | 0875ebdd | `make dev-format-check` | Passed after the two fixes. |
| R11 | 8ce8b7b0 | `make dev-lint` | Passed. |
| R12 | 4fcd8778 | `make dev-test FILTER=AgentRecoveryDelegatedChildLinkTests` | Passed, 12/12 (after the test refactor). |
| R13 | 82ac5ba1 | `make dev-swift-build PRODUCT=RepoPrompt` | Passed (final, after all edits). |

### Post-review wording correction (2026-10-23)

After the A/B R1 receipt reviews (no P0/P1), one presentation-only correction. Fences, lane semantics and execution fixtures are unchanged; other P2 coverage is deferred.

- `AgentModeViewModel+RecoveryList.swift`: the `recoveryDelegatedChildPresentation` summary now says "This run is linked to a delegated session" / "…is linked to N delegated sessions" instead of "started". This covers the one-child, multiple-child and other-workspace summaries. A link proves only a saved stub, never a start.
- `AgentComposerUIModels.swift`: the `AgentRecoveryListRowProps.text` comment now covers both held input and delegated-child status.
- `AgentRecoveryDelegatedChildLinkTests.swift`: the presentation test asserts that two distinct stubs (one found, one missing) and the other-workspace row say "is linked to" and never claim "started". A `claimsStarted` helper does word-boundary matching, so "restarted" doesn't count.

| Ticket | Short | Command | Result |
|---|---|---|---|
| P1 | 97a1ab14 | `make dev-test FILTER=AgentRecoveryDelegatedChildLinkTests` | Passed, 12/12. |
| P2 | c1b19589 | `make dev-format-check` | Passed, 0/2170 files require formatting. |

Not run for this correction (by instruction): build/packaging, lint, broader tests, app lifecycle, provider execution.

## Not run

- `PRODUCT=repoprompt-mcp`: no MCP wire or protocol surface changed. The TaskLocal and `RequestMetadata` are app-internal, and no tool schema, argument or result shape changed.
- A release-configuration compile (only debug builds/tests ran). The `#else` (release) branches in `AgentRunMCPToolService.start` are not compiled by this evidence. That includes the release `startRun` closure with its fence-release `defer`. They mirror the existing release cleanup and start calls.
- After the R7/R8 style-only fixes (removing a redundant `self.`, hoisting one test `await`), only the new suite and the app compile re-ran; the broad 441-test run (R6) predates them.
- Full-root `dev-test-parallel`, `dev-core-test`, live/app/provider verification, and any Oracle review (forbidden for this worker; the main agent owns reviews).

## Remaining limits

- **Explicit-tab reuse:** under a tracked parent, an `agent_run.start` that reuses an explicit tab whose session does not record that parent now fails closed. A link is only honest for the admitted parent's child; the target is discarded as on the other pre-dispatch failures.
- **Untracked first turn:** the link commit records the admitted attempt's run evidence through `ensureRunAttempt(.keepExisting)` when the parent run began untracked (for example, a first turn before the lane was claimed). That attempt can then appear as a run card after a crash. This is additive evidence, not a dispatch.
- **Fence scope:** the fence is scoped by TaskLocal over `startRun` and released when `startRun` returns or throws. Unstructured work created during the start inherits the TaskLocal, but a released admission is never armed from it. Work that runs before the release, or that captured the fence explicitly (the Codex driver), still requires the parent admission and child identity to hold.
- **Other workspaces:** the recovery Open looks up the child only in this window's workspace (owner-validated index or hydrated live session). A child row whose parent card belongs to another workspace is not resolved at all; it says "open the parent to check". A child missing from this workspace is reported as not found here, and there is no cross-workspace route.
- **Untested Open success:** the successful Open path (switch/unstash in a real prompt manager) is not exercised by tests. The harness has no prompt manager; lookup, action presence and the missing-child failure are tested.
- **Unused links:** a committed link may remain unused after a later pre-dispatch failure or a discarded child. It is presented honestly (missing or never-started) and never replayed.
- **Routed doc:** `docs/context/agent-mcp-delegation-depth.md` documents the admission and commit-check seams this extends. A one-line pointer to the Step 5b link fence may be wanted; that is left to the main agent with the plan/status update.
