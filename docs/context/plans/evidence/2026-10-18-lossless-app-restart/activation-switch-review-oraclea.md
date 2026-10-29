# Crash-recovery activation switch: OracleA review
Scope: read when the task touches the production recovery activation value and its switch on.
Authority: Reference
Last-verified: 2026-10-29
Covers: OracleA review of the switch from off to Claude Code and Codex

The switch enables production registration for Claude Code standard and Codex, plus same-conversation resume and history reconciliation. In `activation-switch.diff`, the production constant is the only executable production-code change; the remaining changes update comments and tests.

**No P0/P1 findings in the supplied scope.**

The updated tests retain the intended contract:
- Explicitly allow `.continueWithText`, `.sendSaved`, `.questionAnswerAsInput`, and `.reconcileOnly`.
- Explicitly reject `.continueInNewConversation`; the `allCases` set comparison also catches unintentionally enabled actions.
- Keep `freshClaudeConversation`, `safeRestart`, and native Claude fresh-session IDs disabled.
- Preserve inactive-registration refusal and XCTest’s absent production registry.
- Update production-dependent availability and baseline-capture assertions consistently.

No updated comment contradicts the supplied code or live-check report.

### P2/P3 — Minor

- **P2 — `Tests/RepoPromptTests/AgentMode/Recovery/AgentProcessRegistryTests.swift:100`:** `testProductionActivationStaysOffAndInactiveRegistryRefusesReservations` now asserts production is enabled. Rename it to reflect subset activation and inactive-registry refusal.

## Recommendations

No blocking changes identified. Rename the stale test and run the affected recovery suites before merging; this review used only the supplied text and did not execute tests.