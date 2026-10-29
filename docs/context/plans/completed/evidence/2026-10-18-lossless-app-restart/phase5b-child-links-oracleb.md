# Step 5b initial review — OracleB

Scope: read when the task touches the durable delegated-child link review and its required repairs.
Authority: Reference
Last-verified: 2026-10-23

Main verified the exact requested preset UUID/name. Initial snapshot 2026-10-23/1253-2, 19 source/test files (+1248/-50). Full response follows, Markdown hard-break whitespace normalized; original local export unchanged. [Disposition](phase5b-child-links.md).

# Oracle Review



# Review: Lossless-restart Step 5b (delegated child links)

## Summary

This change records a link from a parent agent run to the child session it starts. The link uses the dispatcher's existing server-side invocation UUID (carried as a new `currentToolInvocationID` TaskLocal and stored in `RequestMetadata.toolInvocationID`). When a recovery-tracked parent calls `agent_run.start`, the parent's tab, session, full run ownership, process run ID and recovery lane are captured together with the existing delegation admission, in the same synchronous step. They are re-checked at each suspension point.

Before the child is dispatched, three things happen in order:
1. The child gets a covering `.written` owner save (reusing `commitRecoverySavedPlacement`).
2. The link is committed through the parent lane's gate. It goes in as a new additive `delegatedChildLinks` record collection, which keeps unknown fields and allows only exact repeats.
3. A TaskLocal fence, scoped around `startRun`, re-checks the parent admission in the starter, in `mcpDispatchInstruction`, and in both `isStillCurrent` predicates.

After a restart, the catalog attaches links to the parent's run card. The row shows the child's status honestly (missing, no saved messages, has messages, or unknown) and offers Open for children in this workspace only.

Against the five acceptance points the design holds up:
- **Admission:** an independent caller, or a parent without durable admission, returns `nil` before any new behaviour.
- **Fail closed:** a tracked parent missing the invocation ID, a current attempt, or an owned lane is refused.
- **Order:** save, then link, then dispatch is enforced. Failures go through the existing discard paths.
- **Codec:** additive, and keeps extras.
- **Gates:** no Phase 3/4 gate is touched.

**I found no P0 or P1.** Everything below is P2/P3.

---

## P2 — Consider (cheap fixes recommended now; otherwise defer explicitly)

### F1 — Child status is mostly hidden in the banner; repeated child IDs collide in `ForEach`
- **Failure scenario:**
  - A parent run card already has a one- or two-sentence `recoveryListTurnText` detail. The child text, including "…may never have started" and "Delegated work is never restarted automatically", is appended to that detail.
  - The detail renders with `.lineLimit(2)` in a fixed 52 pt row. Run rows pass `text: nil`, so there is no View button.
  - In practice the honest child status (acceptance 4) is cut off. With several children, the HStack also packs one "Open delegated session XXXXXXXX" button per child next to the run actions, Dismiss and Open.
  - Separately, two links can name the same child. Example: two explicit-tab `agent_run.start` calls to the same existing child under one attempt. That produces two identical `.openDelegatedSession(id)` values, and `ForEach(row.actions, id: \.self)` gets duplicate IDs (undefined SwiftUI behaviour) and repeated text.
- **Impact:** The status text the contract requires is effectively not visible. This is cosmetic only; the Open action itself works.
- **Evidence:**
  - `AgentModeViewModel+RecoveryList.swift` ~216–230 (`detail + children.detail`, `text` not set).
  - `AgentModeViewModel+RecoveryList.swift` ~400–425: one action per link, no dedupe.
  - `AgentRecoveryListBanner.swift` ~120–124 (`lineLimit(2)`), ~133 (View shown only when `row.text != nil`), ~137 (`ForEach … id: \.self`).
- **Smallest fix:**
  - In `recoveryDelegatedChildPresentation`, dedupe by `childSessionID` for both the text and the actions.
  - In the three run cases, pass `text: children.detail.isEmpty ? nil : children.detail.trimmingCharacters(in: .whitespaces)`, so the full status shows in the existing View popover.
  - Optionally make the inline addition short, e.g. " N delegated session(s) linked; see View."

