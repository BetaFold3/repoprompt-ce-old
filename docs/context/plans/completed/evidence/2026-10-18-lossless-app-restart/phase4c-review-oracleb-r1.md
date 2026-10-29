# Step4c repair review1 — OracleB

Scope: read when the task touches the explicit uncertain-exit repair or its review findings.
Authority: Reference
Last-verified: 2026-10-23

Delta snapshot `2026-10-23/1820-2`; preset `7CDD523E-1D7C-47EA-98FE-D5FEA24D2D8C`; chat `step4c-repair-review1-34D6DC`; operation `19A3B476-9571-4349-A255-53DB45715CED`. Full response follows.

# Oracle Review



# Step 4c re-review, round 1/2 (fresh lane): regressions in the repair delta

## Summary

The repair changes one thing in the coordinator. When a prompt is admitted, has an unresolved helper and had `arm` sent, it now goes through `admittingUncertainRelaunchExit()` (`AgentLifecycleShutdownCoordinator.swift:132-147`). That swaps only the exact `restartTimeoutMessage` for the neutral `restartArmUnconfirmedMessage` (`:301`), keeps every other message, and clears `awaitsCleanExitAcknowledgement`. The admission check now runs once and its result (`admitted`) feeds both the rewrite and `appending(..., allowsUncertainRelaunchExit:)` (`:962-972`).

I checked every way a prompt can be presented. Nothing else changes:
- **Not admitted, `.safe` or `.unresolvedUnarmed`:** the new code only runs inside the `.unresolved` branch when `admitted` is true.
- **Restored prompt (Step 4b):** it is rebuilt by `observeRelaunchHelperStop` → `present(...)` from the original `messages` parameter, not from the rewritten `failure`.
- **Repeated presentations of the same prompt (the `while true` loop):** they reuse the rewritten `failure`, so the Equatable "same prompt again" checks still hold.
- **Choices and alert branch:** `allowsUncertainRelaunchExit` is false when `admittingUncertainRelaunchExit` runs and is set by `appending` straight after. `offeredChoices` and the alert branch don't depend on `awaitsCleanExitAcknowledgement` when the exit is offered, because the `offersUncertainRelaunchExit` case is checked first in `makeLifecycleShutdownFailureAlert`.

A timeout-admitted prompt always contains `restartTimeoutMessage`. The witness requires an acknowledged clean write, and `awaitCleanWrite` only clears `cleanWrite` on `false`. So `finalizationFinished` always picks the restart-timeout text, and the exact-string replacement can't silently miss.

The test changes hold up. The pass-through to the real alert builder is checked on both kinds of admitted prompt (timeout, and arm returning a blocker). The unadmitted case keeps the timeout text. The plain-quit negative is correct, since `present` only uses relaunch when the reason is `.safeRestart`. The composed driver test exercises the real `AppRelaunchCoordinator` path.

**No P0 or P1 regressions.**

## P2

### C4c-R1-01: the composed test's clock loop has a fixed iteration count, not a real-time limit
- **Scenario:** In `testSafeRestartComposedLostArmAcknowledgementOffersAnHonestExitAndTheDriverKeepsTheHelper`, the prompt needs three virtual-clock moves: the shared 7 s work expiry, the abort-acknowledgement deadline, and the 8 s final expiry. Between them, the driver's session and the `AsyncStream` reply hop executors. The loop gives up after 20 iterations, each doing `settle()` and at most a 1 ms real sleep. On a loaded host, the waits may not have registered when the 20 iterations run out. The following `waitUntil("the admitted prompt")` never moves the clock, so it fails after 5 s.
- **Impact:** an occasional false failure in the lifecycle suite. It is test-only and fails loudly.
- **Evidence:** `AgentLifecycleShutdownCoordinatorTests.swift:~2249-2257` (`for _ in 0 ..< 20 { … try? await Task.sleep(nanoseconds: 1_000_000) }`).
- **Smallest fix:** bound the loop by real time, the way `waitUntil` does (a 5 s `Date()` deadline), and keep advancing only to pending deadlines at or before `finalExpiry`. Alternatively, raise the iteration cap. Either is cheap; deferring it is reasonable.

## P3 (listed, not looped on)

### C4c-R1-02: a late `armed` can be described as "did not confirm whether it was armed"
- **Scenario:** `arm` succeeds and `stillCurrent()` holds, so `relaunchArmed = true`. Then `finalizationFinished` sees `isExpired` and rewrites the result to `restartTimeoutMessage`. `present` clears `relaunchArmed` and calls `abandon`. If the abort is unresolved (`armWasSent`), the admitted prompt says the helper "did not confirm … whether it was armed", although it did, just after expiry.
- **Impact:** wording is slightly wrong in a narrow timing race. The alert body still discloses the real outcome ("may reopen automatically, or it may not").
- **Evidence:** `finalizationFinished` (expiry override plus the `cleanWrite != nil` rewrite), together with `:132-147`.
- **Fix:** none needed. Optionally reword to "did not confirm in time that it was armed".

### C4c-R1-03 (not caused by this delta): the new comment overstates the restored prompt's accuracy
- **Scenario:** On an admitted prompt, the comment at `:964-966` says the restored ordinary prompt's original `messages` "are true once the helper's stop is proven". But the restored prompt is rebuilt by `present`, which sets `awaitsCleanExitAcknowledgement = (cleanWrite != nil)` = true and reuses `restartTimeoutMessage` ("could not confirm … that it recorded a clean exit"). The clean write is known to be acknowledged at that point. The same applies to the unadmitted prompt where verification hung after the acknowledgement. That one is asserted at test `~1790-1796` with the comment "is true again".
- **Impact:** this behaviour predates the delta, and the conjunction wording ("A, B, and C") is defensible. Still, the delta now treats "clean write acknowledged" inconsistently depending on whether the prompt was admitted.
- **Fix:** either soften the comment ("kept verbatim; correct as a conjunction") or defer a follow-up that derives `awaitsCleanExitAcknowledgement` from "enqueued but not acknowledged" rather than `cleanWrite != nil`. Out of scope for this round.

## Recommendations
1. Nothing blocks the commit for this lane: no P0 or P1 is open, and the repair matches its stated scope (exact-text replacement, admitted prompts only, other diagnostics kept, acknowledgement flag cleared).
2. Optionally make the composed-test loop real-time bounded (C4c-R1-01) before committing; it is a one-line change and there's no need to rerun the suite only for it. Otherwise list it as deferred.
3. Record C4c-R1-02 and C4c-R1-03 as deferred P3s. If the acknowledgement flag is revisited later, base it on "pending" rather than "enqueued".
4. Validation scope is as you reported. This lane did no live UI, real-helper or packaging checks; production stays OFF.
