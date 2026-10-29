# Step 5c planning — OracleA

Scope: read when the task touches bounded worktree-merge review preservation, its local storage prerequisites or implementation sequence.
Authority: Reference
Last-verified: 2026-10-23

Same planning chat remaining-pre-live-scope-584329; exact returned inherited preset 61D024A4-CCFB-4C9C-A614-CC65E0A1864C / OracleA matched. Main read the complete response. This is not a correctness review or live acceptance. The initial explicit-slice request failed before provider start because one card path was wrong; native path search corrected it and one accepted consultation completed. Raw text below retains all content with trailing-whitespace normalization only. Original export remains local.

# Oracle Plan

## 1. Summary

**Step5c can remain a targeted extension of the existing merge operation.** Use its exact `Equatable` value plus existing session/lifecycle/save ownership evidence at the two pre-handoff boundaries: publishing an actionable review and calling either `applyGitWorktreeMerge`. Add a historical-review marker to that same operation, retain its saved artifacts, and expose View/Copy/Discard through existing session discovery. No new generation, lease, proposal store, or transaction framework is warranted. **Artifactless explicitly confirmed direct apply can retain its behavior**, provided `.applying` receives the covering owner-save before VCS handoff.

This is source-based guidance, not validation or acceptance.

## 2. Current-state analysis

The supplied flow has three concrete gaps:

1. **Publication precedes durable acknowledgement.**<br>
   `requestWorktreeMergeReview` upserts `.awaitingApproval`, then publishes `pendingWorktreeMergeReview`. `persistWorktreeMergeOperationsChange` only calls `scheduleSave`.

2. **Both initial apply paths likewise rely on scheduled persistence.**<br>
   `requestWorktreeMergeReviewAndApply(preview:...)` and `applyConfirmedWorktreeMerge` set `.applying` immediately before `applyGitWorktreeMerge`, without awaiting a covering write.

3. **Expired approval is treated as withdrawal.**<br>
   `cancelPendingWorktreeMergeReview`, the non-accept branch of `requestWorktreeMergeReviewAndApply`, and cold reconciliation all turn pending approval into `.cancelled`. This loses the distinction between an expired transport and a rejected proposal.

Reusable pieces:

- `AgentSessionWorktreeMergeOperation` already contains operation identity, endpoints, fingerprints, artifact references, and state.
- `commitRecoverySavedPlacement` requires a `.written` receipt covering its captured state under the same owner, binding, and persistence context.
- Existing operation summaries and attention selectors already surface `.awaitingApproval`.
- The reconciler already owns in-flight merge recovery. Leave that algorithm unchanged.
- The publisher creates actual preview artifacts, but **paths and `fileExists` checks alone do not establish durable retention**. The store exposes unconditional snapshot deletion, and preview creation can fall back to a temporary directory.

## 3. Design

### A. Smallest operation-owner/save fence

Use one narrow helper in `AgentModeViewModel+WorktreeMerge.swift`, conceptually:

> Commit this exact operation for this captured session owner; return success only if the covering write and post-await ownership checks both pass.

It should reuse `commitRecoverySavedPlacement`, not replace its receipt logic.

#### Capture and validate

Before the first new suspension, capture:

- the `AgentTabSession` object;
- durable session ID and tab binding;
- the existing session-incarnation/reset/persistence ownership evidence;
- the exact expected `AgentSessionWorktreeMergeOperation`.

After **each** asynchronous artifact preparation, preview reconstruction, or save:

1. The tab still owns the same session object.
2. Authoritative durable-session resolution still identifies that session.
3. Existing binding/incarnation/reset evidence remains valid.
4. The operation with that ID still equals the captured expected value.
5. The task is not cancelled and the existing lifecycle admission rules still permit this handoff.

A matching operation alone is insufficient: reset or rebinding can leave identical values. Conversely, lifecycle identity alone cannot detect rejection, replacement, or changed merge metadata.

**No new generation is needed if the existing evidence already detects reset/rebinding.** Confirm that fact in the existing save/lifecycle implementation. The shown helper documents relevant receipt coverage, but its private capture/check implementations are not supplied. In particular, verify that a covering transcript save includes `worktreeMergeOperations`.

