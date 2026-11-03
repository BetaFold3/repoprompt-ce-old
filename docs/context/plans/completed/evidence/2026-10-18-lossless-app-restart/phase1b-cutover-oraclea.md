# Phase 1b production cutover — OracleA initial review

Scope: read when the task touches the lossless-restart production cutover's initial review findings.
Authority: Reference
Last-verified: 2026-10-21

Preset identity verified: OracleA, `61D024A4-CCFB-4C9C-A614-CC65E0A1864C`. Chat: `restart-production-cutov-FC4603`. Same immutable code tree `8e55c2b2ed48bc3bb504f00a6e9ef0f99bb2abe8`; the permitted retry used lossless indentation packing after the provider's character-limit rejection. Neither review lane received the other's findings.

# Oracle Review

The cutover activates app-shared recovery, durable input admission, receipt-backed Codex queue acknowledgements, provider delivery evidence, startup reconciliation, scheduler gating, and a basic recovery UI. The separation between acceptance and uncertain delivery is substantially improved, but several integration gaps still leave input without an actionable recovery path or permit dispatch under stale ownership. This is a static review of the supplied snapshot; the reported validation was not rerun.

## P0 — Must fix

### R01 — A refused submission can withdraw the only recoverable copy of its draft

**Evidence:** `Sources/RepoPrompt/Features/AgentMode/ViewModels/AgentModeViewModel.swift:15927–15936`; `AgentModeViewModel+Recovery.swift`, `withdrawUnprojectedRecoveryInput`.

- **Scenario:** Composer admission commits successfully and consumes the stored composer revision. During that await, the submit claim becomes stale—for example, the user switches tabs—or synchronous submission subsequently refuses the input. Both paths withdraw the admitted intent.
- **Impact:** The durable composer has already been consumed, while the intent becomes withdrawn and disappears from recovery presentation. The unchanged live draft does not necessarily produce another mutation/write. A subsequent crash therefore loses the draft from normal recovery, despite it having been durable before Send.
- **Smallest fix:** Do not withdraw a composer-consuming admission until the retained live draft has been durably restored under a validated revision. Otherwise leave the committed intent held rather than withdrawing it.

## P1 — Should fix

### R02 — Held composers and composer persistence failures have no production UI

**Evidence:** `Sources/RepoPrompt/Features/AgentMode/ViewModels/AgentModeViewModel+RecoveryList.swift:80–215`; `AgentModeViewModel+Recovery.swift`, `resolveHeldRecoveryComposer`; `AgentRecoveryCoordinator.swift`, `ComposerState` and `unsavedPredecessorInputs`.

- **Scenario:** Clear Chat preserves a nonempty old-generation composer, or a predecessor flush/image-promotion/composer write fails.
- **Impact:** The controller retains held input or refuses further writes/admission, but the recovery list renders neither composers nor these failures. Its actions cannot invoke held-composer or predecessor resolution. Ordinary reset can consequently leave a session blocked with no supported recovery action; background persistence failure can remain invisible.
- **Smallest fix:** Expose the existing held-composer/predecessor resolution methods and persistent composer/preparation errors in the composer UI. Refresh that presentation when those states change, not only when startup changes.

### R03 — Handoffs added during provider preparation are not attached to the durable intent

**Evidence:** `Sources/RepoPromptAgentCore/AgentMode/Runtime/AgentModeRunService.swift:629–661`; `Claude/ClaudeAgentModeCoordinator.swift:1943–1957`; `Runners/ACPIntegratedAgentModeRunner.swift:1400–1403`.

- **Scenario:** Provider preparation creates a recovery/context handoff after the initial intent was admitted and its dispatch committed. Claude and ACP subsequently prepend it and associate its stage only with the runtime `AgentProviderHandoff`.
- **Impact:** The actual provider text contains a handoff absent from the durable intent. A successful stage-delivery outcome can clear the session payload; a later crash then leaves no durable carrier for that prefix. The new `attachPendingHandoff` store operation has no production caller in this diff.
- **Smallest fix:** Persist the newly staged snapshot on its exact carrier before committing dispatch/entering the provider boundary. Do not consume the session payload unless that association succeeded.

### R04 — Recovery Edit loses a queued intent’s pending-handoff context

**Evidence:** `Sources/RepoPrompt/Features/AgentMode/ViewModels/AgentModeViewModel+RecoveryList.swift:378–443`; `Sources/RepoPromptAgentCore/AgentMode/Runtime/Runners/CodexIntegratedAgentModeRunner.swift:120–151`.

