# Phase 1b shutdown re-review 1 — OracleB

Scope: read when the task touches review of R4 shutdown preservation fixes and sealed window admission.
Authority: Reference
Last-verified: 2026-10-21

Preset identity verified: OracleB, `7CDD523E-1D7C-47EA-98FE-D5FEA24D2D8C`. Chat: `restart-shutdown-r1-orac-F28A7E`. Frozen tree: `1c704e777d0ca799bcd7a1a93d24ae290280ead7`. Each lane received only its own prior findings and dispositions.

# Oracle Review



# R4 Phase 1b-shutdown — re-review round 1 (independent lane)

This is a static review of tree `1c704e77` against the initial review tree `4dab2d61`. I did not run or execute anything.

## Summary

The delta covers every finding I raised:
- **R4-1:** question writes are now keyed by exact interaction ID (upsert or remove). Removals are tracked per window and per lane and serialized on one task chain.
- **R4-2:** a Close Anyway latch stops the later quit from writing a clean mark.
- **R4-3:** a window registered during Stage A joins the quit and fails the attempt. Admission is sealed at the point of no return, and window scenes defer their activation until admitted.
- **R4-4:** answers are refused during the freeze across all routes, and Cancel removes only the snapshots this window introduced.
- **R4-7:** new fixtures cover the real view model.
- **R4-10:** the composer is edit-frozen.
- **R4-11:** a re-shown Stage B prompt keeps its own messages.

The delta also changes the boundary itself:
- Stage A now waits for the `shutdownInProgress` mark to be confirmed on disk before crossing the point of no return.
- The clean write goes through a gate that requires an authorization.
- Expiry is captured once on the monotonic clock and checked at each success transition.
- Retry joins a pending clean write instead of writing again.

Most fixes are correct, and the coordinator meets the stated interpretation:
- No late work replies, closes or writes.
- Nothing ever writes a correction.
- The clean write is authorized only after every admitted participant was prepared, torn down and finalized, and only before expiry.
- No unclean mark can be ordered after the clean write during Stage B.

There are two regressions in the new code. One is a likely P1 in SwiftUI wiring that the tests never exercise. The other is a P2 race in the new snapshot-removal logic.

## Status of my prior findings

| ID | Prior | Status | Notes |
|---|---|---|---|
| R4-1 | P1 | **Fixed.** One new race from the fix (N2) | The store merge in `updateQuestionSnapshots` is correct: upsert beats remove, untouched snapshots are kept, and an unchanged write is skipped. `introduced = live − (alreadyStored − earlier.introduced)` correctly avoids claiming other owners' questions. The torn-down skip is correct. |
| R4-2 | P2 | **Fixed** | `proceedAnyway` sets `hasUnfinalizedWindowClose`. `runFinalization` then returns `([], false)` without authorizing a clean write, so the `shutdownInProgress` mark confirmed in Stage A stays. |
| R4-3 | P2 | **Coordinator logic fixed.** SwiftUI wiring likely broken (N1) | Admission happens at the only path into `allWindows`. The seal is set synchronously before `beginIrreversible`. The participant-revision fence plus the `participantsChanged` check in `preparationFinished` close the Stage A race. |
| R4-4 | P2 | **Fixed** | Guards come before any mutation in: the drafts-bearing `submitAskUserResponse`, both private resolvers, `submitMCPElicitationResponse`, and `mcpResolvePendingInteraction` (question, elicitation and user-input kinds). Cancel removes only `introduced`, through the serialized chain. |
| R4-5 | P2 | **Accepted as settled** | The cited card sources make the "no partial-answer surface" claim plausible, and the `ask_user` drafts are owned by the VM. I did not re-verify the card source. |
| R4-6 | P2 | **Accepted** | `shutdownTeardownReason` was removed. The fixture asserts that a `queued` intent survives the real teardown. |
| R4-7 | P2 | **Fixed** | The remaining limits are as stated: the row actions are not driven through the VM, and there is no second VM for a real reopen. |
| R4-8, R4-9 | P3 | Deferral accepted | — |
| R4-10 | P3 | Fixed in code; enforcement is UI-only (N4) | — |
| R4-11 | P3 | Fixed | `lastFailure` is re-presented. |

I have no contests.

