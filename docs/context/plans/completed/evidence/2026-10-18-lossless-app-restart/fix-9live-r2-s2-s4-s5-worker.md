# 9-live round 2: S2, S4 and S5 (survivor item and row wording)
Scope: read when the task touches the surviving-process recovery item, Let it finish, or interrupted-turn row wording.
Authority: Reference
Last-verified: 2026-10-29
Covers: diagnosis and changes for S2, S4 and S5 from the round-2 live check

Source findings: `verifier-9live-r2-results.md` (S2, S4, S5; rows V1 and E6). Raw evidence: `.agent-artifacts/lossless-restart-ordinary-acceptance/cycle15/` (`p3a-k1/`, `kill1/`).

## S2: Let it finish "removed" the survivor item

**Verdict: intended behavior and a timing coincidence. Not a bug. No code change.**

Contract (spec §R6 "Let finish (default): record the choice and keep watching"; `verifier-scenarios.md` V1): Let it finish keeps the item, with "You chose to let it finish; RepoPrompt keeps watching it.", **while the process family lives**. Exit watching then ends the restriction, and the item leaves.

Code path:
- `AgentModeViewModel+RecoveryList.swift` `letRecoveryRuntimeFinish` → `AgentRecoveryCoordinator.letRuntimeFinish` → `AgentProcessRegistry.letFinish`. That persists `letFinish = true` and keeps the record's state.
- `restrictionSnapshot()` and `AgentRecoveryCatalog.addRuntimeRestrictions()` never filter on `letFinish`. The item stays while the state is `live`/`unknown`/`toolsRemaining`.
- The detail text appends the Let finish sentence (`recoveryListRuntimeText`).
- Existing coverage: `AgentRecoveryRuntimeOwnershipTests.testLetFinishPersistsAndKeepsTheRestriction`. The new S5 test also pins the sentence in the item text.
- The item leaves only when a refresh classifies the family `exited` (`AgentProcessRegistry.swift:724`). Per-process exit watches trigger that refresh (`installWatches`/`watchFired` → `requestRefreshFromEvent()`, lines 753 and 763) without the user pressing Refresh.

Evidence that the process exited at the click:
- K1's loop was `for i in $(seq 1 58); do sleep 10; …`, started 00:14:40. 58 × 10 s ends at 00:24:20.
- The live runtime record `ED097DFD-0435-4EEB-A156-3E68B7AAE33C.json` (read only) is `state: exited`, `letFinish: true`, `updatedAt` 00:24:20.8.
- `letFinish` requires the displayed revision, and the exit write issues a new revision. So the Let finish write landed first, and the exit write followed under a second later.
- Screenshots: `04-v1-send-refused.png` at 00:24:18 still shows the item; `05-v1-let-it-finish.png` at 00:24:25 shows it gone (badge 33).

Guide note (not edited, per brief): V1's "Let finish keeps the item with 'You chose to let it finish'" can only be checked while the process lives. Use a sleep long enough (≥ 20 min) and read the text right after the click. V1's "after the process exits, Refresh clears the survivor item" is also stricter than the code: the exit watch normally clears it with no Refresh. Refresh is only needed when a watch couldn't be installed. The main agent may want to reword V1.

## S4: "RepoPrompt quit unexpectedly during this turn…" after a normal quit

**Verdict: wording issue. Fixed.**

A Turn interrupted row is always rebuilt from a turn stamp written by an earlier launch, and it survives later normal quits. The `.appCrash` text now names the earlier launch. Other reasons are unchanged: a normal quit still reads "RepoPrompt was quit during this turn."
- `Sources/RepoPrompt/Features/AgentMode/ViewModels/AgentModeViewModel+RecoveryList.swift:776`: `.appCrash` → "In an earlier launch, RepoPrompt quit unexpectedly during this turn."
- Only the recovery-list turn row uses this text. The crash-hold banner ("RepoPrompt quit unexpectedly while this session was working…") is separate and goes away once the hold is confirmed, so it was left alone.

## S5: survivor item names the shim's PID

**Verdict: presentation gap. Fixed.**

