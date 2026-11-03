# Step 4d3b initial OracleA review

Scope: read when the task touches Step 4d3b live identity review evidence.
Authority: Reference
Last-verified: 2026-10-23

Snapshot: staged 2026-10-23/2349. Returned preset identity verified by main. Verbatim response follows.

# Oracle Review

The changes add an inactive, default-off Claude live-identity path: launch-scoped classification attaches evidence to existing content results, shares the history reader’s identity/digest projection, and persists canonical rows with ledger entries. Owner-side refusals invalidate Claude proofs without changing receipts or cursors. Gate-off behavior appears preserved in the supplied diff, but two error-path gaps can leave proofs valid after disqualifying output. Validation results were supplied, not independently rerun.

## P1 — Should fix

### R1 — Direct disqualification does not notify the canonical owner
**File:** `ClaudeNativeProcessSessionController.swift:3608–3618` (`noteLiveTranscriptOutbound`, `disqualifyLiveTranscript`)

- **Failure scenario:** With qualification enabled, an assistant row has already been qualified and saved. A malformed stdout line then calls `disqualifyLiveTranscript`, but the helper only updates controller state. If no subsequent `user`, `assistant`, or `result` payload arrives, no refusal carrier reaches the owner. Unidentified or overlapping outbound writes have the same notification gap.
- **Impact:** The producer is disqualified, but the tab’s existing Claude proofs remain valid and can be persisted or reused for reconciliation. This is not merely the accepted delay before an invalidation save: no invalidation is requested.
- **Smallest fix:** Emit a metadata-only refusal carrier when an eligible producer transitions to disqualified through these direct paths. Preserve sticky repetition for later payloads and suppress evidence for disabled/ineligible launches.
- **Regression test:** Qualify a row, deliver a malformed line with no subsequent payload, drain events through the owner, and verify proof invalidation. The current malformed-line test checks only the controller latch.

### R2 — EOF draining bypasses qualification for the final buffered payload
**File:** `ClaudeNativeProcessSessionController.swift:3601–3605` (`currentLiveTranscriptQualification`), interacting with `handleStdoutEOF` at `3356–3363`

- **Failure scenario:** `handleStdoutEOF` clears `activeStdoutLaunchToken` **before** flushing remaining framed bytes through `handleLine`. The new qualification lookup consequently returns `nil` for every flushed payload. A newline-free final result contradicting an earlier qualified assistant—or a final retraction/unsupported payload—is still translated and routed without classification.
- **Impact:** The final payload can bypass both result-agreement checking and proof invalidation. This violates the requirement to classify every payload fed to the translator, particularly on the process-loss boundary relevant to restart recovery.
- **Smallest fix:** Keep the exiting launch’s qualification available while draining its buffered tail, then retire it. Preserve token checks so a replacement launch cannot be affected across asynchronous handling.
- **Regression test:** After qualified output, deliver a contradictory or disqualifying final JSON payload without a newline, trigger EOF, and assert that the refusal carrier reaches the owner before qualification is retired.

## Recommendations

Fix R1 and R2 before accepting this inactive step, then rerun the affected qualification, lifecycle, and reconciliation suites. Keep all production activation gates off; neither fix requires a new persistence mechanism or broader provider profile.
