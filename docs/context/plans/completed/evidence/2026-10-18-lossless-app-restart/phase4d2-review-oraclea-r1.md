# Step4d2 re-review 1 — OracleA

Scope: read when the task touches the Step4d2 re-review 1 of the Claude native history projection and reconciliation repair delta.
Authority: Reference
Last-verified: 2026-10-23

Repair delta `2026-10-23/2130` against staged snapshot `2026-10-23/2057`. Returned preset identity (`OracleA`) verified by main; this lane received only its own prior R1. No P0/P1; R1 closed; no new findings. Reply below retained verbatim; main dispositions are in phase4-prerequisite-resolution.md.

# Oracle Review

The repair delta fixes cross-turn canonical-output checking and attachment-only fork classification, clarifies unsupported-baseline handling, and avoids unnecessary baseline projection while preserving graph and integrity validation. The changes remain focused on the stated Step 4d2 contract.

## Review outcome

**Approved for this bounded delta. No new findings.**

- **R1 — Closed.** `AgentProviderHistoryImport.swift:510–539` carries the passed-user state into subsequent persisted turns while retaining first-turn filtering. The new Claude/Codex regressions and reconciliation composition test cover the reported failure and positive control.
- **Receipt-only race — Acceptable by source inspection.** `AgentModeViewModel+RecoveryActions.swift:959–972` rechecks ownership before recording an unsupported baseline. That path preserves the newer receipt, creates no claim or prefix proof, and admits only the ordinary no-UUID send. Ownership staleness remains denied. The acknowledged missing race-specific VM test is nonblocking.
- The remaining changes preserve whole-candidate validation, genuine tool-fork source requirements, foreign-window target rejection, and fail-closed handling of unavailable proofs.

No P0/P1 remains open or contested; no new P2 findings.

**Validation basis:** supplied diff and code inspection, plus the reported passing checks and negative controls. I did not execute tests or independently inspect logs. This approval does not extend to production activation or live-provider qualification.