# Recovery transactions — OracleB re-review 2

Scope: read when the task touches lossless restart recovery transaction review evidence.
Authority: Reference
Last-verified: 2026-10-21

Verified preset: OracleB. Source review; no independent execution.



# OracleA lane, re-review round 2 of 2: recovery transactions (inactive)

## Summary

This round changes one thing in the source. Inside the serialized submission, `effectiveConsumption` adds a restore-learned baseline (`restoredBaselineRevision`) to the cutoff captured when the submission was called. It does this only while that baseline is still `durableComposerRevision`.

- **N-2** is done: a successful write clears `heldComposerRevision`.
- **N-3** is done: the restore-before-edits rule is now written on the controller.
- **New tests** cover the race where a queued or direct submission is enqueued during a paused restore. A negative control shows they fail without the fix.

I traced the new state through every operation that changes it and found no regressions. My round-1 findings stay closed. **No P0 or P1 is open for this lane**, so this step's review loop is done from my side.

## Disposition of my round-1 items

| ID | Status | Evidence |
|---|---|---|
| N-1 (P2, gates the cutover) | Still deferred, accepted | Held-draft resolution is still listed as pending. It must stay on the step's `deferred:` line as a prerequisite for the production cutover. |
| N-2 (P3) | **Closed** | `writePending` success sets `heldComposerRevision = nil`. That is correct for both `.committed` and `.unchanged`, because `commitComposer` only gets past the held-generation check when no held composer is stored. The tail of `testHeldDraftSurvivesNewGenerationTypingAndFlushAcrossReload` tests it, using a record edit as a stand-in for a future resolution. |
| N-3 (P3) | **Closed** | The class doc now says producers must call `loadRestorableComposer()` before edits, or pass the baseline to `init`. It also says a submission queued behind the restore is covered by `effectiveConsumption`. |

## Regression trace of `restoredBaselineRevision`

| Where it's set or cleared | Behaviour | Safe? |
|---|---|---|
| Restore, same generation | Set only when the stored revision is not in `issuedRevisions` | Yes. Under the single-writer contract, a revision this controller didn't issue was stored before any of its own writes, so it is older than any edit being submitted. |
| Restore, held composer | Cleared to `nil` | Yes. A held draft can never be consumed (the store also checks the generation). |
| Restore failure | Left as is | Yes. Durable state didn't change. |
| `writePending` success | Cleared | Yes. The stored composer is now one this controller issued. |
| `writePending` failure | Kept | Yes. The store didn't change. If it changed elsewhere, the store's check on `stored.revision` rejects the consumption. |
| `performSubmission` success | Kept only if the receipt's composer revision still equals it | Yes. After a consumption it becomes `nil`, so it is cleared. |
| `effectiveConsumption` | Adds the baseline only, and only if it is still durable and not already in the call-time set | Yes. It never adds a revision issued after the call, so R2 in the race can't become consumable. |

Other paths I checked:

- **Restore finished before the call.** `consumption(for:)` already includes the non-issued durable revision, so the `!contains` guard makes `effectiveConsumption` a no-op.
- **Trimmed `issuedRevisions` entries.** A trimmed self-issued revision could later look "non-issued" to a restore. Trimming only removes revisions at or before a committed or submitted one, so any such revision is still older than any later submitted edit. Consuming it is correct.
- **Ordering in the race test.** The test counts on `enqueuedOperationCount`. `serialized` increments it synchronously on the main actor before its first suspension. So once the count goes up, the submission is on the chain and its call-time cutoff predates R2. The test is deterministic.

## Findings

### P2

**A2-1: The baseline argument assumes one controller per session, but no code enforces it**

- **Scenario:** Two controllers are alive for the same session, for example an old controller not torn down during a future tab rebind.
  1. Controller A's restore is paused in the gate.
  2. The user types R1 in A and submits it.
  3. Controller B writes R0′ before A's gated read runs.
  4. A's restore learns R0′ as a non-issued baseline, and the submission consumes it, even though R0′ is newer than R1.
- **Impact:** B's newest draft is silently dropped from durable storage. It can't happen today: nothing builds the controller, and the class doc already states the single-writer contract.
- **Evidence:** `restoredBaselineRevision` doc ("Under the single-writer contract…"), `applyRestoreRead`, `effectiveConsumption`.
- **Smallest fix:** Add "exactly one live controller per session at a time; tear down the old one before building a new one" to the producer-contract list for the cutover, next to N-1, N-3, F-7 and F-8. No code change now.

### P3

**A2-2: `testRestoredBaselineNeverAddsANewerStoredRevisionToConsumption` doesn't test the baseline guard its name describes**

- **Why:** After `flush()`, the stored revision is R2, and R0 is no longer stored at all. Even if `effectiveConsumption` added `restoredBaselineRevision` unconditionally, nothing would change, because R0 isn't the stored composer.
- **What it does catch:** a naive fix that adds whatever is durable when the submission runs. That is still worth keeping.
- **Fix:** Rename it to something like `…NeverConsumesANewerSelfWrittenRevision`, or add a comment saying what it catches. Testing the guard itself would need a second writer, which the contract forbids, so no new test is warranted.

**A2-3: Some doc comments no longer match the code**

- **`submitQueued`:** it still says it consumes "only if it is the submitted revision or one this controller issued before it". It now also consumes a durable or restored revision this controller didn't issue.
- **`enqueuedOperationCount`:** it's a test-only counter in a production type. It's internal and costs nothing, and it is documented as test observability. That's fine, but it is a hook, so the summary's "No new … hook" claim is slightly off.
- **Fix:** one-line doc edits. Per policy, no re-review is needed.

## Recommendation

- No P0 or P1 is open. From this lane's side the step can be committed once the signing block is cleared.
- Status line suggestion: `deferred: N-1 held-draft resolution (cutover gate); A2-1 single-controller-per-session contract; F-7/F-8/N-3 producer contract; A2-2/A2-3 doc/test naming`.
