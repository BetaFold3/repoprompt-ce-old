# Phase 2 OracleA second re-review

Scope: read when the task touches Phase 2 second re-review findings for lossless app restart.
Authority: Reference
Last-verified: 2026-10-21

Frozen snapshot: `70ee3c8bdb05a833bb4fb826d72ae7c9616c3040`. Preset identity verified before synthesis. Raw response follows unchanged; a self-label in prose does not determine preset identity.

# Oracle Review

The R2 delta fixes both outstanding required findings: question hand-over no longer assumes durability, and missing-transcript-tail warnings now survive subsequent launches. The two prior P2 residuals are also addressed. However, the newly added Codex interruption fallback introduces an ownership race that should be fixed before approval. This assessment uses the supplied snapshot and reported validation only; it does not establish live acceptance.

## P1 — Should fix

### F11-R2 — Deferred interruption can cancel a replacement Codex turn

**Evidence:** `CodexAgentModeCoordinator.swift:7173–7191`, `failCodexRunForUnsavedQuestion`.

- **Failure scenario:** The failed question’s run has no captured `codexAuthoritativeActiveTurn`. The function awaits `finalizeCodexRun`, then launches an unstructured task calling `reconcileAndInterruptCurrentTurn()`. Finalization releases the run and can suspend during terminal publication; a replacement run can start on the same controller before that task reconciles. The fallback then targets the **replacement current turn**, not necessarily the run whose question failed.
- **Impact:** Recovery from a question-persistence failure can unexpectedly cancel newly started work. The supplied replacement-run test changes ownership **during the creation write**, so its early `.drop` path does not cover this later race.
- **Smallest fix:** Obtain and pin the failed run’s provider turn identity before releasing its ownership, and interrupt only that identity. Do not issue an unscoped “interrupt current turn” after finalization. Add a focused test that starts a replacement during the finalization suspension with no initially captured authoritative turn ID.

**Disposition:** **Open P1**, introduced by this delta.

## Prior finding dispositions

| Finding | R2 disposition |
|---|---|
| **F01 / F01-R1 — P0** | **Closed.** Adopted snapshots remain pending, include in-flight values, and successor writes wait for predecessor retirement. Reply preservation requires a successful write. The failed-retirement regression exercises the original bypass. |
| **F03 / F03-R1 — P1** | **Closed.** The additive `recoveredOutcome` marker replaces launch-local bookkeeping and survives transcript rebuilds. The supplied three-launch test covers continued listing and durable dismissal. No provider-history reconciliation is claimed. |
| **F05-R1 — P2** | **Closed.** Closed-session catalog rows receive the retained compose-tab identity. |
| **F08 residual — P2** | **Closed.** Index summaries without occurrence identity cannot be dismissed before opening. |
| **F02, F04, F06, F07, F09, F10** | Remain **closed** within this re-review’s scope. The ACP outer-error change preserves typed process-loss attribution. |

## Recommendations

- **Do not approve this snapshot yet:** F11-R2 remains open.
- R2/2 is exhausted; report the remaining P1 to the owner. Recommend the bounded identity-fencing fix and affected validation, not another ordinary review round.
- Keep O3 live acceptance pending. Leave registry, Resume, retention, and optional polish deferred.
