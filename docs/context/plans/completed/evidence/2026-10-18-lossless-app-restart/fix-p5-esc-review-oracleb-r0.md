# Step 8 P5 Esc fix review round 0: OracleB

Scope: read when the task touches Escape or keyboard focus of the recovery View popover (verifier check P5).
Authority: Reference
Last-verified: 2026-10-28
Covers: OracleB round-0 review of the P5 fix (chat p5-esc-review-oracleb-r0-30618C)




# P5 Esc fix review: recovery View popover

## Summary

The fix leaves the decision table as it is and makes the popover's own window key one main-queue turn after `show`. That means Escape now reaches the window where the event monitor handles it (`AgentRecoveryNativePopover.swift:303-308`). When the popover closes, `close()` makes the previously key window key again before the popover window is ordered out (`:318-322`). The key logic sits in a small seam that the tests can drive: `AgentRecoveryNativePopoverKeyWindow` and `AgentRecoveryNativePopoverKeyFocus` (`:33-71`). Four fake-window tests cover it.

I traced the paths the brief asks about: the deferred `makeKey` against close or re-open, close ordering, outside clicks (same window, another window, the window behind a sheet), the anchor toggle, a second row's View, and dismantle. All of them come out correct. The `self.popover === popover` guard drops a stale deferred `takeKey`. `returnKey` runs before `popover.delegate = nil` and `popover.close()`. In `.closeAndDeliver`, key is returned before AppKit dispatches the click.

**I found no P0 or P1.** The remaining findings are about two things:
- **App deactivation:** the acceptance criterion "focus returns to the window that had it" is not met when the app is switched away.
- **The evidence report:** it says guardrails pass, but its own commands table shows them failing.

All AppKit claims below are inferred from code reading. None was observed in a running app.

## Findings

### P2

**P5-R1: Switching apps no longer gives focus back to the window that had it**
- **Failure scenario:** The user opens View and doesn't click anything. `takeKey` now makes the popover window key. The user presses Cmd-Tab and comes back.
  - The observer is on `didResignActiveNotification`. By the time it fires, the app is inactive and the popover window is no longer `isKeyWindow`, so `returnKey` correctly does nothing.
  - The window AppKit remembers as key at deactivation is now the popover window, which then closes. On reactivation AppKit picks a key window by its own fallback.
  - Before this change, in this exact flow (no click inside), the anchor window or sheet stayed key throughout, and reactivation restored it.
- **Impact:** After coming back, the composer or sheet may not have key. With a sheet attached, key could land on the parent window. The user then needs an extra click before typing, which breaks the acceptance criterion "Keyboard focus returns to the window that had it". The worker report admits this is unverified (P9 inference). It is easy to work around, hence P2.
- **Evidence:** `AgentRecoveryNativePopover.swift` ~`:350-356` (`didResignActiveNotification` observer); `:65` (`returnKey` requires `popoverWindow.isKeyWindow`); `:282` and `:305-307`.
- **Smallest fix:** Observe `NSApplication.willResignActiveNotification` instead. At that point the app is still active and the popover window is still key, so `close()` → `returnKey` makes the anchor window or sheet key first, and AppKit remembers it for reactivation. The popover still closes on app switch. Update the `returnKey` doc comment, which currently gives "the app was deactivated" as a reason to leave focus alone. If you'd rather not change this, have verifier step 11 record exactly which window has key on return, and decide from that.

**P5-R2: The report's validation claims contradict its own table, and the claimed script change is not in the reviewed diff**
- **Failure scenario:**
  - The worker report says "Unit tests, lint and guardrails pass", but its commands table shows `make guardrails` exiting 2 with 4 agent-context errors.
  - The table says the header failed with "Scope: P5 fix worker report". The file under review now has a compliant `Scope: read when the task touches …` line, so it was edited after the run and guardrails were not rerun.
  - The `[reachability]` error (no doc links to this report) is not addressed anywhere in the diff.
  - "Other changes" says `Scripts/source_layout_guardrails.sh` was edited, but that hunk is not in `prompt-exports/p5-esc-review.diff`. Either the diff is incomplete or the change was never made.
- **Impact:** Pre-commit checks will fail at commit time. This conflicts with the policy rules "say how each result was obtained" and "Later edits: rerun affected validation". It is developer tooling and fails loudly, so P2.
- **Evidence:** `fix-p5-esc-worker.md:7` (claims guardrails pass); the `make guardrails` row of the commands table (exit 2); `fix-p5-esc-worker.md:2` (header now compliant); the "Other changes" section; `p5-esc-review.diff` (only two files).
- **Smallest fix:**
  1. Rerun `make guardrails`.
  2. Link the report from the spec's Step 8 line, or from whatever doc is meant to make evidence reachable.
  3. Include the guardrails-script hunk in the diff (or drop the claim).
  4. Change the summary line to match the actual result.