Do not reread current ownership after an await and adopt it as the new owner.

#### Avoid concurrent publication without another lease

Use the existing operation state as the synchronous reservation:

- Only `.previewed` operations may enter initial review/apply.
- Transition to `.awaitingApproval` before suspending.
- A second request for the same operation cannot overwrite that reservation.
- Replacing a different pending review marks the old operation historical **before** reserving the new one—even if the old review has not yet been published.

Thus the old request fails its exact-value check when its save completes. Do not use `updatedAt` as a uniqueness token.

After successful save and checks, install the pending review, continuation, and timeout, then refresh UI within the same uninterrupted MainActor turn. No actionable review is exposed during preparation.

#### Before both initial VCS apply calls

For the accepted-review path and `applyConfirmedWorktreeMerge`:

1. Validate the captured owner and expected operation after any preview-reconstruction await.
2. Change that operation to `.applying` synchronously.
3. Capture the resulting exact value.
4. Await `commitRecoverySavedPlacement`.
5. Revalidate ownership, exact value, cancellation, and lifecycle eligibility.
6. Immediately hand off to the existing `applyGitWorktreeMerge` path.

A failed or non-covering save means **no VCS call** and a visible error. Never proceed on generic flush success.

Keep the save prerequisite outside the existing VCS error handler: failing to obtain permission to start is not evidence that Git attempted and failed a merge. If still the same owner/value, restore a known-unstarted state—historical approval for a review, `.previewed` for direct apply—and persist it normally. If ownership changed, do not mutate the replacement session.

Once VCS has accepted the operation, preserve existing execution semantics. This fence neither cancels already-owned Git work nor prevents external filesystem changes. Late results must not overwrite a different session or replacement operation.

### B. Historical review state in the existing operation

Add an optional persisted property:

`historicalReviewReason: HistoricalReviewReason?`

Cases:

- `lifecycle`
- `timeout`
- `replacement`
- `restored`

Keep `status == .awaitingApproval`; the marker means **saved review, no live approval authority**. Absence defaults to `nil`.

This avoids another operation status and retains existing summary discovery. Add the same optional marker to `AgentSessionWorktreeMergeSummary` so closed-session presentation can distinguish historical review from a live approval request.

Transitions:

| Event | Durable result |
|---|---|
| New live review | `.awaitingApproval`, marker `nil` |
| Lifecycle interruption / timeout / replacement | `.awaitingApproval`, corresponding marker |
| Cold restore of unmarked `.awaitingApproval` | `.awaitingApproval`, `.restored` |
| Explicit Reject / historical Discard | `.cancelled`, existing completion/error metadata |
| Live acceptance | `.applying`, marker cleared |

Update both cancellation handling **and** the outer non-accept branch; otherwise the latter would overwrite preservation with `.cancelled`.

Use an explicit preserve/withdraw argument at cancellation call sites, not interpretation of reason strings. Cancel the timeout and resolve the old continuation once; preservation does not keep the RPC alive.

Discard only withdraws the review. It must not call `abortGitWorktreeMerge` or delete Git state. Await a covering save before reporting durable dismissal; retain a retryable visible error if that save fails.

### C. Durable artifact boundary

For a pending review, persist **the existing published proposal**, not a regenerated diff.

Before review publication require:

- readable manifest, map, and sidecar;
- sidecar identity/endpoints matching this operation;
- readable `allPatchPath` when the published proposal declares one;
- artifact storage whose lifetime survives ordinary restart.

An absent patch is acceptable only when the published preview legitimately has no patch—not when an expected patch disappeared. Report “No saved textual patch” in that case.

**Do not use the temporary-directory fallback for a recoverable review.** Artifact preparation or storage failure refuses publication.

#### Minimal retention decision

First trace the actual snapshot cleanup scope. Choose this bounded rule:

- Reuse the published directory if existing ownership already protects it for the unresolved operation.
- Otherwise, preserve an operation-owned copy of the existing artifact bundle under the existing durable-artifact storage facility, and store those references in `previewArtifacts`.

