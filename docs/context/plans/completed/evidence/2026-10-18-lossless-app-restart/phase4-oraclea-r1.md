# Phase 4 OracleA first re-review

Scope: read when the task touches lossless restart Phase 4 first re-review findings or their disposition.
Authority: Reference

Reviewed tree: `85142397c2e1d74b0a74bb0a6a7750ef9c314ff6`, delta from `e876de21cca35adeda4d007930080f8ee9cb199b`. Main verified the exact requested OracleA preset identity and read the complete response. This is raw findings evidence, not source acceptance.

# Oracle Review

The fixes add app-shared recovery-action holds, payload-specific authorization, blocking reconciliation failures, completion preservation, conservative history-import checks, saved-bubble reuse, typed helper-stop proof, a registry launch seal, and request-scoped restart reasons. **P0: none identified. P1: changes required—P1-01, P1-06, and P1-07 remain open.** This assessment uses only the supplied diff and context; reported validation was not independently rerun and is not live qualification. The inactive checkpoint is not full Step 4/R7 completion or activation approval.

## P1 — Required findings still open

### P1-01 — Post-commit shutdown/reset refusal can strand the shared action hold

**Disposition:** Substantially repaired, but the fix introduces an unsettled-dispatch path.

**Evidence:** `Sources/RepoPromptAgentCore/AgentMode/Runtime/Recovery/AgentRecoveryCoordinator.swift:2669–2677`, together with `finishRecoveryActionDispatchCommit`, `noteRecoveryActionStaleCommitSettled`, and `settleRecoveryActionIfFenced`.

**Failure:** While an authorized dispatch commit awaits persistence, shutdown or reset preparation freezes the lane. After the commit returns:

1. `finishRecoveryActionDispatchCommit` can still accept the action authorization and populate `hold.dispatchAttemptID`; it does not check the lane’s shutdown/reset freeze.
2. `isValidForHandoff` then fails, so `settleStaleDispatch` writes the attempt back to queued.
3. `noteRecoveryActionStaleCommitSettled` ignores that settlement because it requires `hold.dispatchAttemptID == nil`.
4. Subsequent submission revocation cannot settle the hold either, because `settleRecoveryActionIfFenced` also requires no dispatch attempt.

The runner remains suspended in `awaitRecoveryActionSettlement`. Cancelling Stage A can therefore leave the workspace’s manual, MCP, and scheduled dispatches permanently blocked despite verified non-handoff.

**Smallest fix:** Report stale-commit settlement against the exact committed attempt, including when its ID was already attached to the hold. Successful settlement must resolve `.notHandedOff`; failed evidence persistence must resolve `.uncertain`. Add an injected test that freezes the lane during the dispatch write, completes that write, cancels shutdown, and verifies the runner finishes and the workspace hold releases.

### P1-06 — Send saved still rejects a required, ordinary recovery case

**Disposition:** Partially repaired; the disclosed newer-message restriction is not an accepted scope cut.

**Evidence:** `Sources/RepoPrompt/Features/AgentMode/ViewModels/AgentModeViewModel+RecoveryActions.swift:473–476`; `Sources/RepoPrompt/Features/AgentMode/ViewModels/AgentModeViewModel.swift:16898–16917`.

**Failure:** A saved, verified-unsent message already has its deterministic bubble, and another user message follows it. `recoverySavedIntentBubble` refuses it solely because a newer user sequence exists. The user must edit and submit another message rather than send the original saved intent under its existing identity.

Removing generic Continue for verified non-handoff prevents the wrong payload, and latest-bubble reuse is a meaningful repair. Neither closes R1a/R7’s original-message workflow for an older displayed bubble. The added refusal test confirms the limitation rather than satisfying that workflow.

**Smallest fix:** Carry the saved message’s explicit user-item/turn anchor through the existing normal run and response-attachment seams, instead of relying on the latest user message. Reuse the original bubble and attachments without deleting or duplicating later messages. Do not merely remove the guard while responses would still attach to the wrong turn. Test successful dispatch with a newer user bubble present.

### P1-07 — Cleanup is bounded locally, but not by the request’s absolute deadline

**Disposition:** The extra 16-second wait and signal-as-proof problem are repaired; the absolute-budget requirement and unresolved-helper policy remain open.

**Evidence:**
- `Sources/RepoPrompt/App/AgentLifecycleShutdownCoordinator.swift:833–847`
- `Sources/RepoPrompt/App/AppRelaunchCoordinator.swift:76–113`
- `Sources/RepoPromptPlatform/Infrastructure/Process/ProcessRelaunchHelper.swift:769,819,867–872`

**Failure:** R4 reserves one second by setting its work expiry to seven seconds, but passes a **relative duration** into serialized helper work. That duration is reused after serialization, previous-helper cleanup, identity inspection, and spawning. The parent then starts another relative timer, and cleanup creates its deadline from the time cleanup actually begins—not from R4’s captured expiry.

For example, if preparation receives seven seconds and spawning consumes two seconds before the prepare timer starts, preparation can wait until approximately second nine and cleanup until second ten. R4’s failure path awaits serialized abandonment, so its seven-second timeout does not independently bound that wait.

**Smallest fix:** Propagate the request’s captured absolute work and final cleanup expiries through the helper hooks. Recompute remaining time after serialization and spawning; cap cleanup at the original final expiry. At that expiry, retain unresolved ownership without joining work indefinitely. Test the composed coordinator and parent driver with one shared injected clock and time consumed before the helper timer starts.

**Policy remains unresolved:** The no-choice branch deliberately leaves the request unfinished and admission frozen (`AgentLifecycleShutdownCoordinator.swift:760–787`). Subsequent ordinary Quit/window-close requests cannot escape that active restart request. Ordinary quit/window-close paths without a preceding unresolved restart retain their existing deadline behavior, but this restart exception is **not approved**. Keep Restart disabled until the policy is resolved; elapsed time or successful signal delivery must never become stop proof.

## Other required finding dispositions

| ID | Disposition | Source basis |
|---|---|---|
| **P1-02** | **Closed for the supplied bounded scope** | `.blocked` and `.associationUnavailable` stop continuation; successful unconfirmed observation remains distinct. |
| **P1-03** | **Closed** | Request-bound completion survives failed row persistence and prevents dispatch through `.blocked(..., completion:)`. |
| **P1-04** | **Closed via conservative refusal** | Codex canonical overlap withholds rows and ledger writes while retaining confirmed completion. This is not qualification of a live merge. |
| **P1-05** | **Closed** | Every baseline user constituent requires a positive, conversation-specific native-user association independently of filtered observation rows. |
| **P1-08** | **Closed** | Registry launch admission is sealed before the all-stopped discovery/proof and remains sealed through exit, including sessionless reservations. |
| **P1-09** | **Closed** | The termination entry consumes the restart reason before confirmation or joining; the caller also disarms after `terminate` returns. |

No additional independent P0/P1 regression is identified within this bounded review. The settlement hang above is a regression caused by the P1-01 repair. Existing **P2-02**, post-exit open-failure presentation, remains deferred; no optional-only review round is requested.

## Recommendations

- Fix the exact stale-commit settlement path and older-bubble normal dispatch path.
- Pass absolute request deadlines through helper preparation, arming, and cleanup.
- Keep all production gates OFF and retain the explicit blocked status for unresolved restart policy, normal-live Claude merging, and O3 acceptance.
- Use the remaining bounded rereview for these required behavioral changes—not deferred polish.