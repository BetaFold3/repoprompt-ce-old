# 9-live fix 1 (Esc): OracleB round-0 review

Scope: read when the task touches Escape or keyboard focus of the recovery View popover (verifier check P5).
Authority: Reference
Last-verified: 2026-10-28
Covers: the OracleB review of the Esc diff, copied from its export

Main agent outcome: ESC-1 applied (Esc during an input-method composition is left to the composition); ESC-2 deferred; ESC-3 added to the next live check; ESC-4 done (lint ticket 3e059a7b-46ca-4e31-b5d7-9afcec550836 passed on the final Esc tree; EventDecision tests 12/12).




# Review: Step 9-live-fixes (1), Esc closes only the recovery View popover (`9fix-esc.diff`)

This diff implements option A from the diagnosis. While a native recovery View popover is shown, Esc pressed in the popover's window or in the anchor's window closes the popover and is swallowed. Esc in any other window is still passed through. The earlier fix tried to give the popover window key focus and never worked; that code is deleted (`AgentRecoveryNativePopoverKeyWindow`, `AgentRecoveryNativePopoverKeyFocus`, the deferred `takeKey`, `returnKey`, `previousKeyWindow`), along with its four tests.

The design is sound and the deletion is clean:
- **Monitor lifetime is unchanged.** `installMonitors()` runs only after the `anchor.window` guard in `show` (`AgentRecoveryNativePopover.swift:249`). Every close path (`update`, `dismantleNSView`, `popoverDidClose`, resign-active, the monitor itself) goes through `close()`, which calls `removeMonitors()` first (`:272-273`). So Esc with no popover open is unaffected.
- **Mouse-downs are decided exactly as before** (`:29-34`), so P1–P4 and P7–P11 are untouched.
- **Esc only closes in two windows** (`:37`). A different key window (Cmd-`, an alert, an unrelated sheet) still gets its own Esc.
- **Sheet order is correct.** A local monitor runs before `sendEvent`/key-equivalent and responder-chain dispatch, so returning `nil` keeps the sheet's `cancelOperation` from seeing that press.
- **No stale references.** Nothing else used the deleted types, and the build and tests ran green.

I found no P0 or P1.

---

## P2

### ESC-1: Esc while the composer has IME marked text closes the popover instead of cancelling the composition

- **Failure scenario:**
  1. The user opens View. The popover never takes key, so typing still goes to the composer (live step 4 expects this).
  2. The user types with an input method that uses marked text, such as Vietnamese Telex, Japanese or Chinese. The underlined composition or a candidate window is shown.
  3. The user presses Esc to cancel the composition.
  4. The local monitor runs before the text view's `keyDown` → `NSTextInputContext.handleEvent`. It sees Esc in the anchor window, closes the popover and swallows the key.
- **Impact:** The composition stays and needs a second Esc. Nothing is lost, and the workaround is obvious. Still, the IME state is more recent than the popover, so this breaks the design's own rule that the most recently opened transient UI closes first. The mention and snippet palettes are an accepted trade-off; IME composition isn't covered by that argument.
- **Evidence:** `AgentRecoveryNativePopover.swift:37` and `:328-332` (`isInAnchorWindow` is the only gate). Monitor installation is at `:297-302`.
- **Smallest fix:** In `shouldConsume`, before deciding, pass Esc through when the key window's first responder is composing:
  ```swift
  let isComposing = (event.window?.firstResponder as? NSTextInputClient)?.hasMarkedText() ?? false
  // isEscapeKey: event.type == .keyDown && event.keyCode == 53 && !isComposing
  ```
  This is one line, and the next Esc then closes the popover. Optionally add a `decide` row for it, or just a comment.

---

## P3

### ESC-2: Holding Esc in the sheet can still dismiss the sheet through key repeat

- **Failure scenario:** View is open in the Needs Attention sheet and the user holds Esc past the repeat delay. The first key-down closes the popover and removes the monitor (`:338` → `close()` → `removeMonitors()`). The auto-repeat key-downs then reach the sheet, and SwiftUI's default Escape dismisses it. This is the R6 symptom again, though it now needs a deliberate hold.
- **Impact:** The sheet closes and has to be reopened. No data is lost (Continue drafts survive through step 2). The worker already lists this as inferred and minor.
- **Evidence:** `:272-273`, `:337-339`.
- **Smallest fix:** Defer it. If wanted later, the coordinator can keep a tiny key-down monitor alive until Esc's key-up arrives, swallowing Esc events where `isARepeat` is true. That isn't worth a review round now.

### ESC-3: The live steps don't check where key focus lands if the popover really did become key

- **Failure scenario:** The diagnosis never ran the click-inside probe. If dragging inside the selectable `Text` does make `_NSPopoverWindow` truly key (step 11), the deleted `returnKey` would have returned key to the parent on close. Now AppKit chooses, which is usually the parent but unverified.
- **A separate, pre-existing point:** if the popover is *not* key after the drag (as the diagnosis infers from the live step 9), Cmd-C in step 11 goes to the composer and copies its selection rather than the popover's. That is not caused by this diff, because `takeKey` never ran before. It shouldn't be counted as a regression of this step.
- **Evidence:** Removed code at old `:61-71` and `:317-320`; the worker's report, step 11.
- **Smallest fix:** Extend live step 11:
  1. After the Esc that closes the popover, type one letter. It should land in the composer (banner) or keep focus in the sheet.
  2. Record whether Cmd-C copied the popover text or the composer selection.
  3. If Cmd-C failed, file it as a separate pre-existing finding.

### ESC-4: Lint wasn't shown clean on the final tree for this step

- **Failure scenario:** The worker's last `make dev-lint` (`d5d38b60…`) exited 1 on the other worker's files, and SwiftLint `--strict` never ran after this step's final comment edits. The list worker's passing run (`fcb9cb97…`) may postdate those edits, but neither report establishes the order.
- **Impact:** Validation method only. The edits were comments only, so the risk is low.
- **Smallest fix:** Before committing, run `make dev-lint` once on the combined tree and cite the ticket in this step's status line.

---

## Recommendations

- **Commit after the lint rerun (ESC-4).** No P0 or P1 is open.
- **Fix ESC-1 now.** It is one line and in the policy's "fix if cheap" class, and it matters if you type through an IME. Add a one-line comment saying Esc goes to an active composition before the popover.
- **List ESC-2 as deferred.**
- **Fold ESC-3's checks into live step 11.** Keep the Cmd-C result separate from this step's pass/fail.
- **During the live re-check, prioritise:**
  - steps 1 and 2 (one Esc in the banner and in the sheet);
  - step 5 (running turn);
  - step 6 (mention list order);
  - step 12 (Esc in another window leaves the popover open).

  The unit tests only cover `decide`. The wiring in `shouldConsume` (`:328-332`), meaning which window is compared to which, is proven only by these live steps.
- **No changes needed for:** the outside-click path, the resign-active observer, or the comment rewrites. They match the new behaviour.