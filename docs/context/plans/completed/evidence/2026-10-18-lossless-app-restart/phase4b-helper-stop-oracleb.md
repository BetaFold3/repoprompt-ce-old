# Step 4b review — OracleB

Scope: read when the task touches the retained-helper late-stop recovery review.
Authority: Reference
Last-verified: 2026-10-23

Main verified the exact requested preset UUID/name. Initial snapshot 2026-10-23/1204, seven source/test files. Full response follows; original local export unchanged. [Disposition](phase4b-helper-stop.md).

# Oracle Review



# Review: Lossless restart Step 4b (late stop proof restores choices)

**Verdict: Accept.** I found no P0 or P1 issues. There are two P2 findings and four P3 findings. All can be deferred, and some are one-line fixes.

## Summary

Before this change, a Stage B restart whose helper had already been sent `arm` stayed stuck forever once its stop couldn't be proven. That was true even if the exact helper process exited later. The patch adds four pieces:

- **A stop-proof latch** (`ProcessRelaunchStopProofLatch`). The session's background readers fill it in. It only accepts two kinds of proof: the exact child's observed exit, or a matching `aborted` reply that arrives after an `abort` was sent.
- **A cancellable `stopProof()` wait**, which also returns at once if the proof arrived earlier.
- **A release step in the driver.** Once proof arrives, the driver releases exactly the helper it was holding (serialized with the other hooks).
- **A watch in the coordinator.** It is registered before the no-choice prompt appears. When proof arrives it dismisses that prompt and shows the original failure again with the normal Retry / Quit Anyway choices.

A `presentationID` check makes the coordinator ignore answers from older or dismissed prompts. Every path that ends a request cancels the watch. The `dismissFailure` hook can now also close an app-modal alert (one with no parent window) via `abortModal`.

I traced each acceptance criterion through the code:

- **Only real proof counts.** End of input, a delivered signal, timeouts, other correlation IDs and unprompted acks are all ignored by the latch.
- **No missed or double-resumed waits.** Waiters are added and removed under one lock, and both the "cancelled before registering" and "proof already there" cases are handled.
- **Stale answers are ignored.** The new prompt's ID is set in the same main-actor step that dismisses the old one, before the old prompt's answer can be processed.
- **The notification does nothing by itself.** It only dismisses and re-presents. There's no Retry, no new helper, no saving, no launch mark and no new deadline. The expiry stays at 7 s, as the test asserts.
- **An explicit Retry still uses the existing path** (`startFinalizationAttempt(freshDeadline: true)`), which gets a fresh helper only after the old one's proof.
- **Stage A can't reach this path.** `.unresolved` requires that `arm` was sent.

The user's most likely action also works: they press the only button, "OK", on the no-choice prompt. That answer is ignored, but the watch keeps running. When proof arrives, the dismiss call finds nothing to close and the normal choices are shown fresh.

---

## P2

### S4b-P2-01: App-modal dismissal can re-enter `runModal` before the old modal loop has unwound
- **Scenario:** A Restart safely request reaches the no-choice Stage B prompt while RepoPrompt is not the active app (the user switched away during the roughly 8 s run). In that case `NSApp.keyWindow` and `NSApp.mainWindow` are nil, so the prompt falls back to `alert.runModal()`. The helper's exit then arrives. The watch runs *inside* that modal loop, because the main queue keeps running during a modal session. It calls `dismissFailure`, which calls `NSApp.abortModal()`, and then immediately calls `present(...)`. The new present task's `abandon` finishes without real waiting (no helper is held), and its `presentFailure` can call `runModal()` again *before the outer `runModal` has returned*. Depending on which modal session the pending abort lands on, two things can happen:
  - The new prompt closes at once and returns `.abort`. That maps to `.cancel`, which passes the new presentation check and re-presents again, so the prompt flickers or loops.
  - Or the alerts end up nested.
- **Impact:** A prompt glitch on a path that is gated off. The fallback is not executed until O3 live acceptance. No data loss: the answer checks still prevent a wrong Quit or Retry.
- **Evidence:**
  - `WindowStatesManager+LifecycleShutdown.swift` ~L80–86: the new `abortModal` branch.
  - Same file, the `runModal()` fallback in `presentLifecycleShutdownFailure`.
  - `AgentLifecycleShutdownCoordinator.swift` ~L872–879: the watch calls `dismissFailure` and `present` back to back.