The latter is a file-copy integration, not a new proposal record or storage framework. It is preferable to adding global merge-reference discovery to every snapshot deletion path. Do not introduce retention cleanup in Step5c.

The durable-artifact API and exact owning path are not in the packet; identifying that existing integration is required before implementation. Do not claim that the shown `_git_data` references are already protected.

Copies must preserve the bundle layout and complete before the operation’s covering save. Interrupted copies never become published references. A later failed operation save may leave an unused bundle; cleanup remains deferred.

For legacy operations with missing artifacts, preserve metadata and show **proposal unavailable**. Never regenerate under the same operation ID and present it as the original proposal.

### D. Historical discovery and read-only presentation

Reuse the existing summary/index/sidebar route:

- Historical `.awaitingApproval` remains discoverable through `activeWorktreeMergeSummaries`.
- Extend attention presentation to say **Saved merge review**, not “waiting for approval.”
- Closed-session Open hydrates the session and reveals the historical operation; it does not create `PendingWorktreeMergeReview`.

Keep the existing live review card unchanged where practical. Add a small historical presentation in the same card file, taking the persisted operation and read-only actions rather than live acceptance callbacks.

Actions:

- **View:** saved metadata and a bounded excerpt of the saved patch.
- **Copy saved patch:** exact saved patch contents, not the excerpt or a fresh Git diff.
- **Discard:** durable withdrawal only.

Load artifacts asynchronously outside the MainActor; publish results only if operation identity and artifact references still match. Missing/unreadable artifacts disable Copy and show the reason without hiding the operation.

Display explicitly:

> Saved review from an ended request. Nothing will be merged automatically. The original agent cannot receive a result.

On restore/open, reuse the existing inspection hook to compare saved source/target fingerprints. For historical reviews, mismatch, missing fingerprints, or inspection failure affects the displayed validation result—not withdrawal or automatic application. Do not convert a historical review to terminal `.stale` merely to express that its preview is outdated.

Leave reconciliation of `.applying`, `.conflicted`, and `.awaitingCommit` unchanged. Step5c adds no recovered Merge button and no automatic replay; it does not redesign existing explicit conflict-resolution workflows.

### E. Explicit direct apply remains separate

**Yes: artifactless `applyConfirmedWorktreeMerge` can keep its current behavior.**

It has no pending review to preserve. Require:

- existing preview fingerprints and current inspection behavior;
- the exact-owner fence;
- a covering `.written` save of `.applying`;
- the existing explicit confirmation path.

Do not require a patch archive or historical-review marker for it. Likewise, do not broaden `continueWorktreeMerge` and `abortWorktreeMerge` into this proposal mechanism.

## 4. File-by-file impact

| File | Change |
|---|---|
| `Sources/RepoPrompt/Features/AgentMode/ViewModels/AgentModeViewModel+WorktreeMerge.swift` | Add narrow owner/operation commit boundary; reserve review state before awaits; commit before publication and both initial apply calls; distinguish preserve/withdraw; add historical read/discard actions; update attention wording. |
| `Sources/RepoPromptAgentCore/AgentMode/Runtime/AgentSessionWorktreeMergeOperation.swift` | Add optional historical reason to operation and summary; preserve cold-restored awaiting approval; reuse read-only validation without changing in-flight reconciliation. |
| `Sources/RepoPrompt/Features/AgentMode/ViewModels/AgentModeViewModel+RecoveryActions.swift` | Reuse `commitRecoverySavedPlacement` unchanged functionally; extend its documentation to mention merge-operation barriers. Verify its capture covers operation metadata. |
| `Sources/RepoPrompt/Features/AgentMode/Views/ToolCards/AgentWorktreeMergeReviewCard.swift` | Add historical read-only presentation without reusing live Merge callbacks. |
| `Sources/RepoPromptWorkspace/VCS/GitWorktreeMergePreviewPublisher.swift` | Only if needed: integrate preservation of the existing published bundle through existing durable-artifact storage. No diff regeneration. |
| `Sources/RepoPromptWorkspace/VCS/GitDiff/GitDiffSnapshotStore.swift` | No default change. Inspect cleanup ownership; avoid adding a global pinning subsystem here. |
| Existing lifecycle cancellation callers, hydration/index and historical-card host files—paths not supplied | Pass explicit dispositions, propagate optional summary marker, and expose historical Open/View actions. Enumerate through bounded call-site tracing. |
| `Tests/RepoPromptTests/AgentMode/WorktreeMergeReviewStateTests.swift` | Add state, compatibility, preservation, and historical-summary tests. Extend existing save/VCS fixtures where located for ordering tests. |

