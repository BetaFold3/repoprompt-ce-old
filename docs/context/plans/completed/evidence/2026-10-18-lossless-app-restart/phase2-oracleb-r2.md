# Phase 2 OracleB second re-review

Scope: read when the task touches Phase 2 second re-review findings for lossless app restart.
Authority: Reference
Last-verified: 2026-10-21

Frozen snapshot: `70ee3c8bdb05a833bb4fb826d72ae7c9616c3040`. Preset identity verified before synthesis. Raw response follows unchanged; a self-label in prose does not determine preset identity.

# Oracle Review



# Phase 2 lossless restart: R2 final re-review (OracleA lane)

**Basis:** I reviewed the full R1→R2 delta (`0cabecc5` → `70ee3c8b`) and the supplied files only. I had no repository access, so line numbers are approximate (≈). All validation is fixture or stub runs. Nothing here shows live behaviour, and O3 live acceptance is still pending.

## Summary

The delta addresses every finding I raised in R1:
- **R1-F1 (mid-turn steering):** the stamp now finds the turn that *contains* the steered user item, and the run/turn join reads user-activity IDs from inside a turn. A three-way test (no steer, steer as its own turn, steer as a mid-turn activity) covers this through save, reload and reconcile.
- **R1-F2 (Codex lane hand-over):** the run fence and the lane fence are now separate, and a lane-only hand-over now fails loudly and interrupts the provider.
- **R1-F3 (unsaved hand-over):** handed-over question snapshots are no longer assumed durable, and the successor writes them only after the predecessor retires.
- **R1-F4 (headless ACP):** the bridge passes the typed process-loss error through unnormalized.
- **R1-F5 (Claude witness):** the real Claude witness is now tested through the protocol existential.

The delta also fixes four other items:
- **R1-F7:** span lifecycles are re-closed when a provisional stamp is withdrawn.
- **R1-F8:** a durable, dismissable `recoveredOutcome` marker replaces the per-launch "tail may be missing" set.
- **Closed-session compose tab:** closed-session items now keep their compose tab.
- **Legacy schedules:** an indexed schedule summary with no attempt ID can't be dismissed until the session is opened.

I found no P0 and no P1. One new P2 is a side effect of the R1-F3 fix: in-flight question creations are now handed over as live.

## Disposition of my R1 findings

| ID | Status | Basis |
|---|---|---|
| R1-F1 (conditional P1) | **Closed** | I can't see `importLegacyItems` in the supplied files, so I accept the worker's evidence that live steering always opens its own turn. That makes the mid-turn shape reachable only from saved data, so this is P3. The containing-turn fix landed anyway: `containsUserItem` + `lastIndex` in `stampLiveInterruption` (≈486), and the activity join in `attempt(for:)` (≈83–89; more than one distinct attempt is treated as ambiguous). The test covers all three shapes through a real save, reload and reconcile, so the closure doesn't depend on that downgrade. |
| R1-F2 (P2) | **Closed** | `runHeld` and `laneHeld` are now separate checks. The replacement-run test asserts *no* interrupt, and the hand-over test asserts the run fails and the provider is interrupted. The leftover "Expired question" is a disclosed limitation, but see R2-F1. |
| R1-F3 (P2) | **Closed, with regression R2-F1** | Adopted snapshots are pending, and every write is ordered behind the predecessor's retirement. The test covers resubmitting the same answer, a failed retirement, failing writes, and finally `.preserved`. |
| R1-F4 (P2) | **Closed** | `outerStreamError` passes the typed error through and is unit-tested. I accept that Claude's `mapError` already returns it unchanged (outside the diff). |
| R1-F5 (P2) | **Closed** | The existential call comes first, and the direct call that follows returns `false`, which proves the real witness consumed the answer. |
| R1-F6 (P3) | Deferral accepted | — |
| R1-F7 (P3) | **Mostly closed** | Residual in R2-P3-c. |
| R1-F8 (P3) | **Closed** | The marker is durable on the turn and carried by `preservingInterruptedTurnEnvelopes`. Listing uses `attemptsByID[marker.runAttemptID]`. Dismiss survives an unrelated write and another fresh launch (tested). |
| R1-F9, F10, F11 (P3) | Deferral accepted | Python test skip, acknowledgement retention, banner noise. |

## P2

### R2-F1: An in-flight question creation is now handed over as live, leaving a "ghost" live question (PLAUSIBLE)

**Scenario**
1. A Codex native question (or an `ask_user`) calls `commitCreation`. That inserts `knownIDs[id]` and moves the snapshot into `inFlightUpserts` (new in this delta) while the write is pending.
2. During that write, a same-owner lane hand-over runs `claimLane`.
   - The predecessor's `liveSnapshots` now returns `inFlightUpserts[id]`. Before this delta, the `compactMap` dropped it.
   - So the successor adopts the never-published question as **live** and writes it after retirement.