- **Smallest fix:** Make the watch re-present on a separate step, after the old prompt has returned. For example, set `request.pendingStopRecovery = presentation` before dismissing. Then have the old present task call `present(...)` itself when its `presentFailure` returns with a stale `presentationID` and that marker set. If the old prompt was already answered ("OK" pressed), the watch presents directly. Alternatively, defer the fix and add an explicit "no key window / app inactive" case to the O3 live checklist.

### S4b-P2-02: Test gaps in the most realistic sequences
- No coordinator test covers "user presses OK, then proof arrives, then the normal choices appear". This is the main real-world path, since OK is the only button. The existing test proves the watch survives an ignored answer, but stops before the proof arrives.
- No test shows that a request-ending path cancels the watch. `cancelledStopWaits` is only ever asserted to be `0`.
- `AppRelaunchCoordinatorTests` only proves release through an observed exit, not through a late matching `aborted` reply. The latch tests cover that reply at the session level only.
- **Smallest fix:** Add one coordinator test (no-choice prompt, then `choose(.retry)` gets ignored, then proof arrives, then assert the restored choices). Add one driver test that delivers a late matching `aborted` and expects `awaitRetainedHelperStop() == true`. Both are cheap.

---

## P3

### S4b-P3-01: A buffered unprompted `aborted` is still accepted as proof by `awaitStop`
- **Scenario:** An `aborted` with the correct correlation ID arrives *before* any `abort` was sent, while no loop is reading events (for example, in the `.ready` state). The latch correctly ignores it, and the new test asserts that. But the event stays buffered in `events`. A later `abort()` then goes `stopUnarmed`, then `awaitStop`, reads the buffered event, and returns `.safe(.abortAcknowledged)`. So `awaitStop` and the latch disagree on what counts as proof. This existed before the patch, and the real helper only sends `aborted` in reply to `abort`, so it can't realistically happen.
- **Evidence:** `ProcessRelaunchHelper.swift`, the `awaitStop` `aborted` case (~L1035).
- **Fix (one line):** In `awaitStop`, accept the `aborted` case only if `stopProofLatch.recorded != nil`, and otherwise `continue`. The reader task records into the latch before it forwards the event, so this check is safe.

### S4b-P3-02: Wrong proof label after the latch's early return
- The new early return in `stopUnarmed` (~L989–993) sets `state = .finished` but leaves `helperExited` false. A later `abort()` (~L905) then returns `.safe(helperExited ? .exitObserved : .abortAcknowledged)`, which mislabels a proof that was really `.exitObserved`. It only affects diagnostics; callers only check `.safe`.
- **Fix:** In the early return, set `helperExited = (proof == .exitObserved)`. Or have `abort()` return `.safe(stopProofLatch.recorded ?? …)`.

### S4b-P3-03: Repeated messages on a Stage B re-present
- `handle(.finalization, .cancel)` re-presents `request.lastFailure?.messages`, and those already include any appended "unresolved" or "unresolvedUnarmed" reason. A second `abandon` can then append it again. This existed before the patch, but `lastFailure` is now updated in more places.
- **Fix:** Store the original `messages` on the request and re-present those.

### S4b-P3-04: Small duplication
- `failedPhase` is computed the same way in both `present` and `observeRelaunchHelperStop`. A `stage.failedPhase` computed property removes it.
- `observeRelaunchHelperStop` takes five values (`attempt`, `stage`, `messages`, `timedOut`, `presentation`) that only exist to rebuild the same `present` call. That's acceptable as is.

---

## Not flagged (in scope, checked)
- **A watch for a helper whose stop is never proven stays alive until the process exits.** This is the accepted existing blocker (O9/O10), not something this patch introduces.
- **`supersede` now goes through the new `abortModal` branch for window-scope app-modal prompts.** It only fires when that exact alert is the current modal window, so this is a small improvement rather than a regression.
- **The release keeps going after the watch is cancelled once proof has arrived** (`serialized` uses an unstructured task). That's harmless: the proof is real, and the coordinator still ignores the result.
- **Real AppKit sheet/modal dismissal and the real `Process` exit hookup are still unexecuted.** This is correctly left to O3 and not claimed by this patch.
