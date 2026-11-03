# Step 5c initial review — OracleB

Scope: read when the task touches Step5c merge-review preservation findings and disposition.
Authority: Reference
Last-verified: 2026-10-23

Returned identity verified: OracleB (7CDD523E-1D7C-47EA-98FE-D5FEA24D2D8C), explicit selection. Chat step5c-initial-b-FA2723; operation 46863501-9DA0-4C47-B4C0-08FF0DB589C6; status completed/ok. Same source snapshot2026-10-23/1620, tree e86152af1da0579a94fcd6a7cbb091782d24fa82. Full response follows. Markdown hard breaks normalized to explicit line breaks and trailing spaces removed; original export unchanged at /Users/tnguyen/workspace/repoprompt-ce-personal-touch/prompt-exports/oracle-review-2026-10-23-162758-step5c-initial-b-fa2-7ccd.md.

# Oracle Review



# Step 5c review: preserving pending worktree-merge reviews

**Verdict: no P0 or P1 findings, so nothing blocks this source checkpoint.** I found four P2 defects and several P3 items. All of them are narrow races or attention/UX problems with a workaround. None of them lets Git run without a covering save, shows a review without a covering save, or claims a withdrawal that wasn't saved.

## Summary

The change keeps a pending worktree-merge review across an app restart. It reserves an `awaitingApproval` operation and copies the same preview bundle into `AgentSessions/.worktree-merge-reviews/<sessionID>/`, under the session file's captured stamp root, using no-follow file-descriptor I/O. It then installs the copied refs with a `.live` marker and needs a covering `.written` save before the card is shown.

After that:
- **Ending without a decision:** run end, reset, replacement and timeout turn a shown review into read-only history. On a cold load, the reconciler turns `.live` into `.historical`.
- **Reject, Cancel and Discard:** each counts as done only after a covering save of the withdrawal. If that save isn't covering, the review is put back as history and the user gets a truthful failure message.
- **Both first-apply routes** persist `.applying` with a covering receipt before handing off to VCS, and restore the known-unstarted state if that save isn't covering.
- **Historical actions:** View, Copy and Discard only read the copied bundle and never touch Git. The "Now" fingerprint check stays separate from the saved bytes and prediction.

### Checked against the acceptance list
- **Show is gated:**
  - `awaitWorktreeMergeReviewDecision` is only reached after `covered && ownerIsCurrent && exact` (`AgentModeViewModel+WorktreeMerge.swift:464`).
  - Nothing awaits between that guard and the publish.
- **Git handoff is gated:**
  - `runInitialWorktreeMergeApply` is the only first-apply path.
  - Both routes go through the `.applying` save guard (`:529-533`).
  - `continueWorktreeMerge` and `abortWorktreeMerge` are unchanged, and their status guards exclude `awaitingApproval`, so history can't be continued or aborted.
- **No continuation is rebuilt:**
  - On a cold load the reconciler never calls `inspect` for a preserved review (`AgentSessionWorktreeMergeOperation.swift:316-321`).
  - The preview route refuses non-`previewed` existing operations (`:427`), so history can't be re-reviewed or re-applied.
- **Old builds and old sessions still work:**
  - An old build ignores the optional `reviewPreservation` key.
  - An `awaitingApproval` record without the marker is still cancelled on load, as before.
  - The summary's `isHistoricalReview` field is optional and normalized to `nil`.
- **The copy can't escape its bundle:**
  - Every open uses `O_NOFOLLOW` per component.
  - `..` and outside references are refused before anything is opened.
  - The assembled copy, not the source, is validated before a `RENAME_EXCL` publish.
  - Failed assemblies are removed.

---

## P2: real defects, unlikely or easy to work around

### S5C-01: a Reject that fails the owner check before any change leaves an invisible `.live` review, and the error message is wrong
- **Where:**
  - `AgentModeViewModel+WorktreeMerge.swift:1041`: the entry guard of `withdrawWorktreeMergeReviewDurably` returns `false` without changing anything.
  - Caller at `:485-489`.
