# Restart minor fixes — worker report
Scope: read when the task touches restart-spec Step 7-minor (cancelled Codex bash row status and the recovery View popover click).
Authority: Reference
Last-verified: 2026-10-26

Source: spec "#### Minor observations" and the live-acceptance handoff ("Codex command in progress at quit", "Recovery buttons").

## Item 1 — Codex bash row reads `success` after quit cancelled its command: FIXED

### Root cause (code and tests only; saved app data was not read, per the main agent)

The handoff says the row was saved as `success`. That status comes from the relaunch path, not from the quit teardown:

1. **Restore re-arms the row.**
   - `applyCodexRestore` calls `reconcilePersistedCodexCommandStatusIfNeeded(session:)` (`CodexAgentModeCoordinator.swift:1544`).
   - With no rollout path, or after reconciliation, that calls `rebuildLiveBashExecutionState` (`:8942`).
   - That function turns every saved bash row still marked running into a live execution. The persisted summary keeps `status:"running"` and `processId`.
   - `updateBashLivenessTaskState` then starts the PID poll for any POSIX PID.
2. **The poll guesses success.** `pollBashLiveness` (`:9545`) settles a row as `statusWord: "finished", isError: false` (previously hard-coded) when two things hold:
   - its PID is gone;
   - it is past the 1.0 s quiet-signal grace and the 1.2 s unobserved-process grace.
3. **The guess reads as success.**
   - `normalizedStatusWord` maps `finished` to `success` (`AgentTranscriptServices.swift:672`).
   - `scheduleSave` then persists the row as a summary-only `success`.

After relaunch no Codex app-server is attached (`codexController == nil`), so no real completion can ever correct that guess. The command was killed by the quit, and the row says it succeeded.

`finished` is a reasonable provisional guess while an app-server is live, because the real `item/completed` result can still arrive. It is wrong once no provider exists.

Not proven statically: exactly why the row was still marked running when the quit saved it. The quit teardown (`AgentModeViewModel.swift:3977–3984`: `cancelEphemeralRuntimeState()` then `cancelAgentRun`) reaches `drainCodexTerminalBuffersForCancellation`, which settles *tracked* live executions as `cancelled`. A row the drain didn't settle survives as running, and the relaunch path above turns it into `success`. The fix is at the point that produces the wrong status, so it doesn't depend on which way the row escaped the drain.

### Fix

> Superseded by "Review follow-ups (round 1)" below. The helper was removed, the outcome now depends on controller ownership, and the word is `interrupted`. The text that follows describes round 0.

`CodexAgentModeCoordinator.swift`:
- New `static func vanishedBashProcessSettlement(hasLiveProvider:)` (`:9626`):
  - with a live provider: `("finished", false)`, unchanged;
  - without one: `("cancelled", false)`.
- `pollBashLiveness` passes `hasLiveProvider: session.codexController != nil` and uses the result (`:9577`, `:9602`).
- `withCommandExecutionTerminalStatus` fills `exitCode: 1` for `cancelled`, the same as the existing user-Stop drain. The card therefore shows the same state a Stop-cancelled command already shows (`ToolCardStatus.fromTranscriptStatus(.cancelled)` → `.failure`), and the persisted status word is `cancelled`.

Not changed: recovery classification, intents, shutdown ordering, the cancellation drain, the rollout reconciler, and provider protocol handling.

### Tests

Two tests added to `CodexAgentModeCoordinatorLivenessTests`. Both use a real exited and reaped PID (`/usr/bin/true`) and drive the real path: `reconcilePersistedCodexCommandStatusIfNeeded` → rebuild → liveness poll.

- `testRestoredRunningBashRowWithVanishedProcessSettlesAsCancelledWithoutLiveProvider` (`:1495`), with no controller:
  - the JSON status normalizes to `cancelled`;
  - `toolIsError` is not `true`. The bash persistence policy normalizes it to `nil`; asserting `false` failed on the first run, so the assertion was corrected;
  - `sanitizedToolResult` gives `persistedStatusWord == "cancelled"` and `transcriptStatus == .cancelled`.
