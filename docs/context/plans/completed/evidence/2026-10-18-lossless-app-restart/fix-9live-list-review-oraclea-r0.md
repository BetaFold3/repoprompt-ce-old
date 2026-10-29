# 9-live fix 2 (recovery list): OracleA review, round 0

Scope: read when the task touches the recovery list's Continue editor text, refused-continuation row text, the order of surviving-process items, or the composer's send-refusal notice.
Authority: Reference
Last-verified: 2026-10-28
Covers: the OracleA review (round 0) of the recovery-list diff, copied from its export; the fixes are in fix-9live-list-worker.md


The list diff preserves Continue drafts outside row views, restores recorded unsent text, puts the unsent warning before refusal reasons, prioritizes runtime items, and makes admission-refusal notices persistent. The dispatched-only draft cleanup is a justified correction to the plan’s broader “completed” wording. Review is limited to `9fix-list.diff`; validation results are supplied evidence, not independently rerun.

## P2 — Consider

### LIST-01 — Persistent refusal can follow a switch to a different session

- **Evidence:** `AgentInputBar.swift:829–835, 2429, 2530–2538`.
- **Scenario:** Session A receives a persistent refusal, then the user switches to session B whose composer contains identical text. Because `localInputText` does not change, the new text-change hook does not clear the notice.
- **Impact:** Session B can indefinitely display A’s recovery restriction, incorrectly implying that B cannot send. Editing or submitting clears it.
- **Smallest fix:** Also clear persistent notices when `currentTabID` changes. Add a regression case switching between two tabs with identical drafts.

### LIST-02 — Successful-dispatch draft cleanup lacks an integration assertion

- **Evidence:** `AgentModeViewModel+RecoveryList.swift:844–856`; `AgentRecoveryStartupCompositionTests.swift:1468–1495`; `AgentRecoveryReconciliationTests.swift:2199–2225`.
- **Scenario:** The real continuation path is tested for refusal retention, but successful cleanup is tested only through the result predicate. Those tests would still pass if the report were not populated correctly or the dictionary cleanup stopped working.
- **Impact:** The successful-send half of the draft lifecycle—and protection against clearing newer edits—remains unverified.
- **Smallest fix:** Exercise `performRecoveryListContinuation` with a controlled dispatched result. Assert that the matching draft clears, while a different draft written during the await survives. Cover `.outcomeUnrecorded(.dispatched)` as well.

## Recommendations

No blocking P0/P1 issue identified in the supplied scope. Fix the tab-switch notice leak and add the cleanup regression test. Before activation, complete the planned live checks for editor dismissal, banner/sheet transitions, and persistent-notice behavior.