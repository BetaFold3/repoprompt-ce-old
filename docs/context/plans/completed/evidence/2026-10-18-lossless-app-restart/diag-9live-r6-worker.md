# 9-live diagnosis: R6 (P5 Esc still fails)
Scope: read when the task touches Escape or keyboard focus of the recovery View popover (verifier check P5).
Authority: Reference
Last-verified: 2026-10-28
Covers: diagnosis only, no code changes

This diagnoses why the P5 fix in commit `c3996ab5` failed the 9-live check (R6 in [verifier-9live-results.md](verifier-9live-results.md)). The fix and its reviews are in [fix-p5-esc-worker.md](fix-p5-esc-worker.md) and the `fix-p5-esc-review-oracle{a,b}-r0.md` files. No source, test or ledger file was changed, and nothing is staged or committed.

Line numbers refer to `HEAD` (`74edea8b`). `git merge-base --is-ancestor c3996ab5 74edea8b` succeeds, and `AgentRecoveryNativePopover.swift` is unchanged between them, so the verified build contains the fix exactly as reviewed.

## Evidence labels

- **Verified (code):** read in this repository.
- **Verified (probe):** observed in a standalone `swiftc` scratch program in `/tmp/p5probe` that uses the same AppKit classes. It is not the RepoPrompt app. Events in the probe were synthetic (`NSApp.postEvent`), not System Events key codes.
- **Inferred:** AppKit knowledge or reasoning that no probe or code reading checked directly.

## Probe programs run (all terminated)

| Binary | Runs (arguments) | What it did |
|---|---|---|
| `/tmp/p5probe/probe` | `app` (twice), `transient`, `semi`, `app mkof`, `app fr` | `NSWindow` with an `NSTextField` as first responder. An `NSPopover` with `NSHostingController(Text(...).textSelection(.enabled))` shown relative to a subview. One main-queue turn later, `makeKey()` on `popover.contentViewController?.view.window`; `mkof` adds `makeKeyAndOrderFront`, `fr` adds `makeFirstResponder(contentView)` and another `makeKey`. A key-down monitor logs `event.window`, then a posted Esc. |
| `/tmp/p5probe/probe2` | `field`, `sheet`, `sheet consume`, `consume` | A SwiftUI root in an `NSHostingView`, optionally a SwiftUI `.sheet`, and an `.applicationDefined` popover anchored in the main window or the sheet. `field` uses an `NSTextField` as popover content. `consume` installs a local monitor that closes the popover and returns `nil` for Esc in the anchor's window. |

- Each run quit itself (`NSApp.terminate`, under a 15 s self-exit and a 20 s `timeout`).
- A later command (a rebuilt `probe2` with a synthetic click inside the popover) was rejected before it ran. It never executed.
- At the owner's request, no GUI process was launched after that. `pgrep -fl /tmp/p5probe/` found no running probe processes.
- The RepoPrompt app was not launched, stopped or signalled.

## Q1: why the popover window does not become key

### Root cause (verified in the probe; inferred to apply to the app)

Two independent facts, either of which defeats the fix:

1. **`_NSPopoverWindow.isKeyWindow` copies its parent's key state.**
   - In every probe run (`.applicationDefined`, `.transient`, `.semitransient`; SwiftUI or `NSTextField` content), the popover window reported `isKeyWindow == true` right after `show` and one turn later.
   - At the same time, `NSApp.keyWindow` was the parent `NSWindow` (`NSApp.keyWindow === popoverWindow` was `false`).
   - `firstResponder` on the popover window also returned the parent's field editor until something was explicitly made first responder.
   - `AgentRecoveryNativePopoverKeyFocus.takeKey` (`AgentRecoveryNativePopover.swift:53-56`) starts with `guard … !popoverWindow.isKeyWindow …`. That guard is therefore always false, and `makeKey()` is **never called** in the app. Verified (probe for `isKeyWindow`; code for the guard).
2. **Even an unconditional `makeKey()` does not move key to the popover window.**
   - In the probe, `makeKey()`, `makeKeyAndOrderFront(nil)`, and `makeFirstResponder(contentView)` followed by `makeKey()` all left `NSApp.keyWindow` as the parent.
   - This held for all three behaviors, and with an `NSTextField` as content.
   - `canBecomeKey` returned `true` throughout, but key did not move. Verified (probe).

So the posted Esc arrived with `event.window` set to the parent window (logged by the monitor in the probe). `decide` (`:28`) only closes when `isInPopoverWindow`, so it returned `.ignore` and the Esc went on to the parent's first responder. Verified (probe for `event.window`; code for `decide` and `:374-375`).

This matches the live observations:
- step 4: "the letter goes into the composer; the popover does not take key; no beep";
- step 1: Esc leaves the popover open;
- step 11: Esc right after reopening fails.