- `testRunningBashRowWithVanishedProcessStaysProvisionallyFinishedWithLiveProvider` (`:1521`) is the control. With a controller attached, the row still persists as `success`, so live behavior is unchanged.

Fail-first: with the settlement temporarily forced back to `("finished", false)`, the first test failed three times with `"success" is not equal to "cancelled"`, which is the reported symptom. The fix was then restored and re-verified (`grep` plus the final green run).

### Behavior note

> Wrong in round 0; corrected under "Review follow-ups (round 1)" below.

A command still running when the idle shutdown (300 s) retires the app-server now settles as `cancelled` instead of `finished` once its PID disappears. The app-server's teardown ends its children, so `cancelled` is the more accurate label.

## Item 2 — View popover swallows the next press on its row: NOT CHANGED (stopped at diagnosis)

### Root cause

`AgentRecoveryListRow` (`Sources/RepoPrompt/Features/AgentMode/Views/Components/AgentRecoveryListBanner.swift:121–124`) presents the viewer with a SwiftUI `.popover(isPresented: $isViewing, arrowEdge: .top)` on the View button. On macOS, SwiftUI backs this with a **transient** `NSPopover`.

While it is open, a click outside it is used to close the popover and is not delivered to the control underneath. So the first Remove/Dismiss press only dismisses the viewer. The Continue editor popover (`:137`) behaves the same way, but its actions are hidden by `AgentRecoveryActionQualification.production`.

### Why stopped

SwiftUI has no API to set the popover `behavior` on macOS, so the smallest standard fix the brief had in mind (`.semitransient` or similar) isn't available.

A toggle-style View button wouldn't help: the swallowed click never reaches any SwiftUI button.

Each real fix needs new presentation code or a UX choice, and the click behavior can only be checked in the running app, which this task may not launch.

### Options

| Option | Change | Cost / risk |
|---|---|---|
| **A. AppKit popover bridge** (recommended) | A small `NSViewRepresentable` anchored on the View button owning an `NSPopover` with `.applicationDefined` behavior, so outside clicks pass through. It closes on View re-press, on any row action, on Escape or a Close button, and when the row is dismantled. | About 60–80 lines, local to this view or `RepoPromptUI/Components`. Needs a live click check (CGEvent and AX press), and needs closing when the session or window changes. |
| B. Sheet | View opens a `.sheet` with a Done button. The row is used inside the Needs Attention sheet, so this nests sheets. | About 10 lines; modal UX change for the owner to accept. |
| C. Inline disclosure | The row expands to show the saved text. | Breaks the fixed 52 pt row and 3-row banner height (`reservedHeight`); larger layout change. |
| D. Mitigation only | Make View toggle, and close the viewer at the start of each row action. | Doesn't fix the swallowed click; not recommended. |

No automated test is practical for the pure AppKit click delivery. A ViewInspector-style test can't show NSPopover event swallowing.

## Files changed

- `Sources/RepoPromptAgentCore/AgentMode/Runtime/Codex/CodexAgentModeCoordinator.swift` (+14/−2)
- `Tests/RepoPromptTests/AgentMode/Codex/CodexAgentModeCoordinatorLivenessTests.swift` (+80)
- Diff: `prompt-exports/restart-fixes/minor.diff` (these two files only; no untracked files). The owner's pre-existing changes, such as `Tests/RepoPromptTests/Helpers/CodemapSeamTestSupport.swift`, are excluded and were not touched.

## Validation

- `make dev-build`: passed. Packaging republished `/Applications/RepoPrompt CE Dev.app` as the coordinated build does; nothing was launched, relaunched or stopped.
- `make dev-test FILTER="'CodexAgentModeCoordinatorLivenessTests|AgentToolResultPersistencePolicyTests|BashToolResultParserRecoveryTests'"`:
  - first run (job `5cde9adc-…`): 1 failure, the `toolIsError == false` assertion described above;
  - after the fix (job `bfa9e671-…`): 83 tests, 0 failures;
  - final run after the lint wrap (job `cae489b2-a792-4e85-98ba-2a5e780b07b7`): 83 tests, 0 failures.
