# Crash-recovery activation switch: OracleB review
Scope: read when the task touches the production recovery activation value and its switch on.
Authority: Reference
Last-verified: 2026-10-29
Covers: OracleB review of the switch from off to Claude Code and Codex



# Review: crash-recovery activation switch (`.off` → `.claudeAndCodex`)

## Summary

The diff changes one line of behaviour: `AgentRecoveryActivation.production` goes from `.off` to `.claudeAndCodex` (`AgentRecoveryActivation.swift:43`). The other `Sources` edits are comments only, in `AgentRecoveryActivation.swift`, `AgentProcessRegistry.swift` and `AgentModeViewModel+RecoveryActions.swift`. Four test files used to pin production as OFF and now pin the new contract.

- **Actions are pinned exactly.** The set-equality check over `AgentRecoveryActionKind.allCases` pins all four allowed kinds. `continueInNewConversation`, `freshClaudeConversation` and `safeRestart` are each asserted off.
- **Fresh session ID is pinned off.** Registration is active, coverage is a subset, and `allowsFreshSessionID` is asserted false.
- **No other behaviour changed** in the diff, and no edited comment is now false.

I found no P0 issues. The main P1 is about the evidence behind the flip, not the code.

## P1 — Should fix

### 1. Round 4 tested only Claude, but the flip also turns on Codex
- **Where:** `AgentRecoveryActivation.swift:41-43`, and `verifier-9live-r4-results.md` (*Synthetic sessions* table).
- **Issue:** The `production` doc comment says the switch happened "after the 9-live round 4 live checks passed". But round 4 only ran Claude sessions: C1 and C2, `claude -p` and `claude --resume`. No Codex session was killed, checked, reconciled or continued. `.claudeAndCodex` also registers `.codexAppServer` and `.codexExec` and turns on resume and reconcile for Codex.
- **Existing claim:** The type comment on lines 20-21 ("Claude Code (standard) and Codex are the live-qualified ones") predates this diff (O32). Codex may have been qualified in rounds 1-3; the X1/X2 sessions in the cleanup list suggest that. Neither the r4 evidence doc nor the new comment says where that Codex evidence is.
- **Fix:** Add a line to the r4 evidence doc and/or the `production` doc comment that names the round and evidence file where Codex passed. Example: "Codex: round N, `verifier-9live-rN-results.md`; round 4 re-checked the Claude blocker T1 only." If no Codex live pass exists, the flip goes further than its evidence.

## P2 / P3 — Minor

- **P2 · `AgentProcessRegistryTests.swift:100`: the test name is now false.** It is still called `testProductionActivationStaysOffAndInactiveRegistryRefusesReservations` but now asserts the opposite. Rename it, e.g. `testProductionActivationIsClaudeAndCodexSubset…`.
- **P2 · `AgentRecoveryCoordinatorTests.swift:2644-2648`: the production assertion doesn't belong in this test.** The test is "before activation" and now checks `inactive`. The added `production.isAvailable(.reconcileOnly) == true` line has nothing to do with its subject. Move it to the activation tests. Also confirm that nothing later in the test body still passes `production` (or its `checksActive`) to the coordinator. If something does, the test passes only by accident, or tests an active production state under the name "before activation".
- **P2 · `AgentRecoveryActionTests.swift` (~420-432): the refusal could come from the wrong gate.** The `.continueInNewConversation` request is expected to come back `.disabled`. That only shows the action-kind gate works if `target` is a covered provider (Claude standard or Codex). If `target` is uncovered, the provider gate refuses it and the assertion passes for the wrong reason. Add `XCTAssertTrue(production.capturesDispatchBaselines(for: <target's provider>))`, or reuse a target known to be covered.
- **P2 · Missing positive test for production.** No test runs `production.perform` with an allowed kind, such as `.continueWithText`, and checks that it gets past the gate to the performers. Until this diff, the production runner only ever had to refuse. A small test asserting it does *not* return `.disabled` would close the gap.
- **P2 · `AgentProcessRegistryTests.swift:106`: fresh session ID is pinned for one family only.** `allowsFreshSessionID` is checked for `.claudeNative` only. Add `.claudeHeadless`, or loop over the Claude families.
- **P2 · Runtime coverage is pinned only by value.** `production == .claudeAndCodex` compares two source values, so a change inside `.claudeAndCodex` would pass this test. Check that another test pins its families and providers explicitly. If none does, add `covers(family:provider:)` assertions for the four pairs and one uncovered Claude variant.
- **P3 · Duplicated status comment.** "production is .claudeAndCodex since the 9-flip" appears in the type comment (lines 25-26), on `production` itself (41-42) and in `AgentProcessRegistry.production`'s doc. These will drift. Keep the status on `production` only.
- **P3 · Redundant assertions.** The four individual `allows` assertions in `AgentRecoveryActionTests` repeat what the set-equality check already pins. They're harmless as readable labels, but you could drop them.

## Recommendations

1. Before merging, record where Codex passed its live check, in the r4 evidence doc or the `production` comment (P1 #1).
2. Make sure the merge commit is `e059c451` plus exactly this diff. The verified build was that HEAD with only the `production` line changed; the rest of this diff is comments and tests.
3. Rename the stale `…StaysOff…` test, and move the production assertion out of the "before activation" coordinator test.
4. Search `Tests/` for `activation: .production`, `AgentRecoveryActivation.production` and `AgentRuntimeLaunchAuthority.production`. Any test that silently assumed OFF, rather than asserting it, now tests something else.
5. Add one positive production-path test (an allowed kind passes the gate) and pin fresh session ID off for `.claudeHeadless`.