### The sub-questions

- **Is `contentViewController?.view.window` nil or the wrong window one turn after `show`?**
  - No. It was a non-nil `_NSPopoverWindow` whose `parent` is the anchor's window, both synchronously after `show` and one turn later. Verified (probe).
- **Does `canBecomeKey` return false for `.applicationDefined`?**
  - No, it returned `true`. Verified (probe).
  - The blockers are the `isKeyWindow` copy (guard) and `makeKey` not taking effect. The private reason for the second is unknown; a likely explanation is that a popover window only becomes the real key window through its own mouse-down/first-responder path. Inferred.
- **Does something make the main window key again afterwards (the SwiftUI click on View, button focus, the event monitor)?**
  - Not needed to explain the failure. The probe reproduces it with no click at all.
  - Nothing in this file calls `makeKey` on the anchor window between `show` and the Esc. The `.closeAndDeliver` path's `makeKey` only runs on a mouse-down.
  - Verified (code, and the probe without clicks). Whether SwiftUI also re-asserts key in the app was not checked and is moot.

### Side observations

- **Step 9 (Esc after selecting text inside the popover fails).**
  - This suggests that even clicking inside a SwiftUI `Text` with `.textSelection` does not make the popover the key window. The old comment "the popover window was key" after a click inside was never true for this content. Inferred from the live result; the click probe did not run.
  - With an editable `NSTextField`, a click inside probably does take key. Inferred from general AppKit experience.
- **`returnKey` (`:61-71`) also reads the copied `isKeyWindow`.**
  - It calls `previousKeyWindow.makeKey()` on a window that is already key, so it is a harmless no-op on the observed paths.
  - It never restores anything meaningful, because key never left. Inferred from the probe facts plus code.

## Q2: why one Esc closes the sheet too

- The sheet is a SwiftUI `.sheet` (`AgentRecoveryNeedsAttentionSheet.swift:298-301`).
  - It has no `.keyboardShortcut(.cancelAction)`, no `onExitCommand` and no `interactiveDismissDisabled`.
  - Its "Done" button calls `dismiss()` but has no cancel shortcut.
  - SwiftUI sheets on macOS dismiss on Escape by default. Verified (code); default dismissal verified in the probe.
- Order of events (the popover is anchored in the sheet window and that window stays key; Q1):
  1. Esc arrives with `event.window` = the sheet window (`SheetPresentationWindow` in the probe).
  2. Our local monitor runs first. Local monitors run before the event is dispatched to the window. Inferred from AppKit's documented monitor contract, and consistent with the probe log order.
  3. The monitor sees `isInPopoverWindow == false` and returns `.ignore`. It does **not** consume the event (it returns the event).
  4. The event is dispatched to the sheet window, and SwiftUI's default sheet Escape dismisses the sheet (probe `sheet`: `sheetFlag` became `false`).
  5. The sheet's content, including the View row, is torn down. `dismantleNSView` → `close(reportingClosed: .deferred)` (`:220-224`, call at `:223`) closes the popover. In the probe, which has no dismantle wiring, the popover stayed shown.
- So the popover does not close *in addition to* the sheet because of Escape. It closes *because* the sheet went away.
- The Esc reaches the sheet's default cancel/dismiss handling after our monitor has passed it through. It does not reach it before the monitor.
- **Probe `sheet consume`:** a monitor that closes the popover and returns `nil` for Esc in the anchor's (sheet's) window left the sheet open (`sheetFlag == true`, `attachedSheet != nil`) and the popover closed. Verified (probe, synthetic event).

## Q3: smallest reliable design

### Options evaluated

| Option | Verdict |
|---|---|
| **A. Consume Esc in the anchor window's local monitor while our popover is shown** | **Recommended.** It works whether or not the popover is key. The only extra routing is for Esc in the anchor window, and only while the monitor is installed (`installMonitors` runs only in `show`; `removeMonitors` runs in `close`). Verified (code for the monitor lifetime; probe `sheet consume` and `consume` for the closing behavior). |
| B. `.transient` / `.semitransient` | Rejected. Neither makes the popover key on `show` or after `makeKey` (verified, probe), so Esc still goes to the parent window. Both also bring back AppKit's transient outside-click handling, which `fix-popover-worker.md` replaced so outside clicks reach their targets. Whether a transient popover closes on Esc while not key was not checked; inferred no, since its window doesn't receive the key event. |
| C. Make the popover window key some other way | Rejected. `makeKey`, `makeKeyAndOrderFront` and `makeFirstResponder` all failed in the probe (verified). The remaining routes are private API or replacing `NSPopover` with a custom `NSPanel`. Both are larger, and taking key would also steal typing from the composer while the popover is open (review P5-R3). |
| D. A `cancelOperation:` responder | Rejected. In the banner, the first responder is the composer `NSTextView`. Its delegates already turn `cancelOperation` into mention/snippet-palette dismissals (`TextFieldMentionHelpers.swift:135,495`, `SnippetPaletteHelper.swift:115`), and a new responder can't get ahead of it without changing the composer. In the sheet, SwiftUI's own sheet dismissal handles Esc. A responder would need to be inserted per window and ordered before SwiftUI's handling, which is fragile. Inferred. |