### F2 — The fence TaskLocal outlives the start in unstructured tasks
- **Failure scenario:**
  - `MCPDelegatedChildDispatchFence.$current.withValue(admission) { startRun(...) }` puts the admission in a TaskLocal. Every `Task {}` created inside that scope inherits it, including long-lived provider and run-loop tasks.
  - Any later `mcpDispatchInstruction` or `AgentExternalMCPRunStarter.start` for the child that runs inside such a task still sees `fence.linkedChildSessionID == childID`. It then requires the parent's admitted attempt to still be current.
  - With `detach: true` the parent usually finishes its turn soon after. That later child dispatch would then be refused with "run attempt … changed before the child was started".
  - The inherited admission also holds a strong reference to the `revalidateDelegation` closure (which captures the view model) for the lifetime of those tasks.
- **Impact:** Probably latent. I couldn't confirm a current path that calls `mcpDispatchInstruction` from an inherited task, but nothing guarantees it won't happen.
- **Evidence:**
  - `AgentRunMCPToolService.swift` ~1607 and ~1626 (scope).
  - `AgentModeViewModel+DelegatedChildLinks.swift` ~205–213 (`mcpDelegatedChildDispatchFence` checks only `linkedChildSessionID`).
- **Smallest fix:**
  - Add a one-shot release on the admission: `fileprivate(set) var dispatchFenceReleased = false`.
  - Have `mcpDelegatedChildDispatchFence(for:)` return `nil` once it is set.
  - Set it right after `startRun` returns or throws, e.g. `defer` inside the `withValue` body via a small `mcpReleaseDelegatedChildDispatchFence(_:)`.
  - The Codex bounded-ack driver keeps its explicit `childLinkFence` capture, so its pre-handoff check is unaffected.

### F3 — An attempt first recorded by the link path may never get a terminal (needs verification)
- **Failure scenario:**
  - `AgentRecoverySessionLane.commitDelegatedChildLink` calls `ensureRunAttempt(.keepExisting, transcriptTurnID: nil)` to cover "a parent whose run began before its lane was claimed".
  - Suppose the normal run-end and shutdown path only commits terminal/shutdown evidence for attempts it recorded itself, or it skips because it had no lane when the run began.
  - Then this attempt stays open in the record. On the next launch a parent that finished cleanly would show an interrupted-run card, and possibly a crash hold ("Sending is paused…").
- **Impact:** If this happens, it is a wrong answer plus a blocked send, but only on the late-lane-claim path. Nothing in the diff shows that the terminal path reaches this attempt.
- **Evidence:** `AgentRecoveryStore+DelegatedChildLinks.swift` ~75–84. None of the tests end the parent run after a link-created attempt and inspect the record.
- **Smallest fix:**
  - Add one harness test: claim the lane, `beginParentAttempt`, commit the link (this creates the attempt), end the run through the normal VM end path, then assert `runAttempt(id:).terminal != nil`.
  - If the test fails, the fix belongs in the existing terminal commit (look up by attempt ID). Don't add anything new in Step 5b.

### F4 — The service-level happy path is untested (validation gap, load-bearing)
- **Failure scenario:**
  - All positive coverage drives view-model pieces directly.
  - No test runs `AgentRunMCPToolService.execute` for a tracked parent that has a current attempt and a claimed lane. Such a test would show that:
    - the target is created;
    - the child save and link commit come before `startRun`;
    - `MCPDelegatedChildDispatchFence.current` is set inside `startRun`;
    - `probe.starts.count == 1`.
  - If durable admission is on in normal use, a wiring regression here either blocks every delegated start or lets dispatch happen before the link, and nothing catches it.
- **Evidence:**
  - `AgentDelegationServiceBoundaryTests.swift` ~243–270 covers refusals only.
  - Wiring at `AgentRunMCPToolService.swift` ~990–997, ~1120, ~1466, ~1562–1588, ~1607/1626.
- **Smallest fix:**
  - Add one boundary test using the existing `makeKnowledgeStartService(…, toolInvocationID:)`.
  - Set up a real recovery coordinator, mandatory admission, a claimed lane and `beginRunAttempt` on the root.
  - In a custom `startRun`, assert that the link is already in the parent record and that the fence's `linkedChildSessionID == target.sessionID`.
  - This is non-live work and worth finishing before live verification.