- **Scenario:**
  1. A review card is shown.
  2. The owner stops matching before the user clicks Reject. Ways this happens:
     - the R4 shutdown freeze is active (`submitWorktreeMergeReviewDecision` doesn't check the freeze, and the live merge card isn't shown as disabled in this diff);
     - a binding transition is in progress;
     - `persistenceState` has rotated.
  3. The user clicks Reject.
  4. `finishPendingWorktreeMergeReview` has already removed the card. Then `withdrawWorktreeMergeReviewDurably` returns `false` at entry, so `kept` is never installed.
- **Impact:**
  - The operation stays `awaitingApproval` with a `.live` marker, no card and no continuation.
  - The thrown `worktreeMergeRejectNotSavedText` says it is "kept as a read-only ended review (Discard removes it)". That's false: `isHistoricalReview` is false, so no historical card appears and Discard can't reach it.
  - The sidebar shows a purple "awaiting approval" badge that nothing can act on.
  - A relaunch heals it (`.live` becomes historical), and so does the next lifecycle cancel, which silently turns it into `.cancelled`.
  - The existing race test only changes the owner at the `.withdrawalSave` hook, which runs after the entry guard, so this path isn't covered.
- **Smallest fix:** in the entry guard, if `worktreeMergeOperationIsExact(expected)` holds but the owner doesn't match, install `kept` before returning `false`. For Discard, `kept == operation`, so nothing changes there. Add a test case: Reject while `beginPersistentBindingTransition()` was already called before the decision.

### S5C-02: an old historical review can hide a live conflict in the sidebar and root capsules
- **Where:**
  - `AgentModeViewModel+WorktreeMerge.swift:~118-124` (`sidebarAttention`). It now includes historical `awaitingApproval` records and picks the newest by `updatedAt`.
  - `AgentWorktreeMergeAttention.init(summary:)` behaves the same way through `activeWorktreeMergeSummaries`.
- **Scenario:**
  1. Merge A is `.conflicted`.
  2. The agent previews and requests merge B, and that review times out or the run is stopped, so B becomes history with a newer `updatedAt`.
  3. The session row and the workspace-root `MERGE →` capsule now show a grey clock for B instead of the orange conflict for A.
  4. Historical records stay until someone discards them, so the conflict stays hidden.
  5. The blocker-stack card is still correct, because the conflict is ranked above history there.
- **Impact:** a needs-action conflict loses its sidebar attention signal to a read-only record.
- **Smallest fix:** rank historical candidates below active ones, for example sort by `(isHistoricalReview ? 0 : 1, updatedAt)`. Apply the same ranking wherever summaries are turned into attention.

### S5C-03: `statusWorktreeMerge` treats history as an active operation
- **Where:**
  - `AgentModeViewModel+WorktreeMerge.swift:~560`: `active = filter { !$0.status.isTerminal }`.
  - Historical reviews stay `awaitingApproval`, which isn't terminal.
- **Scenario:**
  - After a timed-out review, `manage_worktree status` without an operation ID returns the historical operation with status `awaiting_approval`. An agent polling for approval reads that as still pending.
  - After the next preview, status without an ID fails with "multiple active worktree merge operations exist".
  - Historical records pile up until each is discarded.
- **Impact:** a misleading answer to the agent, or a workflow error. The workaround is to pass `operation_id`.
- **Smallest fix:** exclude `isHistoricalReview` from the implicit "active" selection. Consider also exposing the marker, or a `historical_review` status, in the MCP reply.

### S5C-04: a review that fails before it is shown destroys an existing `previewed` operation
- **Where:** `AgentModeViewModel+WorktreeMerge.swift:439, 449, 453, 465`. The `withdrawWorktreeMergeReview` calls set the operation to `.cancelled`.
- **Scenario:**
  1. The agent previews; the operation is `previewed`.
  2. The original `_git_data` snapshot is rotated or deleted (the case retention is meant for), or the bundle is over the 512 MB / 20,000-entry limits. Per-file patches roughly double the size of `all.patch`.
  3. The agent calls apply-with-review.
  4. Retention throws, and the previewed operation becomes `.cancelled`.