## 5. Risks and migration

- Missing historical markers decode as `nil`; restore converts old `.awaitingApproval` records to historical reviews.
- Older binaries may still cancel awaiting approval and discard unknown marker fields. Do not promise lossless downgrade.
- Artifact references already saved in temporary or deletable locations cannot be repaired by inventing the old proposal.
- Receipt coverage and artifact lifetime are the two local facts still requiring source confirmation. Neither needs provider evidence or live execution.

## 6. Implementation order

1. **Confirm existing owner/reset evidence, save coverage, artifact lifetime, and cancellation call sites.**
2. **Add optional historical metadata and serialization/state tests.**
3. **Land artifact preparation, review reservation, covering-save barriers, and preserve/withdraw handling together.**
4. **Add historical discovery and read-only View/Copy/Discard.**
5. **Validate with fixtures:** publication/write ordering; failed and non-covering saves; reset/rebind/replacement during awaits; both initial apply routes; artifactless direct apply; missing artifacts; cold restore; stale reads; no historical VCS mutation.
6. **Review this bounded delta with A/B under the existing policy.** Record source/fixture results accurately; no Step5c tests have yet run.

**Cut:** new leases/generations, CAS/journaling, generic artifact pinning, recovered application, proposal regeneration, retention cleanup, and changes to unrelated VCS workflows. The unknown-helper and Claude-native identity blockers remain untouched.

## Narrow artifact-copy clarification

The first attempt was rejected before admission by the two-stream Oracle cap; no question was pending from it. After initial reviews completed, the retry continued the same planning chat and returned inherited exact OracleA preset UUID/name, verified. Main read the complete clarification below. This permits the narrower operation-owned retained-directory integration subject to proving captured-root lifetime and path relocation; no new durable-store/GC framework is selected.

# Oracle Plan

## 1. Summary

**Yes—the operation-owned filesystem copy is the narrower acceptable integration.** It preserves an existing proposal without introducing another proposal store or adapting the generic durable-object infrastructure. Keep `operation.previewArtifacts` as the sole persisted reference, publish it only after the retained copy is complete, and require the covering owner-save before actionable review. Record this as a reversible scope assumption. No implementation or validation has occurred for Step5c.

## 2. Current-state analysis

The supplied source establishes that:

- `previewWorktreeMerge` can publish into temporary storage.
- `GitDiffDataMaintenance` deletes tab-associated snapshots and entire workspace `_git_data` directories.
- `DurableArtifactGarbageCollector` protects catalog targets and explicitly supplied roots—not arbitrary references in session records.
- Transcript serialization includes `worktreeMergeOperations`; its covering-write checks already include mutation generation, binding, and persistence context.

Therefore neither the original preview directory nor an unrooted durable-object publication satisfies retention. **Copying outside those cleanup domains solves the specific lifetime problem.** Lifecycle/reset checks remain separate from save coverage.

## 3. Design

### Minimal prerequisite: establish one authoritative retained root

Before implementation, identify the **existing persistence-root resolver and its deletion callers**, and verify:

1. **Ownership:** the root comes from the captured session’s persistence context—not a later lookup of `activeWorkspace`, a provider-supplied path, or a temporary fallback.
2. **Lifetime:** ordinary tab close, snapshot retention, destination reuse, and cache cleanup cannot delete it. Explicit deletion may remove it only under existing intentional session/workspace deletion semantics.
3. **Restoration:** the existing artifact-reference representation can locate the copy after reopening the saved session.
4. **Path authority:** existing filesystem helpers can create and read beneath that root without following symlinks outside it. Lexical path-prefix checks alone are insufficient.

