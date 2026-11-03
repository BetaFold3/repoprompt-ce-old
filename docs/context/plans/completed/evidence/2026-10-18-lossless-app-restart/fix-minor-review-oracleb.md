# Restart minor fixes — OracleB initial review
Scope: read when the task touches restart-spec Step 7-minor review findings (cancelled Codex bash row status).
Authority: Reference
Last-verified: 2026-10-26

Covers: OracleB fresh-chat initial review of the Step 7-minor item 1 diff (review mode, explicit slices incl. review policy). Verbatim export follows.

# Oracle Review



# Review: Step 7-minor, item 1 (vanished Codex bash process settles as `cancelled` when no provider is attached)

## Summary

The change replaces the hard-coded `("finished", false)` that `pollBashLiveness` used for a running bash row whose PID has disappeared. It now goes through `vanishedBashProcessSettlement(hasLiveProvider:)`, which returns `cancelled` when `session.codexController == nil` and keeps `finished` otherwise.

This fixes the reported relaunch path. Restore rebuilds live executions from persisted running rows, the PID poll finds the PIDs gone, and no app-server exists, so those rows now persist as `cancelled` instead of `success`. The change stays inside its scope: classification, intents, shutdown ordering, the cancellation drain and the rollout reconciler are untouched.

Two tests cover both branches through the real reconcile → rebuild → poll path, using a genuinely reaped PID, and the fail-first check is sound. I found no P0 or P1. The main gap is that "a controller is attached" stands in for "this controller owns this command". That stand-in can be wrong in a narrower set of cases, and the tests don't cover them.

### Path-by-path assessment

| Path | Verdict |
|---|---|
| **Relaunch restore, no reconnect yet** | Correct. `applyCodexRestore` → `reconcilePersistedCodexCommandStatusIfNeeded` (`:1544`) → rebuild (`:8942`) → poll. Nothing can deliver a result, so `cancelled` is right. |
| **Real result already recorded** (delivered before quit, or present in the rollout) | Not affected. The poll only looks at `bashLiveExecutionByKey` entries that are `isRunning`. Rollout reconciliation runs before the rebuild, so rows it already settled are never re-armed. `finalizeLiveBashExecution` removes the execution, so the poll cannot overwrite a terminal row. |
| **Command really finished just before quit, completion not delivered or in the rollout** | Now shows `cancelled`, where before it showed `success`, and the true outcome is unknown. This errs in the safe direction (see M3). |
| **Idle app-server shutdown (300 s)** | Correct **only if** idle shutdown sets `session.codexController` to nil. The slices provided don't show this. If the controller object survives disconnected, those rows still settle as `success`, and the report's "Behavior note" is wrong (see Recommendations). |
| **App-server attaches later** (user sends, resume) | The poll treats any later controller as the owner of the command. See M1. |
| **Late real result after settlement** | Unchanged from before. A resumed app-server normally doesn't re-send `item/completed` for a command from before the quit. If one arrives, it is handled the same way it was against the old provisional `finished`. |

## Findings

### P2

**M1: An attached controller is treated as owning the command, so restored rows can still settle as `success`**
- **Evidence:** `CodexAgentModeCoordinator.swift:9577–9579` evaluates `session.codexController != nil` at poll time. `rebuildLiveBashExecutionState` (`:8942–8959`) records nothing about which provider, if any, owned the execution.
- **Failure scenario:** a row saved as running is restored. Its saved PID now belongs to an unrelated live process, which is plausible after a reboot or PID wraparound. `shouldTreatRunningProcessAsAlive` therefore keeps the row running. The user then sends in that tab, so a controller attaches. When the unrelated process later exits, the poll sees `hasLiveProvider == true` and settles the row as `finished`, which reads as `success`. A user who sends within the roughly 1.2 s grace plus poll interval after restore hits the same race. So does an in-run app-server crash and restart that installs a new controller before the poll runs.
- **Impact:** the exact reported symptom comes back, in a narrower and unlikely window. No data is lost, and the command really was killed.
- **Smallest fix:** store ownership on the live execution instead of checking presence at poll time. For example, in `rebuildLiveBashExecutionState`, mark executions as `providerOwned = (session.codexController != nil)`, or store the controller's `ObjectIdentifier` or a generation number. Then settle as `finished` only when the execution is owned by the *current* controller, and as `cancelled` otherwise. This is about 5–10 lines.

**M2: The tests prove the two branches of the helper, not the property across paths**
- **Evidence:** `CodexAgentModeCoordinatorLivenessTests.swift:1495` calls `reconcilePersistedCodexCommandStatusIfNeeded` directly on a fresh session with no rollout path. It never goes through `applyCodexRestore`, despite the "Restored" name. `:1521` attaches a controller before the row exists.
- **Not covered:**
  - a controller attached after restore and before the PID vanishes (M1; this would currently fail);
  - a restore with a rollout path that already holds the real completion, which would prove the new branch can't preempt reconciliation;
  - the idle-shutdown teardown path behind the report's behavior note.
- **Impact:** a regression in restore ordering, or the M1 case, would pass the suite.
- **Smallest fix:** add one test. Restore through `applyCodexRestore`, attach a controller after the rebuild, then let the PID vanish, and assert `cancelled` once M1 is fixed. Optionally add a rollout-present test that asserts the recorded status survives.

### P3

**M3: An unknown outcome is labeled `cancelled`, with an exit code of 1 filled in**
- **Failure scenario:** the command really exited 0 a few milliseconds before quit, and the completion was in neither the transcript nor the rollout. It now reads `cancelled`, and the card shows `.failure` with `exitCode: 1`, which `withCommandExecutionTerminalStatus` fills in. The same pre-existing code path handles user Stop.
- **Impact:** cosmetic and rare, and it errs in the safe direction, which matches the step goal.
- **Fix:** none required. Optionally write `interrupted`, which also normalizes to `cancelled` (`AgentTranscriptServices.swift:679`), so the raw JSON doesn't claim the user cancelled it. Either way, note the trade-off when the spec's "Minor observations" entry is updated.

**M4: The helper is wider than it needs to be**
- **Evidence:** `:9626–9628`. `isError` is `false` in both branches. The function is `static` and internal, but the tests don't call it directly.
- **Fix:** return only the status word, and make it `private`, or test it directly. If M1 is fixed, this helper turns into the ownership check anyway.

## Recommendations

1. **Accept the step as is.** No P0 or P1 is open, the goal is met for the reported scenario, and nothing outside scope changed.
2. **Check one thing before trusting the behavior note:** confirm that idle shutdown (300 s) and the app-server's own teardown set `session.codexController = nil`. If the controller object survives disconnected, the idle-shutdown case still settles as `success`, and either the report's note needs correcting or M1's ownership fix becomes the actual remedy for that path.
3. **Fix M1 if it's cheap (about 10 lines).** Record which controller owns each live execution at rebuild and upsert time, and settle as `finished` only for executions owned by the current controller. This also closes the in-run crash and restart case.
4. **Add the M2 test** (restore through `applyCodexRestore`, then attach a controller later). It doubles as fail-first evidence for M1.
5. **Defer M3 and M4.** When the owner updates the spec's "Minor observations", note that item 1 is fixed for no-provider settlement, and that an unknown outcome now deliberately reads `cancelled`.