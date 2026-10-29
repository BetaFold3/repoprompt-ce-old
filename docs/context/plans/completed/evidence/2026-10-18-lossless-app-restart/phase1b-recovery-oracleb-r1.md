# Recovery transactions — OracleB re-review 1

Scope: read when the task touches lossless restart recovery transaction and lifecycle-gate review evidence.
Authority: Reference
Last-verified: 2026-10-21

Verified preset: OracleB. Source review; no live validation.

# Phase 1b recovery transactions: re-review round 1 of 2 (OracleA lane)

## Summary

The fixes for my P1 (F-1) and for F-2, F-3, F-5 and F-6 are adequate. I found no regression that is P0 or P1 under the review policy.

- **Held composer protection.** A composer saved under an older reset generation is now protected at the store, which is the layer that matters:
  - `commitComposer` refuses to replace or remove it, even when the composer revision matches.
  - `insertIntent` never consumes it.
  - The controller keeps it out of `durableComposerRevision`, so `consumption(for:)` can't name it.
- **Restore baseline.** The restore baseline is now learned inside the serialized operation, so a `.superseded` restore no longer leaves the controller without a baseline.
- **Managed images.** Re-importing an image that is already in this session's managed storage references it in place instead of copying it.
- **Run evidence.** Run evidence from another session's run is rejected before any read or write.

The minimal refusal option (b) has a known cost: new-generation drafts can't be saved until something resolves the held draft. That is acceptable while nothing is active, but it must be a gating item for the production cutover (N-1).

## Disposition of my initial findings

| ID | Was | Status | Evidence |
|---|---|---|---|
| F-1 | P1 | **Closed** | **Store write:** `commitComposer` throws `heldComposerUnresolved` whenever the stored composer's generation differs from the binding's. This check runs before the composer CAS and before the unchanged shortcut, so neither a matching `expectedComposerRevision` nor `snapshot: nil` gets past it.<br>**Store submit:** `insertIntent` consumes only when `stored.transcriptResetGeneration == binding.transcriptResetGeneration`.<br>**Controller:** `applyRestoreRead` sets `durableComposerRevision = nil` and `heldComposerRevision = stored.revision`. `performSubmission` and `writePending` keep the held revision separate.<br>The store guard is sufficient on its own, so a producer that passes a held revision into `init(durableComposerRevision:)` still can't destroy it.<br>**Tests** cover held→type, held→clear, held→submit (queued and direct), an unaware controller, and a fresh-store reload. |
| F-2 | P2 | **Closed** | `applyRestoreRead` runs inside `serialized`, sets the baseline before the `.superseded` guard, and still applies the incarnation and generation fences. A later `writePending` reads `durableComposerRevision` when it runs, so it uses the learned baseline. Covered by `testTypingDuringRestoreOfStoredComposerLearnsBaselineAndLaterFlushSucceeds`. |
| F-3 | P2 | **Closed** | `managedFileName(of:sessionID:)` resolves both sides the same way and requires that the parent directory match and the name be safe. A missing managed file gives `attachmentUnavailable` and is never re-created. Another session's managed file is still copied. The id, title and `createdAt` are carried through, so a re-imported reference compares equal and the controller's equality check returns "unchanged". |
| F-4 | P2 | **Closed** | All three gaps now have tests, plus tests for unknown fields on retained entities and for a foreign run owner. |
| F-5 | P3 | **Closed** | `writePending` trims `..<index` only on success. I checked the reordering cases (a stale submission after a trim, and a pending write serialized before a submission), and in each one `consumption(for:)` gives the same answer. |
| F-6 | P3 | **Closed** | `requireOwnership` runs in `ensureRunAttempt` (before `writableRecord`), `attachDeliveryAttempt` and `recordRunTerminal`. A `persistentSessionID` of `nil` is rejected. |
| F-7 | P3 | Deferred, accepted | Documented. See also N-3. |
| F-8 | P3 | Deferred, accepted | The non-reentrant call rule is now documented on `AgentRecoveryLifecycleGate`. |

