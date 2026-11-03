# Step 8-popover worker report

Scope: read when the task touches the recovery banner View popover (Step 8-popover).
Authority: Reference
Last-verified: 2026-10-26
Covers: worker session 6B0F267F-ABCA-4E24-BAFB-E4323A162A43 final report (AppKit NSPopover with outside-click pass-through).

The View popover in the recovery banner is now a native AppKit `NSPopover`. It builds, lint, guardrails and the new unit tests pass, but nobody has checked the real click behavior yet. That needs your live verifier.

**Files changed**
- `Sources/RepoPrompt/Features/AgentMode/Views/Components/AgentRecoveryNativePopover.swift` (new): adds a `.agentRecoveryNativePopover(isPresented:arrowEdge:content:)` modifier that shows the existing SwiftUI content in an `NSPopover` via an `NSHostingController`. It also holds a small pure function that decides what to do with each click or key press. There was no existing NSPopover or popover helper in `RepoPromptUI` or `Infrastructure/UI`. The layout doc says to prefer the narrowest owner, so it sits in the AgentMode components folder.
- `Sources/RepoPrompt/Features/AgentMode/Views/Components/AgentRecoveryListBanner.swift`: one line in the View button changes from `.popover(isPresented: $isViewing, arrowEdge: .top) { viewer }` to the new modifier. Everything else is untouched, including the Edit/Continue popover.
- `Tests/RepoPromptTests/AgentMode/Recovery/AgentRecoveryNativePopoverEventDecisionTests.swift` (new): 5 tests of the decision function. The frozen ledger was not touched.

**How the outside click gets through**
- **AppKit doesn't close it.** The popover uses `.applicationDefined`, so AppKit's own close-on-outside-click handling is off and can't eat the click.
- **A local event monitor closes it instead.** While the popover is open, the monitor watches left, right and other mouse-downs, plus key presses:
  - **Click inside the popover:** nothing happens and it stays open.
  - **Click outside it:** the monitor closes the popover, sets `isViewing = false`, and hands the click back unchanged so AppKit delivers it to whatever is under the pointer. This is what fixes the double click.
  - **Click on the View button itself:** it closes and the click is dropped. Otherwise the button would immediately reopen it; this keeps the old toggle behavior.
  - **Escape while the popover has focus:** it closes and the key press is dropped.
- **The click lands as a real click.** The popover's window may have keyboard focus. When the click is on the banner's own window, the monitor makes that window active *before* AppKit handles the click. That way the click isn't spent just activating the window.
- **It also closes** when the app goes to the background, when SwiftUI sets `isViewing = false`, or when the row disappears (without writing the binding in the middle of a view update). If AppKit closes it on its own, the binding is set back to false.
- **Same content, size and position.** Each opening gets a fresh hosting controller, so the viewer's `.task` (the compare-with-current-file inspection) runs on every open and is cancelled on close, as before. It sizes to the content's preferred size, so the existing `.frame(width: 360)` and `maxHeight: 240` still decide the size. It's anchored to the View button's bounds with `.top` → `.maxY`, so it still opens above the button. Content updates while open, such as the inspection text arriving, flow through.

**Validation**
- `make dev-build`: passed, with no warnings from the changed files.
- `make dev-lint`: passed (0 files need formatting; swiftlint strict clean).
- `make guardrails`: passed. Its one warning is the existing AGENTS.md route-count warning, which this change didn't cause.
- `make dev-test FILTER=AgentRecoveryNativePopoverEventDecisionTests`: 5 tests, 0 failures.
- `make dev-test FILTER=AgentRecoveryListHeaderTextTests` (existing banner tests): 6 tests, 0 failures.

**Not verified**
- The live click behavior, including whether making the window active first is actually needed and works.
- That `.maxY` puts the popover in the same spot SwiftUI's `arrowEdge: .top` did.
- That the hosted content looks the same now that it no longer inherits SwiftUI environment values like `controlSize` and `disabled`. The viewer has no controls, so I expect no visible change.
- The Edit/Continue popover in the same row still uses SwiftUI `.popover` and probably has the same double-click problem. I left it alone because the task named only View.

**Instructions for the live verifier** (needs a session with a recovery row that has a View button, i.e. held input or a draft with text or attachments):
1. Click **View**. The popover opens above the button, showing the title, detail, text (selectable and scrollable) and attachments. On an edit-proposal row the "Comparing with the current file…" line should switch to the result.
2. With it open, click the row's **Edit** or **Remove** button (or **Restore** / **Discard…**) once. Expected: the popover closes **and** that button acts on the same click (Edit fills the composer, Remove removes the row, Discard… shows its confirmation dialog).
3. Open it again and click once in the composer text field. Expected: it closes and the field gets focus right away; typing works without a second click.
4. Open it again and click once on a session in the sidebar or a toolbar button. Expected: it closes and that item activates on that single click.
5. Open it again and click **View** again. Expected: it closes and stays closed. A third click reopens it.
6. Open it, click inside its text and select some. Expected: it stays open and the text is selectable. Press Escape: it closes.
7. Open it and switch to another app with Cmd-Tab. Expected: it closes. Back in the app, one click on View reopens it, and the inspection text runs again.

Nothing is committed or staged, and the spec and evidence files are unchanged. The other modified files in `git status` were already there before this task.