Use the existing session-owned durable storage location if it satisfies these conditions; otherwise use the existing recovery root resolved from the same captured persistence context. **If neither can be established, refuse recoverable review publication rather than add storage infrastructure or fall back to temporary storage.**

### Narrow copy boundary

Add one internal, operation-specific copy helper alongside the merge implementation. Its conceptual interface is:

> Captured retained root + expected operation + published artifact references → retained artifact references, or error.

It performs filesystem work off the MainActor and owns no persistent state beyond the copied files.

Sequence:

1. Capture session ownership, lifecycle/reset evidence, expected operation value, and retained root before suspension.
2. Validate the published bundle using existing layout/readers:
   - sidecar identity and endpoints match the expected operation;
   - required artifacts exist and are readable;
   - referenced paths remain within the bundle;
   - reject escaping paths, symlinks, and unsupported file types.
3. Copy into a uniquely named hidden sibling beneath the retained root. Use generated session/operation/copy identifiers for destination components, never display names or provider paths.
4. Validate the **assembled copy**, including its sidecar identity and required references. Source disappearance or detected replacement fails the operation; never regenerate.
5. Rename the completed directory to a unique final sibling on the same filesystem. Never overwrite or merge into an existing destination.
6. Return references pointing exclusively into that final directory.
7. On the MainActor, revalidate captured ownership, lifecycle/reset state, and exact operation value. Only then install the retained references and perform the covering owner-save.
8. Publish the actionable review only after that save succeeds and the final ownership checks pass.

The retained bundle becomes application-immutable: no later preview publication writes into it.

**Path relocation needs one explicit check:** determine whether the sidecar/map embeds absolute paths. Preserve proposal payload bytes; relocate only known location metadata if the existing format requires it. No retained reader may silently follow references back into `_git_data`. If existing readers cannot support relocation narrowly, refuse publication pending that bounded reader adjustment.

Atomic rename establishes complete-directory visibility, **not power-loss durability**. No fsync framework is introduced.

### Failure and lifecycle behavior

- Copy, validation, rename, or covering-save failure: no actionable review.
- Cancellation or owner change after copying: no publication and no mutation of the replacement session.
- Unreferenced completed copies may remain; retention cleanup stays deferred.
- Old missing artifacts remain unavailable.
- Historical View/Copy reads only retained artifacts; it never regenerates a patch.
- Explicitly confirmed artifactless direct apply remains unchanged except for its already-planned durable `.applying` barrier.

This boundary does not claim transactional protection against concurrent external writers or cancellation of an already-owned VCS operation.

## 4. File-by-file impact

| File/component | Bounded impact |
|---|---|
| `AgentModeViewModel+WorktreeMerge.swift` | Add the operation-specific retention helper and call it before the existing owner-save/publication boundary; preserve lifecycle and exact-value checks. |
| Existing artifact layout/readers | Change only if necessary to resolve relocated references entirely within the retained bundle. Exact files require the local reference trace. |
| `AgentModeViewModel+TranscriptSaveMaxWait.swift`, `AgentModeViewModel.swift` | Reuse established save coverage; no artifact-specific persistence mechanism. |
| `DurableArtifactStore.swift`, `DurableArtifactGarbageCollector.swift`, `GitDiffDataMaintenance.swift` | **No changes.** No new family, catalog, enumerator, pinning, or cleanup exemptions. |
| Existing merge/artifact tests and plan evidence | Add focused fixtures and record the root authority/lifetime trace. No new test framework. |

## 5. Implementation order

1. Confirm the root resolver, cleanup exclusions, and artifact relocation behavior.
2. Implement the narrow copy helper and fixture checks for missing/escaping artifacts, identity mismatch, completed-copy visibility, and no destination overwrite.
3. Integrate copy → owner revalidation → covering save → publication; test cancellation/reset and save failure.
4. Verify retained references remain usable after fixture deletion of the original bundle; review the bounded delta with A/B.

**Cut:** generic durable-store integration, global GC roots, retention optimization, regeneration, and new transaction machinery. If root authority cannot be proven locally, block only pending-review publication—not explicit direct apply or unrelated work.
