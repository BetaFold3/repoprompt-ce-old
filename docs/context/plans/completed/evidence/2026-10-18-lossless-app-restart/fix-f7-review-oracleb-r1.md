# Oracle Review

Scope: read when the task touches lossless restart Step 7-F7 (composer tab ownership and submit-path diagnostics) implementation or review evidence.
Authority: Reference
Last-verified: 2026-10-26

# Step 7-F7 re-review, round 1: composer tab ownership and submit-path logging

This round persists the six submit-path exits I flagged in F7-R1. It also makes `local_attempt_latched` persistent at all four view sites and logs only a reason (`completion_blocked` / `schedule_completion_blocked`) in both completion closures. Silent exits in the scheduled-send path and the recovery-admission stale exit now log too. Separately, `refreshRecoveryListUI` now publishes a non-submittable snapshot of the current tab when that tab has no session, without creating one (R4).

**Verdict:** F7-R1 is resolved and I accept the disposition. I found no new P0 or P1. The `materializingSession` flag cannot leave a stale or foreign submit target, other callers behave as before, and no new log line carries user content.

## Verification of F7-R1

| Site | Status |
|---|---|
| `submitTargetRejectionReason` exits (`AgentModeViewModel.swift:15362`, `:15515`) | persistent ✔ |
| `agent_session_id_mismatch` (`:15424`) | persistent ✔ |
| `source_pending_state_changed` (`:15523`) | persistent ✔ |
| `invalid_first_send_destination` (`:15530`, `:15538`) | persistent ✔ |
| `local_attempt_latched`, at both sites in `sendMessage` and both in `scheduleMessage` (`AgentInputBar.swift:2348`, `:2371`, `:2417`, `:2448`) | persistent ✔ |
| Completion closures (`AgentInputBar.swift:2400`, `:2472`) | log a reason only; `blockedMessage` is not logged ✔ |

The completion-closure logs also catch everything else. Any `.blocked` result that reaches the view now leaves at least one persistent line, even when the view-model exit has no specific reason of its own. That covers what the observability bullet asked for.

Leaving claim-time logs non-persistent is acceptable, because the view already persists `claim_<diagnosticReason>`. I don't contest any of the dispositions.

## Regression check on `materializingSession`

- **Other callers:** the parameter defaults to `true`, and `refreshRecoveryListUI` is the only caller that passes `false`. Every existing call site keeps its old behavior.
- **No stale or foreign target:**
  - With `false`, a missing session gives `submitTarget = nil`. An existing session goes through the same `makeComposerSubmitTarget(tabID:session:)` call as before.
  - `refreshRecoveryListUI` only takes the `false` branch after checking `sessions[ownerTabID] == nil`, and all of this runs synchronously on the main actor, so the state can't change in between.
  - The ternary parses as intended: `||` binds tighter than `?:`.
  - The published `currentTabID` is always `currentTabID`, so this cannot produce another tab's props.
- **Behavior compared with earlier versions:**
  - **Fresh-workspace default tab:** a current tab with no session is the default tab of a new workspace before its first composer sync. Before F7 and in round 0, nothing was published there, so the composer showed default props with no target. The snapshot published now is equivalent, and the first `syncComposerUIState()` still creates the session and publishes a real target.
  - **Removed session:** when the current tab's session has been removed, round 0 left a stale target that the submit-time checks would reject. Now the button is honestly disabled. That is strictly better.
- **Materialization through other helpers:** `makeComposerProps` also calls helpers such as `canScheduleSend`, `isProviderPickerLocked`, and `agentWorkspaceLookupContextIdentity`. I can't read those from here, but the new test's `session(for: tabA, createIfNeeded: false) == nil` assertion checks the "never creates a session" guarantee end to end.
- **Privacy:** every new log takes a fixed literal reason, `route.rawValue`, or tab UUIDs. The `catch` branches log a fixed reason and not `error.localizedDescription`. Completion blocks log the reason and not the message. `rejection.diagnosticReason` is literal-only, as the worker reports. Nothing carries user content.
- **Test timing change (R3):** the observer uses `.receive(on: RunLoop.main)`, which always delivers on a later run-loop turn. Sampling the counter after `beforeDelivery()` therefore can't miss the delivery, and the setter's own synchronous sync can no longer satisfy the wait.

## P3 (improvements, not looped on)

**F7-R1-N1: a second publication path outside `syncComposerUIState`**
- **Where:** `AgentModeViewModel+RecoveryList.swift:1062`.
- **Problem:** the `else` branch calls `ui.composer.update(...)` directly. That bypasses the ownership boundary in `syncComposerUIState` and its DEBUG `test_syncComposerCallCount`. The logic is correct, since the owner is always the current tab. But it is a second place that must keep the ownership rule, and the spec's audit item asks to minimise those. It also means `postAndAwaitRefresh` would time out instead of passing if a refresh ever took this branch.
- **Smallest fix:** add a `materializingSession:` parameter to `syncComposerUIState` and call it from here. Or leave it as is and add a one-line comment saying this is the only other publication site.

**F7-R1-N2: scheduled-send exits without a specific reason**
- **Where:** `AgentModeViewModel+ScheduledSend.swift:~420`.
- **Problem:** in `executeComposerScheduleAttempt`, the `newWorkBlockedMessage` exit has no specific reason, while the submit path logs `new_work_blocked` (`AgentModeViewModel.swift:15354`). The `ensureSessionReady` failure just above `:413` falls outside the hunk, so I can't confirm whether it logs. The generic `schedule_completion_blocked` line covers both, so this is diagnostic precision only.
- **Fix:** add `schedule_new_work_blocked` and, if needed, `schedule_session_not_ready`.

**F7-R1-N3: no way to correlate the two log lines of one rejection**
- **Where:** `AgentModeViewModel+ComposerUI.swift:12-22`.
- **Problem:** one rejection now writes two lines: `submit_rejected` from the view model and `view_rejected … completion_blocked` from the view. They share only the target tab ID. Two quick attempts on the same tab can't be told apart.
- **Fix (optional):** log the attempt or submission-token identifier, which is not user content, in both.

**F7-R1-N4: no assertion that scheduling is off in the no-session snapshot**
- **Where:** `AgentComposerTabOwnershipTests.swift:~111`.
- **Problem:** the removed-session case asserts there is no `submitTarget`, but not that `canSchedule` is false. `canScheduleSend(tabID:session: nil)` is computed independently of the target. If it can return `true`, the schedule control may look enabled until `canScheduleToRenderedTarget` refuses it, which would also add a persistent `schedule_unavailable_for_rendered_target` line.
- **Fix:** add `XCTAssertFalse(props.canSchedule)`, or confirm the view gates scheduling on the rendered target.

## Recommendations

1. **Commit the step.** F7-R1 is closed and the delta introduces no P0 or P1.
2. If they're cheap, fold in N2 (two literal reasons) and N4 (one assertion). Defer N1 and N3, or record them as deferred on the status line.
3. Keep the R2 `assumed:` entry visible: there is still no ordering test for "publish after the tab switch", and the view's tab-change re-sync is the fallback.
4. Two things still need live checks, and neither the tests nor this review cover them:
   - the planned live composer checks (Send stays enabled across many recovery writes, and there is no foreign MCP chip);
   - a Tab-tag first send, using the new `ComposerSubmit` log, to capture the open F7 rejection reason.