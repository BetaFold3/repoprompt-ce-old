# Phase 4 OracleA final re-review

Scope: read when the task touches lossless restart Phase 4 final re-review findings, checkpoint scope or activation blockers.
Authority: Reference

Reviewed source tree: `5f9151eb9c92b78ebb42b28226633c1e7652e6e0`, delta from `85142397c2e1d74b0a74bb0a6a7750ef9c314ff6`. Main verified the exact requested OracleA preset identity and read the complete response. The owner-approved inactive checkpoint is not full Phase 4 completion or activation approval.

# Oracle Review

The delta repairs exact-attempt stale-commit settlement, narrows hard exclusion to the action’s durable session, settles non-Codex pre-runner failures, propagates captured restart budgets, and restores normal choices when `arm` was never sent. **P0: none identified. P1: no remaining fix required to checkpoint the bounded, inactive source under O9; full Phase 4 remains blocked as detailed below.** No new checkpoint-blocking regression was identified. This assessment uses the supplied source and diff; the reported 592 passing tests were not independently rerun and are not live qualification.

## Required-repair verdicts

| Finding | R2 disposition |
|---|---|
| **P1-01 — Stranded action hold** | **Closed.** `AgentRecoveryCoordinator.swift`, `noteRecoveryActionStaleCommitSettled`, now matches the attached attempt against the returned receipt IDs, revokes its authorization, and settles successful queue restoration as `.notHandedOff` or failed persistence as `.uncertain`. The added transaction-gated shutdown test covers the reported interleaving, runner completion, and admission reopening. |
| **P1-06 — Older saved bubble** | **Open for the full contract; explicitly permitted as unfinished work in O9’s inactive checkpoint.** The wording change does not implement stable-ID sending for an older bubble. |
| **P1-07 — Restart deadline and unresolved-helper policy** | **Reported duration-reuse defect repaired; activation-policy blocker remains.** R4 captures work and cleanup expiries and passes them through serialized hooks to the parent session. Cleanup is capped rather than renewed after identity inspection/spawn. The composed shared-clock test exercises the original two-second delay scenario. |
| **P1-02/03/04/05/08/09** | Previously closed dispositions stand; no regression identified in this delta. |

The narrowed hold preserves same-session exclusion across successor lanes while allowing sibling live input; workspace automatic-busy projection remains. The non-Codex defer revokes only the carried action and uses the existing no-commit/no-in-flight settlement fence. Plain quit and window close do not enter the restart-helper branches and retain their existing deadline behavior.

## P1 — Full-contract blockers, not unsafe-checkpoint regressions

### P1-06 — Older displayed messages still cannot use Send saved

- **Evidence:** `AgentModeViewModel+RecoveryActions.swift:473–476` refuses a saved bubble when a later user sequence exists. `AgentTranscriptServices.swift:3298–3424` derives turn membership positionally; `AgentTabSession.swift:3005–3039` appends new output at the tail.
- **Failure and impact:** A verified-unsent older message cannot be dispatched under its existing identity through the required R1a/R7 workflow. Editing it as a **new** message is not completion of that requirement.
- **Smallest checkpoint-safe action:** Preserve the refusal, original intent, and transcript; keep this finding open and Phase 4 blocked. The supplied membership evidence does not support my earlier anchor-only repair prescription. A future implementation needs an authorized, source-grounded attachment solution—not merely removal of the guard.

### P1-07 — Ambiguous arm-sent shutdown remains an unapproved exception

- **Evidence:** `AgentLifecycleShutdownCoordinator.swift:791–815` retains the no-choice branch after unresolved abandonment; `AppRelaunchCoordinator.swift`, `abandonCurrent`, distinguishes this from proven arm-never-sent state.
- **Failure and impact:** If `arm` may have reached the helper and its stop cannot be proven, the restart request stays unfinished and blocks subsequent ordinary quit/window-close requests.
- **Smallest checkpoint-safe action:** Keep Restart disabled pending explicit resolution of this activation condition. Restoring Retry/Cancel for an unarmed helper is correct, but neither that repair nor O9 approves the ambiguous-arm exception.

## Recommendations

- **Accept the O9 inactive partial checkpoint**, without claiming full Phase 4 completion.
- Record P1-01 closed; retain P1-06 and P1-07’s policy component as explicit full-contract/activation blockers.
- Keep all production gates OFF, O3 pending, and normal-live Claude merging blocked.
- End R2 at **2/2**; no additional round for optional polish.