## Regression check on the new code

- **Merging unknown fields** (`preservingUnknownMembers`):
  - It runs only for the same generation. Images and tagged files are matched by id, and the workflow by source.
  - An entity the new snapshot omits loses its unknown fields along with it, and the test proves those fields don't move onto another entity.
  - The encoders write known fields after copying the unknown ones, so a carried-over unknown field can't override a known one.
  - The decoder marks absent optional keys as consumed, so a known optional key never ends up stored as an unknown field. The merged record therefore still round-trips exactly. I don't see a way for this path to produce a record the codec would later preserve as unreadable.
- **`intentReceipt`:** when no composer is stored, both `composerRevision` and `heldComposerRevision` are `nil`, which is correct.
- **Generation ordering:** `writableRecord` rejects a binding older than the record, and the codec rejects a composer newer than its record. So "other generation" can only mean "older generation", and the refusal can't be reached from a stale direction.

## New findings

### P2

**N-1: A live reset with a saved draft blocks all composer saves until a resolution API exists (cutover gate)**

- **Scenario:**
  1. The user has a non-empty, saved draft in the composer.
  2. The user resets the transcript in the same app launch.
  3. The producer rebinds a gen-1 controller. The stored composer is still gen 0.
  4. From then on, every `writePending` fails with `heldComposerUnresolved` until something resolves the held draft. The text is usually still in the live composer, so this isn't silent loss. But the 2-second durability bound is gone for that session, and `lastWriteFailure` stays set.
- **Status:** Can't happen while the package is inactive. You've already listed resolution as a prerequisite.
- **Ask:** Put this on the step's status line (`deferred:` or `assumed:`) as an explicit blocker for the cutover, not just in prose.
- **Smallest fix when the cutover lands:** add a gated store call `resolveHeldComposer(binding:, revision:, disposition: .discard | .carryForward)`.
  - `.carryForward` re-labels the snapshot to the binding's generation and keeps its revision and content, so the controller can adopt it as its baseline.
  - The live reset-rebind path calls `.carryForward` before the new controller's first write.
  - The restart path presents the held draft to the user.

### P3

**N-2: The controller never clears `heldComposerRevision` after a successful composer write**

- **Why it's safe to clear:** `commitComposer` only succeeds when the stored composer was nil or from the same generation. So after a `.committed` or `.unchanged` receipt, no held composer exists.
- **Problem:** Today this can't be reached, because nothing removes a held composer except deleting the session. Once N-1's resolution API exists, the controller would keep reporting a stale held revision until the next submission or restore.
- **Fix:** set `heldComposerRevision = nil` in the success branch of `writePending`. It's one line.

**N-3: A write queued before the first restore read still fails terminally**

- **Scenario:** The user types before `loadRestorableComposer` has been queued, and a composer is already stored. The first write then fails with `composerRevisionConflict(expected: nil, …)`. The restore learns the baseline right after, but no retry is scheduled (the F-7 behaviour), so the draft is saved only on the next edit or flush.
- **Fix (cheapest is a producer contract):** call `loadRestorableComposer()` before forwarding any edits, or pass the discovered baseline to `init`. Write this down next to the gate's call-discipline note.

## Recommendations

1. F-1 through F-6 are closed, and no P0 or P1 is open for this lane. From this lane's side, the step can be committed once the signing block is cleared.
2. Record N-1 on the status line as a prerequisite for the production cutover: held-composer resolution with discard and carry-forward, where the live reset-rebind uses carry-forward. It must land in the same change as, or before, any producer that builds this controller.
3. Apply N-2 now if convenient (one line, no re-review needed under the policy). Otherwise list it as deferred.
4. Add the N-3 restore-before-edits rule to the deferred producer contract, alongside F-7 and F-8.
5. No round 2 is needed for this lane.
