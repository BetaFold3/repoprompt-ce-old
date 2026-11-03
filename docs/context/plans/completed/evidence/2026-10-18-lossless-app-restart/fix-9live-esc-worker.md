# 9-live fix 1: Esc closes only the View popover
Scope: read when the task touches Escape or keyboard focus of the recovery View popover (verifier check P5).
Authority: Reference
Last-verified: 2026-10-28
Covers: AgentRecoveryNativePopover.swift and its tests

This implements Step 1 (R6) of [plan-9live-fixes-oracled.md](plan-9live-fixes-oracled.md), using option A from [diag-9live-r6-worker.md](diag-9live-r6-worker.md). It changes only `Sources/RepoPrompt/Features/AgentMode/Views/Components/AgentRecoveryNativePopover.swift` and `Tests/RepoPromptTests/AgentMode/Recovery/AgentRecoveryNativePopoverEventDecisionTests.swift`. Nothing is staged or committed. The XCTest ledger, `Scripts/source_layout_guardrails.sh` and the spec are not touched; this suite has no ledger rows.

## Evidence labels

- **Verified (code):** read in this repository.
- **Verified (test):** asserted by a unit test that ran and passed.
- **Verified (probe):** from the diagnosis's standalone AppKit probe, not the RepoPrompt app. No probe ran for this fix.
- **Inferred:** AppKit's documented behaviour or reasoning, not observed in the app.

## The change

- **`AgentRecoveryNativePopoverEventDecision.decide`** has a new parameter, `isInAnchorWindow`.
  - Esc returns `.closeAndConsume` when the key-down is in the popover's window or in the anchor's window.
  - Esc in any other window, and every other key, returns `.ignore`.
  - Mouse-downs are decided exactly as before. `isInAnchorWindow` doesn't affect them.
- **`shouldConsume`** computes `isInAnchorWindow` as `event.window != nil && event.window === anchor?.window`.
- **Deleted:**
  - `AgentRecoveryNativePopoverKeyWindow` and its `NSWindow` conformance;
  - `AgentRecoveryNativePopoverKeyFocus` (`takeKey`, `returnKey`);
  - the deferred `takeKey` after `show`;
  - `returnKey` in `close`;
  - `previousKeyWindow` and where it was set in `show`.
- **Kept:** the `willResignActive` observer, which still closes the popover on app switch.
- **Comments fixed:**
  - The type doc now explains why Esc is handled in the anchor's window: the popover's window doesn't become key, even with `makeKey()`. That fact is Verified (probe) in the diagnosis.
  - The `.closeAndConsume` doc names both windows.
  - A note in `decide` explains why this is not any-window.
  - The `willResignActive` comment no longer says `close` gives key back.
  - The outside-click (`.closeAndDeliver`) comment no longer says that `close` gave key back.
- **Monitor lifetime is unchanged.** `installMonitors()` runs only in `show`, and `removeMonitors()` runs first in `close`. So with no popover open, Esc behaves as before. Verified (code).

### Esc in the Needs Attention sheet

When a row's View popover is open in the sheet, the anchor `NSView` is inside the sheet's content. So `anchor.window` is the sheet's window.

The popover's window doesn't become key, so the Esc key-down arrives with `event.window` set to the sheet's window. `decide` returns `.closeAndConsume`. The monitor closes the popover and returns `nil`, so AppKit never dispatches the event. The sheet's default Escape dismissal therefore never sees that press, and the sheet stays open.

Which parts are verified and which are inferred:
- **Verified (code):**
  - the monitor closes the popover and returns `nil` for Esc when `event.window` is the anchor's window (`shouldConsume`, `.closeAndConsume`);
  - the sheet has no `.keyboardShortcut(.cancelAction)`, `onExitCommand` or custom Escape monitor of its own (`AgentRecoveryNeedsAttentionSheet.swift`: the "Done" button at `:62` has no shortcut, and `.sheet` is at `:299`), so its Escape handling is SwiftUI's default sheet dismissal.
- **Verified (test):** the decision for Esc in the anchor window is `.closeAndConsume`.
- **Inferred, from AppKit's documented local-monitor contract:**
  - the monitor runs before the event is dispatched to the window, so it runs before SwiftUI's sheet cancel handling;
  - a `nil` return stops dispatch.

  The diagnosis's probe (`sheet consume`) showed exactly this with a synthetic event: the sheet stayed open and the popover closed. That is Verified (probe), not observed in the app.
- **Inferred:** in the app, `event.window` for that Esc is the sheet's window. This is Verified (probe) in the diagnosis.
- **Live check:** P5 sheet, below.

### Other Escape handlers this can pre-empt (while a popover is open)