**P5-R3: The popover now always takes key, so code that looks up the key window sees the popover**
- **Failure scenario:** While View is open, without any click inside, `NSApp.keyWindow` is now `_NSPopoverWindow`. Anything that resolves "the current window" through the key window now gets the popover's window:
  - responder-chain menu commands such as Cmd-W, Cmd-Enter, or tab commands;
  - SwiftUI `@FocusedValue`/`focusedSceneValue`-driven `Commands`;
  - any app code that calls `NSApp.keyWindow` to find the active workspace window.

  Before, this only happened after a click inside the popover. Now it happens every time it opens.
- **Impact:** Shortcuts beep or are disabled while the popover is open. If any non-UI path uses `NSApp.keyWindow` (for example to resolve the active window for a background operation), it could pick the wrong window or none. Escape or a click recovers, and the worker report documents this as a trade-off (verifier step 4), so P2 at most.
- **Evidence:** `:305-307` (`takeKey` is unconditional); `fix-p5-esc-worker.md`, "Shortcuts while the popover is key".
- **Smallest fix:** No code change unless a real dependency turns up. Grep for `NSApp.keyWindow` / `NSApplication.shared.keyWindow` outside UI code. If something non-interactive relies on it, have it use `mainWindow` or an explicit window reference instead.

### P3

**P5-R4: `returnKey` runs synchronously inside SwiftUI updates, while `takeKey` was deferred to avoid exactly that**
- **Scenario:** `close()` is reached from inside a SwiftUI update in two places: `updateNSView` (binding set to `false`, ~`:258-260`) and `dismantleNSView` (row removed, P10, ~`:221-225`). In both, `returnKey` calls `makeKey()` there and then, which posts the didBecomeKey/didResignKey notifications during the view update. The report justifies deferring `takeKey` by saying the key change should happen outside the SwiftUI update, and that reasoning applies equally here.
- **Impact:** Probably harmless, since `makeKey` is not a SwiftUI state write, but it could produce "modifying state during view update" runtime warnings if something observes key changes.
- **Smallest fix:** None now. Add to verifier step 13 (P10) a check that the Xcode console shows no SwiftUI update warnings. Deferring `returnKey` would mean also deferring `popover.close()`, which is a larger change.

**P5-R5: The tests don't cover the coordinator wiring, and one assertion proves nothing**
- **Scenario:**
  - `testShownPopoverTakesKeySoEscapeReachesIt` passes `popoverWindow.isKeyWindow` as `inPopover`. That ties key status to `event.window === popoverWindow`, which is the very AppKit assumption under question, so the assertion is circular.
  - The real risks are not exercised: that `returnKey` runs before `popover.close()`, that `previousKeyWindow` is captured before `show`, and the stale-async guard.
- **Impact:** A future reordering inside `close()` would pass every test.
- **Smallest fix:** Drop the circular `decide` assertion, or label it as illustrative. Rely on the live verifier for the wiring and don't loop on it.

**P5-R6: The report overstates what is "verified" for close paths**
- **Scenario:** The report says `close` returns key "on every close path". That is not true in two cases:
  - In the `popoverDidClose` path (AppKit closed the popover), the window is already ordered out, so `returnKey` does nothing.
  - In the deactivation path, `returnKey` also does nothing (P5-R1).
- **Smallest fix:** In the "Verified" section, change "every close path" to "every close path we initiate".

**P5-R7: Cycling windows with Cmd-\` leaves a popover open that Escape can't close**
- **Scenario:** With the popover key, Cmd-\` makes another window key. The event monitor ignores it, so the popover stays open. Escape in either window is then `.ignore`, because neither is the popover's window, and only a mouse click closes it.
- **Impact:** This already happened before the change, and it's rare. Listed for completeness.
- **Smallest fix:** None now. If it matters later, close on the popover window's `didResignKeyNotification`, but only once it has taken key.

## Recommendations

1. Apply the P5-R1 fix (`willResignActiveNotification`); it is a one-line change. If you don't, make verifier step 11 a pass/fail check on which window has key after Cmd-Tab back, for both the banner and the sheet.
2. Fix P5-R2 before committing: rerun guardrails, make the report reachable, include or drop the guardrails-script hunk, and correct the "guardrails pass" sentence.
3. The root cause is still inferred. In verifier step 1, first confirm that a single Esc closes the popover and does not reach the composer. Also grep for any other `addLocalMonitorForEvents` that handles `keyCode == 53` (for example a composer or agent-interrupt Esc handler). Such a monitor could consume Esc before this one does, or trigger an action such as interrupting a running agent as well. Add "Esc does not interrupt a running agent turn" to step 1.
4. Do the P5-R3 grep for `NSApp.keyWindow` in non-UI code. Escalate only if something background-driven depends on it.
5. Add the console-warning check from P5-R4 to verifier step 13.
6. P5-R5 through P5-R7 are cheap to defer: list them under `deferred:` and don't run another review round for them.