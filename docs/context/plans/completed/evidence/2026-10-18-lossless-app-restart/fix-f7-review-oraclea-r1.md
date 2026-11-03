# Oracle Review

Scope: read when the task touches lossless restart Step 7-F7 (composer tab ownership and submit-path diagnostics) implementation or review evidence.
Authority: Reference
Last-verified: 2026-10-26

The delta clears stale submit targets when the current tab has no session, expands persistent rejection diagnostics, and strengthens provider-availability and queued-notification assertions. Changes remain focused on F7 and composer observability.

## Review result

**No new findings in the supplied delta.**

- **Non-materializing snapshot:** `AgentModeViewModel+ComposerUI.swift:48–50` produces a nil submit target when the session is absent and `materializingSession` is false. `refreshRecoveryListUI()` publishes that snapshot for the current tab, replacing—not retaining—the stale target.
- **Existing callers:** The flag defaults to `true`, preserving their previous target-generation behavior. The ownership guard remains intact.
- **Logging privacy:** The added calls log diagnostic reasons, routes, and identifiers—not draft text, blocked-message text, or error descriptions.
- **Test sequencing:** Sampling the sync counter after `beforeDelivery()` prevents the synchronous tab-switch setter from satisfying the notification wait.

Reported build, lint, and targeted tests passed; these results were not independently executed. Real activation/workspace-switch sequencing, Tab-tag first-send coverage, and live composer checks remain acknowledged validation gaps, not new findings.

## Recommendations

Accept this delta without another review round. Retain the recorded coverage deferrals and run the planned live composer checks before considering F7 operationally verified.