- **Composer mention list and snippet palette.** Both dismiss through the text view's `cancelOperation` delegate hook (`TextFieldMentionHelpers.swift:135,495`, `SnippetPaletteHelper.swift:115`). That hook runs during dispatch, so with a popover open the first Esc closes the popover and a second Esc closes the list. Verified (code) for where the hook is; inferred for the order in the app.
- **Running turn.** A grep of `Sources/RepoPrompt` and `Sources/RepoPromptUI` for Escape bindings (`keyCode == 53`, `.escape`, `cancelAction`, `onExitCommand`, `cancelOperation`) found none that interrupt an Agent turn. The 9-live run also saw Esc not interrupting a turn. With this change, Esc with a popover open is consumed, so the turn keeps running. Inferred.
- **Other local key-down monitors** (`TooltipBubble.swift:210`) return the event and only hide a tooltip; the order between monitors is undocumented (diagnosis, Verified code).

## Tests

`AgentRecoveryNativePopoverEventDecisionTests` (12 tests):

| Test | Asserts |
|---|---|
| `testOutsideClickClosesAndIsDelivered` | Mouse-down outside: `.closeAndDeliver`, with or without `isInAnchorWindow` (mouse-down table unchanged). |
| `testClickInsidePopoverKeepsItOpen` | Unchanged: `.ignore`. |
| `testClickOnAnchorTogglesClosedWithoutReopening` | Unchanged result, `.closeAndConsume`. It now passes `inAnchorWindow: true`, as the real anchor click has it. |
| `testEscapeInPopoverCloses` | Unchanged: `.closeAndConsume`. |
| `testEscapeInAnchorWindowClosesAndIsConsumed` | **New:** Esc in the anchor's window → `.closeAndConsume`. |
| `testEscapeInAnUnrelatedWindowIsIgnored` | **New (split from `testKeysElsewhereAreIgnored`):** Esc in neither window → `.ignore`. |
| `testOtherKeysAreIgnored` | **New (rest of the old test):** a non-Esc key in the anchor window, in the popover window, or elsewhere → `.ignore`. |
| Five `testRegionPlacement…` tests | Unchanged. |

Removed: `testShownPopoverTakesKeySoEscapeReachesIt`, `testShownPopoverDoesNotTakeKeyWhenItCannotOrAlreadyHasIt`, `testClosingAKeyPopoverGivesKeyBackToThePreviousWindow`, `testClosingLeavesFocusAloneWhenThePopoverIsNotKeyOrThePreviousWindowCannotTakeIt`, and their `FakeWindow`. The seam they tested is deleted. Their premise, that the popover's window takes key, is false (Verified (probe) in the diagnosis). This is a deliberate contract change, not a weakened assertion.

The unit tests cover the decision table only. They don't route real events through `NSEvent` monitors; the live check below is the proof of the routing.

## Commands run

All through the conductor. Logs are under `~/Library/Application Support/RepoPrompt CE/Conductor/82430cd62f1cefa34a697069b92288bdf6730d048fa0ae24fa2aa774dd59c311/jobs/`.

| Command | Result | Log (`jobs/…`) |
|---|---|---|
| `make dev-test FILTER=AgentRecoveryNativePopoverEventDecisionTests` | Exit 0; 12 tests, 0 failures (exec 2m 54s, full compile). | `3548fc50-1e7d-4496-9a2f-b63a4ea665cf.log` |
| `make dev-test FILTER=AgentRecoveryListHeaderTextTests` | Exit 0; 9 tests, 0 failures. | `bacd7e43-1325-4642-8595-bb4e9eddb371.log` |
| `make dev-lint` | Exit 0: SwiftFormat "0/2205 files require formatting", then `swiftlint lint --strict`, clean. | `b508f9e8-bf4e-4e99-a1b3-2f50f13db6e6.log` |

After those runs I made comment-only edits to the source file (the type doc, the resign-active comment, and rewrapping). Then:

