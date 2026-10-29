# Step 4d6 — OracleA initial review

Scope: read when the task touches source review findings for lossless restart Step 4d6 generic-call presentation.
Authority: Reference
Last-verified: 2026-10-24

Independent fresh review; exact preset identity verified. Reviewed four-file staged source tree `0bc4bccbc110342401a0ba3f560f7c6ceacbf3e7`, +160/-20, with main-verified 123 tests, product compile and style evidence. Complete response follows.

# Oracle Review

The frozen four-file diff removes unsupported liveness inference from generic tool-call cards: missing or unclassifiable result evidence now displays neutral, while explicitly classified outcomes remain unchanged. Cancellation eligibility is separated from display status, retaining the previous classifier and gates. Tests cover neutral fallback, explicit running summaries, cancellation parity, and settled outcomes.

## Findings

No actionable findings.

- **Cancellation parity:** `ToolCardRouter.swift:987–1006` reproduces the old eligibility exactly: missing evidence qualifies; attached evidence qualifies only when the existing classifier returns `.running` using its old `.running` fallback. Run-scope, action availability, and RepoPrompt-name checks are preserved.
- **Display semantics:** `ToolCardRouter.swift:975–981` changes only the fallback. Explicit render-summary `.running` remains supported; ordinary `"status":"running"` retains its existing neutral classification.
- **Header behavior:** `ToolCardRouter.swift:1070–1076` preserves timestamp suppression and the cancel action, adding clearly run-scoped tooltip and accessibility wording.
- **Scope:** No changes to execution ownership, provider qualification, result-card classification, persistence, recovery, or activation appear in this diff.

Validation results are supplied evidence, not independently executed in this text-only review. Actual tooltip rendering and accessibility behavior remain visually unverified.

## Recommendations

Accept this bounded source step without additional changes. Keep activation **OFF** and missing-proof recovery **blocked**. This review does not establish live restart readiness or verified Resume behavior.