- Fail-first, single test (job `4ed5414d-6fed-42e7-9f42-d527036349b0`): 3 expected failures (`success` ≠ `cancelled`) with the old settlement.
- `make dev-lint`:
  - first run: 2 `wrapFunctionBodies` findings in the new test helper; fixed;
  - re-run: exit 0.
- `make guardrails`: exit 0, with one existing warning (AGENTS.md route count 24 > 15, not from this change).

Not run: the full test suite, and any live-app check of either item (launch not allowed). No routed context document is invalidated. The restart spec was not edited, as instructed. The owner may want to update its "Minor observations" entry for item 1 after review.

## Review follow-ups (round 1)

This round covers OracleA MINOR-01 (P1), MINOR-02 and MINOR-03, and OracleB M1–M4. Line numbers refer to the current tree.

### MINOR-01 / M1 — settle as `finished` only for the owning controller: FIXED

In round 0 the poll checked only whether *a* controller existed. A restored row could still settle as `success` if a controller was attached after the rebuild.

Ownership is now recorded on the execution:

- **New field.** `AgentBashLiveExecutionState.ownerControllerGeneration: UUID?` (`AgentSessionRunStateRecords.swift:305`). It holds the `codexControllerGeneration` of the controller whose events drive the execution. It is `nil` when the execution was rebuilt from saved rows.
- **Claiming on create and upsert.** In `CodexAgentModeCoordinator.swift`:
  - `ensureLiveBashExecutionState` (`:8624`) and `upsertLiveBashExecution` (`:8753`) take `claimsCurrentProvider: Bool = true`. Provider event paths keep the default, so they claim.
  - A new state is stamped with the current generation, or `nil` if no controller is attached.
  - Existing and migrated states are claimed through the private helpers `currentControllerGeneration(of:)` (`:8725`) and `claimLiveBashExecution` (`:8730`). A migrated state carries its previous owner across.
- **Claiming on running updates.** `applyLiveBashRunningUpdate` (`:8857`) re-stamps the owner from the current controller and keeps the old owner if none is attached.
- **Rebuild claims nothing.** `rebuildLiveBashExecutionState` (`:8967`) works like this:
  - it captures each execution's owner by transcript item before `clearBashLiveExecutions()`;
  - it upserts with `claimsCurrentProvider: false` (`:8997`);
  - it puts the captured owners back in a `defer`.

  So a row rebuilt from saved data stays unowned even when a controller is attached, and an execution that was already live keeps the owner it had.
- **The poll checks ownership.** `pollBashLiveness` (`:9618`, `:9644–9646`) settles a vanished PID as `finished` only when a controller is attached and `execution.ownerControllerGeneration == currentGeneration`. Otherwise it settles as `interrupted`.

The generation is a fresh UUID each time the `codexController` `didSet` sees a new identity, including nil. That means a replaced controller does not inherit executions owned by the old one.

### Recommendation 2 — do idle shutdown and app-server teardown nil the controller? Yes

Every path that retires the app-server stops the liveness poll and sets `session.codexController = nil`:

| Path | Stops poll | Sets `codexController = nil` |
|---|---|---|
| Idle shutdown (300 s): `scheduleCodexIdleShutdownIfNeeded` (`:9414`) calls `await shutdownCodexSession(session)` (`:9451`), defined at `:10456` | `:10467` | `:10484` |
| Transport closed while idle (`:8189–8204`): `invalidateCodexControllerForReconnect` (`:4661`), then the idle-shutdown schedule | `:4682` | `:4696` |
| Provider switch | `:3573` | `:3579` |
| Reset paths | `:10312`, `:10397` | `:10317`, `:10399` |

**Corrected behavior note.** The round 0 note said such a row "settles as `cancelled` once its PID disappears". That is wrong, because these paths stop the poll before the PID is checked again. Nothing settles the row at shutdown time.

The row settles the next time live executions are re-armed:
- on restore, through `reconcilePersistedCodexCommandStatusIfNeeded` (`:9919`) and the rebuild;
- or when a later reconcile rebuilds the executions.