3. Admission sees `!laneHeld`:
   - Codex returns `.persistenceFailed`: the run fails with "couldn't be saved", and `forget` and `end` run only on the *retired* controller.
   - `commitAskUserForRecovery` throws "session changed".
4. The successor keeps the ID in `liveInteractionIDs` indefinitely. The catalog treats live IDs as "presented by the live card", so the question is:
   - not shown;
   - not listed as historical;
   - not removed.

   On a later retirement or relaunch it surfaces as an "Expired question" for a request the user never saw.

**Impact.** A misleading or hidden recovery card and a contradictory error message. No input is lost. The window is one store write during a lane hand-over, which is narrow.

**Evidence**
- `AgentRecoveryQuestionPersistenceController.swift` ≈131–134 (`liveSnapshots` now includes `inFlightUpserts`) and ≈402–409 (`writePending` moves the creation into `inFlightUpserts`).
- `CodexAgentModeCoordinator.admitCodexNativeQuestion` ≈7143–7155 (the `!laneHeld` branches act only on the captured `questions`).
- The new Codex test only calls `releaseLane`. It never claims a successor, so it doesn't exercise adoption.

**Smallest fix.** Hand over only interactions whose creation has committed. Their latest pending or in-flight draft still wins:

```swift
liveInteractionIDs.filter { committedSnapshots[$0] != nil }
    .compactMap { pendingUpserts[$0] ?? inFlightUpserts[$0] ?? committedSnapshots[$0] }
```

This keeps the R1-F3 coverage, because a draft of a committed question that is in flight still transfers. It restores the documented "historical Expired question" limitation for a creation that was racing a hand-over. Add one assertion to the Codex hand-over test after claiming a successor lane: the successor's `liveInteractionIDs` does not contain the ID.

## P3 (list only, not looped)

| ID | Issue | Smallest fix |
|---|---|---|
| R2-P3-a | On a lane-only hand-over where the creation write succeeded, the run fails with "couldn't be saved for crash recovery" even though the snapshot was saved. | Use neutral wording for that branch, or accept it. |
| R2-P3-b | `failCodexRunForUnsavedQuestion` falls back to `reconcileAndInterruptCurrentTurn()` when no authoritative turn ID was captured. That fire-and-forget task could interrupt a turn the user started right after the failure. | Interrupt only with a captured `expectedTurnID`, or accept it given how short the window is. |
| R2-P3-c | The R1-F7 re-close flips **every** `.cancelled` span in the turn, including spans that were genuinely cancelled earlier. `summary.hadError` also stays `true` (disclosed). | Accept and document. |
| R2-P3-d | `requiresOpenBeforeDismiss = attemptID == nil` also covers genuine attempt-less confirmations, such as closed-app missed deadlines in unhosted sessions. Those now need Open before they can be dismissed. This is conservative and Dismiss still never confirms. | Accept as UX, or record it in the agent-scheduled-messages doc. |
| R2-P3-e | The new mid-turn join and stamp are fixture-only coverage of a saved-data shape. Per the worker, live steering never produces it. | None; keep it described as a fixture result. |

## Validation notes

- The compile, the lint rerun, the three suites rerun after lint, and the full suite table cover the files this delta touches.
- Suites run before the lint fix are acceptable: the lint fix was a modifier move and a test-only `XCTUnwrap`.
- The two preserved failures (the `await` in an autoclosure, and the fixture non-vacuity fix with its assertions unchanged) are disclosed adequately.
- None of these runs is live evidence, and they must not be cited as passing O3.

## Recommendations

1. **P0/P1:** none open. I close R1-F1 (implemented; downgrade to P3 accepted on the worker's steering evidence, which doesn't affect the closure), and no other P1 remains. Nothing needs to go to the owner from this lane.
2. **R2-F1 (P2):** fix it if cheap. It is a one-line filter in `liveSnapshots` plus one assertion. It doesn't need another review round; per policy, rerun `AgentRecoveryQuestionPersistenceTests`, `CodexAgentModeCoordinatorLivenessTests` and `AgentRecoveryCoordinatorTests`. If it isn't fixed, list it under `deferred:`.
3. **P3s:** list R2-P3-a through R2-P3-e under `deferred:` on the Step 2 status line, together with R1-F6, F9, F10, F11 and the earlier F14, F15 (bounding), F17 and F18, plus optional polish and retention. Resume, the registry and O3 stay deferred, as you stated.
4. **Checkpoint:** from the OracleA lane, Step 2 can be committed once validation passes. The status line should record `rounds 2/2` with no open P0/P1 from this lane. It should also keep stating that the SwiftUI layer, the visible app, real providers and O3 live acceptance were not exercised, and that all results are fixture or stub results.
