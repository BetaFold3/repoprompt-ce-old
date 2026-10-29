# Step 7-F7 — OracleB initial review (2026-10-26)

Scope: read when the task touches lossless restart Step 7-F7 (composer tab ownership and submit-path diagnostics) implementation or review evidence.
Authority: Reference
Last-verified: 2026-10-26

Fresh chat `f7-review-oracleb-EB6379`, preset OracleB (7CDD523E…), mode review, same explicit slices as OracleA. Identity verified from the result (`model_preset_name: OracleB`).

Verdict: ownership guard correct for every traced caller (activation, first-send source/destination syncs, no current tab, non-current removal); no dropped scheduler notifications; safety fences untouched; no user content in logs. One P1 on observability completeness.

| ID | Sev | Finding | Disposition |
|---|---|---|---|
| F7-R1 | P1 | Pre-existing exits returning `staleComposerSubmitTargetMessage` (`submitTargetRejectionReason` ~15362/~15515, `agent_session_id_mismatch` ~15424, `source_pending_state_changed` ~15523, `invalid_first_send_destination` ~15530/~15538) and `local_attempt_latched` (~2415) are not persistent; view completion closures show `blockedMessage` without logging. The spec's open Tab-tag question would stay unanswerable. | Accepted, fix: persist those calls, add `completion_blocked` log without message text. |
| F7-R2 | P2 | No Tab-tag first-send test; workspace-switch publish order (worker audit item 3) unpinned. | Add workspace-switch test if cheap, else `assumed:`; Tab-tag test deferred. |
| F7-R3 | P2 | "Switch while queued" test samples the sync counter before `beforeDelivery`, so a setter's own sync could satisfy it. | Fix (cheap). |
| F7-R4 | P3 | Current tab with no session gets no publish from refresh (same as OracleA R2). | Fix with OracleA R2 if cheap. |
| F7-R5 | P3 | Current-tab fields that depend on other tabs (blocking session name, delegated-question rows) refresh only on next current-tab sync. Optional: publish owner props on non-current sync. | Deferred (departs from spec's literal skip; cosmetic). |
| F7-R6 | P3 | `initial_turn_preflight_blocked` / `destination_preflight_blocked` each label two exits. | Fix (rename second). |
| F7-R7 | P3 | Stale comment on `recoveryCoordinatorChangeObserver` (~629). | Fix (comment). |