| Command | Result | Log (`jobs/…`) |
|---|---|---|
| `make dev-test FILTER=AgentRecoveryNativePopoverEventDecisionTests` | Exit 1: `AgentInputBar.swift` (another worker's file) "was modified during the build". Not a test failure. | `b7038ac4-7467-4a25-a9cb-ad731160a5a1.log` |
| `make dev-test FILTER=AgentRecoveryNativePopoverEventDecisionTests` (rerun) | Exit 0; 12 tests, 0 failures (exec 2m 40s). | `bf2831d2-3234-4ddd-8fa9-68566c391125.log` |
| `make dev-test FILTER=AgentRecoveryNativePopoverEventDecisionTests` (after the final rewrap) | Exit 0; 12 tests, 0 failures (exec 1.3 s; a concurrent job had already compiled the tree). | `1477bc3c-674d-499a-9c92-6b3e337abdbf.log` |
| `make dev-test FILTER=AgentRecoveryListHeaderTextTests` (final) | Exit 0; 9 tests, 0 failures. | `f832b534-4313-475e-8c46-0dd623d922b0.log` |
| `make dev-lint` (final) | Exit 1, but only for files edited concurrently by other workers. `AgentRecoveryListBanner.swift:204-206` (indent), `AgentModeViewModel+Recovery.swift:292`, `AgentRecoveryStartupCompositionTests.swift:1471,1485`, `AgentRecoveryVMProducerAdmissionTests.swift:1556` (trailingCommas); "4/2205 files require formatting". Neither of this fix's files is flagged. SwiftLint did not run after SwiftFormat failed. | `d5d38b60-0de5-4ace-ad4f-c5889460cd4d.log` |

The comment edits after the clean lint run add no line over the existing width of the file. `.swiftformat` has `--maxwidth none` and `.swiftlint.yml` has no `line_length` rule. A clean `make dev-lint` over the final tree needs the other workers' formatting fixed first.

Not run: `make guardrails` (the main agent wires this report in), the full test suite, and any live or GUI check.

## Manual steps for the live verifier

Use a Dev build containing this change and a session with a recovery row that has a View button (held input, or a draft with text or attachments). Send Esc as a real key press (System Events key code 53 is fine) after a real click on View.

1. **P5, banner.** Click the composer and type a few characters. Click **View**, then don't click anything. Press **Esc** once.
   - Pass: the popover closes on that press. The composer's text and caret are unchanged; that Esc did not reach the composer.
   - Then type one character. It goes into the composer at the caret, with no extra click.
2. **P5, sheet.** Open Needs Attention, click **View** on a row, press **Esc** once.
   - Pass: the popover closes and the sheet stays open.
   - Press **Esc** again: the sheet behaves as it does with no popover (its default Escape dismissal).
3. **Esc with no popover open.** With no popover open, press **Esc** in the composer, and separately in the sheet. Pass: the same as before this change (the composer is unchanged; the sheet dismisses as it did before).
4. **Typing while open (observation).** Open View and type a letter without clicking. Expected: the letter goes into the composer, and the popover stays open (it never takes key). Press **Esc**: the popover closes, and the next letter goes into the composer.
5. **Esc during a running turn.** Start a turn that runs for a while, open View, and press **Esc** once. Expected: the popover closes and the turn keeps running. Record whether a second Esc does anything to the turn; expected: the same as Esc with no popover open.
6. **Esc with the composer's mention list open.** Type `@` in the composer so the mention list opens, then click **View** once.
   - If the mention list closed on that click, record it and skip the rest of this step.
   - Otherwise press **Esc** once. Expected: the popover closes and the mention list stays open.
   - Press **Esc** again. Expected: the mention list closes.
   - Repeat with the snippet palette if convenient, and record the order observed.
7. **P1/P7 (row actions).** Open View, then click once on another row's Edit, Remove, Restore, Dismiss or Open, in the banner and in the sheet. Pass: the popover closes and the button acts on that click.
8. **P2 (composer).** Open View, then click once in the composer. Pass: the popover closes, the composer has focus, and typing works at once.
9. **P3 (sidebar/toolbar).** Open View, then click once on a sidebar session or a toolbar button. Pass: the popover closes and that item activates on that click.
10. **P4 (toggle).** Open View, then click **View** again. Pass: the popover closes and stays closed, and the next click reopens it. Then press Esc in the composer: same as with no popover.
11. **Selectable text.** Open View, drag to select text inside, and press Cmd-C. Pass: the popover stays open, the text is selected and copied, and Esc then closes it with one press.
12. **P8 (other window).** Open View, then use File > New Window and click a control in the new window once. Pass: the popover closes, that window activates under normal first-click rules, and nothing else changes focus. If the popover is still open while the other window is key, Esc there goes to that window and leaves the popover open (by design, not any-window).
13. **P9 (app switch).** Open View, press Cmd-Tab away and back. Pass: the popover has closed, one click on View reopens it, and Esc right away closes it. Record which window has key when you return (expected: the main window, or the sheet).
14. **P10, if a removable row is available.** Open View and remove that row while it is open. Pass: the popover goes away; the next View on a returning row opens with one click and closes with one Esc. If a console is available, check it for "Modifying state during view update" warnings.
15. **P11 (window behind the sheet).** Open View in the sheet, then click the window behind the sheet, outside the popover. Pass: the popover closes and keyboard focus stays on the sheet, not in the composer behind it. Then press Esc: the sheet's default Escape handling (no popover is open).

## Not verified

- **Not observed in the app:** the routing of a real Esc through the local monitor (consume before dispatch, in both the banner and the sheet). It is Verified (probe) in the diagnosis and Inferred for the app; steps 1, 2 and 5–6 above check it.
- **Not checked:** how a held Esc (key repeat) behaves. Only the first key-down is consumed; repeats after the monitor is removed reach the composer or the sheet. Inferred, minor.
