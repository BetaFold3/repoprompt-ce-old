# Restart fix F5obs — OracleA initial review
Scope: read when the task touches restart-spec Step 7-F5obs review findings (quit-failure dialog and shutdown phase logging).
Authority: Reference
Last-verified: 2026-10-26

Covers: OracleA fresh-chat initial review of the F5obs diff (review mode, explicit slices incl. review policy). Verbatim export follows.

# Oracle Review

The change adds persisted, request-correlated shutdown diagnostics covering termination entry, Stage A progress, deadlines, failure dialogs, choices, and completion. It also adds regression tests for suspended composer preparation, stalled teardown, repeated quit requests, and late completions. The supplied diff preserves the deadline policy, user-choice wait, quit blocking, and dialog text.

## Findings

No actionable findings in the supplied diff and context.

- **Behavior:** No additional suspension points or reordered shutdown operations. The participant-loop snapshot preserves the original iteration semantics, and the existing attempt and presentation fences remain intact.
- **Privacy:** Logged fields contain identifiers, counts, booleans, and controlled tokens—not blocker messages, session titles, drafts, paths, or credentials.
- **Diagnostic accuracy:** Dialog-stage precedence matches the alert builder, including unresolved relaunch helpers and clean-exit acknowledgement. Unified-log timestamps supply phase timing.
- **Tests:** The additions cover unchanged deadlines under repeated requests, the expected Stage A/B timeout prompts, and rejection of late completion. The composer test exercises the real view-model preparation path; the coordinator tests use controlled timing.

Validation results are implementer-reported, not independently rerun. Persisted-log readback demonstrates test-process logging, not live-app quit behavior.

## Recommendations

Accept F5obs on the supplied evidence. Keep the underlying F5 diagnosis open until an owner-approved live reproduction provides the shutdown trace and screenshot; this change improves observability rather than establishing the original hang’s cause.