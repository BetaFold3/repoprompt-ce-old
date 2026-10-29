# Step 7-F7 — OracleA initial review (2026-10-26)

Scope: read when the task touches lossless restart Step 7-F7 (composer tab ownership and submit-path diagnostics) implementation or review evidence.
Authority: Reference
Last-verified: 2026-10-26

Fresh chat `f7-review-oraclea-4C56A7`, preset OracleA (61D024A4…), mode review, explicit slices: review policy, spec F7 + safety fences + cross-cutting, `fix-f7-review.diff`, surrounding code, `fix-f7-worker.md`. Identity verified from the result (`model_preset_name: OracleA`).

Verdict: no P0/P1. Ownership guard addresses F7; submit fences, tokens, admission and dispatch untouched; logs carry reason strings and identifiers only.

| ID | Sev | Finding | Disposition |
|---|---|---|---|
| F7-R1 | P2 | Pre-existing rejection exits (`local_attempt_latched`, target-validation failures in `executeComposerSubmitAttempt`) still default `persistent: false`, so some "This composer changed…" paths stay invisible in normal runs. | Fix (same as OracleB R1). |
| F7-R2 | P2 | `refreshRecoveryListUI` skips publication when the current tab has no session, leaving a stale submittable snapshot; removal test doesn't assert clearing. | Fix if cheap without recreating a session; else defer. |
| F7-R3 | P2 | Tests equate non-nil target with Send enabled (ignore `canSendWithCurrentProvider`); no real activation/workspace-switch sequencing; no Tab-tag first-send test. | Add provider-availability assertion and a workspace-switch test if cheap; Tab-tag first send deferred until the new logs identify the reason. |
