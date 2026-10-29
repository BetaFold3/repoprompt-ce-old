# Step4c repair review1 — OracleA

Scope: read when the task touches the explicit uncertain-exit repair or its review findings.
Authority: Reference
Last-verified: 2026-10-23

Delta snapshot `2026-10-23/1820-2`; preset `61D024A4-CCFB-4C9C-A614-CC65E0A1864C`; chat `step4c-repair-review1-FD88B4`; operation `63CC63D2-CC89-4513-B2A4-D666B96BD081`. Full response follows.

# Oracle Review

The repair removes contradictory restart advice from admitted uncertain-exit prompts: it replaces only the exact generic timeout message, preserves other diagnostics, and clears the clean-acknowledgement flag justified by the pre-arm witness. Added tests exercise the coordinator-generated failure through the real alert builder, the real relaunch driver over an in-memory helper channel, and plain-quit isolation.

**Verdict: Approved for this bounded repair.** No new actionable findings in the two-file delta.

### Prior finding F1 — Resolved

- **Scenario:** The deadline expires during `arm`, and abandonment reports `.unresolved`.
- **Evidence:** `AgentLifecycleShutdownCoordinator.swift:128–148, 962–977` applies the neutral wording only after uncertain-exit admission succeeds. Stop-proof recovery still receives the original messages rather than the transformed prompt.
- **Verification:** The updated timeout test checks the actual coordinator-generated alert for contradictory text. The composed-driver test additionally checks retained helper ownership and that explicit exit introduces no further frames, kills, or helper spawns.
- **Remaining fix:** None.

The change does not alter eligibility, deadline handling, helper ownership, or production gating. Reported lifecycle **48/48**, compile, formatting, and lint results were supplied by the requester; I did not independently rerun them.

## Recommendations

Accept F1 as closed; no further repair is required for this delta. Keep production activation **OFF** and live qualification pending—the in-memory channel and alert-builder tests do not establish visible AppKit, real-helper, or provider behavior.