### F5 — `delegatedChildLinks` is never pruned
- **Failure scenario:** An orchestrator parent that spawns many workers, e.g. Knowledge fan-out, collects links forever. The whole record is rewritten atomically on every mutation, including debounced composer writes.
- **Impact:** Slow growth in record size and write cost. There is no correctness impact.
- **Evidence:** `AgentRecoveryStore+DelegatedChildLinks.swift` ~44–51 (append only). `replace` carries links forward unconditionally.
- **Fix (defer is fine):** If `runAttempts` are ever pruned, drop links whose `parentRunAttemptID` is no longer present in the same `replace`. Otherwise growth matches run attempts, which is acceptable for now.

---

## P3 — Improvements (explicit defer is fine)

- **F6 — Inconsistent shape of the link-failure catch.**
  - Location: `AgentRunMCPToolService.swift` ~1570–1585.
  - The worktree and provider catch blocks call `WorktreeStartupInstrumentation.record(.failed…)` before the `#if DEBUG` and then pass `false` to `performTerminalQualificationCleanup`.
  - The new block skips the record call in DEBUG and passes `true`. This is probably equivalent, assuming the flag means "record the failure".
  - Suggestion: hoist the `record` call above the `#if` and pass `false`, matching the other two blocks, so the debug and release cleanup are visibly the same.
- **F7 — Misleading wording for other workspaces.**
  - Location: `AgentModeViewModel+RecoveryList.swift` ~407.
  - In the Needs Attention sheet, a parent from another workspace is checked against the viewing window's `ownerValidatedSessionIndex`. The row then says the child "can't be found in this workspace" even though it exists where the parent is.
  - Suggestion: when `item.workspaceID != persistenceWorkspace?.id`, show "Open the parent session to check its delegated sessions" and offer no child actions.
- **F8 — Invocation ID source in DEBUG / EDIT_FLOW_PERF builds.**
  - Location: `MCPConnectionManager.swift` ~11655.
  - In these builds `invocationID` comes from the inherited `appInvocationID` when one is present. If that value can come from a client or bridge and gets reused, the second start hits `delegatedChildLinkConflict` and fails closed. That is safe, and it is still the dispatcher's existing ID as the contract requires.
  - Suggestion: no change needed. Just note it in the plan's assumptions.
- **F9 — No revision compare-and-swap on the store mutation.**
  - `AgentRecoveryStore.commitDelegatedChildLink` takes no `expectedRevision`, unlike the other mutations. It is only reached inside the lane's gated `transaction` after `ensureRunAttempt`, so this is fine today.
  - Suggestion: add a one-line doc note that callers must hold the session gate.

---

## Acceptance cross-check (no action)

| # | Status |
|---|---|
| 1 | The ID is scoped inside `withConnectionID` at the same level as `currentTabContextHint`, which already reaches `captureRequestMetadata`. An independent caller returns `nil`. A tracked parent with no ID, attempt or lane is refused before the target is created (tested). |
| 2 | The captured ownership, process run ID and lane identity are re-checked at child creation, after worktree preparation, after the save, after the link, in the starter, in `mcpDispatchInstruction`, and in `isStillCurrent`. It reuses `isCurrentRunAttemptForCurrentBinding` and `lane.isValidForHandoff`; no new generation counter or registry. |
| 3 | Only a covering `.written` receipt counts (`staleWriteCoversCapture`). Exact repeats are idempotent and conflicts fail. A link failure discards the target and dispatches nothing. |
| 4 | Links are shown under the run attempt's card; nothing is recreated or resumed; Open only switches to or unstashes a tab. See F1 for visibility and F7 for wording. |
| 5 | No Phase 3/4 gate is touched. The link path only runs when `requiresDurableRecoveryAdmission(for:)` is true. |

**Recommendation:** commit is not blocked. Doing F1, F2 and F4 now is cheap. Run the F3 test first and decide based on what it shows. Defer F5–F9.
