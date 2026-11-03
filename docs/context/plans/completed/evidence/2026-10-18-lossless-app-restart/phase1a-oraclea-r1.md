# Lossless restart Phase 1a — OracleA revised-contract review

Scope: read when the task touches Phase 1a's revised receipt-based deadline and validation-test correction review.
Authority: Reference
Last-verified: 2026-10-20

Fresh review identity verified for OracleA. This round reviews newly introduced receipt-based scheduling behavior and the validation correction, not a minor-polish-only loop. See [Phase 1a evidence](phase1a.md) for disposition.

## Verbatim review

The A→B delta replaces immediate rewrites after covering stale saves with a deadline anchored to the **pre-call monotonic instant**, while retaining conservative handling for failed, deferred, reset-only, and obsolete saves. It also preserves obligations during removal reservations, cancels teardown timers, and separates cold-activation observation testing from deterministic save-before-catch-up integrity coverage.

**No new P0/P1 findings identified in the supplied delta.**

### Data-safety assessment

- **Receipt-based rebasing:** In `AgentModeViewModel+TranscriptSaveMaxWait.swift`, `serviceTranscriptSaveMaxWait` checks owner/task generation after suspension before considering rebasing. `staleWriteCoversCapture` then requires covering source/mutation counters, current context, hydration authority, and unchanged existing binding/transition generation. Combined with the shown synchronous payload/token construction in `saveSessionDetailed`, the pre-call instant is a conservative lower bound for remaining unsaved mutations—not a completion-time extension.

- **Non-covering outcomes:** Failed writes retain the obligation and retry; deferred saves wait and recheck ownership; reset acknowledgements do not qualify as covering writes. Binding replacement or teardown invalidation prevents the old service loop from rebasing or scheduling follow-ons. The first-binding exception is consistent with preserving a creator’s obligation.

- **Reservation and teardown changes:** Parking removal reservations avoids losing the obligation when removal aborts. Fixed one-second authority polling does not introduce write attempts without authority. Timer cancellation is consistent with the explicitly deferred lifecycle-flush responsibility; it does **not** establish durable shutdown behavior.

### R1 — Validation disposition

**Resolved for this review’s scope.**

`AgentModeChatSwitchActivationTests.swift` preserves the existing catch-up, provider-stamp, and transcript-integrity assertions; the changed hydration gate establishes their observation precondition rather than weakening them.

The new save-before-catch-up regression separately exercises real hydration followed by foreground saving. Its memory comparison permits only removal of an exactly generated `summary_text` from a summary-only JSON object, with the rest of that object unchanged. IDs/order and other encoded fields remain checked. The durable comparison disables that exception entirely. The supplied runtime/storage policy excerpts support this distinction.

This resolves the validation gap without claiming that the original failure was a baseline flake or establishing Phase 1a’s effect on ordering frequency. The deliberately failing strict diagnostic remains diagnostic evidence, not a passing test.

Validation results are **reported evidence supplied in the request**, not independently executed here.

## Recommendations

Proceed with this lane’s A→B review approved and no open P0/P1 findings. Before committing, complete the other required review, inspect the full staged diff, and rerun the required staged checks. Keep crash/restart and durable lifecycle guarantees explicitly pending Phase 1b; this approval does not certify them.
