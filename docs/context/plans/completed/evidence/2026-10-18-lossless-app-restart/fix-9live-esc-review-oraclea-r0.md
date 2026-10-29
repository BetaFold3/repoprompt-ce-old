# 9-live fix 1 (Esc): OracleA round-0 review

Scope: read when the task touches Escape or keyboard focus of the recovery View popover (verifier check P5).
Authority: Reference
Last-verified: 2026-10-28
Covers: the OracleA review of the Esc diff, copied from its export


Reviewed **only `prompt-exports/9fix-esc.diff`**. The change handles Escape in either the popover’s window or its anchor window, consumes that event, and removes the ineffective key-window hand-off. Mouse-event decisions remain unchanged. This matches Step 1’s intended design.

**No actionable findings in the supplied diff.**

- **Multiple windows:** Window-identity checks exclude unrelated windows and dialogs. Escape there remains deliverable normally (`AgentRecoveryNativePopover.swift:325–330`).
- **Sheet dismissal:** The matching Escape closes the popover and returns `nil` from the local monitor, preventing subsequent sheet handling of that event (`:297–302`, `:337–339`). The supplied probe supports this; actual app routing remains unverified.
- **Monitor lifetime:** Closing removes both monitors before closing the popover. Dismantling and AppKit-driven closure also use this cleanup path, preserving Escape behavior when no popover is open (`:188–192`, `:272–293`, `:314–319`).
- **Composer, mention palette, and IME:** No replacement focus manipulation is introduced. While View is open, the first Escape intentionally takes priority over composer cancellation—including dismissing a mention palette or cancelling IME composition. Subsequent Escape events reach the composer after monitor removal.
- **Deleted code:** Removing the fake-window tests is justified because their abstraction failed to represent the observed AppKit behavior. No remaining reference to the removed focus machinery appears in the supplied scope.

## Recommendations

Approve the code change, but keep live acceptance pending. Run the documented banner/sheet Escape checks, including selectable-text interaction, mention palette **and active IME composition**, unrelated-window Escape, app switching, and outside-click regressions. The reported unit tests establish the decision table—not actual AppKit routing or focus restoration.