- **Scenario:** A Codex fallback durably carries a pending handoff and consumes the session’s copy. After a crash, the user selects Edit on that queued intent.
- **Impact:** Edit restores only `intent.payload`, then withdraws the original. `intent.pendingHandoff` is neither restored nor transferred, so the next explicit send silently omits the saved context. Conversely, when the session still has a `.recoveryCarriedByIntent` hold, Edit/Remove does not re-run the join after withdrawal, leaving the payload reserved unnecessarily.
- **Smallest fix:** Preserve/restore the exact pending-handoff association before withdrawing its carrier, and re-run the pending-handoff join after successful withdrawal. Refuse conflicting replacement of a newer payload.

### R05 — Durable generic input no longer drains into an already-requested instruction wait

**Evidence:** `Sources/RepoPrompt/Features/AgentMode/ViewModels/AgentModeViewModel.swift:20109–20121`.

- **Scenario:** A user submits while the agent is running, placing a durable entry in `pendingInstructions`; the agent subsequently calls its instruction-wait tool.
- **Impact:** The newly added `!head.isDurable` condition skips that queued instruction. The continuation-send path handles a *new* submission after waiting begins, not the existing head. Production mandatory admission therefore strands previously queued input at this boundary and can leave the agent waiting unnecessarily.
- **Smallest fix:** Implement the durable head drain here: capture its identities, commit dispatch, revalidate the wait/run, and deliver that same entry. Keep it queued on proven pre-handoff failure.

### R06 — Dispatch does not enforce lane retirement and reset freezing across its await

**Evidence:** `Sources/RepoPromptAgentCore/AgentMode/Runtime/Recovery/AgentRecoveryQueuedInput.swift`, `AgentRecoveryDispatchEvidence.begin`; `AgentRecoveryCoordinator.swift`, `beginDispatch`/`beginDispatches`; `AgentModeRunService.swift:629–661`.

- **Scenario:** Another window claims the same session while a dispatch commit is suspended. The predecessor lane retires, but its session’s provider/run fields remain unchanged.
- **Impact:** Dispatch returns successful receipts without revalidating the lane. The common run-service check validates provider/run fields, not lane ownership; `attachRunAttempt` likewise accepts a matching binding without requiring an unretired lane. The old owner can still hand input to the provider. Additionally, dispatch methods do not honor `isResetPreparationActive` or participate in its drain.
- **Smallest fix:** Revalidate the exact live lane after dispatch commits and immediately before handoff; settle a stale pre-handoff receipt without sending. Include dispatch operations in the existing reset freeze/drain, rather than freezing only new admissions.

### R07 — Codex dispatch records no run-start evidence

**Evidence:** `Sources/RepoPromptAgentCore/AgentMode/Runtime/Codex/CodexAgentModeCoordinator.swift:5452–5460`; `AgentRunTerminalCommitBarrier.swift:362–368`; `AgentRecoveryQueuedInput.swift`, `begin`.

- **Scenario:** Codex accepts a first prompt, then RepoPrompt crashes before either a transcript save or terminal completion.
- **Impact:** The Codex path records a delivery attempt carrying `activeRunAttemptID`, but never ensures the corresponding recovery run-attempt record before handoff. Terminal recording creates it only later. An accepted intent can consequently have neither a saved turn nor discoverable open-run evidence, losing the interruption/crash-hold representation.
- **Smallest fix:** Ensure the existing Codex run attempt—with its available process/turn join identities—before both direct and fallback-drain handoffs.

### R08 — Reused process run IDs cannot identify individual Claude attempts

**Evidence:** `Sources/RepoPromptAgentCore/AgentMode/Runtime/Runners/AgentProviderHandoff.swift`, `attachRunAttempt`; `AgentSessionRestoreSupport.swift`, `attemptsByProcessRunID` and `evidence(for:)`; `AgentSessionDataService.swift:3521–3528`.

- **Scenario:** Claude completes one turn and starts another attempt using the same process run ID. The second turn is not saved before the crash.
- **Impact:** Production attachment passes `transcriptTurnID: nil`. Startup then considers the second attempt represented merely because an older saved span contains that process run ID. The interruption lookup also overwrites earlier attempts in a one-value-per-process dictionary. This hides recovery-only attempts and can attribute terminal/shutdown evidence to the wrong turn.
- **Smallest fix:** Record the actual transcript-turn association when it becomes available. Use process-run fallback only when the match is unambiguous; an older turn sharing a process must not satisfy a newer attempt’s saved-turn test.

### R09 — Terminal attempts without saved turns disappear from recovery presentation

**Evidence:** `Sources/RepoPromptAgentCore/AgentMode/Runtime/AgentSessionDataService.swift:3524–3528`; `AgentRecoveryStartupReconciliation.swift`, `hasRecoveryItems`.

- **Scenario:** A short run records terminal evidence, but the app crashes before its turn/transcript is saved.
- **Impact:** `recoveryOnlyRunAttempts` explicitly excludes every terminal attempt. With no saved interrupted turn, there is no corresponding row warning that results are missing. This is precisely the recovery-record-only case R1a requires discovering.
- **Smallest fix:** Include unmatched terminal attempts and render their actual terminal outcome with a missing-transcript warning. They need no open-process crash hold.