- **Impact:**
  - The operation is no longer usable for the supported explicitly confirmed direct apply.
  - The agent must preview again, and on the size path it fails again.
  - This is inconsistent with the artifactless refusal, which leaves the `previewed` operation unchanged (the test asserts that).
- **Smallest fix:** when `expectedOperation` was `previewed`, restore it on pre-show failures, the same way `restoreUnstartedWorktreeMerge(.previewed)` does: `operation = expectedOperation` plus `lastError = reason`, still guarded on exactness. Keep cancelling only when there was no prior operation. Optionally add "use confirmed direct apply" to the limit-exceeded message.

---

## P3: improvements

- **S5C-05: the historical card text contradicts its reason** (`AgentWorktreeMergeReviewCard.swift:~418`). `endedText` always says "ended without a decision", but the stored reason can be "The worktree merge was not started…" (the user had accepted) or "was rejected, but … couldn't save". Branch the wording on the reason, or drop "without a decision".
- **S5C-06: a covering save followed by an owner change can leave durable and in-memory state apart** (`:464-466`, `:530-532`).
  - The publication save writes `.live`, then the owner changes, for example a quit freeze. Memory is withdrawn to `.cancelled` with only a scheduled save. If that save never lands, the next launch shows a historical card for a review that was never shown.
  - The `.applying` save has the same shape. A covered save, then an owner change, means a relaunch reconciles the operation to `.failed` ("no merge commit detected").
  - Both outcomes are honest and read-only. Document them as accepted, or attempt a final save of the restored state.
- **S5C-07: Copy isn't byte-exact for non-UTF-8 patches** (`:~702`). `String(decoding:as: UTF8.self)` substitutes replacement characters. Either report "unavailable" on invalid UTF-8 or document the limit.
- **S5C-08: View can render up to 1 MB of patch** in `UnifiedDiffView` on the main thread, while the live card deliberately uses a bounded excerpt. Consider a smaller display limit plus "Copy for full".
- **S5C-09: the card re-runs a full merge inspection on every appearance** (`.task(id: operation.id)`). That includes conflict prediction, and it happens on every tab switch. Consider caching the result per operation and `updatedAt`.
- **S5C-10: `requireRetained` only checks path shape.** It never checks that the path is under this session's own store root, so an edited or forked session JSON could point the readers at another `.worktree-merge-reviews/<uuid>/…` tree. It's local-only. A fix is to compare against `dataService.worktreeMergeReviewRetentionParent`.
- **S5C-11: confusing error type** (`AgentSessionDataService.swift:~4843-4851`). `worktreeMergeReviewRetentionParent` throws `AgentScheduledSendMutationError`, so the user sees scheduled-send wording inside the merge error text. Use a merge-specific error or message.
- **S5C-12: misleading replacement reason** (`:431`). `cancelPendingWorktreeMergeReview` runs before the owner capture and retention, so a new request that then fails (frozen, not durable, retention error) still ends the older shown review with the reason "Replaced by newer worktree merge review". Moving the call isn't trivial, because the lifecycle cancel would then withdraw the new request's own reservation. The cheapest fix is a more neutral reason.
- **S5C-13: test gaps.**
  - The `.initialPersistence` await point is never exercised, because the harness always pre-saves.
  - No test covers the S5C-01 entry-guard path.
  - No test covers history alongside a conflict in sidebar attention (S5C-02).
  - No test covers a retention failure on the stored-operation route (S5C-04).
- **Check, not a finding:** the live card's `diffExcerptProvider` in `AgentModeView` now gets paths under `AgentSessions/.worktree-merge-reviews/…`. If that reader restricts paths to `_git_data`, the live card would show "Diff excerpt unavailable". It isn't in this diff, so I couldn't confirm either way.

---

## Blocking status

| Severity | IDs | Blocks the checkpoint? |
|---|---|---|
| P0 | none | — |
| P1 | none | — |
| P2 | S5C-01, S5C-02, S5C-03, S5C-04 | No. Fix if cheap (01–03 are each a few lines), otherwise defer. |
| P3 | S5C-05 through S5C-13 | No. Defer. |

The validation results quoted in the request are fixture and compile-only results, not live runs. I found no fixture assertion that contradicts the implementation.
