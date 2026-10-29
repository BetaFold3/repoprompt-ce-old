# F7 fix: worker report (2026-10-26)

Scope: read when the task touches lossless restart Step 7-F7 (composer tab ownership and submit-path diagnostics) implementation or review evidence.
Authority: Reference
Last-verified: 2026-10-26

Covers: finding F7 and the first bullet of "Cross-cutting observability" in `2026-10-18-lossless-app-restart-spec.md`, at base `d971983b`. Nothing is staged or committed. The visible app was not launched.

## Files changed

| File | Change | Why |
|---|---|---|
| `Sources/RepoPrompt/Features/AgentMode/ViewModels/AgentModeViewModel+ComposerUI.swift` (`syncComposerUIState`, ~196-209) | Publishes `makeComposerProps(tabID: currentTabID)` only when `tabID` is nil, is the current tab, or there is no current tab. An explicit non-current tab skips the store update but still calls `notifyScheduledSendBusyStateMayHaveChanged(tabIDs: [tabID])`. | F7 cause 4: the shared store took the last tab's props. With no current tab, the no-tab props are published, so another tab's props never linger. |
| `…/AgentModeViewModel+RecoveryList.swift` (`refreshRecoveryListUI`, ~1053-1067) | Publishes the current tab once, only if it already has a session (or the no-tab props when there is no current tab). Then sends one explicit busy notification for every other open tab. | F7 cause 3. Busy notifications are kept on purpose. The refresh never creates a session for the current tab, matching the old loop over `sessions.keys`. |
| `…/AgentModeViewModel+Recovery.swift` (~639-644) | Rewrote the "no scheduler churn" observer comment. | It was inaccurate: the refresh re-reports busy state and can call `recordDidChange()` when a tab's busy state changed. It only doesn't *force* a re-evaluation. |
| `Sources/RepoPrompt/Features/AgentMode/Views/AgentInputBar.swift` (`scheduleMessage` ~2351-2407, `sendMessage` ~2419-2474) | Added `logViewSubmitRejection` reasons on every early return that had none. In `sendMessage`: `selected_provider_unavailable` / `no_agent_providers`, `empty_draft`, `claim_<rejection.diagnosticReason>`. In `scheduleMessage`: `schedule_unavailable_for_rendered_target`, `empty_draft`, `schedule_claim_<reason>`. | Cross-cutting observability. These reasons and `view_nil_target` are always on (see [Logging](#logging)); no draft text is logged. |
| `…/AgentModeViewModel.swift` (`executeComposerSubmitAttempt`, ~15334-15598) | Added `logRejectedSubmitTarget(…, reason:)` to each early return that had no log. There are 16 reasons, e.g. `claim_not_current`, `session_not_ready`, `prepared_session_or_claim_changed`, `new_work_blocked`, `initial_turn_preflight_blocked`, `initial_location_preparation_failed`, `state_changed_during_location_preparation`, `initial_location_workspace_preflight_failed`, `first_send_destination_not_created`, `claim_not_current_after_destination_created`, `source_session_replaced`, `destination_preflight_blocked`, `destination_location_preparation_failed`, `state_changed_during_destination_preparation`. | These are the remaining silent exits that produce "This composer changed…" or another blocked message. The change is logging only: no `resyncAfterRejectedSubmitTarget` was added and no control flow changed. These 16 calls pass `persistent: true` (see [Logging](#logging)). |
| `Tests/RepoPromptTests/AgentMode/AgentComposerTabOwnershipTests.swift` (new, 5 tests) | Regression tests listed below. | F7 test list. |

Not changed (as the brief asked): submit-target checks, `renderedSubmitTarget`, submission tokens, the recovery-store commit publisher, and store equality.

**Optional DEBUG assertion: not added.** `AgentComposerUIStore` has no notion of the current tab; it holds only `props`. An assertion would need new plumbing (a current-tab provider in the store). Inside `syncComposerUIState` it would be a tautology, because `update` has exactly one caller (`AgentModeViewModel+ComposerUI.swift:203`).

## Logging

The submit-path reasons added here, plus the existing `view_nil_target`, are logged always on. This holds in normal Dev-app runs and Release builds, with no perf-diagnostics or `enableSteeringDebugLogging` switch.

**Facility.** Unified logging (`os.Logger`):
- Subsystem `com.repoprompt.agents`: the module's existing agent subsystem, also used by `RemoteAgentModeCoordinator`, `ClaudeSteering` and `CodexAppServer`. Category `ComposerSubmit` is new.
- Level `.notice`, which is persisted.
- I looked for an existing recovery or scheduled-send facility to reuse. `AgentModeViewModel+Recovery.swift` and `+ScheduledSend.swift` log with `print`, which a GUI app does not persist, and `AgentRecovery*` / the scheduler have no logger. So the existing subsystem was reused rather than adding a logging system.

**Code.**
- `AgentComposerSubmitDiagnostics` in `AgentModeViewModel+ComposerUI.swift` has two functions: `viewRejected(…)` and `submitRejected(…)`.
- `AgentInputBar.logViewSubmitRejection` and `AgentModeViewModel.logRejectedSubmitTarget` take a new `persistent: Bool = false` parameter.
- Only these calls pass `true`:
  - the view reasons `selected_provider_unavailable` / `no_agent_providers`, `empty_draft`, `view_nil_target`, `claim_<reason>`, `schedule_unavailable_for_rendered_target` and `schedule_claim_<reason>`;
  - the 16 `executeComposerSubmitAttempt` reasons.
- After the review fixes, every rejection exit on the composer send, schedule and submit paths is persistent (see [Review fixes](#review-fixes-2026-10-26) F7-R1).
- These stay DEBUG-only:
  - `stale_completion` and `stale_schedule_completion`: late completions for an attempt that was already superseded; the user sees nothing.
  - The claim-time `claimComposerSubmitAttempt` rejections: the view's persistent `claim_<reason>` already logs the same reason.
- The existing DEBUG perf events are still emitted. No control flow changed.

**Content.**
- `view_rejected reason=… currentTab=… propsTab=… targetTab=…`
- `submit_rejected reason=… route=… targetTab=… currentTab=…`
- Reasons are fixed vocabulary strings, including `AgentComposerSubmitClaimRejection.diagnosticReason` and the target route's raw value. Tab IDs are UUIDs. All values are `privacy: .public` so they are readable after the fact.
- No draft text, attachment names or other user content is logged.

**Read it:**

```sh
log show --last 1h --style compact \
  --predicate 'subsystem == "com.repoprompt.agents" AND category == "ComposerSubmit"'
# live: log stream --level default --predicate 'subsystem == "com.repoprompt.agents" AND category == "ComposerSubmit"'
```

**Verified.** A compiled throwaway binary emitted one `.notice` with this subsystem and category. `log show` read it back unredacted:

```
Df emit[…] [com.repoprompt.agents:ComposerSubmit] view_rejected reason=f7_logcheck currentTab=nil
```

The focused tests don't reach a flagged rejection path, so no app-emitted entry was observed. Inside the agent sandbox `log show` returned no entries; the read-back above ran outside it.

## Audit findings

1. **`createAndActivateSessionTab`** (`AgentModeViewModel.swift` ~22817-22883): safe. It publishes through `updateBindingsFromSession(session)` and `syncAllActiveUIState()` (nil tab) only after `guard currentTabID == tabID`. `prepareFreshSessionForActivation` runs before activation but makes no composer sync.
2. **First-send destination sync** (`AgentModeViewModel.swift` ~15543, previously 15530): safe. `destinationTabID` comes from `createAndActivateSessionTab()`, which returns a tab only after it is current, so this sync normally publishes. If the user switches tabs during the awaits, the new guard correctly skips it, and the existing `defer` already re-syncs only when `destinationTabID == currentTabID`. The source-tab syncs at ~15396 and ~15481 run while the source is current, and their `defer`s already check `currentTabID`.
3. **Tab activation (`onTabChanged`)** (`AgentModeViewModel.swift` ~4004 → `applySessionToBindings` → `syncAllActiveUIState(tabID: session.tabID)` ~10954): safe. `.activeComposeTabChanged` is posted from `PromptViewModel.activeComposeTabID`'s `didSet` (`PromptViewModel.swift:128-140`), after storage, so `currentTabID` already equals the new tab.
   - `setAgentModeActive` (~3848) uses `pendingTabIDForLoad ?? currentTabID`. Each post-storage notification refreshes the pending value.
   - The workspace-switch path (~13331) activates `workspace.activeComposeTabID`. Its ordering against `promptManager.activeComposeTabID` (`PromptViewModel.swift:2518`) is **not proven**. If the prompt manager lagged, the new guard would skip that one publish. In that case the view's `.onChange(of: currentTabID)` → `syncActiveTabUIState` → `syncComposerUIState(tabID:)` (`AgentModeDetailWithSidebarView.swift:173-174, 265-267`) publishes as soon as the tab becomes current. Under the old code those props were inert anyway, because `props.currentTabID` ≠ the view's tab means `renderedSubmitTarget` is nil.
   - **Open:** confirm the ordering live or with a workspace-switch test (I ran `WorkspaceSwitchRecoveryTests`: pass).
4. **Other `applySessionToBindings` callers** (~6090, 8850, 8928, 15435, 15588; `+ScheduledSend.swift` 476, 602): all are already gated on `== currentTabID`. `updateBindingsFromSession` returns early for inactive tabs (~11408). `ContextBuilderAgentViewModel.applySessionToBindings` is a different class and store.
5. **Direct `ui.composer.update` calls:** the only call is in `syncComposerUIState`. The other callers use `requestFocus` / `consumeFocusRequest`, which are tab-tagged requests, not props.
6. **Other shared stores fed by `syncAllActiveUIState(tabID:)` / `syncActiveUIState(tabID:)`:** none has the same bug pattern. `syncStatusPillsUIState`, `syncRuntimeMetricsUIState`, `syncSidebarUIState`, `syncTranscriptUIState`, `syncRunInteractionUIState` and `syncUtilityPanelUIState` take no tab ID and derive from the current tab. Only the composer used the explicit `tabID`.
7. **Behavior note:** `makeComposerSubmitTarget` lazily creates a session (V1-3, `+ComposerUI.swift` ~129-145). Explicit non-current syncs no longer call it.
   - No production caller depended on that. All 67 explicit callers pass a tab that already has a session or that is current: `+DraftsAttachments.swift:43` and `+StatusPillsUI.swift:250-263` are already gated on `== currentTabID`.
   - The fresh-workspace default-tab lazy creation happens on the current-tab sync and is unchanged. `AgentRunLocationTests` and `AgentRunWorktreeStartTests` pass.

## Validation

| Command | Result |
|---|---|
| `make dev-build` | pass (exit 0) |
| `make dev-test FILTER=AgentComposerTabOwnershipTests` | 5 tests, 0 failures. Re-run after the lint fix: 5/5. |
| Same suite against the HEAD versions of `+ComposerUI.swift` and `+RecoveryList.swift` (temporary revert, then restored) | 4 of 5 tests failed (foreign `currentTabID`/`submitTarget`, MCP lock, revision bump, other-tab props with no current tab). The tests detect F7. |
| `make dev-test FILTER="'AgentComposerTabOwnershipTests\|AgentModeChatSwitchActivationTests\|AgentModeStopSubmitTargetTests\|AgentRecoveryReconciliationTests\|AgentRecoveryResetBoundaryTests\|AgentRecoveryStartupCompositionTests\|AgentRecoveryVMProducerAdmissionTests\|AgentScheduledSendCoordinatorTests\|AgentScheduledSendDispatchTests\|AgentStaleResetOwnershipTests\|WorkspaceSwitchRecoveryTests\|AgentScheduledSendNonCodexMandatoryTests\|AgentRecoveryEditProposalTests'"` | 383 tests, 0 failures, 2 skipped; all 13 suites passed |
| `make dev-test FILTER="'AgentRunLocationTests\|AgentRunWorktreeStartTests\|AgentModeRunServiceLifecycleTests\|AgentRecoveryQueuedInputTests'"` | 277 tests, 0 failures |
| `make dev-lint` (swiftformat lint + `swiftlint --strict`) | pass after one fix: `9_701` → `9701` in the new test (numberFormatting) |
| `make dev-format-check` | failed only on that same literal before the fix. Not re-run separately; `dev-lint` runs the same swiftformat lint and passed. |
| `make guardrails` | pass. 1 warning: AGENTS.md has 24 routes > 15; it was already there and not caused by this change. |
| Logging follow-up: `make dev-build` | pass, with no new warnings in changed files. |
| Logging follow-up: the same 13-suite `make dev-test` filter as above (includes the new suite) | 383 tests, 0 failures, 2 skipped; all 13 suites passed |
| Logging follow-up: `make dev-lint` | pass (0/2178 files need formatting; swiftlint strict clean) |

Note: `make dev-test FILTER=a|b` needs the regex quoted inside the make variable (`FILTER="'a|b'"`); the Makefile doesn't quote it.

## Not run

- The full `make dev-test` / `dev-test-parallel` root lane.
- Live composer re-checks (spec "Afterwards"): no visible app launch was allowed.
- Separate coverage for the Tab-tag first send (spec: "Keep separate coverage").
- The plausible first-send race where draft persistence binds a session after the rendered target was captured. Neither was added: the new logs are meant to identify the actual reason first.

## Open questions

- Resolved: the reason logs are now always on (see [Logging](#logging)).
- Resolved by the review fixes (F7-R1): the claim-time rejections stay non-persistent on purpose, to avoid logging each one twice. See Review fixes.
- The workspace-switch ordering in audit item 3.
- The spec says "about 67 call sites". I counted 68 explicit-tab `sync*UIState(tabID:)` calls, including the view's `AgentModeDetailWithSidebarView.swift:267`.

## Review fixes (2026-10-26)

These address `fix-f7-review-oraclea.md` (A) and `fix-f7-review-oracleb.md` (B).
- Full diff of this step against HEAD: `fix-f7-current.diff`. It covers only `Sources/RepoPrompt/Features/AgentMode/**` and the new test file; the unrelated `CodemapSeamTestSupport.swift` change is excluded.
- Delta against the reviewed `prompt-exports/restart-fixes/fix-f7-review.diff` (local only): `prompt-exports/restart-fixes/fix-f7-r1-delta.diff` (local only). I built it by applying `fix-f7-review.diff` to HEAD copies of the files and diffing that against the current files.
- Nothing is staged or committed.

| Finding | Change |
|---|---|
| B F7-R1 (P1) / A F7-R1 | Rejection exits on the composer send/schedule/submit path now log persistently (details below). |
| B F7-R3 | Switch-while-queued test: the sync counter is now sampled after `beforeDelivery()`, so a setter's own synchronous sync can't satisfy the wait. Delivery needs the main run loop, so only the delivered refresh counts. |
| B F7-R6 | Renamed the second exit of each duplicated pair: `initial_turn_preflight_blocked_after_preparation` and `destination_preflight_blocked_after_preparation`. The two `invalid_first_send_destination` exits already existed and are not a before/after-preparation pair; I left them unchanged. |
| B F7-R7 | Fixed the `recoveryCoordinatorChangeObserver` comment (`+Recovery.swift` ~629). The observer republishes the current tab, re-reports busy state and forces a scheduler re-evaluation. |
| A F7-R2 / B F7-R4 | Done; it was cheap (details below). |
| A F7-R3 / B F7-R2 | `assertComposerOwned` now also asserts `props.canSendWithCurrentProvider` wherever a test claims "Send stays enabled". The workspace-switch test was not added (details below). The Tab-tag first-send test stays deferred. |
| B F7-R5 | Deferred, as the review dispositions say. |

**F7-R1 details.** These now pass `persistent: true`:
- the `submitTargetRejectionReason` exits in the existing-session (~15362) and first-send (~15515) routes;
- `agent_session_id_mismatch`, `source_pending_state_changed`, and both `invalid_first_send_destination` exits;
- the schedule path's existing `submitTargetRejectionReason` exit (`+ScheduledSend.swift` ~426);
- `local_attempt_latched` in both `sendMessage` and `scheduleMessage`.

New persistent logs:
- The 6 silent stale-message exits of `executeComposerScheduleAttempt`: `schedule_claim_not_current`, `schedule_prepared_session_or_claim_changed`, `schedule_state_changed_during_location_preparation`, `schedule_initial_start_location_pending`, `schedule_state_changed_after_destination_created`, `schedule_state_changed_during_destination_preparation`.
- The composer-origin stale exit of `submitUserTurnAdmittingRecoveryInput`: `admission_no_longer_current`, route `recovery_admission`, logged only when `origin == .composer`.
- `completion_blocked` / `schedule_completion_blocked` in the view's completion closures whenever `effects.blockedMessage != nil`. Only the reason is logged, never the message.
- Thrown preparation failures (`InitialNewWorktreePreparationError`) were already covered by the persistent `*_location_preparation_failed` logs.

Vocabulary is fixed:
- `submitTargetRejectionReason` returns only string literals.
- `AgentComposerSubmitClaimRejection.diagnosticReason` returns literals or a `targetRejected(reason:)` built from those literals or `"inactive_composer_tab"`.
- Neither contains user content.

Left non-persistent on purpose:
- The claim-time `claimComposerSubmitAttempt` logs. Claiming is not a hot path (it runs once per user submit), but the view already logs `claim_<diagnosticReason>` persistently for every composer claim, so persisting them too would log each rejection twice.
- `submitUserTurnCreatingSessionIfNeeded(text:)` and `(text:sourceTabID:createAndActivateSessionTab:)`. Their silent exits are only reached by internal entry points; the composer view never calls them.

**F7-R2 / R4 details.**
- `makeComposerProps(tabID:materializingSession:)` with `false` skips `makeComposerSubmitTarget` when the tab has no session. That is the only helper that creates a session; the others use `createIfNeeded: false` or none.
- `refreshRecoveryListUI` publishes that non-submittable current-tab snapshot when the current tab has no session.
- The removal test now asserts `currentTabID == A`, a nil `submitTarget`, and that A's session was not re-created.

**F7-R3 workspace-switch test: not added.**
- The audit question is the order between `workspace.activeComposeTabID` and `promptManager.activeComposeTabID`.
- Existing helpers either pin `currentTabID` with `test_setCurrentTabIDOverride`, which bypasses that order, or need PromptViewModel/WorkspaceManager and sidebar-index fixtures that are private to other suites (`makeWorkspaceFixture`, `SidebarIndexStreamHarness`).
- I didn't build that infrastructure. The ordering stays `assumed:` (audit item 3).

**Validation (after the review fixes).**

| Command | Result |
|---|---|
| `make dev-build` | pass |
| `make dev-test FILTER=AgentComposerTabOwnershipTests` | 5/5 pass |
| The 13-suite filter from Validation | 383 tests, 0 failures, 2 skipped; all 13 suites passed |
| The 4-suite run-lifecycle filter (`AgentRunLocationTests\|AgentRunWorktreeStartTests\|AgentModeRunServiceLifecycleTests\|AgentRecoveryQueuedInputTests`) | 277 tests, 0 failures |
| `make dev-lint` | pass (0/2178 files need formatting; swiftlint strict clean) |

**OracleB r1 P3s:**
- **N1:** added a comment at the direct `ui.composer.update` in `refreshRecoveryListUI`. It marks this as the only composer publication outside `syncComposerUIState`, and it publishes current-tab props only.
- **N2:** added persistent `schedule_session_not_ready` and `schedule_new_work_blocked` reasons in `executeComposerScheduleAttempt`.
- **N4:** asserting `props.canSchedule == false` in the removed-session test failed. `canScheduleSend(tabID:session:)` returns true for a nil session by design, because that is the new-session start path. The view still cannot schedule from that snapshot, because `canScheduleToRenderedTarget` also requires `renderedSubmitTarget != nil`. Production code is unchanged and the assertion was not kept.

After these changes, `make dev-build` and `make dev-lint` passed. The 13-suite filter passed except for the N4 assertion. After removing that assertion, `AgentComposerTabOwnershipTests` passed 5/5. `fix-f7-current.diff` was regenerated.

## Reviews

- Initial: [OracleA](fix-f7-review-oraclea.md), [OracleB](fix-f7-review-oracleb.md) on `prompt-exports/restart-fixes/fix-f7-review.diff` (local only).
- Re-review 1: [OracleA](fix-f7-review-oraclea-r1.md), [OracleB](fix-f7-review-oracleb-r1.md) on `prompt-exports/restart-fixes/fix-f7-r1-delta.diff` (local only); no P0/P1 open. OracleB N4 (`canSchedule` true in the no-session snapshot) is by design: `canScheduleSend` allows a new session's first schedule and the view also requires a rendered submit target; deferred.
