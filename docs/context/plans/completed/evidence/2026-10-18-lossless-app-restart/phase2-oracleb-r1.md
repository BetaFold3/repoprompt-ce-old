# Phase 2 OracleB first re-review

Scope: read when the task touches Phase 2 first re-review findings for lossless app restart.
Authority: Reference
Last-verified: 2026-10-21

Frozen snapshot: `0cabecc5cb118849e687f097782d226109d6eb3f`. Preset identity verified before synthesis. Raw reviewer response follows unchanged; any self-label in its prose is not preset identity.

# Oracle Review

# Phase 2 lossless restart: R1 re-review (OracleA lane)

## Summary

I reviewed the R1 delta (`923f69a8` to `0cabecc5`) only from the supplied diff and file excerpts. I had no repository access, so line numbers are approximate (≈). The worker's validation results are fixture and stub runs; they do not show live behaviour, and O3 is still pending.

The delta addresses all 11 of my required findings:
- **Joins and cold restore.** The run/turn join now covers steered turns. Cold restore closes runs that ended ordinarily as their real outcome instead of stamping them as interrupted.
- **Catalog.** It lists:
  - interruptions from this launch;
  - drafts in closed sessions;
  - question save failures.
- **Questions.**
  - Historical questions are worded as uncertain.
  - An answer is sent only after it is saved.
  - Live questions carry over on a same-owner lane hand-over.
  - A Codex native question is shown only after it is saved, and only to the exact owner.
- **Process loss.** Claude, ACP and headless runs now record provider-process loss as a typed cause.
- **Index and actions.**
  - Schedule discovery reads schema-7 indexes.
  - Index summaries carry the attempt ID.
  - Row actions find their session from the catalog.
  - Open works across workspaces.
- **Contract changes, accepted as deliberate.**
  - Dismiss acknowledgements are no longer evicted.
  - The early-reply contract is replaced.
  - A run that completed ordinarily is no longer shown as interrupted.

Nine of my original findings close. F9 and F10 close with P2 residuals. F1 closes only for steering that opens its own transcript turn; one plausible gap remains and needs a single check.

### Disposition of my original findings (checked against the delta, not the worker's table)

| ID | Status | Basis |
|---|---|---|
| F1 | **Partly closed** (see R1-F1) | Steered turns now join their run attempt, and the end-to-end test covers teardown → save → reload → reconcile for steering that opens a new turn. The live stamp still looks up the last user item as a *turn* ID. |
| F2 | Closed | "Expired question" title, uncertainty wording, and bounded automatic retry of owed removals. |
| F3 | Closed | `.questionSaveFailed` item, Retry, bounded retry; tested. |
| F4 | Closed | Schema-7 index read for schedules only; never cached or rewritten; tested. |
| F5 | Closed | `recoveryListCatalogItem` maps `paused-` to `crash-`; confirm and open are tested. |
| F6 | Closed | `addLiveRunInterruptions` lists from the current record for listed and unlisted sessions; tested on a steered turn. |
| F7 | Closed | `ordinaryTerminalOutcome` covers both stamping and sanitizing; tested through save and reload. Small residual in R1-F7. |
| F8 | Closed | Verified by `testWithdrawingTheLastIntentKeepsCardAcknowledgements`. |
| F9 | Closed for the stated scope | New P2 R1-F3 in the hand-over itself. |
| F10 | Mostly closed | Claude EOF and stream-end, the ACP process-exit flag, and the Claude CLI path are typed. Residuals in R1-F4 and R1-F5. |
| F11 | Closed | Codex ordering, failure and replacement tests per request kind; producer inventory recorded. |
| F12, F13, F16, F19 | Closed | — |
| F14, F15 (bounding), F17, F18 | Deferral accepted | — |

---

## P1 (conditional): verify before checkpoint

### R1-F1: Live interruption stamp still misses steering recorded as a mid-turn user activity (PLAUSIBLE; P1 if confirmed, otherwise P3)

**Scenario**
1. A Claude or ACP run is steered while it is running, and the steering item is projected into the open turn as a `.user` activity rather than as a new turn. `AgentSessionRestoreSupport` explicitly handles "mid-turn user activities" joined by user-item ID, so this shape exists for some input.
2. A window close or quit commits `windowClose` or `appQuit`.
3. `terminalTurnID` is `session.items.last(where: .user)?.id`, which here is the activity's ID. `stampLiveInterruption` looks for `turns.firstIndex(where: { $0.id == turnID })`, finds nothing, and returns without a stamp.
4. The turn is saved closed as `.cancelled`.

**What happens after relaunch.** The turn is listed nowhere:
- it isn't open, so cold restore doesn't stamp it;
- its run attempt's own turn is saved, so it isn't recovery-only;
- it isn't in `outcomeTurns`.