### R10 — An uncertain scheduled transfer has no usable resolution path

**Evidence:** `Sources/RepoPromptAgentCore/AgentMode/Runtime/Scheduling/AgentScheduledSendRecovery.swift`, `AgentScheduledSendTransfer.resolve`; `Recovery/AgentRecoveryStartupReconciliation.swift`, `restrictionReason`; `Sources/RepoPrompt/Features/AgentMode/ViewModels/AgentModeViewModel+RecoveryList.swift:134–148`.

- **Scenario:** A scheduled dispatch restarts with a linked `.deliveryUnknown` intent. The user confirms the previous run stopped and attempts to resolve its saved input.
- **Impact:** The transfer keeps a session-wide admission restriction. Its row offers only Open. Even withdrawing an intent after a delivery attempt remains `.hold` in the transfer resolver, so resolving the input does not provide a route to lifting the restriction. Editing into the composer therefore does not make the session usable.
- **Smallest fix:** Provide an explicit, exact-attempt cancellation/resolution action that settles ownership of the pending schedule and then removes its transfer restriction/hold. This must not resend or claim non-delivery.

### R11 — R1a not-sent stamping misses mid-turn user items

**Evidence:** `Sources/RepoPromptAgentCore/AgentMode/Runtime/AgentSessionRestoreSupport.swift:325–333`.

- **Scenario:** An optimistic steering or waiting-continuation bubble is saved as a user activity inside an existing turn, but its intent remains queued or uncertain at crash.
- **Impact:** Stamping visits only `turn.request`. The deterministic mid-turn user item retains its normal delivered-looking presentation, contradicting the recovery evidence and R1a’s per-intent requirement. The scheduled-marker exclusion also needs receipt-kind-aware treatment, not blanket exclusion.
- **Smallest fix:** Join delivery presentation by deterministic user-item ID across request anchors and user activities. Distinguish accepted schedule receipts from saved/unknown receipts.

### R12 — Admission and actual submission can use different composer contents

**Evidence:** `Sources/RepoPrompt/Features/AgentMode/ViewModels/AgentModeViewModel.swift:15843–15938`; `AgentModeViewModel+Recovery.swift`, `admitRecoveryInput`.

- **Scenario:** An attachment import finishes or the workflow selection changes while the durable admission write is suspended.
- **Impact:** Admission persists one content snapshot, but `submit(identity)` subsequently calls the ordinary submission path using the live session again. Only the identity is carried forward—not the admitted attachments/workflow/interview snapshot. The actual send can consume content absent from its durable intent or differ from what recovery later restores.
- **Smallest fix:** Carry one immutable submitted-content snapshot through admission and synchronous projection. Preserve later composer mutations as a separate revision; do not re-read them as part of the admitted send.

## P2 — Consider

### R13 — The tab-switch composer flush is defined but not wired

**Evidence:** `Sources/RepoPrompt/Features/AgentMode/ViewModels/AgentModeViewModel+Recovery.swift`, `flushRecoveryComposer`.

- **Scenario:** The user types and immediately switches tabs.
- **Impact:** No production invocation of the new helper appears in the supplied changes, so tab switching still relies on the debounce/max-delay timer rather than the required boundary flush.
- **Smallest fix:** Invoke it from the outgoing-tab transition and test switching before debounce expiry.

## Context limits and reported choices

- **Provisional `unknown` surviving another crash:** conservative and acceptable here; it preserves the interruption rather than inventing a cause.
- **Memory-only Hide:** consistent with the explicitly deferred durable-dismiss package.
- **Same-launch clearing of `isUndeliveredRemoteSend`:** the shown normalizer only sets it. Confirming whether successful retries clear it requires the unchanged retry-success handlers and transcript projection/update code.
- **Turn-wide output as acceptance:** it should not override an intent’s evidence without an unambiguous association to that input. R08 demonstrates why process identity alone is insufficient.
- **Attachment retention:** the load-bearing unchanged context is `finalizeAttachmentsForTurn`, its `.deleteFiles` implementation, and the cleanup reference-set integration with recovery records. No new defect in that settled baseline is asserted without those bodies.

## Recommendations

**Do not approve the production cutover as-is.** Fix the recovery ownership and actionable-UI gaps above, then add focused tests covering stale post-admission refusal, lane retirement during dispatch, durable queued input reaching a wait, pending-handoff recovery Edit, repeated Claude process IDs, terminal-only recovery, and explicit resolution of uncertain scheduled transfers.

Keep live-provider/crash acceptance accurately marked deferred; the supplied fixture results do not establish those guarantees.
