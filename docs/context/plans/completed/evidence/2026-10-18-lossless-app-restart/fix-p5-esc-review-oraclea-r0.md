# Step 8 P5 Esc fix review round 0: OracleA

Scope: read when the task touches Escape or keyboard focus of the recovery View popover (verifier check P5).
Authority: Reference
Last-verified: 2026-10-28
Covers: OracleA round-0 review of the P5 fix (chat p5-esc-review-oraclea-r0-88E5BE)


The change addresses P5 by making the popover key after presentation and restoring the previous key window on close, without widening Escape handling. The deferred callback’s identity check protects against closing or replacing the popover before it runs. The patch is focused, and static review found no confirmed P0/P1 regression. Actual AppKit focus and event delivery remain unverified.

## P2 — Consider

### F1 — The regression test assumes the AppKit behavior the fix depends on
**Evidence:** `Tests/RepoPromptTests/AgentMode/Recovery/AgentRecoveryNativePopoverEventDecisionTests.swift:99–105`; `Sources/RepoPrompt/Features/AgentMode/Views/Components/AgentRecoveryNativePopover.swift:304–307`.

- **Scenario:** The real popover window is unavailable when the deferred callback runs, cannot become key, or does not receive Escape as expected. The fake always sets `isKeyWindow = true`, and the test supplies that value directly as `inPopover`.
- **Impact:** Tests can pass while the original P5 failure persists. They also do not establish focus restoration or single-click delivery when opening from a sheet.
- **Smallest fix:** Run and record the planned live verification for both banner and sheet before considering P5 resolved. Retain the unit tests as helper-policy coverage, not evidence of real event routing.

### F2 — The evidence report contradicts its recorded guardrails result
**Evidence:** `docs/context/plans/evidence/2026-10-18-lossless-app-restart/fix-p5-esc-worker.md:7`, versus its **Commands run** table.

- **Scenario:** A reviewer relies on “Unit tests, lint and guardrails pass,” although the recorded guardrails invocation exited with an error.
- **Impact:** The report incorrectly presents validation as complete.
- **Smallest fix:** Change the summary to reflect the recorded failure, or record a subsequent successful run. Keep historical failures clearly distinguished from current validation.

## Recommendations

Keep the implementation pending live verification; no additional production-code change is justified by the supplied evidence. Prioritize immediate Escape from the sheet, composer focus restoration, outside-click delivery, app switching, and rapid close/reopen. Correct the validation summary before sign-off.