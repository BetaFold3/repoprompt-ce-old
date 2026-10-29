# P5 Esc closes the recovery View popover
Scope: read when the task touches Escape or keyboard focus of the recovery View popover (verifier check P5).
Authority: Reference
Last-verified: 2026-10-28
Covers: AgentRecoveryNativePopover.swift and its tests

Verifier result P5 (spec "Steps 8/9 verifier scenarios"): with View open and nothing clicked, Esc, even pressed twice, does not close the popover. This fixes it, based on review finding F3 in `fix-popover-review-oracleb.md`. Unit tests and lint pass; the worker's guardrails run failed only on this report's header and reachability, which the main agent fixed afterwards (see Main-agent follow-up). The behavior in the running app is unverified: nobody has launched it, so the external verifier still needs to run the steps below. Nothing is staged or committed.

## Root cause

Line numbers refer to `HEAD` (`fbf5777d`) of `Sources/RepoPrompt/Features/AgentMode/Views/Components/AgentRecoveryNativePopover.swift`.

- `:28`: `decide` closes on Escape only when `isEscapeKey, isInPopoverWindow`.
- `:319`: `isInPopoverWindow` is `event.window === popoverWindow`. A key-down's `event.window` is the key window.
- `:234`, `:254`, `:258`: the popover uses `.applicationDefined` and is shown with `show(relativeTo:of:preferredEdge:)`. Nothing then makes its window key.
- So, straight after opening, the window that had key (the anchor's main window or the Needs Attention sheet) stays key. Esc arrives with `event.window` set to that window, `decide` returns `.ignore`, and Esc goes on to the composer or sheet. The popover stays open however often Esc is pressed.
- How sure is this:
  - **Code, confirmed:** the decision table and the `event.window` comparison.
  - **Inference from the live P5 failure and F3:** that `NSPopover.show` with `.applicationDefined` does not make the popover key. I didn't check this in AppKit itself.
- The old comment at `:330` ("The popover window was key") only held once the user had clicked inside the popover.

## The change

`AgentRecoveryNativePopover.swift`. Escape handling stays where it was, in the popover's own window only, and nothing is added for the anchor window.

- **`:33-74`, new seam:**
  - Protocol `AgentRecoveryNativePopoverKeyWindow`, which `NSWindow` conforms to at `:42`. It covers `isVisible`, `canBecomeKey`, `isKeyWindow` and `makeKey()`.
  - Enum `AgentRecoveryNativePopoverKeyFocus` with two functions:
    - `takeKey(popoverWindow:)` at `:53` makes the popover's window key, unless it is already key or can't become key.
    - `returnKey(from:to:)` at `:61` runs on close. If the popover's window is still key, it makes the window that was key at open key again, provided that window is a different window, still visible and able to become key. Otherwise it changes nothing.
- **`:242` and `:282`:** the coordinator weakly remembers `NSApp.keyWindow` as `previousKeyWindow` when it shows the popover.
- **`:303-309`:** after `show`, one main-queue turn later, it calls `takeKey` with the popover's window.
  - The extra turn is there because `show` runs inside SwiftUI's `updateNSView`, so the key change happens outside that view update. This follows the deferred binding writes already in this file.
  - The call is skipped if the popover was closed or replaced in the meantime (`self.popover === popover`).
- **`:317-321`:** `close` calls `returnKey` before `popover.close()`. That covers Esc, a click on the anchor, an outside click, a row action, SwiftUI-requested close, dismantle, AppKit close and app deactivation. Key goes back to where it was before the popover took it, and AppKit doesn't have to choose a new key window when the popover's window is ordered out.
- **`:385-387`:** the comment on the outside-click `makeKey` now says why it can still be needed. The code there is unchanged. Since `close` has already given key back, it is normally a no-op.

What changes for the user, by design:
- Esc right after opening closes the popover on the first press.
- While the popover is open, other keystrokes go to the popover and no longer to the composer. This is the same as the existing behavior after clicking inside it. Once the popover closes, key returns to the window that had it.

## Tests

`Tests/RepoPromptTests/AgentMode/Recovery/AgentRecoveryNativePopoverEventDecisionTests.swift` gains a recording `FakeWindow` (`:85`) and four tests:

- `testShownPopoverTakesKeySoEscapeReachesIt` (`:99`): the popover's window is asked to become key once. With that window key, `decide` turns Escape into `.closeAndConsume`.
- `testShownPopoverDoesNotTakeKeyWhenItCannotOrAlreadyHasIt` (`:108`): nothing happens when the window is already key, can't become key, or is nil.
- `testClosingAKeyPopoverGivesKeyBackToThePreviousWindow` (`:121`).
- `testClosingLeavesFocusAloneWhenThePopoverIsNotKeyOrThePreviousWindowCannotTakeIt` (`:130`): key is not moved when the popover is not key (focus already moved), the previous window is hidden or can't become key, the previous window is the popover itself, or either window is nil.

The existing decision-table tests are unchanged and still pass, so Esc outside the popover's window is still `.ignore` and the anchor-window behavior is unchanged when no popover is open. The frozen ledger was not touched.

These tests do not reach the real `NSPopover` / `NSWindow` path. Three things are still unproven:
- that `host.view.window` is non-nil one turn after `show`;
- that `_NSPopoverWindow.canBecomeKey` is true;
- that `makeKey` really routes Esc there.

Only the live check below proves them.

## Commands run

| Command | Result | Job log |
|---|---|---|
| `make dev-test FILTER=AgentRecoveryNativePopoverEventDecisionTests` | exit 0; 14 tests (10 existing + 4 new), 0 failures; no diagnostics in the changed files; compiled the `RepoPromptApp` module with the change | `~/Library/Application Support/RepoPrompt CE/Conductor/82430cd62f1cefa34a697069b92288bdf6730d048fa0ae24fa2aa774dd59c311/jobs/c071135e-6084-4344-8a7e-9602579dbfbe.log` |
| `make dev-test FILTER="'AgentRecoveryNativePopoverEventDecisionTests\|AgentRecoveryListHeaderTextTests'"` | rejected by the conductor before running: "matched no curated ledger entry or source suite" (the same as in `fix-popover-worker.md` round 1), so each suite was run on its own | none |
| `make dev-test FILTER=AgentRecoveryListHeaderTextTests` | exit 0; 9 tests, 0 failures | `…/jobs/9fbc4919-34e1-4914-8e91-ecb2fbe88b89.log` |
| `make dev-lint` | exit 0; SwiftFormat "0/2205 files require formatting"; `swiftlint lint --strict` reported no violations | `…/jobs/5a5d56b5-7c81-4cc2-a904-a6a2d71b671d.log` |
| `make guardrails` | exit 2 (`make: *** [guardrails] Error 1`). Source layout, contributor allowlist (768 entries) and notice inventory checks pass. The agent-context check reports 4 errors, all in two evidence files. Each fails `[header]`: the required `Scope:` line here ("Scope: P5 fix worker report", as specified in the brief) and the untouched `fix-f1-regression-bisect.md` do not use the form `Scope: read when the task touches …`. Each also fails `[reachability]`: no reachable doc (for example the spec's Step 8 line) links to either file yet. The AGENTS.md route-count warning was already there. | terminal output only |

`make dev-build` was not run separately. The test build compiled the changed app source in the same module, and the only other change is the guardrails script.

## Focus on close: what AppKit does, verified vs inferred

**Verified (code and unit tests):**
- On every close path the coordinator initiates, `close` makes the window that was key at open key again, but only if the popover still has key.
- That puts key back in the state it had before this change, when the popover never took key, before the event (if any) is delivered:
  - **Outside click in the anchor window, or a row action (P1–P3, P7):** the anchor window is key again. The existing `makeKey` check then finds it key, and the click is delivered as a normal click, as before.
  - **Click in another RepoPrompt window (P8):** the anchor window is key again first. The other window then gets normal first-click activation, as before.
  - **Click on the window behind the sheet (P11):** the sheet window was key at open and is made key again. AppKit doesn't let a window with a sheet attached take key. This is unchanged.
  - **Click on View (P4):** the anchor window is key again and the click is consumed, as before.

**Inferred (AppKit behavior, not observed here):**
- An `NSWindow` keeps its `firstResponder` while it isn't key. So when the anchor window becomes key again, the composer (or whatever had focus there) has focus again with no extra work.
- If `returnKey` didn't run, AppKit would choose a new key window when the key popover window is ordered out, probably the parent or main window. Doing it explicitly avoids depending on that choice, especially with a sheet.
- **App deactivation (P9):** the popover's window is no longer key once the app is inactive, so `returnKey` leaves focus alone. On reactivation AppKit picks a key window itself, because the one it remembers (the popover's) has closed. I expect this to be the main window or the sheet. Unverified. This case already behaved this way before the change, after a click inside the popover.
- **Shortcuts while the popover is key:** menu shortcuts that act on the key window (for example Cmd-W) now reach the popover's window instead of the main window. Not checked. Again the same as the existing behavior after a click inside.

## Manual steps for the external verifier

Use a Dev build containing this change and a session with a recovery row that has a View button (held input, or a draft with text or attachments). Use both the composer banner and the Needs Attention sheet where noted.

1. **P5, banner.** Click the composer and type a few characters. Click **View**, then don't click anything. Press **Esc** once.
   - Pass: the popover closes on that press.
   - Then type one character. It must go into the composer at the caret, with no extra click. The composer's earlier text and caret are unchanged, and the first Esc did not reach the composer.
2. **P5, sheet.** Open Needs Attention, click **View** on a row, press **Esc** once.
   - Pass: the popover closes and the sheet stays open and keeps key: Tab moves through the sheet's controls, and Esc again acts on the sheet as it did before this change.
3. **Escape with no popover open.** With no popover open, press **Esc** in the composer and in the sheet. Pass: the same as before this change.
4. **Typing while open.** Open View and type a letter without clicking. Expected: the composer does not change (the popover has key; you may hear a beep). Press Esc: the popover closes and the next letter goes into the composer. Record what you observe; this step documents the trade-off and has no pass/fail.
5. **P1/P7 (row actions).** Open View, then click once on another row's Edit, Remove, Restore, Dismiss or Open. Pass: the popover closes and the button acts on that click.
6. **P2 (composer).** Open View, then click once in the composer. Pass: the popover closes, the composer has focus, and typing works at once.
7. **P3 (sidebar/toolbar).** Open View, then click once on a sidebar session or a toolbar button. Pass: the popover closes and that item activates on that click.
8. **P4 (toggle).** Open View, then click **View** again. Pass: the popover closes and stays closed, and the next click reopens it. Then press Esc in the composer: same behavior as with no popover.
9. **Selectable text.** Open View, drag to select text inside, and press Cmd-C. Pass: the popover stays open, the text is selected and copied, and Esc then closes it.
10. **P8 (other window), if a second window can be opened.** Open View, then click a control in the other window once. Pass: the popover closes, that window activates under normal first-click rules, and nothing else changes focus.
11. **P9 (app switch).** Open View, press Cmd-Tab away and back. Pass: the popover has closed, one click on View reopens it, and Esc right away closes it. Also record which window has key when you return (expected: the main window or the sheet).
12. **P11 (window behind the sheet).** Open View in the sheet, then click the window behind the sheet, outside the popover. Pass: the popover closes and keyboard focus stays on the sheet, not in the composer behind it.
13. **P10, if a removable row is available.** Open View and remove that row while it is open. Pass: the popover goes away, and the next View on a returning row opens with one click and closes with one Esc.

## Other changes

- `Scripts/source_layout_guardrails.sh`: after `fix-10b-live-apply.md`, added `fix-f1-regression-bisect.md` (that file already exists and is unchanged) and this report to the lossless-restart evidence allowlist.

## Main-agent follow-up (2026-10-28)

After the OracleA and OracleB round-0 reviews (no P0/P1; [A](fix-p5-esc-review-oraclea-r0.md), [B](fix-p5-esc-review-oracleb-r0.md)):
- B P5-R1 applied: the app-switch close now observes `NSApplication.willResignActiveNotification` instead of `didResign…`. The popover window is still key then, so `close` gives key back to the window that had it before AppKit records the key window for reactivation. Inferred from AppKit's documented order; not observed live.
- B P5-R2 / A F2 applied: the summary line now matches the guardrails result. This report's header is fixed, it and the bisect report are linked from the spec's status lines, and both are allowlisted in `Scripts/source_layout_guardrails.sh`. Guardrails are rerun before the commit.
- B P5-R6 applied: "every close path" now says "every close path the coordinator initiates".
- B recommendation 3: a grep for other local Escape monitors (`keyCode == 53`) found only `AgentChangesPresentation.swift:448`, the Changes panel's search field, which is not in this flow.
- B P5-R3: `NSApp.keyWindow` is read in `GlobalKeyboardShortcutsCoordinator`, `WindowStateManager`, `WindowStatesManager+LifecycleShutdown`, `RepoPromptApp` and `OpenPanelService`. This was already the case after a click inside the popover; deferred, to be watched in the verifier's shortcut step.
- Deferred, no further round: A F1 and B P5-R5 (the unit tests cover the helper policy, not real event routing; the live verifier is the proof); B P5-R4 (key returned synchronously inside a SwiftUI update; add a console-warning check to the P10 step); B P5-R7 (Cmd-` leaves an open popover that Escape can't close; this predates the change).
