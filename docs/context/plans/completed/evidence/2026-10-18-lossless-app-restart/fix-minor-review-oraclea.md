# Restart minor fixes — OracleA initial review
Scope: read when the task touches restart-spec Step 7-minor review findings (cancelled Codex bash row status).
Authority: Reference
Last-verified: 2026-10-26

Covers: OracleA fresh-chat initial review of the Step 7-minor item 1 diff (review mode, explicit slices incl. review policy). Verbatim export follows.

# Oracle Review

The change narrowly replaces inferred `finished` with `cancelled` when a bash process disappears without an attached controller, preserving the existing attached-controller behavior. It does not change recovery classification, intents, shutdown ordering, or cancellation handling. The reported validation supports those two branches, but controller presence alone establishes neither command ownership nor its actual outcome.

## P1 — Should fix

### MINOR-01 — Reconnection can restore the false-success behavior

**Evidence:** `CodexAgentModeCoordinator.swift:9577–9579, 9599–9604, 9626–9628`; added attached-provider test in `CodexAgentModeCoordinatorLivenessTests.swift:1521`.

- **Failure scenario:** A running row is restored for a command killed by quit. Before its liveness grace expires, a replacement controller attaches. The poll now chooses `finished` for that old execution solely because `session.codexController != nil`.
- **Impact:** The row again persists as `success`, violating the step’s goal. A replacement controller’s presence does not establish that it will deliver the old command’s completion. The attached-provider test currently validates this outcome without distinguishing restored executions from current-provider executions.
- **Smallest fix:** Preserve execution provenance when rebuilding restored rows. Permit provisional `finished` only for executions owned by the current provider generation; keep restored/unresolved executions non-success unless an authoritative completion resolves them. Add a regression test that attaches a replacement controller between restoration and settlement.

## P2 — Consider

### MINOR-02 — Missing completion evidence is treated as proven cancellation

**Evidence:** `CodexAgentModeCoordinator.swift:9621–9628`; `fix-minor-worker.md`, “Fix,” describes synthesizing `exitCode: 1`.

- **Failure scenario:** A command exits successfully just before quit or idle teardown, but its completion is not recorded before the controller disappears. The saved row remains running, and the new branch labels it cancelled.
- **Impact:** A genuinely successful command can display a cancellation/failure outcome. The fallback avoids unsupported success, but replaces it with another unsupported assertion; it also cannot establish the command’s exit code.
- **Smallest fix:** Retain a non-success fallback, but distinguish an inferred interrupted/unknown outcome from confirmed cancellation, without inventing an observed exit code. If conservative `cancelled` is intentional product policy, explicitly document that meaning rather than claiming the command necessarily was interrupted.

### MINOR-03 — Tests do not establish authoritative-result precedence

**Evidence:** Added tests in `CodexAgentModeCoordinatorLivenessTests.swift:1495–1533`; `CodexAgentModeCoordinator.swift:8932–8940` replaces the row and removes live-execution tracking.

- **Failure scenario:** A controller attaches after fallback settlement and delivers the real completion. The tests stop immediately after inferred settlement; neither exercises that later event.
- **Impact:** They do not prove that an authoritative success or failure can correct the inferred cancellation after tracking has been removed. Nor do they demonstrate that an already-recorded authoritative result survives subsequent polling. The supplied excerpts do not establish an overwrite bug, but leave this requested guarantee unverified.
- **Smallest fix:** Add event-path tests for both orderings: authoritative completion before polling, and authoritative completion after fallback cancellation. Assert final status, output, exit code, and persistence—not just normalized status.

## Recommendations

Address **MINOR-01** before approving the step. Explicitly choose the semantics of an unobserved outcome, and add authoritative-completion ordering tests. Treat the reported 83 passing tests and fail-first check as evidence for the isolated fallback—not proof of reconnect, teardown, or late-result correctness.