## New findings (from the fixes)

### N1 — P1 (likely; compile-only, verify before commit): every admitted scene window gets torn down right after admission

**Scenario**
1. A scene window is created with `WindowState.forWindowScene()`, so `applicationAdmission == .pending`. `body` renders the `.pending` branch (`Color.clear`).
2. `.onAppear` runs `registerWindowState`. That sets `applicationAdmission = .admitted` (it is `@Published`) and calls `activateAfterApplicationAdmission`.
3. SwiftUI re-renders, and `admittedContent` switches from the `Color.clear` branch to the `ContentView` branch.
4. The lifecycle modifiers are attached to the result of a `switch` inside a `@ViewBuilder`, so they apply to each branch (the same way they do on `Group`). The branch change therefore fires `.onDisappear` for the old branch, then `.onAppear` for the new one.
5. In that `.onDisappear`, the guard `windowState.applicationAdmission == .admitted` is already **true**. The window then runs `beginClose()`, `pollAndSaveState()`, `unregisterWindowState()` and `Task { await windowState.tearDown() }`.
6. The second `.onAppear` registers the window again, but its state is already closed or tearing down.

**Impact:** this happens on every launch for the first window, on New Window, and on the tab "+". It breaks the app's basic workflow:
- focus and title side effects stop;
- the window is removed from the registry and then re-added;
- an async teardown runs against a window that is still in use.

The coordinator tests and `testWindowSceneActivationWaitsForAdmissionAndARefusedWindowNeverActivates` never render `WindowContentView`, so they can't catch this. The validation notes say the shell behaviour is compile-only and that the full app was not launched.

**Evidence**
- `WindowContentView.swift:~22-23`: `body` begins with `admittedContent`, and the lifecycle modifiers are chained on it.
- `~38-45`: `.onAppear { guard windowStatesManager.registerWindowState(windowState) …`
- `~47-69`: `.onDisappear` with the guard on `.admitted`, followed by unregister and teardown.
- `~82-99`: `admittedContent` is a `@ViewBuilder` `switch` (`_ConditionalContent`) whose branch changes as a direct result of the `.onAppear` registration.

**Smallest fix**
- Give the lifecycle modifiers a stable single-view host, for example `ZStack { admittedContent }`, then apply `.navigationTitle`, `.background`, `.onAppear`, `.onDisappear` and `.sheet` to that stack. A branch change then no longer counts as the view appearing or disappearing.
- Verify with one manual launch, then New Window, checking that the window stays registered and is not closing. If you'd rather not wait for a live run, add a cheap guard in `.onDisappear`: skip teardown unless `windowState.nsWindow == nil || windowState.isClosing`. The container fix is the real remedy.

### N2 — P2: a superseded or abandoned Stage A can delete a question that a newer active freeze already preserved

**Scenario A (supersede)**
1. A window close is in Stage A. Its `prepareRecoveryForShutdown` for session S is inside `lane.prepareForShutdown(upsert X)`.
2. Cmd-Q arrives. `requestApplicationQuit` first calls `beginShutdownFreeze(appRequestID)` on the view model, which replaces `shutdownFreezeState`. Only then does it call `supersede`, whose `endShutdownFreeze(windowRequestID)` is ignored by the stale-request fence. The window stays frozen under the app quit.
3. The app quit's Stage A reaches S. Its `await shutdownQuestionSnapshotWriteTask?.value` finds nothing pending yet. It issues `upsert X`, which queues behind the window's write at the lane or gate.
4. The window's write lands. Its post-write check `isStillFrozenForThisRequest()` is false, so it takes the "cancelled while in flight" branch: it adds `introduced` (which contains X) to `stale` and enqueues `removing: [X]`.
5. The app's upsert lands with `alreadyStored ∋ X`, so the app does not count X as introduced. Then the window's removal lands and deletes X.
6. The quit crosses the point of no return. Teardown cancels the live question, so X and its partial answer are gone.

**Scenario B:** the same pattern after an app-quit Stage A times out on a hung step and the user picks Cancel, then quits again immediately. The old attempt's view-model preparation is still in flight, and the new `Request`'s work does not wait for the old request's work.

