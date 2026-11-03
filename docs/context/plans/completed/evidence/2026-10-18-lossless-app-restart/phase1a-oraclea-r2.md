# Phase 1a final review — OracleA

Scope: read when the task touches lossless restart Phase 1a review evidence.
Authority: Reference
Last-verified: 2026-10-20

Preset identity verified: `61D024A4-CCFB-4C9C-A614-CC65E0A1864C` (OracleA). Final re-review round 2/2; code inspection, not independently executed validation.

The round-2 delta restores the pre-existing window-close debounce behavior while retiring only the new maximum-wait obligation, adds a one-second floor exclusively for already-expired rebased deadlines, and strengthens the save-before-activation regression test with post-activation comparisons against original stored input. Test timer cleanup is now explicit, and the guardrail changes remain exact-path additions for review evidence.

## Review result

**No actionable regressions found in the prior-round → current delta.** This is a scoped approval of these fixes, not a fresh review of all Phase 1a changes.

- **Window-close debounce preservation — `AgentModeViewModel.swift:3835–3838`.** Replacing `cancelTranscriptSaveTimers(session)` with `clearTranscriptSaveMaxWait(session)` removes the confirmed cancellation regression without introducing a lifecycle flush. The supplied `cancelEphemeralRuntimeState()` leaves `saveDebounceTask` untouched. Workspace discard still cancels both timers. The revised test checks positive persistence through the pending debounce after teardown and verifies that delivering the obsolete maximum-wait wakeup does not start a save. The existing close flag prevents subsequent mutations from arming a new obligation.

- **Expired rebase handling — `AgentModeViewModel+TranscriptSaveMaxWait.swift`, `rebaseTranscriptSaveMaxWait` / `rebasedTranscriptSaveDeadline`.** The implementation preserves `capturedAt + 10 seconds` whenever it remains future, including when less than one second remains. At equality or after expiry, it instead returns `completedAt + 1 second`. The deterministic boundary assertions cover both sides and exact equality. This fixes immediate expired-deadline wakeups without extending valid healthy-write deadlines.

- **Save-first activation regression — `AgentModeChatSwitchActivationTests.swift`, `testSaveBeforeActivationCatchUpReconcilesOnlyGeneratedToolSummaries`.** The added real foreground activation checks owner reuse, provider/run state, synchronization, and unchanged reconciled items. Transcript, projections, counts, visible-row count, and analytics are compared with a reference rebuilt from the original stored items—not the potentially changed in-memory items. Earlier strict durable-item comparisons remain intact.

- **Held timer cleanup — `AgentModeChatSwitchActivationTests.swift`, `HeldSaveTimers`.** Cleanup cancels session timer tasks before releasing held sleeps. The helper also rejects sleeps that start after closure, replacing the long sleep without leaving suspended continuations indefinitely.

The reported 13/13 focused tests and combined 283-test run support these conclusions. I reviewed the supplied code and snapshot differences only; I did not independently execute tests or inspect job artifacts. These results do not establish live-close, crash/restart, packaging, or release durability.

## Recommendations

Accept this round-2 delta and close this review lane with no open findings. Keep lifecycle durability explicitly deferred to Phase 1b; preserving a pending debounce restores existing behavior but is not an awaited close-time durability guarantee. No further minor-polish review round is warranted.