At that point the row is unowned, so it settles as `interrupted`, which is stored as `cancelled`. Executions whose real completion arrives are unaffected.

**Residual.** When the transport closes while a run is active, the controller is kept during the recovery grace (`scheduleCodexTransportClosedFallback`, `:4848`). During that window ownership still matches the dead controller, so a vanished PID can still settle as the provisional `finished` until the controller is replaced. Closing that gap would need a liveness signal from the controller, which is not a small local fix, so it was left alone.

### MINOR-02 / M3 — raw word `interrupted` instead of `cancelled`: DONE

The poll now writes `interrupted`:

- `interrupted` is a terminal word, so the bash parser treats the row as not running.
- `normalizedStatusWord` maps it to `cancelled`. The persisted status word, `transcriptStatus == .cancelled` and the card (`ToolCardStatus.fromTranscriptStatus(.cancelled)` → `.failure`) are identical to round 0.
- `withCommandExecutionTerminalStatus` adds a default exit code only for `completed`, `failed`, `cancelled` and `canceled`. The `exitCode: 1` that round 0 invented is therefore gone, and the row has no exit code.

The raw word does not survive the save: by the time the row is observed or persisted, it already reads `cancelled`. The tests assert the normalized `cancelled` and `exitCode == nil`.

### M2 / MINOR-03 — tests: ADDED

All four tests are in `CodexAgentModeCoordinatorLivenessTests`. They use a real PID that has exited and been reaped (`/usr/bin/true`).

- `testRestoredRunningBashRowWithVanishedProcessSettlesAsInterruptedWithoutLiveProvider` (`:1495`, renamed from round 0) restores through `restoreCodexMetadata` with no controller.
- `testRestoredRunningBashRowStaysUnownedWhenControllerAttachesAfterRebuild` (`:1507`) is the new M2 test:
  - it restores and asserts that live executions were rebuilt;
  - it then attaches a controller and lets the PID vanish;
  - it asserts a non-success outcome: `cancelled`, no exit code, and `toolIsError` not `true`.
- `testLiveProviderBashExecutionWithVanishedProcessStaysProvisionallyFinished` (`:1520`) is the control, now driven by real provider events (`.toolCall` plus an in-progress `.toolResult`):
  - the helper asserts that the execution's owner equals the session's current generation;
  - the vanished PID still persists as `success`.
- `testAuthoritativeBashCompletionBeforePollSurvivesLivenessPoll` (`:1538`) is the ordering test:
  - an authoritative `failed` result with `exitCode: 2` arrives before any poll, which removes the live execution;
  - after 2 s, which is past every liveness grace, the row still reads `failed` with exit code 2 in both liveness metadata and persisted form.

**Fail-first.** With the poll rule temporarily put back to round 0's `currentGeneration != nil ? "finished" : "cancelled"`, the M2 test failed with `"success" is not equal to "cancelled"` (job `985ad579-52ec-4401-925a-d6df0df8b843`). The fix was then restored.

### M4 — shrink or privatize the helper: DONE

`vanishedBashProcessSettlement` is removed and the rule is inlined in the poll. The only new helpers, `currentControllerGeneration(of:)` and `claimLiveBashExecution`, are `private`.

### Validation (round 1)

- `make dev-build`: exit 0. Packaging republished the Dev bundle as usual; nothing was launched, relaunched or stopped.
- `make dev-test FILTER="'CodexAgentModeCoordinatorLivenessTests|AgentToolResultPersistencePolicyTests|BashToolResultParserRecoveryTests'"`:

  | Job | Result |
  |---|---|
  | `6bd4e753-…` | 3 failures: tests expected the raw `interrupted`, which is already normalized by then |
  | `97784180-…` | 1 failure: an output assertion on `boom`, but the settled row JSON is a summary |
  | `6892772c-…` | 85 tests, 0 failures |
  | `32f1873f-4985-46cf-a1a9-a080ef6f6c95` (final) | 85 tests, 0 failures |

  The `interrupted` assertion and the `boom` assertion were wrong test expectations; neither change weakened what is being checked.
