# Step 8-popover review — OracleB (round 0)

Scope: read when the task touches the recovery banner View popover (Step 8-popover).
Authority: Reference
Last-verified: 2026-10-26
Covers: OracleB (preset 7CDD523E-1D7C-47EA-98FE-D5FEA24D2D8C) fresh-chat review of the NSPopover change (popover-r0 diff) against review-policy.md.




# Review: native NSPopover for the recovery banner's View button (`popover-r0.diff`)

## Summary

The change swaps the SwiftUI `.popover` on the recovery row's **View** button for `.agentRecoveryNativePopover`. That new modifier shows the existing `viewer` in an `NSPopover` with `.applicationDefined` behaviour, inside a fresh `NSHostingController` for each open. A local event monitor decides how to handle each event:

- **Outside click:** closes the popover and lets the click through.
- **Click on the View button:** closes it and drops the click.
- **Escape inside the popover:** closes it and drops the key press.

It also closes when the app is deactivated, when the binding goes false, or when the view is dismantled. A pure decision enum is unit-tested. The event-monitor code itself looks right:

- Returning `nil` drops an event; returning it lets it through.
- The monitor is removed inside its own handler, which is safe.
- The local monitor and the `.main`-queue observer both run on the main thread, so `MainActor.assumeIsolated` is sound.
- `delegate = nil` before `close()` stops our own closes from looping back.
- Weak captures and the weak delegate mean there's no retain cycle.

The main risk is how state flows into the hosted view (F1). The rest is minor.

## Findings

### P1

**F1 — The inspection result may never appear (stuck on "Comparing with the current file…")**
- **Evidence:** `AgentRecoveryNativePopover.swift:101-103` (rootView is only refreshed from `updateNSView`), and `AgentRecoveryListBanner.swift`, where `viewer`'s `.task` writes the row's `@State inspection`.
- **Mechanism:** `viewer` is now built by calling `content()` inside `updateNSView`, not as part of SwiftUI's own popover content. The `Text(inspection…)` value is fixed into the `NSHostingController`'s `rootView` at that moment. The hosted view has its own SwiftUI graph and doesn't track the row's `@State`.
  - When `.task` sets `inspection = (rowID, text)`, the row's `body` probably won't re-run, because the body never reads `inspection`; it only appears inside the escaping closure. SwiftUI only re-runs a body for state the body actually read.
  - If the body doesn't re-run, `updateNSView` isn't called and `host.rootView` is never refreshed.
- **Failure scenario:** On an edit-proposal row (`inspectsOnView`), click View. The popover keeps saying "Comparing with the current file…" until something unrelated re-renders the row.
  - A second open would instead keep showing the previous comparison. `inspection = nil` at the start of `.task` doesn't reach the screen either, which defeats the "never show an earlier View's comparison" guarantee.
- **Impact:** Edit-proposal rows show no or stale inspection text. The worker's report says these updates "flow through", but that's a design claim; it hasn't been checked live.
- **Smallest fix:** Move the viewer into its own `View` struct (e.g. `AgentRecoveryRowViewer(row:, inspect:)`) that owns `@State private var inspection` and runs the `.task`. The state is already described as "transient; recomputed on each View", and the per-open hosting controller now gives fresh state on every open, so this matches the intent and removes the dependence on the outer graph. Row-prop changes still flow through `updateNSView`. If you don't fix it first, at least make live-verifier step 1 a hard gate on an edit-proposal row, checking both the first and second open.

### P2

**F2 — If the button is dismantled while open, the binding is left `true`, and View can then appear dead**
- **Evidence:** `:69-72` (`close(reportingClosed: false)`), `:113` (`guard anchor.window != nil else { return }`).
- **Scenario:** The View button's `if` branch is removed while the popover is open (`row.text` turns nil and attachments are empty) but the row's `@State` survives. `isViewing` stays `true`.
  - If the branch comes back, it auto-reopens, or, if `updateNSView` runs before the NSView is in a window, `show` returns silently.
  - Clicking View then sets `true → true`, which isn't a change, so nothing happens until the row is recreated.
- **Fix:** In `dismantleNSView`, close without writing synchronously, then reset the binding after the update finishes: `DispatchQueue.main.async { isPresented.wrappedValue = false }`. Use the same async write in `popoverDidClose` (`:145-148`). AppKit can close the popover while SwiftUI is removing views, so the write there can currently land during a view update (acceptance criterion 6).

**F3 — Escape only works once the popover window is key; nobody has checked that it is key on open**
- **Evidence:** `:28` (`isEscapeKey, isInPopoverWindow`), `:181-182`.
- **Scenario:** If `NSPopover.show` with `.applicationDefined` doesn't make the popover key, then pressing Escape straight after opening, without clicking inside first, goes to the composer window and is ignored. The popover stays open (acceptance criterion 3). Verifier step 6 clicks inside before pressing Escape, so it won't catch this.
- **Fix:** Add a verifier step: open, then press Escape at once. If it fails, make the popover window key after `show`, which also matches the `makeKey` comment at `:193`. Don't widen Escape handling to the anchor window, because the composer may use Escape itself.

**F4 — The hosted content loses inherited SwiftUI environment**
- **Evidence:** `:116`. The worker already noted this.
- **Detail:** The appearance follows the window. App-level environment injected higher up (custom fonts or theme keys, if any) won't reach `viewer`. There's probably no visible change for this text-only view.
- **Fix:** Check visually during live verification. Only if something differs, pass the relevant environment values in explicitly.

### P3

- **F5 — No safety net in `deinit`** (`:84-91`). Cleanup of the monitor and observer depends entirely on `dismantleNSView` running. SwiftUI reliably calls it, so this is acceptable. An `isolated deinit` or a `removeMonitors` call there would make the leak guarantee (acceptance criterion 5) unconditional.
- **F6 — Tests fit the stakes.** The pure decision table is the right thing to unit-test. The risky parts (monitor lifetime, binding writes, makeKey, popover placement) can't be unit-tested well and are rightly left to the live verifier. No extra tests are needed.
- **F7 — The worker report states unverified claims as facts.** "Content updates while open … flow through" and "same position" are written as design facts. Mark them unverified until the live run, in line with the policy's "say how each result was obtained".
- **F8 — The Edit/Continue popover still uses SwiftUI `.popover`** and probably has the same double-click problem. That's out of scope as the owner requested, and the worker correctly left it as a follow-up.

I found nothing at P0. These are fine as written:

- Multiple rows each have their own monitor, and the first outside click closes any open popover before another can open.
- Clicks in a different window of the app are delivered without `makeKey`, which is normal macOS first-click behaviour, not a regression.
- Clicking the View button drops the mouse-down, and the mouse-up that follows doesn't fire the button.

## Recommendations

1. **Fix F1 before live verification.** Extract the viewer into its own view that owns `inspection` and the `.task`. It's small, keeps the content identical, and removes the likeliest live failure.
2. **Apply the F2 fix:** make the binding writes from `dismantleNSView` and `popoverDidClose` async.
3. **Extend the live-verifier checklist:**
   - Step 1 on an edit-proposal row: confirm the inspection result appears, then reopen and confirm the result is recomputed and not stale.
   - Escape straight after opening, without clicking inside (F3).
   - The same flow from the Needs Attention sheet: a different anchor window, so the `makeKey` path runs against the sheet.
4. Treat F4, F5 and F7 as cheap tidy-ups or deferred items. Don't run another review round just for them.
5. After the fixes, rerun `make dev-build`, `dev-lint`, `guardrails` and both test filters. Under the policy, a re-review is only needed if F1 or F2 changes the reviewed behaviour, and F1 does.