The new steered join doesn't help, because `attempt(for:)` checks only `turn.id` against dispatch `userItemID`s, never a turn's activity IDs. This launch's catalog row (`latestTurnID`) points at the activity ID rather than at a turn, which is only cosmetic.

**Impact.** A turn interrupted by quit or window close looks like an ordinary cancel after relaunch. That is the core honest-interruption acceptance item.

**Evidence**
- `AgentRunTerminalCommitBarrier.swift`: ≈244 (`terminalTurnID`) and ≈470–478 (the `firstIndex` guard).
- `AgentSessionRestoreSupport.swift`: ≈63–75 (`attempt(for:)`).
- Both new tests build steering as a separate user item, which becomes its own turn: `testLiveTeardownStampSurvivesSaveAndReloadAndReconcilesByRunAttempt` and `coldRestoreSteered`.

**Verification.** Check whether a steering or queued input accepted during an active run is appended to the transcript as a turn request or as a span activity. If it is always a new turn, downgrade this to P3.

**Smallest fix** (cheap, so worth doing either way):
- In `stampLiveInterruption`, resolve the turn that *contains* the item: `turn.id == id || turn.request?.id == id ||` any span activity with that `id`.
- In `AgentRecoveryRunTurnJoin.attempt(for:)`, also look up the turn's `.user` activity IDs in `steeredAttemptsByTurnID`.
- Add one test variant where the steer is a mid-turn activity.

---

## P2

### R1-F2: Codex native question is silently dropped on a same-owner lane hand-over during its creation write (run hangs)

**Scenario**
1. The run, attempt generation, run ID and Codex controller are all unchanged, but `claimLane` replaces the lane during the creation `await`. This is the same-owner, same-binding hand-over that the F9 fix exists for.
2. `ownerHeld` requires `AgentRecoveryLiveQuestions.lane(for: session) === lane`, which is now false.
3. The two possible results:
   - On `.success`, the code returns `.drop` and ends the question, removing its snapshot.
   - On `.failure(.retired)`, it also returns `.drop`, not `.persistenceFailed`.
4. Either way the request is never shown and never answered, the run stays active, and the Codex app-server waits on its server request indefinitely.

**Impact.** A stuck run with no visible cause. The window is a single store write, so this is narrow.

**Evidence.** `CodexAgentModeCoordinator.swift`: ≈7107–7124 (the `ownerHeld` lane identity check) and ≈7126–7139 (`.failure → ownerHeld ? .persistenceFailed : .drop`; `.success → .drop`).

**Smallest fix.** Split the fence:
- If the run ownership (ownership, generation, run ID, controller) is unchanged but only the lane changed, re-commit to the current lane and publish.
- Or, minimally, return `.persistenceFailed` so the run fails loudly.

Keep `.drop` only for an actual run or owner change.

**Also check.** Confirm that `finalizeCodexRun(reason: "question-persistence-failed")` interrupts the provider turn. The test asserts no server reply, but not `cancelCurrentTurn`. Without an interrupt, the app-server turn may stay blocked on the unanswered request and refuse the next `turn/start`.

### R1-F3: Hand-over adopts *unsaved* question snapshots as committed, so a reply can skip preservation

**Scenario**
1. `liveSnapshots` returns `pendingUpserts[$0] ?? committedSnapshots[$0]`.
2. `adoptLiveInteractions` stores each one in the successor's `committedSnapshots`.
3. The predecessor's preserving retirement flush is asynchronous, so it may be in flight or may fail.
4. The user answers with the same draft. `draftDidChange` sees `committedSnapshots[id] == snapshot` and writes nothing, so `needsPreservation` is false and `resolveAfterRecoveryQuestionFlush` replies at once.

**Impact.** This breaks the new "reply only after the snapshot is saved" ordering. A crash in that window loses the answer's recovery record. The answer itself did reach the agent, so the impact is low.

**Evidence**
- `AgentRecoveryQuestionPersistenceController.swift`: ≈129–133 (`liveSnapshots`) and ≈236–245 (`adoptLiveInteractions`).
- `AgentRecoveryCoordinator.claimLane`: ≈1094–1112.

**Smallest fix.** Have `adoptLiveInteractions` put adopted snapshots into `pendingUpserts` and call `scheduleImmediateWrite()`; the upsert is idempotent. Then update the "Adoption itself writes nothing" assertion.

### R1-F4: Headless ACP bridge's typed process loss may be erased by the outer `normalizeError`

**Scenario.** The inner `catch` throws `HeadlessProviderProcessLostError`. The outer `catch` then calls `continuation.finish(throwing: provider.normalizeError(error))`. If a real provider's `normalizeError` wraps unknown errors (the test provider returns them unchanged), `HeadlessAgentModeRunner`'s `error is HeadlessProviderProcessLostError` check fails and the cause stays `.ordinary`.

The `ClaudeCodeAgentProvider` throw inside its stream task may pass through a similar normalizing `catch`, which is outside the diff.