- `make dev-lint`: exit 0.
- `make guardrails`: not rerun this round. It was not requested, and no files were added or moved.

### Files and diffs (round 1)

| File | Change |
|---|---|
| `Sources/RepoPromptAgentCore/AgentMode/Runtime/Codex/CodexAgentModeCoordinator.swift` | +56/−9, round 0 and round 1 combined |
| `Sources/RepoPromptAgentCore/AgentMode/Runtime/Session/AgentSessionRunStateRecords.swift` | +3, new |
| `Tests/RepoPromptTests/AgentMode/Codex/CodexAgentModeCoordinatorLivenessTests.swift` | +189 |

- `prompt-exports/restart-fixes/minor.diff` was regenerated with `git diff` of these three files only. The owner's changes are still excluded.
- `prompt-exports/restart-fixes/minor-delta.diff` is `git diff --no-index minor-r0.diff minor.diff`, a diff of the two patch files. Applying round 0 to a scratch tree for a true source-level delta was denied by the permission prompt.

### Leftovers

- The transport-closed-while-active residual described under Recommendation 2.
- Item 2 (the View popover) is unchanged; options A–D above still apply.
- The scratch directory `/tmp/rpce-minor-r0` holds HEAD extracts only and was not deleted.

## Review follow-ups (round 1 re-review)