The record's root is the launcher shim (`node …/claude-rotator/shim/bin/claude`, PID 56334). The CLI itself (56474) is a `writer` member (`kill1/runtimes-before/ED097DFD-….json`: members `writer 56474`, `unknown 57000`). The restriction carried only `rootPID`.
- `Sources/RepoPromptAgentCore/AgentMode/Runtime/Recovery/AgentProcessRegistrySupport.swift:225, 249, 268`: new `AgentRuntimeRestriction.writerPID` (optional; default `nil`; dropped when equal to the root).
- `Sources/RepoPromptAgentCore/AgentMode/Runtime/Recovery/AgentProcessRegistry.swift:234`: the projection sets it from the first `writer` member whose identity isn't the root.
- `Sources/RepoPrompt/Features/AgentMode/ViewModels/AgentModeViewModel+RecoveryList.swift:1150-1154`: the item reads "(1 process found, started as PID 56334, agent PID 56474)". Without a distinct writer, the text is unchanged.

## Tests

- `AgentRecoveryStartupCompositionTests.testInterruptedTurnTextNamesTheEarlierLaunchOnlyForAnUnexpectedQuit` (S4): exact `.appCrash` detail; `.appQuit` unchanged.
- `AgentRecoveryStartupCompositionTests.testSurvivingRuntimeTextNamesTheAgentPIDAndLetFinish` (S5, plus S2's text): shim root + writer → both PIDs; writer equal to the root → root only; `letFinish` → "You chose to let it finish; RepoPrompt keeps watching it."
- `AgentProcessRegistryTests.testMixedExecUpgradesToolsToWritersAndNeverDemotesWriters` (S5): the registry snapshot has `rootPID 950` and `writerPID 951`.

## Validation

| Command | Ticket | Result |
|---|---|---|
| `make dev-test FILTER=AgentRecoveryStartupCompositionTests` | `c4e94a86-1d5c-4a6e-8555-35f2200862a0` | Failed: build error "input file `AgentRecoveryReconciliationTests.swift` was modified during the build" (another worker's concurrent edit). |
| same, rerun | `79335f2f-f8bf-492e-8ef4-296ea356a815` | 24 tests, 0 failures; both new tests passed. |
| `make dev-test FILTER=AgentProcessRegistryTests` | `4ca79eb6-f2f0-4022-8200-a8e69340061c` | 46 tests, 0 failures. |
| `make dev-test FILTER=AgentRecoveryRuntimeOwnershipTests` | `0ad1bc65-ebba-4538-bf97-d2a2a24de8e0` | 16 tests, 0 failures. |
| `make dev-lint` | `d75bd0c0-0265-41e7-af96-28e68e2a70bd` | Failed only on `CodexNativeSessionController.swift:1851-1852` (`docComments`). That file holds another worker's uncommitted change, not touched here. No lint finding in the files changed here. |

Not run: live re-check of S2/S4/S5 (needs a kill and relaunch), and the full test suite.

## Review follow-up (OracleB P3-8, wording only)

Owner scope cut: wording only. The alive-member constraint on `writerPID` was dropped, and a partial version was reverted. The registry diff is again only the one-line projection at `AgentProcessRegistry.swift:234`.
- `AgentModeViewModel+RecoveryList.swift:1150-1159`: with both PIDs the survivor text reads "(1 process found; launcher PID 56334, agent PID 56474)". With only a writer it reads "(…; agent PID Y)". With only a root it is unchanged: "(…, started as PID X)".
- Test updated: `AgentRecoveryStartupCompositionTests.testSurvivingRuntimeTextNamesTheAgentPIDAndLetFinish`.
- Not done: `writerPID` comes from recorded writer members, so it may still name a member whose lifetime the last refresh couldn't check.
- `make dev-test FILTER=AgentRecoveryStartupCompositionTests`: ticket `3f03ac4e-0b98-499c-ab15-b2bac1df20ca`, 24 tests, 0 failures.
- `make dev-lint`: ticket `737b3ad2-2d0f-43b0-a2e2-aa3fee9b680e` failed on a `redundantType` in the new switch. Fixed; rerun ticket `dd1afb05-4bb7-4f6e-865d-bf5cf4bc4364` completed.
