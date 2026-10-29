# Step 8-attention-1 review — OracleB (round 0)

Scope: read when the task touches Needs Attention classification, the composer recovery banner rule or the needs-action counts (Step 8-attention-1).
Authority: Reference
Last-verified: 2026-10-26
Covers: OracleB (preset 7CDD523E-1D7C-47EA-98FE-D5FEA24D2D8C) fresh-chat review of the att1-r0 diff against review-policy.md.

# Review: Step 8-attention-1 (needs-action / informational classification)



## Summary

The diff sorts every catalog item into **needs-action** or **informational** when the catalog is built. Nothing is persisted, and the switch in `AgentRecoveryCatalogProjection.attention(for:facts:)` covers every payload without a `default`. Run cards (`turn`, `outcomeTurn`, `recoveryOnlyRun`) are informational unless `record.unresolvedAction(for: key)` finds an open recovery action. Every other payload is needs-action.

On the surfaces:
- **Composer banner:** it now keeps only needs-action items, and in the ready state it is hidden when the session has no rows. The "Nothing interrupted… N items elsewhere" text is gone.
- **Sidebar badge and elsewhere count:** both count open needs-action items only.
- **Sheet:** it has a "Needs action" section, then a collapsed "Information" section.

**Acceptance checks:**
- **Send paths and gates:** no send, admission, crash-hold, restriction or Dismiss path is touched. The changes are in presentation and in `AgentRecoveryCatalogActionFacts`.
- **No downgrades:** only the three run payloads can ever be informational.
- **Unfinished actions:** the detection reuses the same accessor the store uses to refuse a duplicate reservation (`AgentRecoveryActionModels.swift:274`). It is computed in `append` after `records[sessionID]` is set, on both the startup path (`addResolution`) and the live path (`addLiveRunInterruptions` / `addHeldInputOfUnlistedSessions`). The card keys are the same ones actions are reserved against.
- **Banner contents:**
  - Runtime items are added before the `.filter` and are not affected by it, since the method call binds tighter than `+`.
  - The dismissed-crash-hold paused indicator is added before the filter.
  - Preparation failures of tabs with no session still match `bannerItems` and are needs-action.
- **`nonisolated` classifier:** safe. It is a pure function over value types, follows the same pattern as the existing `recordStillMatches`, and touches no shared state.

**I found no P0 or P1 issues.** The findings below are P2/P3. Two of them are checks I could not settle from the attached code.

## P2

### ATT1-1: The classifier only treats "no outcome recorded" as needs-action; an unsuccessful recorded outcome makes the card a note again
- **Evidence:**
  - `AgentRecoveryCatalog.swift:269` uses `facts.hasUnfinishedAction ? .needsAction : .informational`.
  - `:368` computes it only from `unresolvedAction`.
  - The new coordinator test completes with `.importedUnconfirmed` and asserts the card is informational again.
- **Scenario:**
  1. After a relaunch, a run card shows "Resume was interrupted; status unknown" as needs-action in the banner.
  2. The user clicks Reconcile or Continue (with typed text).
  3. The action records an outcome that is not a success (a durable failure or refusal, `importedUnconfirmed`, or a not-dispatched result written as an outcome).
  4. The card becomes informational, and the banner disappears if it was the only row.
  5. Any inline result or failure text leaves with it. That breaks the banner's contract that "failures stay inline on their row until the action succeeds" (`AgentRecoveryListBanner.swift` doc).
- **Impact:** if a continuation's typed text never became an intent, then "text stays unsent if the user does nothing" is true, but the card is in the collapsed Information section and the badge does not count it. If the text did become an intent, the intent card covers it and there is no impact. I could not confirm from the attached code which outcome kinds can be written without an intent.
- **Smallest fix:** check the `AgentRecoveryActionOutcome` kinds. If any outcome can leave continuation text unsent, also treat "the last action on the key resolved without success" as needs-action, and add a classifier test for that outcome.

### ATT1-2: Starting an action on a run note moves the row between sections and briefly shows the banner
- **Evidence:**
  - `AgentRecoveryNeedsAttentionSheet.swift:24-25` and `:63/:79` render the two sections as separate `ForEach`s.
  - The worker report notes that an action still running in this launch also counts as unfinished.
- **Scenario:**
  1. Run notes are now actionable only from the collapsed Information section.
  2. The user clicks Resume/Continue on one.
  3. The reservation marks it needs-action. The row leaves the Information `ForEach` and reappears under "Needs action", so SwiftUI gives it a new identity and any row-local `@State` resets.
  4. If it belongs to the active session, the composer banner appears and the badge goes up by one.
  5. When the outcome is recorded, the row moves back and the banner disappears.
- **Impact:** confusing UI; it can lose a row-local confirmation or warning step if `AgentRecoveryListRow` keeps one in `@State`. Not verified live, since the app was not launched.
- **Smallest fix:** check it in the running app. If the jump is disruptive, render both sections from one `ForEach` with header rows placed between them, so row identity stays stable. Alternatively, keep a row in the section it was in while its coordinator action state is `.working`.

