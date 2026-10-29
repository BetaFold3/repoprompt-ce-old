# Step 4d3b initial OracleB review

Scope: read when the task touches Step 4d3b live identity review evidence.
Authority: Reference
Last-verified: 2026-10-23

Snapshot: staged 2026-10-23/2349. Returned preset identity verified by main. Verbatim response follows.

# Oracle Review

# Review: Step 4d3b inactive Claude live identity (staged snapshot 2026-10-23/2349)

## Summary

This change adds an inactive, default-off path that gives live Claude output a stable identity:

- **Producer state.** `ClaudeLiveTranscriptProducerState` is created per stdout launch token. It classifies every raw payload of the current launch against an allowlist of the observed O19 output shape. Once a launch is disqualified, it never qualifies again.
- **Evidence.** Qualifying output becomes transient evidence on `AIStreamResult`. Complete-text evidence is attached to the single `content` result. Result agreement and disqualification travel as metadata-only lifecycle carriers.
- **View model owner.** `applyClaudeLiveTranscriptEvidence` runs before any generic mutation. When it accepts, it appends the reader-derived canonical row and its `NativeItem` together, then saves through the existing serialized save. Every refusal clears all Claude envelope proofs in the tab.
- **Reuse, not a fork.** The reader's projection, digest and deterministic ID are reused through `singleTextAssistantRow`, and `semanticMarker` is widened to internal.

What holds up:

- **Gate-off parity is clean.** With the state `nil`, the controller only adds no-op calls, and the view model branch is skipped when evidence is `nil`.
- **Stream and turn ownership are unchanged.** Carriers come before the payload's own results, carry no text or usage, and never mark a turn boundary. The usage and result-completion code is untouched.
- **The latch is keyed correctly.** Qualification follows the stdout token, not consumer resets or turns.
- **Save ordering matches the stated boundary.** The test with an older save in flight covers it.

I found **no P0 or P1 issues** while the feature stays inactive.

## P2

### F1: Clearing every proof on any refusal will disable 4d2 recovery once the flag is on
- **Where:** `AgentModeViewModel.swift` around lines 20121–20190 (`applyClaudeLiveTranscriptEvidence` refusal branches → `refuseClaudeLiveTranscript` → `invalidateClaudeEnvelopeProofs()`).
- **Scenario:** Under the strict allowlist, disqualification is the normal result, not the exception. Any of these disqualifies a launch:
  - a tool-use or thinking turn;
  - a steering message (`overlappingOutbound`);
  - an `allowed_warning` rate-limit event;
  - any `system` payload other than `init`, such as `session_state_changed` (the controller already supports it), `status` or `compact_*`;
  - a malformed line;
  - a send without an outbound UUID (`admittedWithoutIdentity` on a retry);
  - a single legacy proofless row (`hasProoflessClaudeItem`).

  Each of these clears the proofs of **every** Claude row in the tab, including rows the 4d2 reader imported and validated. This happens even when the refused launch never inserted a row. Nothing ever restores a proof, so every later reconcile in that tab fails with `ledgerConflict` and shows `recoveryHistoryChangedText`, even though Claude's history did not change. Your own round-trip test asserts exactly this outcome.
- **Impact:** None today, since the flag is off. If the flag is turned on, Phase 4 recovery effectively stops working for almost every agent tab, and the error text misleads the user. Treat this as an activation blocker.
- **Smallest fix (no new persisted state):** Keep the current conservative scope, but only when a launch could actually have tainted the ledger.
  - Add a transient map on the session from launch token to the ledger keys that launch had accepted.
  - On refusal, clear proofs only if the refused launch accepted something in this tab, or if the refusal is a conflict with an existing ledger entry (the `existing != ledgerItem` branch).
  - For proofless, collision, background and never-accepted cases, refuse without clearing proofs.
  - This stays sound: after a restart the earlier launches are gone, and their rows are still checked against native history by the reader.
- **Alternative:** Keep the current rule and record it as an owner-accepted activation blocker.