### Recommended change (A), for the implementing worker

1. **Decision table (`:16-31`).** Close and consume Escape when the popover is shown and the key-down is in the popover's window **or the anchor's window**:
   - `if isEscapeKey, isInPopoverWindow || isInAnchorWindow { return .closeAndConsume }`;
   - `isInAnchorWindow` is `event.window != nil && event.window === anchor?.window`, computed in `shouldConsume` (`:368-378`).
   - Do not make it any-window. Esc in some other window (Cmd-`, review P5-R7, or a dialog that is key above the sheet) should still go to that window.
2. **Remove `AgentRecoveryNativePopoverKeyFocus`** (`:33-74`), the deferred `takeKey` (`:303-309`), `returnKey` in `close` (`:317-320`), and `previousKeyWindow`.
   - `takeKey` never runs.
   - `returnKey` is a no-op on the observed paths.
   - Keeping them preserves a false comment ("so Escape … works without clicking inside first"), and reads `isKeyWindow`, which is not reliable for popover windows.
   - The `willResignActive` observer can stay. It still closes on app switch, and it doesn't depend on key.
3. **Tests (deliberate contract change; the ledger is not touched).**
   - Update the decision-table tests: Esc in the anchor window becomes `.closeAndConsume`. Esc in an unrelated window, and any key-down that isn't Esc, stays `.ignore`.
   - Drop the four `KeyFocus` tests together with the seam they test. Their premise is now known to be false.
4. **Comments.**
   - Fix the type doc and the `.closeAndConsume` doc ("Escape").
   - Fix the outside-click comment at `:386-389`, which refers to `close` having given key back.

### What this meets

- **One Esc closes only the popover, in the banner:** the Esc arrives in the main (anchor) window, the monitor consumes it, and the composer never sees it. Inferred for the app; verified for the posted-event probe `consume`. That run's app was not active, so the evidence is weaker than the sheet run.
- **One Esc closes only the popover, in the sheet:** the Esc arrives in the sheet (anchor) window, is consumed, and the sheet stays open. Verified (probe `sheet consume`); inferred for the app.
- **The composer keeps working:** key never leaves the composer's window, so typing while the popover is open goes to the composer, as observed live in step 4. The next keystroke after Esc goes to the composer at the caret. Inferred, but nothing changes focus in this design.
- **No Escape widening when no popover is open:** the monitor exists only between `show` and `close`. Verified (code: `installMonitors()` called at `:283` in `show`, `removeMonitors()` at `:313` in `close`).

### Risks

- **The composer's own Escape is lost while the popover is open.**
  - If the composer has a mention or snippet palette open, or IME marked text, Esc closes the popover instead, and a second Esc reaches the composer.
  - This is the intended priority (the most recently opened transient UI closes first), but it is a change. Inferred; check live.
- **Esc while a turn is running:** live, Esc with the popover open did not interrupt the turn. With A it still won't on that press, because the event is consumed. Inferred.
- **Monitor order:** other local key-down monitors run in an undocumented order.
  - The only other one in `Sources` that sees key-downs, `TooltipBubble.swift:210`, returns the event and only hides a tooltip asynchronously.
  - The Changes panel's Esc check (`AgentChangesPresentation.swift:448`) is not in this flow.
  - Verified (code grep).
- **Esc key-repeat and key-up:** only the first key-down is consumed. Later repeats and the key-up reach the composer after the monitor is removed. A text view ignores key-up, and a held Esc then acts as a normal Esc in the composer. Inferred, minor.
- **Synthetic versus real events:** the probes used `NSApp.postEvent`, and System Events key code 53 in the live check is a real HID-path event. Both go through the local-monitor stage. Inferred.
- **Live re-check needed:** P5 steps 1, 2, 3, 4, 9 and 11, plus "Esc during a running turn" and a mention-palette-open case. Steps 5–8, 10, 12 and 13 should be unaffected, because mouse handling is unchanged.

## Not done

- No source, test, ledger or guardrails change. This report is not yet in the `Scripts/source_layout_guardrails.sh` evidence allowlist, and no routed doc links to it. The main agent should add both before `make guardrails`.
- No click-inside probe ran (rejected, then GUI probes were stopped), so the step-9 explanation stays inferred.
- No validation commands were run; this is a read-only diagnosis.