### ATT1-3: Two blocking states now depend on catalog items that I could not confirm exist
- **Scheduled-send gate vs. classifier:** the synthesis says scheduled sends are held by "recovery actions in progress" (`scheduledSendHasUnresolvedRecovery`, `AgentModeViewModel+ScheduledSend.swift` 1538-1586).
  - If that gate uses a different predicate than `unresolvedAction(for:)` (for example the `AgentRecoveryActionJoin` classification, or session-level rather than card-key matching), a session's sends can be paused by an action while its run card is informational.
  - The result would be no banner, no badge, and a paused send with no explanation in the composer.
- **Startup restrictions:** a session with a startup restriction (`coordinator.restrictions.sessionRestriction`) whose only catalog rows were run cards used to get a banner. Now it gets none.
  - `addRuntimeRestrictions` returns early while `hasProcessRegistry` is false, which is every launch until Step 9-activation. So before activation, nothing would explain that restriction.
  - Admission still refuses, so the gate is intact and only the explanation is lost.
- **Smallest fix:** confirm by grep that the gate's predicate is `unresolvedAction`, or align the two. Confirm that every startup session restriction comes with a needs-action item (status-unknown, crash-hold or transfer). Add one test for each.

### ATT1-4: The "Needs action (n)" sheet header counts dismissed rows when "Show dismissed" is on
- **Evidence:** `AgentRecoveryNeedsAttentionSheet.swift:24` and `:53` partition `rows`, and `rows` includes dismissed items when the toggle is on.
- **Scenario:** with 2 open items and 3 dismissed ones, turning on Show dismissed changes the header to "Needs action (5)" while the badge says 2. Dismissed needs-action rows are also mixed into the Needs action section.
- **Design gap:** the synthesis (O34-2) puts dismissed and cleared items in their own section behind the toggle.
- **Smallest fix:** count `!entry.isDismissed` in the header, or move dismissed rows to a third section. If the third section is meant for 8-attention-2, record it as deferred.

### ATT1-5: Test gaps for the stakes
- **Startup-path run card:** no test covers an unfinished action from an earlier launch on a startup run card. That path builds its card key from `binding.incarnationID` in `addResolution`; both new tests reserve within the current launch.
- **Undismissed crash hold:** no test covers an active session with an undismissed crash hold whose only other rows are run notes; the banner must still show. Only the dismissed paused-indicator case is updated.
- **Sessionless-tab preparation failure:** no test checks that it still shows the banner.
- **Unsuccessful outcome:** no test covers ATT1-1.
- **Payload table:** `XCTAssertEqual(table.count, 24)` is hard-coded. A new payload is caught by the classifier's exhaustive switch but not by the test table.

## P3

### ATT1-6: Items in other sessions no longer have a composer-level signal
This was decided in the design ("Banner (O34-1)"), so I note it as residual risk rather than a defect.
- With the sidebar collapsed, another session's crash hold, held input or unanswered question shows nowhere. The View-menu item has no count.
- The same applies to `scheduleIndexUnavailable` for the current workspace, which used to show up in the elsewhere text.
- **Fix if wanted later:** add a count to the View-menu item.

### ATT1-7: The new `attention` field defaults to `.needsAction`
`AgentComposerUIModels.swift:481`: `var attention: AgentRecoveryCatalogAttention = .needsAction` lets a future construction site skip classification without any error. The default errs on the safe side, but a required `let` would make the compiler enforce it, the way the payload switch does.

### ATT1-8: Comment and documentation nits
- `openNeedsActionCount` (`AgentRecoveryCatalog.swift:213`) says "badge and menu count", but the menu shows no count.
- The `AgentRecoveryListBanner.swift` doc comment has one very long reflowed line.
- The `headerText` branch for `rows.isEmpty` (`AgentComposerUIModels.swift:454`) is unreachable on screen. That is fine as a fallback, but its comment could say so plainly.

## Recommendations

1. **Before commit:** settle ATT1-3, the two greps for the gate predicate and the restriction-to-item coverage. A mismatch there would raise it to P1 (paused sends with no explanation).
2. **Before commit:** check which `AgentRecoveryActionOutcome` kinds can leave continuation text unsent (ATT1-1). If any can, extend the classifier and add a test.
3. **Cheap fixes now:** ATT1-4 (header count), ATT1-7 (required field) and ATT1-8 (comments).
4. **Tests:** add the startup-path unfinished-action case and the undismissed-crash-hold-with-run-notes case from ATT1-5. They are small and protect the two acceptance rules most at risk ("an unfinished action is never hidden" and "blocking states stay visible").
5. **Verifier's live pass:** check ATT1-2 (section jumps and banner flicker during an action on a run note) and the sheet's collapse/expand. Live rendering was not verified.
6. **Status line:** record ATT1-6 as accepted by design and the workspace grouping and dismissed section as deferred to 8-attention-2.