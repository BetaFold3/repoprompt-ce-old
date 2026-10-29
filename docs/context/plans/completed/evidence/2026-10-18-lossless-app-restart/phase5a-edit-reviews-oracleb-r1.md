# Step 5a R1 — OracleB

Scope: read when the task touches the bounded edit-review repair, regressions or final review disposition.
Authority: Reference
Last-verified: 2026-10-23

Snapshot 2026-10-23/1514, nine-file/+471/-140 repair against unchanged initial staged tree c1d037631854b7d4bd6ef9d2cd5ac64378e4b543. Both fresh independent lanes sent together with the same code/patch/validation and verbatim policy. Each received only its own open P0/P1 verbatim and dispositions; the lane without open P0/P1 checked delta regressions only. Returned explicit preset 7CDD523E-1D7C-47EA-98FE-D5FEA24D2D8C / OracleB matched before synthesis. Main read the complete response. This is the first re-review round; implementation ticket labels are not review rounds. Raw body below preserves all text with trailing-whitespace normalization only; original export remains local.

# Oracle Review



# Step 5a R1 re-review: fix delta and regressions only

**Verdict: no P0 or P1 regressions in the delta.** I found four new items, all P2/P3. None needs another review round.

## What the delta does

- **Owner capture before awaits.** The review's recovery owner is now captured synchronously in a new `mcpCaptureApplyEditsReviewOwner`, before the new awaits (canonical target, preview, ticket). Under mandatory admission, a missing session now fails closed. `mcpAdmit…` only re-checks that frozen owner and never adopts a replacement.
- **One canonical target.** Recovery-tracked reviews resolve one canonical absolute target, either the existing file or a create destination. The preview, the stored proposal and the accepted write all use it. The create resolver was split into `resolveCreation` and `creationTarget` without changing how `createFileWithPostcondition` behaves.
- **Store order.** The store now checks the reset generation before the "already started" shortcut.
- **History View.** View checks the stored absolute path against the visible roots and says so neutrally when the file is outside them.
- **Smaller fixes.** View clears the previous comparison, Discard uses the catalog item, the unused typed decision mapping was removed, the failed-`applicationStarted` path tries to revert to `pending`, and the heading/detail text was reworded.

## Checks that found no regression

- **Create resolver split.** `.literalPreferredIfStronger` still returns `literal` before the folder/exists checks, and `createWithPostcondition` still runs all the post-checks.
- **Untracked path.** When `recoveryOwner == nil`, the preview and write still use `effectivePath`, so behavior is unchanged.
- **Target changes between resolution and preview.** All four combinations of (`existingTarget` set or nil) × (`preview.exists` true or false) are handled. The two that disagree fail closed in `canonicalReviewTarget` before any ticket, commit or card.
- **Store reorder.** Only an earlier-generation proposal is affected, and no live caller sends `applicationStarted` for one.
- **Failed `applicationStarted` commit.** `revertApplicationNotStarted` sets `isFinished` before its await and always ends the live state. If the revert also fails, the state stays `pending`, which `testFailedApplicationStartedCommitRefusesTheWrite` covers.
- **`.task(id:)` reset.** It clears the row's own `@State` before the guard, and the `rowID == row.id` fence is unchanged.
- **Discard via catalog item.** Same `reviewID`/`sessionID` as the old string parsing. It is now stricter, because a row that has left the catalog is refused.

## P2

### R1-P2-1: A known-unwritten edit can be reported as "Edit may have been applied" after a reset or shutdown race
- **File:** `AgentModeViewModel+EditProposalRecovery.swift`, `revertApplicationNotStarted` (~L262) and its callers after the `applicationStarted` commit.
- **Scenario:** `applicationStarted` commits. Then, during the ticket-check hop, a `clearChatPreservingRecovery` or shutdown freeze retires the lane. The revert goes through the retired `lane` and fails, so the record stays `applicationStarted`.
- **Impact:** The row says "Edit may have been applied … uncertain", but the code knows nothing was written. The user may check or undo a change that never happened. Nothing is lost, it is honest about uncertainty, and the window is a single actor hop, so this is P2 at most.
- **Pinned by test:** `testResetOrCancellationAtEachNewAwaitWritesNothing` now asserts this outcome for `(.reviewTicketCheck, .reset)`.
- **Smallest fix:**
  - When the admitted lane can't take the revert, retry once through `admission.session?.recoveryLane` if it has the same `sessionID` and incarnation.
  - `.applicationNotStarted` is not checked against the reset generation, and `writableRecord` accepts a higher-generation binding, so the successor lane can clear it.
  - Then update the test expectation to `.pending`.
  - Alternatively, accept it and record it as deferred.

## P3

### R1-P3-1: Agent-facing diff and error paths become absolute for tracked sessions only
- **File:** `MCPApplyEditsToolProvider.swift`, `previewRequest` (`path: existingTarget ?? effectivePath`).
- **Cause:** The preview runs with the canonical absolute path. As a result:
  - `previewResult.unifiedDiff`, which goes back to the agent through `editSummary(... unifiedDiff:)`, now has the absolute physical path in its header.
  - `ApplyEditsError` messages may also show the absolute path.
- **What is unaffected:** The card diff uses `displayPath`. Untracked sessions still show `effectivePath`.
- **Impact:** Cosmetic. The tool output now differs between tracked and untracked sessions.
- **Fix:** Either leave it, or rebuild the reply's verbose diff with `effectivePath`/`displayPath` (the card already does this). The path the write targets must stay absolute.

### R1-P3-2: `resolveCreateDestination` doesn't fully match its "same refusals" doc
- **File:** `WorkspaceFileMutationService.swift`, `resolveCreateDestination` / `resolveCreation`.
- **Cause:** The default policy is `.literalPreferredIfStronger`, and its literal branch returns early. The scope, folder and already-exists refusals run only later, in `createWithPostcondition`. So this new package API can return a destination that the real create would refuse.
- **Who is affected:** Not the provider, which uses `.canonicalAliasFirst` after a preview that showed the file doesn't exist. It is a trap for any future caller.
- **Fix:** Either narrow the doc ("resolution only; create-time refusals still apply"), or run the folder/exists checks on `absolutePath` inside `resolveCreateDestination`.

### R1-P3-3: Capture moved ahead of the preview, so refusals now come first
- **File:** `MCPApplyEditsToolProvider.swift`, owner capture (~L181).
- **Scenario:** A no-op edit (`editsApplied == 0`) or an invalid edit, on a tab whose owner can't be captured (mandatory admission with no session, shutdown freeze, binding mid-transition). The caller now gets the recovery refusal instead of the no-op summary or the preview error. `requireTargetWindow()` also moved earlier.
- **Impact:** Only the order of error messages changes; nothing is written either way. This is the intended fail-closed behavior, and the ordering source-guard test covers it.
- **Fix:** None needed. At most, mention it in the step notes.

## Not re-raised
Retention and growth, the generic rename, the bounded viewer, the source-order guard not being an end-to-end test, external file-writer races, and nested or overlapping roots are all already deferred or out of scope, and I didn't loop on them. The last one only matters if absolute-path lookup turns out ambiguous for overlapping roots, and it already fails closed through `canonicalReviewTarget`.