**Impact.** No regression; this is the pre-delta behaviour. The F10 coverage is only partly effective, and no test covers either headless path.

**Evidence.** `ACPHeadlessAgentProviderBridge.swift` ≈140–158; `ClaudeCodeAgentProvider.swift` ≈509.

**Smallest fix.** In both outer `catch`es, pass `HeadlessProviderProcessLostError` through unnormalized. Add one bridge-level test using a wrapping `normalizeError`.

### R1-F5: Production witness dispatch for `turnEndedByProcessLoss` on the real Claude controller is untested

**Scenario.** The runner calls through `any NativeAgentRuntimeControlling`. `testClaudeControllerAttributesOnlyUnexpectedEOFTurnsToProcessLoss` calls the concrete type directly.

The fake's witness is *synchronous* (`func turnEndedByProcessLoss(_:) -> Bool`). Its `.processExits` test passes, so a sync witness does work for the fake. That contradicts the stated root cause of the "async witness bug", so the real dispatch path rests on an explanation that hasn't been confirmed.

**Impact.** If the protocol extension's default still wins for the real actor, every Claude process loss records `.ordinary`, and nothing would catch it.

**Smallest fix.** Add one line to the existing test: `let runtime: any NativeAgentRuntimeControlling = controller; XCTAssertTrue(await runtime.turnEndedByProcessLoss(lostTurn))`, called before the direct call, since the answer is given once per turn.

---

## P3 (list only)

| ID | Issue | Evidence | Smallest fix |
|---|---|---|---|
| R1-F6 | `latestTurnID` counts every dispatch with a run attempt, including pre-handoff `failed` or withdrawn steers. The live row can then name a turn that doesn't exist, which changes only the row ID; the card key is the run attempt, so Dismiss still carries. | `AgentSessionRestoreSupport.swift` ≈40–44 | Skip dispatches whose intent is `failed` or `withdrawn`. |
| R1-F7 | When a provisional `unknown` stamp is withdrawn for an ordinary outcome, the turn becomes `.completed`, but its spans stay `.cancelled` and `summary.hadError` stays true. The turn is also listed nowhere, because it isn't in `savedOpenTurnIDs`. | `AgentSessionRestoreSupport.swift` ≈563–569; `AgentSessionDataService.noteColdRestoreStamps` | Re-close cancelled spans to the outcome's lifecycle, or accept and document. |
| R1-F8 | Outcome turns are listed only by the launch that closed them (in-memory `coldRestoreOrdinaryOutcomeTurnIDs`). If the user misses them, the "tail may be missing" notice is gone. | `AgentSessionDataService.swift` ≈281 | Accept as advisory, or persist a hint. |
| R1-F9 | The new ACP cause test needs `python3` on the host. | `AgentRunTerminalCauseTests` (scripted agent) | Skip with a clear message if `python3` is missing. |
| R1-F10 | Acknowledgements are now unbounded within an incarnation, and ack-only records are never removed. | `AgentRecoveryStore.acknowledgeCard` | Retention is deferred per the owner; record it on the status line. |
| R1-F11 | `isEmpty` now keeps the banner in every session whenever any undismissed item exists anywhere. This is deliberate, but could be noisy. | `AgentComposerUIModels.swift` ≈395 | Owner UX call; no change needed. |

---

## Recommendations

1. **Remaining P0/P1:**
   - No P0.
   - No confirmed P1.
   - R1-F1 stays open as a **plausible P1**. One check settles it: does in-run steering land in the transcript as a span `.user` activity? The containing-turn fix is a few lines in the barrier and the join, so I recommend applying it with one mid-turn-activity test rather than spending a round on it. If steering always opens its own turn, downgrade it to P3.
2. **P2s:** fix them where cheap; none justifies another round.
   - R1-F2: split the fence so a lane-only change re-commits or fails loudly, and confirm the failed Codex run interrupts its provider turn.
   - R1-F3: make adopted snapshots pending and write them once.
   - R1-F4: pass the typed error through the outer `catch`es.
   - R1-F5: add the one-line test through the protocol existential.
3. **P3s:** list them as deferred on the Step 2 status line, together with the existing deferrals: F14, F15 bounding, F17 and F18.
4. **Validation:** after these edits, re-run the following, each with its own ticket:
   - `AgentRunTerminalCauseTests`
   - `AgentRecoveryStartupReconciliationTests`
   - `AgentRecoveryQuestionPersistenceTests`
   - `AgentRecoveryResetBoundaryTests`
   - `CodexAgentModeCoordinatorLivenessTests`
   - `AgentModeRunServiceLifecycleTests`
   - `AgentRecoveryCoordinatorTests`

   Keep stating that the SwiftUI layer, the visible app, real providers and O3 live acceptance were not run, and that all results above are fixture or stub results.
5. **If R1-F1 is fixed as recommended:** after the R1-F1 fix, I'd re-review only that change and its test, not the whole delta.
