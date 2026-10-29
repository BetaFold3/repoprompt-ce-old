# Step 8-popover re-review — OracleB (round 1)

Scope: read when the task touches the recovery banner View popover (Step 8-popover).
Authority: Reference
Last-verified: 2026-10-26
Covers: OracleB (preset 7CDD523E-1D7C-47EA-98FE-D5FEA24D2D8C) fresh-chat re-review of the round-1 fixes (popover-delta and popover-r1 diffs).

# Round 1 re-review: native NSPopover for the recovery banner's View button

## Summary

This delta fixes the three round-0 findings:

- **B F1 (stale or missing comparison text):** the popover content moves into `AgentRecoveryRowViewer`, which owns the `inspection` state and the comparison `.task`.
- **B F2 (binding left `true` after dismantle):** `close` now takes a `BindingReport`. Closes started by a SwiftUI dismantle or by AppKit write `false` to the binding one main-queue turn later.
- **A R1 (makeKey only for the anchor's window):** the outside-click `makeKey()` now applies to any app window that can become key, not just the anchor's.

I reviewed this by reading the code only. I didn't build it, run tests or try it live; the validation results are the worker's.

- **B F1 is fixed correctly and completely.** The viewer is now the hosting controller's root view, so the comparison text re-renders inside the popover's own SwiftUI graph. Assigning `host.rootView` again with the same type keeps that state, and a fresh controller per open gives a fresh task each time.
- **B F2 is fixed correctly.** I couldn't find a realistic way for the deferred write to close a popover the user had just reopened.
- **A R1's fix works for the case it targets, but it is broader than it needs to be.** It now calls `makeKey` on windows that the old anchor-only check left alone. That carries a small, unverified focus risk (P2 below).

**I found no P0 or P1.**

## P2 — Consider

### N1 — The wider `makeKey` reaches sheet parents and passive panels, and may leave a covered window behind others
- **Evidence:** `AgentRecoveryNativePopover.swift:211-213`. The check is `window !== popoverWindow, window.canBecomeKey, !window.isKeyWindow`, then `window.makeKey()`.
- **Failure scenarios:** these are possible but unverified. Each needs a live check.
  1. **Sheet parent.** The popover is anchored inside the Needs Attention sheet, and the user clicks the parent window behind the sheet. The old code skipped this, because the parent is not `anchor.window`. Now the parent passes `canBecomeKey` and gets `makeKey()` while a document-modal sheet is still attached. Keyboard focus could end up in the composer behind a modal sheet. This flow is realistic, since the banner is shown in that sheet.
  2. **Passive panels.** An `NSPanel` with `becomesKeyOnlyIfNeeded`, or another utility panel, would be forced key. That takes focus from the main window, which the panel was designed not to do.
  3. **Covered window.** A second app window partly hidden behind another gets `makeKey()` (which doesn't bring it to the front) before AppKit handles the click. AppKit's usual "make key and bring to front" step for a background-window click may then be skipped, so the clicked window could stay behind.
- **Impact:** focus or window order is wrong in uncommon cases. It is easy to recover from, but it is a regression compared with round 0 for windows other than the anchor's.
- **Why it matters:** in round 0, OracleB judged that a first click into another window being spent on activation is normal macOS behaviour. So the extra reach brings risk for little gain.
- **Smallest fix (pick one):**
  - **(a)** Go back to the anchor window, plus the anchor window's sheet parent if needed: `window === anchor?.window`. Then record A R1 as downgraded, with OracleB's reasoning.
  - **(b)** Keep the broad rule but add guards: `window.attachedSheet == nil`, and skip any `NSPanel` whose `becomesKeyOnlyIfNeeded` is set. Add a live-verifier step that clicks a covered second window and checks that it comes to the front.

## P3 — Improvements

- **N2 — A dismantle and re-mount in the same update makes the popover flash open, then close.**
  - **Evidence:** `:72` and `:152-155`. The old coordinator's deferred block only checks "still `true`", so it can't tell its own presentation from a new anchor's.
  - **When it happens:** only if the anchor is torn down and rebuilt in a single update while the row's `@State` survives. I don't see that happening in the row's current layout.
  - **Result:** closed popover and binding `false`, which matches "closes on dismantle". One click reopens it.
  - **The AppKit-close path (`:162`) can't race the user:** reopening would need a click in the same main-queue turn.
  - **Suggestion:** accept as-is and note it.
- **N3 — `show` can still fail silently.**
  - **Evidence:** `:122`, `guard anchor.window != nil else { return }`.
  - **Effect:** if this ever fires with `isPresented == true`, the binding stays `true` and the View button looks dead.
  - **Today:** this is only reachable during a re-mount, and N2's deferred reset covers it.
  - **Optional hardening:** have that guard also schedule the deferred `false` reset.
- **N4 — One of the task's guards can never fail.**
  - **Evidence:** `AgentRecoveryListBanner.swift:297`. `rowID == row.id` compares against the same captured `row` the task started with, so it is always true.
  - **What actually protects the result:** `.task(id: row.id)` cancellation, `Task.isCancelled`, and the display-time check `inspection?.rowID == row.id` (`:271`).
  - **Suggestion:** drop that half of the guard, or leave it; it is harmless.
- **N5 — Evidence-file formatting.**
  - Both new evidence files lack a trailing newline.
  - `fix-popover-review-oracleb.md` has extra blank lines and a second H1 after its header block.
  - Cosmetic only, and no review is needed for docs edits.

## Things I checked and found fine

- **Stale `actions` in the viewer's closure:** not a problem.
  - `content()` is called again on every `updateNSView` (`:112`), so `host.rootView` always gets the current `row` and `actions.inspect` (`AgentRecoveryListBanner.swift:123`).
  - A task already running keeps the `inspect` it started with. That's fine for a one-shot call, and its result is dropped once the popover closes, because the task is cancelled.
- **Binding writes during a SwiftUI update:**
  - `.now` is only used from the event monitor, the deactivation observer, and `update`. In `update` the binding is already `false`, so nothing is written.
  - The dismantle and `popoverDidClose` paths are now deferred.
  - Acceptance criterion 6 holds.
- **No loop from our own closes:** `delegate = nil` comes before `close()` (`:146-147`), so they can't trigger `popoverDidClose`. Calling `close()` again on an already-closed popover is harmless.
- **Resizing when the comparison arrives:** `sizingOptions = [.preferredContentSize]` (`:126`) means the popover resizes when the comparison text comes in.

## Recommendations

1. **Settle N1 before the live run.** I'd pick option (a): limit `makeKey` to the anchor's window and downgrade A R1 in writing. If you keep the broad rule, add the `attachedSheet` and passive-panel guards.
2. **Extend the live-verifier checklist:**
   - On an edit-proposal row: open, check that the comparison text appears, close, reopen, and check that it is recomputed and not stale (B F1).
   - Remove the row, or clear its text, while the popover is open; let it come back; check that View opens with one click (B F2).
   - With the popover open in the Needs Attention sheet, click the sheet's parent window and check where keyboard focus ends up (N1).
   - Click a covered second app window and check that it comes to the front and the click lands (N1).
   - Press Escape straight after opening, without clicking inside first (the deferred round-0 B F3).
3. **Fix scope:** treat N2–N5 as deferred or cheap tidy-ups, and don't run another round for them. If N1 is changed, it's a small behaviour change to code that has already been reviewed. Rerun `make dev-build`, `dev-lint`, and the two test filters, and send both reviewers a regression-only delta check.
4. **Record what's still unverified:** until the live run happens, mark B F1 and B F2 as resolved by design but not yet verified live.