The findings are in `prompt-exports/oracle-review-2026-10-26-142445-minor-bash-row-re-re-9cb8.md`. This round applies R1-01, R1-03, R1-04 and R1-05. As instructed, R1-02 (the transport-close residual) and R1-06 (the rebuild's capture-then-restore `defer`) were not done. Line numbers refer to the current tree.

### R1-01 — `claimsCurrentProvider` is now required: DONE

The default was removed from `ensureLiveBashExecutionState` (`CodexAgentModeCoordinator.swift:8626`) and `upsertLiveBashExecution` (`:8756`), so every call site now states its intent. I audited every caller:

| Call site | Path | Value | Why |
|---|---|---|---|
| `:7788` | `.toolCall` bash event from the native controller | `true` | Provider event |
| `:7864` | `.toolResult` bash running event | `true` | Provider event |
| `:8767` | Inside `upsertLiveBashExecution`, forwarding to `ensure` | pass-through | — |
| `:8849–8856` | `applyLiveBashRunningUpdate` | `true` | See below |
| `:8943` | `finalizeLiveBashExecution` fallback, when no live execution exists | `false` | See below |
| `:9003` | `rebuildLiveBashExecutionState` (saved rows; it runs after the rollout reconcile in `reconcilePersistedCodexCommandStatusIfNeeded`, `:9919`) | `false` | Rebuild from saved rows, unchanged |
| `:9871` | `reconcileCodexCommandExecutionRunningUpdate`, bash branch | `true` | See below |

**`applyLiveBashRunningUpdate` (`:8849–8856`).** Its callers all carry live provider updates:
- buffered running updates flushed before finalization (`:9026`);
- coalesced running updates (`:9325`);
- the `write_stdin` branch of `reconcileCodexCommandExecutionRunningUpdate`.

**`finalizeLiveBashExecution` fallback (`:8943`).** It is reached from the liveness poll and the cancellation drain as well as from events. The state it creates is removed later in the same call, so nothing ever reads its owner.

**`reconcileCodexCommandExecutionRunningUpdate` (`:9871`).** All four callers are live streams:
- `handleCodexToolResult` from the MCP tool tracker (`:6378`);
- the native `.toolResult` fallback (`:7958`);
- `AgentModeViewModel.applyStreamResult` (`AgentModeViewModel.swift:19719`);
- `applyClaudeLiveTranscriptToolRow` (`AgentModeViewModel.swift:20374`).

**No non-event caller claims ownership today, and no observable behavior changed.** The only value that differs from the old default is the `finalizeLiveBashExecution` fallback, and its owner is discarded within the same call.

No path builds live executions from a resumed thread's history:
- `readThreadSnapshot` (`:2798`, `:4353`) only reads turn state and never touches bash executions;
- the rollout import feeds the rebuild, which passes `false`.

The two private `applyCodexCommandExecutionRunningUpdate` overloads (`:9902`, `:9910`) have no callers. They are pre-existing dead code and I left them alone.

### R1-05 — ownership is claimed in exactly one place: DONE

`claimLiveBashExecution` (`:8733`) is now the only writer of a newly claimed owner:
- `ensureLiveBashExecutionState` creates new states with `ownerControllerGeneration: nil` and claims through it when `claimsCurrentProvider` is true, as it already did for existing and migrated states.
- The re-stamp in `applyLiveBashRunningUpdate` (round 1's `:8857`) is deleted.

Deleting the re-stamp alone would have dropped a claim. That function reads `existingLookup?.state ?? ensure(...)`, so an execution that already exists never passes through `ensure`. The existing-lookup branch therefore now goes through `claimLiveBashExecution` too (`:8849`). The rebuild's `defer` still restores owners captured before the clear; R1-06 was not requested.

### R1-03 — a real completion after an `interrupted` settlement: TEST ADDED

`testAuthoritativeBashCompletionAfterInterruptedSettlementReplacesIt` (`CodexAgentModeCoordinatorLivenessTests.swift:1568`) runs these steps:
1. It starts an execution through the controller's events.
2. It swaps in a new controller. This bumps the generation, so the execution becomes unowned.
3. It waits for the poll to settle the row as `interrupted`, stored as `cancelled` with no exit code.
4. It delivers an authoritative `failed` `.toolResult` with exit code 2 through the native event path.

It then asserts:
- no live execution remains;
- there is still exactly one bash row, updated in place;
- the row's liveness metadata and its persisted form both read `failed` with exit code 2.

The event path does reach a row that is already settled. `finalizeLiveBashExecution` falls back to `ensure`, which re-anchors on the row by invocation ID and merges the incoming completion over it. Nothing had to be forced.

### R1-04 — the ordering test's sleep is dropped: DONE

`testAuthoritativeBashCompletionBeforePollSurvivesLivenessPoll` (`:1538`) no longer sleeps for 2 s. It keeps the empty-map guard, which shows the poll has nothing left to act on, and then checks `failed` with exit code 2. It now takes about 0.1 s instead of 2 s. The failed/2 checks are shared with the R1-03 test through `assertFailedWithExitCode2`.

### Validation (round 1 re-review)

- `make dev-build`: exit 0. The Dev bundle was republished as usual; nothing was launched, relaunched or stopped.
- `make dev-test FILTER="'CodexAgentModeCoordinatorLivenessTests|AgentToolResultPersistencePolicyTests|BashToolResultParserRecoveryTests'"`:
  - job `ba77945e-e9a5-4ddb-835e-d842382e7d53`: 86 tests, 0 failures;
  - after the lint fix, job `bf310c86-4342-4bbc-aa81-2fdd3b13a463`: 86 tests, 0 failures.
- `make dev-lint`:
  - first run (job `17c571b2-…`): one `preferCountWhere` finding in the new test; fixed with `count(where:)`;
  - re-run (job `7758d9c0-bb12-4269-8560-7b4df7bbf4ad`): passed.
- `make guardrails`: **exit 2**, from five `[reachability]` orphan errors.
  - The orphans are this report and the four review files: `fix-minor-review-oraclea.md`, `fix-minor-review-oraclea-r1.md`, `fix-minor-review-oracleb.md` and `fix-minor-review-oracleb-r1.md`.
  - The existing route-count warning is also still reported.
  - The errors clear once the spec's Step 7-minor status line links these files, as was done for the earlier F-steps. I'm not allowed to edit the spec, so I left that to the main agent.
  - This round changed no source layout.
- Not run: the full suite and any live-app check. Restoring with a rollout present is still untested; the audit above shows the rollout path ends in the `false` rebuild.

### Diff

`prompt-exports/restart-fixes/minor.diff` was regenerated with `git diff -- Sources Tests ':!Tests/RepoPromptTests/Helpers/CodemapSeamTestSupport.swift'`.
