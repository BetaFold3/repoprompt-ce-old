# Step 8-popover review — OracleA (round 0)

Scope: read when the task touches the recovery banner View popover (Step 8-popover).
Authority: Reference
Last-verified: 2026-10-26
Covers: OracleA (preset 61D024A4-CCFB-4C9C-A614-CC65E0A1864C) fresh-chat review of the NSPopover change (popover-r0 diff) against review-policy.md.


The change replaces only the recovery row’s **View** popover with an AppKit-backed presenter, preserving the existing SwiftUI content and leaving continuation editing untouched. The event monitor correctly distinguishes delivery from consumption, and cleanup covers explicit dismissal, AppKit closure, deactivation, and dismantling. No P0/P1 findings identified from the supplied code. Build and test results are worker-reported; live event delivery remains unverified.

## P2 — Consider

### R1 — Outside-click activation is handled only for the originating window

**File:** `Sources/RepoPrompt/Features/AgentMode/Views/Components/AgentRecoveryNativePopover.swift:190–198`

**Failure scenario:** Open the recovery popover, then click a control in another RepoPrompt window that does not accept first-mouse events. The monitor closes the popover and returns the event, but its `makeKey()` safeguard explicitly excludes that window. AppKit can therefore spend the click activating the destination window without triggering the control.

**Impact:** The single-click behavior is not guaranteed across app windows; that interaction can still require a second click. Returning the original event ensures dispatch, not necessarily control activation.

**Smallest fix:** Extend the activation safeguard to eligible destination app windows rather than requiring `window === anchor?.window`. Verify ordinary windows and sheets before broadening it, so dismissal does not incorrectly change focus.

## Recommendations

- Run the planned live verification, including clicks into **another app window**, not just the banner’s window.
- Verify Escape immediately after opening, repeated inspection-task execution/cancellation, and row removal while the popover is open.
- Keep the pure decision tests, but treat them as branch-logic coverage—not evidence that AppKit delivers the click or that hosting-controller lifecycle behavior is correct.
- No unrelated refactoring is warranted.