## Round 1 (review fixes)

All three fixes are in. Build, lint and both test suites pass. `make guardrails` fails, but only on your in-progress evidence docs; the source checks pass. Live click behavior is still unverified.

**Files changed this round**
- `Sources/RepoPrompt/Features/AgentMode/Views/Components/AgentRecoveryListBanner.swift`: the viewer is now its own view, `AgentRecoveryRowViewer`, which owns the comparison state. The row's unused `inspection` state and its `viewer` property are removed.
- `Sources/RepoPrompt/Features/AgentMode/Views/Components/AgentRecoveryNativePopover.swift`: the binding reset is delayed by one main-queue turn on dismantle and when AppKit closes the popover. Making the clicked window active before the click is delivered now covers any of the app's windows.
- The test file is unchanged.

**How each fix was done**
1. **Stale or missing comparison (F1):** `AgentRecoveryRowViewer` takes `row` and `inspect: (_ rowID: String) async -> String?` (passed `actions.inspect`). It owns `@State private var inspection` and runs the same `.task(id: row.id)`: set it to nil, compare, check for cancellation and a matching row id, then store the result.
   - When the result arrives, the popover's own SwiftUI tree re-renders. It no longer depends on the row's body re-running.
   - The visible content is the same as before: same text, fonts, accessibility IDs, 240 maximum scroll height and 360 width.
   - Each open builds a new hosting controller, so the state starts fresh every time. The task's own nil-reset still prevents showing an earlier comparison.
2. **Binding writes during an update (F2):** `close` now takes `reportingClosed: .now | .deferred`.
   - **Dismantle and AppKit closes** use `.deferred`. The popover closes immediately, and `DispatchQueue.main.async { if isPresented.wrappedValue { isPresented.wrappedValue = false } }` runs afterwards.
   - **Event-monitor closes, app deactivation and SwiftUI-requested closes** still write synchronously; none of these runs inside a SwiftUI update.
   - The `delegate = nil` before `close()` stays, so our own closes never trigger `popoverDidClose` again.
3. **Clicks into another app window (R1):** before handing the click on, the monitor now calls `event.window.makeKey()` when that window is not the popover's window, can become key, and is not already key. Before, this only applied to the anchor's window.

**Validation**
- `make dev-build`: exit 0, no diagnostics in the changed files.
- `make dev-lint`: exit 0.
- `make guardrails`: exit 2.
  - Source layout, contributor allowlist and notice inventory checks pass.
  - The agent-context check fails only on the evidence docs you're writing in parallel: three orphan `fix-popover-*.md` files and the missing scope header in `verifier-scenarios.md`. I didn't touch `docs/` or `Scripts/`.
- `make dev-test FILTER="'AgentRecoveryNativePopoverEventDecisionTests|AgentRecoveryListHeaderTextTests'"`: rejected by the conductor (exit 64, "matched no curated ledger entry or source suite"); it doesn't accept the `|` form. I ran each suite on its own:
  - `make dev-test FILTER=AgentRecoveryNativePopoverEventDecisionTests`: 5 tests, 0 failures.
  - `make dev-test FILTER=AgentRecoveryListHeaderTextTests`: 6 tests, 0 failures.

**Not verified**
- All live click behavior.
- That the delayed reset really brings a returning View button back in a working state.

`git status` now shows the two new files as `A` (added to the index). I didn't stage them, so they must have been added by another process. `Tests/RepoPromptTests/Helpers/CodemapSeamTestSupport.swift` was already modified before this task and isn't mine.

**Live-check list for the verifier** (needs a session with a recovery row that has a View button):
1. Click **View**. The popover opens above the button with the title, detail, selectable scrolling text and attachments.
2. With it open, click the row's **Edit**, **Remove**, **Restore** or **Discard…** once. It closes and that button acts on the same click.
3. Open it, then click once in the composer. It closes, the composer gets focus, and typing works without a second click.
4. Open it, then click once on a sidebar session or a toolbar button. It closes and that item activates on that one click.
5. Open it, then click **View** again. It closes and stays closed; the next click reopens it.
6. Open it, click inside, select text, then press Escape. It stays open while you select, and closes on Escape.
7. Open it, then Cmd-Tab to another app. It closes; back in the app, one click on View reopens it.
8. **(a)** On an edit-proposal row, open View. "Comparing with the current file…" is replaced by the result on the first open, without closing and reopening. Close it, change the target file if practical, then open again. The comparing text shows first and is replaced by a freshly computed result, not the previous one.
9. **(b)** Open View and press Escape straight away without clicking inside. Note whether it closes. Escape is only handled when the popover window has keyboard focus, so it may not close.
10. **(c)** Open the Needs Attention sheet and repeat steps 1–5 on a row there. Same results, and the outside click also works on controls inside the sheet.
11. **(d)** With two RepoPrompt windows open, open View in one, then click once on a button or text field in the other. The popover closes and that control responds on the first click.
12. **(e)** Open View on a row, then remove that row while it's open (for example, act on it from the Needs Attention sheet or another window). The popover disappears with the row. When a row with a View button appears again (the same item re-held, or the row's View branch coming back), one click on View opens it; it doesn't look dead.

Nothing is committed and the app wasn't launched.
