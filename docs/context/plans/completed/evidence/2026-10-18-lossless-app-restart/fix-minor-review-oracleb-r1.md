# Restart minor fixes — OracleB re-review 1
Scope: read when the task touches restart-spec Step 7-minor review findings (cancelled Codex bash row status).
Authority: Reference
Last-verified: 2026-10-26

Covers: OracleB fresh-chat re-review round 1 of the Step 7-minor item 1 delta (controller ownership), with its own dispositions. Verbatim export follows.

# Oracle Review



# Re-review round 1: lossless-app-restart Step 7-minor, item 1

## Summary

The change adds `ownerControllerGeneration: UUID?` to each live bash execution. It is set from `session.codexControllerGeneration` when provider events create or update an execution. Rebuilding from saved rows claims nothing, and owners that were already set survive the rebuild. When a process vanishes, the liveness poll now writes `finished` only if the attached controller owns the execution; otherwise it writes `interrupted`. That word persists as `cancelled` and gets no invented exit code. `vanishedBashProcessSettlement` is gone and the new helpers are private.

I found no P0 or P1 regression in the delta. Here are the cases you asked about:

- **Generation bump while a command is live.** `invalidateCodexControllerForReconnect` (`:4677–4696`) stops the poll and sets the controller to nil, which bumps the generation. The next controller is a new app-server and will not report the old command, so settling it as `interrupted` is correct. Before this change it settled as a provisional success.
- **Stale events from the old controller.** With `cancelEventTask: false`, an event from the old controller can still be processed after the swap and claim the execution for the new generation. That gives the same provisional `finished` as round 0, so it is not a regression.
- **Live rows that never get an owner.** The main provider paths claim ownership on every event: create, existing, migrated, and running updates (`:8857`). The helper in the M2 test asserts that the owner equals the current generation after `.toolCall` plus an in-progress `.toolResult`. An unowned live row only happens if no event at all is processed while the controller is attached. That would be unusual, and it only changes the provisional word.

The step's scope holds. Recovery classification, intents, shutdown ordering and the cancellation step are untouched.

## P2

### R1-01: The ownership claim defaults to on, so callers not updated in this delta silently claim
- **Evidence:** `ensureLiveBashExecutionState` (`CodexAgentModeCoordinator.swift:8623`) and `upsertLiveBashExecution` (`:8753`) both take `claimsCurrentProvider: Bool = true`. Only the rebuild (`:8997`) opts out. The delta did not audit the other callers. For example, the fallback in `finalizeLiveBashExecution` (`:8931–8938`) claims and then immediately removes, which is harmless.
- **Failure scenario:** Any non-event path that turns rows into live executions with the default would claim a restored row for whichever controller is attached. Examples are reconciling a resumed thread's history or importing a rollout. That row would then settle `finished`, which reads as `success`. This is exactly what the step forbids.
  - The window is narrow. A restored dead PID settles about 1.2 s after restore (the unobserved-process grace from `firstSeen`, since `lastSignalAt` is the old item timestamp). The controller usually attaches later than that.
  - It only bites if auto-resume attaches a controller within that grace and the replay goes through these helpers. Restoring with a rollout present is still untested.
- **Smallest fix:** Make the parameter required, with no default, so every call site states its intent. Then grep the callers once.

### R1-02: The transport-closed residual has a cheaper fix than the report suggests
- **Evidence:** `scheduleCodexTransportClosedFallback` (`:4848`) keeps the controller attached during the recovery grace, and the poll keeps running.
- **Failure scenario:** The app-server dies in the middle of a command. Its child process dies with it, the poll sees the vanished PID while ownership still matches, and the row settles `finished`/`success`. The later fallback invalidation never re-settles it.
- **Impact:** This is behavior that predates the change, and it is outside "after relaunch". I agree with deferring it as P2.
- **Cheap fix if wanted:** When transport close is detected for the controller that owns these executions, set `ownerControllerGeneration = nil` on them. A closed transport cannot deliver new completions. Completions that were already buffered still finalize authoritatively through the event path, and any running events among them reclaim ownership anyway. This is about five local lines and needs no liveness signal from the controller.

## P3

### R1-03: A late real completion after a provisional `interrupted` is not covered by a test
Round 0's design relied on a real completion overwriting a provisional `finished`. Owned executions still depend on that. An unowned live row would now show cancelled/failure until the overwrite happens. Neither direction is tested.
- **Fix:** Add one test: the poll settles a row, then an authoritative `failed` with exit code 2 arrives, and the row must read `failed`/2. This test is more valuable than the current ordering test (R1-04).

### R1-04: The ordering test cannot catch the race it is named for
`testAuthoritativeBashCompletionBeforePollSurvivesLivenessPoll` asserts `bashLiveExecutionByKey.isEmpty` before it sleeps. With no live executions the poll has nothing to act on, so the 2 s wall-clock sleep exercises nothing and adds time on a noisy host.
- **Fix:** Drop the sleep and keep the empty-map assertion as the guard. Or replace the test with the one in R1-03.

### R1-05: Ownership is stamped twice in `applyLiveBashRunningUpdate`
`:8857` re-stamps the owner even though the `ensureLiveBashExecutionState` call just above it already claims through `claimLiveBashExecution`. The `?? state.ownerControllerGeneration` fallback is also redundant.
- **Fix:** Delete the line, or keep exactly one place where ownership is claimed.

### R1-06: The rebuild's capture-then-restore `defer` is roundabout
`rebuildLiveBashExecutionState` captures owners, clears, upserts unowned, then calls `setBashLiveExecution` again for each execution in a `defer`. This doubles the writes and splits one rule across two places.
- **Fix:** Look up the captured owner inside the loop and pass it into the upsert. Combined with R1-01, the Bool could become an explicit owner argument (for example `.currentController` or `.preserve(UUID?)`).

## Recommendations

1. Commit the step. No P0 or P1 is open, and none of the delta's behavior is a regression from round 0.
2. Before or with the commit, do R1-01: remove the `claimsCurrentProvider` default and grep its callers. Any caller that rebuilds from history or rollout data should pass `false`.
3. Record R1-02 as a deferred P2 with the cheap fix described above. Leave it to the owner whether it belongs in this step.
4. Fix R1-03 through R1-06 only where they are cheap. R1-03 plus dropping the sleep from R1-04 is the most worthwhile pair. Don't run another review round for them.
5. Validation gaps to note in the status line: the full suite and the live app were not run, and restoring with a rollout present is untested (it relates to R1-01).