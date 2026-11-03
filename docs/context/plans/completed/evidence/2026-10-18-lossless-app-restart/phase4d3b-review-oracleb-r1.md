# Step 4d3b OracleB re-review 1

Scope: read when the task touches Step 4d3b live identity review evidence.
Authority: Reference
Last-verified: 2026-10-24

Snapshot: repair 2026-10-24/0010. Returned preset identity verified by main. Verbatim response follows.

# Oracle Review



# Step 4d3b re-review 1: OracleB lane, regression check of the delta

## Summary

The delta makes six repairs. Producer-side (`emitDirectLiveTranscriptDisqualification`):
- A refusal that comes from outside payload classification (an undecodable line or payload, an unidentified or overlapping outbound message) now sends one metadata-only carrier right when the producer becomes disqualified, but only if it was eligible. The sticky repeats on `user`/`assistant`/`result` payloads are unchanged.
- The stdout tail that is still buffered when the process exits is now classified under the exiting launch's own token (`liveTranscriptEOFDrainLaunchToken`). After the drain, the producer is retired only if the token matches.
- A replacement launch installed during that drain starts disqualified (`launchDuringDrain`).
- A fatal decode failure refuses the producer before the shutdown `await`.

Owner-side, `applyClaudeLiveTranscriptEvidence` adds three cheap guards:
- the evidence must be the reader's exact projection (`matchesProjection`);
- it must belong to the tab's known `providerSessionID` (nil or empty means unknown);
- `canonicalItem.id == localItemID`.

The rest is a corrected doc comment on `providerHistoryRecovery`, one clarifying test comment, and two test additions: direct, overlapping and EOF-tail refusals at the controller level, and one end-to-end path through controller, translator, events stream, integrated runner, run service and view model.

I found **no P0 or P1 regressions**. Notes on the repairs I checked:
- **F2 (fixed).** The token selection `liveTranscriptEOFDrainLaunchToken ?? activeStdoutLaunchToken` is correct for the only reentrant path, the fatal decode → `failProtocolAndShutdown` suspension. `handleLine` → `routeInboundMessage` doesn't suspend on any other branch.
- **Replacement during drain.** A replacement launch can never be read or written by the old drain: the state's token doesn't match, so `currentLiveTranscriptQualification()` returns nil. Retiring by matching token keeps the replacement's state.
- **F3 (confirmed).** `RecoveryActions` line ~1157 compares `session.providerHistoryRecovery == ledgerAtStart` after the awaits. A live insert or invalidation during a recovery read therefore fails closed ("session changed… Nothing was imported") and can't be overwritten.
- **Direct carriers never double-emit.** The `wasQualifying` check is a transition test, and the repeated case is covered.
- **F1 is still an open activation blocker,** not owner acceptance. The delta doesn't change it.

## P2

**R1-P2-1: The conversation guard adds a new trigger for clearing every proof in the tab**
- **Where:** `AgentModeViewModel.swift` ~20129: `session.providerSessionID.map({ $0.isEmpty || $0 == complete.nativeSessionID }) ?? true`
- **Failure scenario:** The tab's `providerSessionID` is still the previous conversation when the first qualified assistant of a new or forked one arrives. This can happen if a resume reports a new `session_id`, an explicit new-conversation path leaves the old ID in place, or the update lags the event order (`claudeAuthoritativeEventSourceID` deliberately refuses to let some streams overwrite it). The mismatch calls `refuseClaudeLiveTranscript`, which runs `invalidateClaudeEnvelopeProofs()` across the whole ledger.
- **Impact:** Nothing today; the feature is inactive. At activation, this is a fail-closed path that destroys every existing Claude proof because of tab-state lag, not because the output contradicted anything. It falls under the already-BLOCKED "conservative all-tab proof clearing" item, but it is a new way to reach it.
- **Fix:** No change now. Add it to the activation checklist: before activation, either confirm that `providerSessionID` is updated in stream order before any assistant (resume and fresh), or make a conversation mismatch refuse only identification (insert into `claudeLiveTranscriptRefusedProducers`, return false) without invalidating proofs.

## P3 (listed, not looped on)

- **R1-P3-1: The projection is computed three times and one guard is redundant.** In `ClaudeLiveTranscriptQualification.swift` and `AgentModeViewModel.swift` ~20129–20133, `matchesProjection`, `canonicalItem` and the `canonicalItem.id == localItemID` check each call `singleTextAssistantRow`. The ID check is already implied by `matchesProjection`, unless `item(for:)` remaps the ID. A single helper would do one projection, e.g. `var verifiedCanonicalItem: AgentChatItem? { guard let row = …, row.localItemID == localItemID, row.envelopeDigest == envelopeDigest else { return nil }; return ClaudeSessionHistoryReader.item(for: row).flatMap { $0.id == localItemID ? $0 : nil } }`.
- **R1-P3-2: `launchDuringDrain` can stay silent.** Suppose the replacement's `resolveLiveTranscriptEligibility` runs while the old drain is still suspended. `currentLiveTranscriptQualification()` returns nil, so the replacement stays `.pending` for its whole launch and never sends a carrier, not even sticky repeats. This is harmless because nothing can qualify and the old producer already refused directly on the fatal path. It's worth one sentence in the `installLiveTranscriptQualification` comment so nobody later reads it as "owner is always told".
- **R1-P3-3: A nested drain can clear the token early.** If a replacement's own stdout EOF drains while the outer drain is still suspended, the inner drain sets `liveTranscriptEOFDrainLaunchToken = nil` before the outer one finishes. The outer drain's remaining tail then falls back to `activeStdoutLaunchToken`, which is nil, so it isn't classified. This is benign since the outer producer is already disqualified, and it's covered by the "source reasoning only" caveat. A comment would do; no change needed.
- **R1-P3-4: Two test timing hazards on a noisy host.** `EventsReader.drainToEnd()` has no upper bound: if EOF ever stops finishing the stream, the test hangs instead of failing. The end-to-end test's `XCTWaiter.fulfillment(of:timeout: 1)` may also be tight on a shared host. Consider wrapping `drainToEnd` in a bounded task and raising the timeout to about 5s.

## Validation notes

- The reader suite (35/35) and reconciliation suite (45/45) ran before the last controller/enum change. The final compile covers the new enum case for any exhaustive switch, so the risk is low, but both are cheap: rerun them with the docs, guardrail and pre-commit checks before committing, and record them as rerun rather than carried over.
- All new coverage uses fixtures and synthetic launches (no subprocess or provider). Describe it that way in evidence.

## Recommendations

1. **Commit is unblocked from this lane.** Nothing P0 or P1 is open, and no contest is pending.
2. **Before committing,** rerun the reader and reconciliation suites, then the planned docs, guardrail and pre-commit checks.
3. **Record R1-P2-1 under `deferred:`** as an activation-checklist item next to the existing BLOCKED items. Those items (broad tool/thinking/resume qualification, all-tab proof clearing, the pre-save crash window, production activation, and F1) stay blocked for the owner.
4. **Apply R1-P3-1 and R1-P3-4 now if they're cheap** (a few minutes each); otherwise defer them. R1-P3-2 and R1-P3-3 only need comment updates.
5. **Don't schedule another review round** for these P2/P3 items.