### F2: Lines flushed at EOF are never classified
- **Where:** `ClaudeNativeProcessSessionController.swift` around lines 3356–3363. `handleStdoutEOF` sets `activeStdoutLaunchToken = nil` and only then calls `handleLine` on the flushed lines. `currentLiveTranscriptQualification()` (around line 3603) then returns `nil`.
- **Scenario:** If the final stdout record has no trailing newline, its translated results are emitted normally but never classified. A disqualifying final record (for example a `supersedes` or `aborted` assistant, or an error result) never reaches the view model, so an earlier qualified row keeps its proof.
- **Impact:** This breaks the "classify every raw payload" acceptance criterion. Real-world impact is small, because the reader re-checks digests and semantic markers when it imports.
- **Smallest fix:** While the EOF lines are being flushed, let `currentLiveTranscriptQualification` accept the EOF's own `launchToken`. For example, set a private `eofFlushLaunchToken` during the loop. Do not move the existing token clearing, which keeps gate-off ordering the same.

### F3: The history-only merge may overwrite live ledger changes made during a reconcile (unverified)
- **Where:**
  - `AgentTabSession.swift` around line 898: the doc comment still says `providerHistoryRecovery` is "changed only by the history-only merge."
  - The new writers are in `AgentModeViewModel.swift` around lines 20150–20190.
- **Scenario:** `reconcileRecoveryHistory` reads the ledger, waits on file I/O off the main actor, and then sets the merged ledger. If a background `.disqualified` carrier arrives during that wait, its proof clearing, and potentially a live insert, can be overwritten by a merge built from the older snapshot. That would restore the proofs.
- **Why it is unverified:** I could not see the merge's commit-time check in the provided context. If the merge already compares the ledger (or the items plus ledger) before committing, this is not an issue.
- **Fix:**
  - If no such check exists: make the merge bail out or retry when `session.providerHistoryRecovery` changed during the wait, and add a test that injects a disqualification inside the reconcile wait.
  - Either way: update the stale doc comment.

### F4: No test covers the production path from controller to runner to view model
- **Where:**
  - The controller tests stop at `EventsReader`.
  - The view model tests inject results through `test_handleStreamResult` / `test_handleBackgroundNativeStreamResult`.
- **Gap:** Two things are unproven:
  - That attached evidence survives the run service's forwarding. Losing it to a rebuild or coalescing step would fail closed, but would silently disable the feature.
  - That runner consumers of `AIStreamResult.lifecycleType` ignore carriers with `text == nil`. Watchdogs or run-state handling that react to lifecycle results would be a regression that only appears with the flag on.
- **Fix:** Add one lifecycle-harness test that routes a stubbed runtime's events (a content result carrying evidence, plus a disqualification carrier) through the real forwarder into the view model.

## P3

- **F5: `ClaudeLiveTranscriptCompleteText` can hold inconsistent values** (`ClaudeLiveTranscriptQualification.swift` around lines 49–90). `localItemID` and `envelopeDigest` are stored separately from what `canonicalItem` / `singleTextAssistantRow` recomputes. A mis-built instance would append a row whose ID differs from the ledger's `localItemID`.
  - Cheap guard in the owner: `canonicalItem.id == complete.localItemID`.
  - Alternatively, derive both fields in a factory and stop exposing the memberwise init.
- **F6: No check against the tab's own conversation.** The accepted path does not compare `complete.nativeSessionID` with `session.providerSessionID` when the latter is known. Refusing on a mismatch is cheap hardening.
- **F7: A test masks merge behaviour.** In `testClaudeLiveCompleteTextInsertsCanonicalRowOnce…`, `endActiveAssistantSegment` runs before the BRAVO step. Without it, a refused complete text merges into the previous unidentified streaming row. That matches legacy behaviour, but the test should say so in a comment rather than hide it.

## Recommendations

1. **Before activation:** Resolve F1, either by narrowing proof clearing to launches that accepted rows (or to real ledger conflicts), or by having the owner explicitly accept "any disqualification permanently ends 4d2 recovery for the tab." As written, disqualification is the normal result for tool-using sessions.
2. **Cheap now:** Fix F2 (classify EOF-flushed lines with the EOF token) and F5 (ID and digest consistency guard). Update the stale `providerHistoryRecovery` doc comment from F3.
3. **Verify:** Check whether the history-only merge re-checks the ledger after its wait (F3), and add the injected-disqualification test if it doesn't.
4. **Test gap:** Add one test through the runner forwarding path (F4) before any acceptance claim. Until then, the view model owner is proven only through test seams.
5. Nothing found argues against committing this step as inactive. Gate-off parity, latch ownership, ordering and the stated save boundary all hold.
