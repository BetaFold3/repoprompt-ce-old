# Step 4d6 — OracleB initial review

Scope: read when the task touches source review findings for lossless restart Step 4d6 generic-call presentation.
Authority: Reference
Last-verified: 2026-10-24

Independent fresh review; exact preset identity verified. Reviewed four-file staged source tree `0bc4bccbc110342401a0ba3f560f7c6ceacbf3e7`, +160/-20, with main-verified 123 tests, product compile and style evidence. Complete response follows.

# Oracle Review



# Step 4d6 review: neutral display for generic tool-call cards, unchanged run-scoped cancel

## Summary

The diff changes how a generic tool-call card shows its status. A call with no attached result, or with a result the classifier can't read, now shows `.neutral` instead of a `.running` spinner. Results the classifier does read keep their existing status, including an explicit `render_summary` running. Cancel eligibility is now a separate function, `allowsRunScopedCancel`. It runs the same `ToolResultStatusResolver` with the old `.running` fallback. `showsRunScopedCancel` then applies the same three checks as before: run scope, a cancel action exists, and the tool is a RepoPrompt tool. Timestamp hiding (`showsTimestamp: !showsCancelButton`) and the cancel closure in `AgentModeView` are unchanged. The cancel button now has a hover tooltip and accessibility label that both say the cancel applies to the run.

**Cancel parity.** I traced the old and new code and the set of cards that can cancel is exactly the same:
- **Old rule:** cancel showed when there was no result evidence, or when `resolve(fallback: .running)` returned `.running`, and the three checks passed.
- **New rule:** `allowsRunScopedCancel` uses that same formula.
- **Explicit `.neutral` results still don't cancel:**
  - `{"status":"running"}` goes through `mapStatusWord` and `fromTranscriptStatus` and comes back `.neutral`, so no cancel. The truth-table row for this case is correct.
  - A command result with a negative exit code and no timing hint gets an explicit `.neutral` from `commandExecutionOverride`, so no cancel.
- **Only the `fallback` argument differs** between the display call and the cancel call. That argument is used only on the last line of `resolve`, so no classified result can behave differently between the two calls.
- **Old vs new status:** the old `status` already returned `.neutral` for `{"status":"running"}`. The truth-table row "status word running → .neutral" is therefore old behavior, not a change, and the requirement to keep explicit statuses unchanged holds.

I found no P0 or P1 issues.

## P2

**P2-1: The tooltip wrapper on the cancel button hasn't been checked visually or with clicks**
- **Location:** `ToolCardRouter.swift`, `ToolCallCard.body`, the `headerTrailingView` branch (about lines 1071–1077).
- **Scenario:** If `.hoverTooltip` adds an overlay or tracking view that catches hit-testing, clicking the button might hover but not cancel. Or a click could reach the card's `onTap` (the Oracle popover) instead. A second risk: if `ToolCardCancelButton` already sets its own `.help` or accessibility label, users would see two tooltips, or VoiceOver would get conflicting labels.
- **Impact:** Cancel is the only in-card way to stop RepoPrompt tools for the run. Your notes say the app visual, tooltip and live checks were not run. Since it's easy to work around (the run-level stop still works), this is P2.
- **Smallest fix:** Before activation, look at `ToolCardCancelButton` and the `hoverTooltip` implementation. If the button already has a label or tooltip, set this text there instead and drop one of the two. Then do one manual click on a running RepoPrompt tool card. No code change is needed if the click works.

## P3

**P3-1: The cheap checks in `showsRunScopedCancel` run after the JSON parse**
- **Location:** `ToolCardRouter.swift`, `showsRunScopedCancel` (about lines 996–1004).
- `allowsRunScopedCancel` parses `toolResultJSON` before the two boolean checks. Most cards are outside an active run, and `showsCancelButton` is read twice per render, so each of those cards parses JSON for nothing. The old code had the same order, so this is not a regression.
- **Fix:** Put `showRunScopedToolCancel && hasCancelAction` first. All the checks are pure, so the result can't change.

**P3-2: Some test names now say the opposite of what the tests assert**
- **Location:** `RemoteTranscriptProjectorTests.swift`, `testToolCallWithoutToolResultRemainsRunning` (about line 115) and `testUnknownToolResultJSONFallsBackToRunning` (about line 155).
- The names are pinned in the ledger and a comment explains this, which is fine for now.
- **Fix:** Rename them when the ledger next allows it.

**P3-3: The parity test misses one explicit-`.neutral` path**
- **Location:** `RemoteTranscriptProjectorTests.swift`, `testToolCallCardRunScopedCancelKeepsPreStep4d6Eligibility`.
- The "status word running" row already covers one explicit `.neutral` result. The `commandExecutionOverride` path (a negative exit code with no timing hint) is not covered. Adding it would pin that explicit `.neutral` blocks cancel while fallback `.neutral` allows it.
- **Fix:** Add a row to both tables: `#"{"type":"command_execution","exitCode":-1}"#`, display `.neutral`, allowed `false`. This is optional, because the formula is shared and parity holds by construction.

**P3-4: The parity test's "old-set oracle" is the same formula as the new code**
- **Location:** `RemoteTranscriptProjectorTests.swift`, the `oldEligibility` line in the parity test.
- Because the oracle repeats the implementation's formula, it can't catch a mistake in that formula. The hard-coded `allowed` column is what really pins the behavior.
- **Fix:** Nothing required. Optionally, reword the comment so it doesn't suggest the oracle is independent.

## Recommendations

1. Commit as is. The display change meets the acceptance criteria, cancel eligibility exactly matches the old set, and nothing changed in pipeline, storage, ledger, recovery, activation or provider qualification.
2. Do the P2-1 check before live activation: confirm that `ToolCardCancelButton` doesn't already set its own label or tooltip, then click the button once by hand. That closes the only unvalidated user-facing path.
3. P3-1 is a one-line reorder with identical behavior. Apply it now if you're touching the file, otherwise defer it. Defer P3-2 to P3-4.