**Impact:** a pending question and its typed partial answer are lost without the user choosing anything. The interleaving is narrow: the writes have to land in that order within milliseconds, under the 8 s budget. So this is P2.

**Evidence**
- `AgentLifecycleShutdownCoordinator.swift`: in `requestApplicationQuit`, the freeze loop runs before the `supersede` loop.
- `AgentModeViewModel+Shutdown.swift`:
  - `beginShutdownFreeze` replaces the state without handing over snapshot tracking;
  - `endShutdownFreeze` has the `state.requestID == requestID` fence;
  - `~263-268`: `else { stale.formUnion(tracked.introduced); shutdownQuestionSnapshots[tab] = nil }`;
  - `~181`: the join covers only removals that were already enqueued.

**Smallest fix:** in the not-still-frozen branch, remove the questions only when the window is truly unfrozen (`shutdownFreezeState == nil`). If a newer request froze this window, hand the tracking over to it instead: merge `tracked` into `shutdownQuestionSnapshots[tab]`, taking the union of `live` and of `introduced`. The newer request's Cancel or live resolution then owns those removals.

The alternative is to serialize `prepareSessionsForShutdown` per view model by awaiting the previous preparation task. A hung earlier preparation is already bounded by the deadline.

### N3 — P3: an unused part of the clean-exit gate

`AgentRecoveryCoordinator.revokeCleanExit()` has no production caller now that registration-time revocation was removed. The gate's `Revocation` states (`.inProgress`, `.committed`) and `cleanOnDisk` / `noteUncleanCommitted` exist only to serve it.

The authorization is created right before an ordered enqueue, so the only fence that still matters is "`cleanExit` requires an authorization", which `recordCurrentLaunch` already enforces.

**Fix:** drop `revoke`, `Revocation` and `cleanOnDisk`, or keep them with a comment saying they are reserved for later use.

### N4 — P3: the composer edit freeze is enforced only in the UI

- `.disabled(agentModeVM.isShutdownFrozen)` only takes effect if `AgentModeChatDetailView` re-renders when `shutdownFreezeState` changes. The view reads from narrow stores like `agentModeVM.ui.composer`, so it may not observe the whole view model.
- `hasPreparedForWindowClose` is not `@Published`.
- Nothing in the lane or view model refuses a composer edit during the freeze. Stage B's `flushComposer` covers edits made before finalization, but anything typed afterwards is lost if the user picks Quit Anyway.

**Fix:** a live check now. As a fallback, ignore `composerDidChange` in the view model while `isShutdownFrozen`.

### N5 — P3: confusing prompt after a late but successful clean write

If the clean write succeeds but `finalizationFinished` runs after the expiry, the code maps that to the timeout path. Because `cleanWrite != nil`, the prompt says RepoPrompt "could not confirm … recorded a clean exit", although the mark is already on disk. Retry then completes, so this is only a wording problem. Separately, a re-presented prompt recomputes `awaitsCleanExitAcknowledgement`, so its header and buttons can disagree with the reused message after `cleanWrite` is released.

**Fix:** in `finalizationFinished`, don't treat expiry as a failure when `cleanWrite` has already returned `true`. Re-present the stored `lastFailure` unchanged.

## Recommendations

1. **N1 blocks the commit.** Wrap `admittedContent` in a stable container before the lifecycle modifiers, then do one manual launch and New Window check (no providers needed) to confirm the window stays registered. If it can't be verified, record it as an open P1 that needs the owner's live check, not as fixed.
2. **Fix N2** with the tracking handover in the not-still-frozen branch; it is a few lines. Add a VM test: freeze for request A with the write held, re-freeze for request B, let B upsert, release A, and assert the question is still stored.
3. **Accept the coordinator boundary as meeting the stated interpretation.** I found no false-clean path, no automatic termination after a timeout, no correction write, and no Stage A crossing without a confirmed unclean mark.
4. **List N3–N5 as deferred P3s.** Fold N4 into the O3 live check alongside the NSAlert, terminate-reply and `performClose` items already pending.
5. **After the N1 and N2 fixes,** rerun `WindowCloseCoordinatorLifecycleTests`, `AgentRecoveryResetBoundaryTests` and `AgentLifecycleShutdownCoordinatorTests`, plus lint. No further review round is needed unless the N1 fix changes registration semantics.
