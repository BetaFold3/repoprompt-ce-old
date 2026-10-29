# 9-live R3 fix: OracleA round-0 review

Scope: read when the task touches restored bash tool rows or the Codex bash reconcile on Claude sessions.
Authority: Reference
Last-verified: 2026-10-28
Covers: the OracleA review of the first R3 diff (gate plus backstop), copied from its export; the backstop it criticises was then removed


## Findings

### P1 — Skipping terminal matches can redirect a completion to an older unfinished row

**Location:** `CodexAgentModeCoordinator.swift`, `bashTranscriptItemIndex`, changed `lastIndex(where:)` predicate.

The backstop does more than reject the previous match: it **continues searching backward for another row**. That can turn a previously correct match into a wrong-row update.

**Failure scenario:**

1. A non-Claude session contains two args-less bash rows: older unfinished **A**, newer **B**.
2. B’s completion updates B by invocation ID. The diagnosis documents that the generic `tool_result` handler updates the invocation-matched row **before** calling this reconcile.
3. Reconciliation receives no args or process identity and has no matching live execution state.
4. Previously, the signature lookup selected B, the newest matching row.
5. Now B is terminal and rejected, so `lastIndex(where:)` selects A. B’s completion can consequently finalize A with B’s output.

This requires args-less Codex/ACP events, but preserving unfinished args-less rows is explicitly the backstop’s stated compatibility rationale. The supplied excerpts establish the lookup behavior; they do **not** establish how frequently those providers produce this sequence.

**Smallest bounded fix:** Find the newest signature-matching row first, then reject that candidate if incoming args are empty and it is terminal. Do not search past the rejected terminal candidate for an older unfinished row. This preserves matching when the newest candidate is unfinished while preventing the newly introduced backward reassignment.

The stronger identity-preserving fix is to pass the known invocation ID into reconciliation and use its existing invocation-first lookup.

**Regression test:** Seed older unfinished A and newer terminal B, both args-less, with no live execution state. Deliver an unidentified completion and assert A remains unchanged. An integration variant should complete B through the generic handler using B’s invocation ID.

Neither added test catches this: each begins with only one restored terminal row.

## Other observations

- **Claude exclusion:** The function-level guard protects callers that still invoke this method while `selectedAgent.usesClaudeNativeRuntime` is true. Removing the Claude-only call is consistent with that protection. No remaining Claude bypass is demonstrated by the supplied excerpts.
- **Incident regression:** The first test has the right event shape: restored args-less cancelled row, new invocation with args, then an args-less result. Row equality and the exact two-row assertion are meaningful checks. However, the supplied material omits `test_handleStreamResult` and its routing conditions, so I cannot independently establish which handler branch it exercises.
- The implementer’s reported test results were not independently verified.

## Recommendations

1. Prevent empty-args lookup from walking backward past a terminal match; add the two-row regression above.
2. Add a positive compatibility test proving an args-less unfinished Codex/ACP row still finishes without duplication.
3. Retain the centralized Claude guard and incident regression. **Resolve the wrong-row selection risk before approval.**