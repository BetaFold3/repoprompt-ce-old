# Step 5b R1 — OracleB

Scope: read when the task touches bounded delegated-child fix review or receipt recovery.
Authority: Reference
Last-verified: 2026-10-23

Snapshot: 2026-10-23/1327; seven-file repair delta +602/-57 against unchanged staged index bb5ebb427845ce476970341a401579be5e32c576. The first completed call's transport receipt was lost during compaction; its full answer was recovered but was not used as identity-verified clearance. One fresh receipt-failure retry used the identical snapshot and own-lane request. The retry returned explicit preset 7CDD523E-1D7C-47EA-98FE-D5FEA24D2D8C, OracleB, matching the requested preset. No pending operation remained. No code changed between calls. Original exports remain local; retained text below normalizes trailing whitespace only.

## First response, recovered without identity receipt

# Oracle Review



## Summary

This delta tightens the Step 5b delegated-child fences:

- **Child identity capture.** It records the child's identity (owner, tab, binding plus transition generation, `AgentSessionPersistenceState`, lane, parent) around the covering save, and checks it again after the link await and in every final dispatch predicate.
- **Cancellation.** It adds cancellation checks at link entry, after each new persistence await, before the service's start, and in the starter fence. Only the ordinary (non-Codex) submission predicate gets the new `!Task.isCancelled` check.
- **Fence release.** A one-shot release runs in a `defer` inside both `startRun` scopes, so work that inherited the TaskLocal can't arm the fence later.
- **Smaller fixes.** The revalidation closure now captures the view model weakly, the catch block's instrumentation matches its neighbours, and the store doc states the gate requirement.
- **Recovery list.** Rows are deduplicated per child, the full status goes in the existing View popover, and a parent row from another workspace says to open the parent instead of looking up the child here.

I found no P0/P1 regressions. The Codex bounded-ack driver still uses its explicitly captured fence without a cancellation check. Unlinked routes still return `nil` from `mcpDelegatedChildDispatchFence` / `mcpRequireDelegatedChildDispatchFence` and behave as before. No new identity, generation or registry was added.

## P2

### R1-B1 — Existing-tab targets can now fail closed if the covering save claims the lane
- **Evidence:** `MCPDelegatedChildIdentity.isContinued(bySaved:)` (`AgentModeViewModel+DelegatedChildLinks.swift`, about lines 116–128). When the child already had persistence state before the save, it requires `persistenceState == saved.persistenceState && lane == saved.lane`.
- **Scenario:**
  1. A routed `agent_run.start` with `tab_id` runs under a recovery-tracked parent.
  2. Admission is built whatever `resolvedTabID` is, and the existing-tab branch of `mcpResolveOrCreateSessionTarget` adds the parent.
  3. The target is a session hydrated from disk: it has persistence state but no lane yet.
  4. If the covering save is where its lane gets claimed (as the first save does in `persistAndClaimLane`), the check sees lane `nil → X` and refuses with "changed while it was being saved".
- **Why it's a regression:** The old `childIsCurrent` allowed this. The brief only traced the new-target creator, not the existing-tab branch.
- **Impact:** Fail-closed, so no wrong dispatch, but a workflow could break. Whether it's reachable depends on when a hydrated session claims its lane, which I can't see from the selected code.
- **Smallest fix:** In `isContinued`, accept `lane == nil && saved.lane != nil` when the persistence state is unchanged. Or confirm that hydration always claims the lane and add one existing-tab case to the tests.

### R1-B2 — The strict identity check is never run against the real configure step with a concrete provider
- **Evidence:**
  - `delegatedChildIsCurrent` compares the full `MCPDelegatedChildIdentity` after `mcpActivateControlContext`, `mcpConfigureSession(agentRaw:modelRaw:…)` and `bindCurrentRequestToTab` (`AgentExternalMCPRunStarter.start`, fence just before `dispatchInstruction`), and again in `mcpDispatchInstruction` / `isStillCurrent`.
  - The positive real-starter test (`testLinkedChildStartsOnceAndReleasedFenceIsNotArmedAgain` → `startChild`) passes `agentRaw: nil, modelRaw: nil`.
  - The service happy path (`testRecoveryTrackedParentStartCommitsChildAndLinkBeforeTheScopedStart`) uses a custom `startRun`, so configure, activate and bind never run.
- **Scenario:** If configuring a concrete provider or model touches any captured fact (binding transition, persistence state, lane), every delegated start under a tracked parent fails closed with "reset, rebound, or replaced".
- **Smallest fix:** Point the boundary happy-path test at the existing `productionStartRun(recordingInto:)` helper with an explicit `model_id`, or pass a real `agentRaw`/`modelRaw` in `startChild`.

## P3

- **Wording claims more than a link proves** (`recoveryDelegatedChildPresentation`, `countText`): "This run started a delegated session" / "started N delegated sessions". The function's own doc says a link is not proof the child started. "created" or "linked" would match the honesty contract.
- **The View popover repeats the inline text for a single child:** `detail` and `text` both contain the same line plus "never restarted". Also, the doc on `AgentRecoveryListRowProps.text` ("The original input (View), when the row is held input") is now out of date because run rows set it too.

Not re-raised: F5 (retention) stays deferred as you recorded. The other P2 dispositions (F1–F4, F6–F9) look correctly applied in the delta.

## Identity-verified receipt retry

# Oracle Review



# Step 5b R1 delta: regression re-review (receipt-retry)

I found no P0 or P1 regressions in the delta. Two new P2s and one P3 are listed below; per policy they are listed, not looped on.

## What the delta does

The delta tightens the delegated-child link in five ways:

- **Child identity is captured and re-checked.** `MCPDelegatedChildIdentity` captures the child's ownership facts: owner object, tab, binding, transition generation, `AgentSessionPersistenceState`, lane and parent. It is taken before and after the covering save, and re-checked after the link await, in `mcpRequireDelegatedChildLinkAdmissionCurrent`, and therefore in every final dispatch predicate.
- **Cancellation is rejected at more points.** The checks are at link entry, after each new persistence await, before the service starts the child, and at the linked starter's fence. The ordinary (non-Codex) `isStillCurrent` also refuses when the task is cancelled, but only when a fence exists.
- **The scoped fence is released once.** A `defer` inside both `startRun` scopes releases it, so later work that inherited the TaskLocal no longer arms it. A fence the Codex driver captured explicitly still runs its checks.
- **The revalidation closure captures the view model weakly,** and the catch block's instrumentation now matches its neighbours.
- **Presentation changes:** one status line and one Open per child session, the full status goes into the row's existing View text, and a parent row from another workspace says "open the parent to check" instead of looking the child up in the wrong workspace.

## Regression checks that held

- **Unlinked routes are unchanged.** In `mcpRequireDelegatedChildDispatchFence`, `guard let fence else { return }` comes before `Task.checkCancellation()`. In `mcpDispatchInstruction`, `guard let childLinkFence else { return true }` comes before `!Task.isCancelled`. An independent caller or a non-admitted parent therefore gets no new cancellation or identity refusals.
- **The Codex bounded-ack driver keeps its contract.** Its `isStillCurrent` is unchanged and still has no cancellation check. It checks the explicitly captured fence, which `isDispatchFenceReleased` does not affect because that flag only gates the TaskLocal lookup. So after "operation started", the driver is still neither cancelled nor withdrawn, and the deadline still produces the non-retryable uncertainty result.
- **Release ordering is correct.** The `defer` runs inside the `withValue` closure after `startRun` returns or throws, in both the DEBUG (nested OMP scope) and release branches. If the admission is nil, the release is a no-op.
- **Catch cleanup:** instrumentation is now recorded once before cleanup, and the cleanup flag changed from `true` to `false`, the same shape as the worktree-preparation and provider-start catches. The new `Task.checkCancellation()` after the link commit sits inside that `do`, so the target is discarded and the durable link is left unused, which matches the documented contract.
- **Durable link history is untouched.** Deduplication happens only in presentation (`seen.insert` filter), and the codec and store invariants are unchanged.
- The weak capture is correct, and a closed window now gives a clear refusal.

## P2

### R1-B-N1: `isContinued(bySaved:)` refuses a lane acquired by the covering save when persistence state already existed

**Evidence:** `AgentModeViewModel+DelegatedChildLinks.swift`, `MCPDelegatedChildIdentity.isContinued` (about L116–127):
```swift
guard let persistenceState else { return saved.persistenceState != nil }
return persistenceState == saved.persistenceState && lane == saved.lane
```

**Failure scenario:** a routed non-Knowledge `agent_run.start` is aimed at an explicit existing tab (the `.existingTab` origin). That tab's session already has persistence state but no lane yet, for example because a lane is only claimed on the first save after hydration, or its earlier lane was released. The covering save claims a lane, so the lane goes from nil to a new lane. The check then throws "changed while it was being saved" and the start fails closed.

**Impact:** a loud, recoverable refusal with nothing dispatched, so it fails safe. It only matters if hydration does not claim a lane, which I could not verify from these slices. The new-target creator (the traced path) is not affected.

**Smallest fix:** allow a lane to appear when there was none:
```swift
return persistenceState == saved.persistenceState && (lane == nil || lane == saved.lane)
```
Alternatively, confirm that hydration always claims the lane and leave the code as is.

### R1-B-N2: no test exercises the real submission path with the new child-identity predicate

**Evidence:** both new positive tests bypass the real path:
- `testLinkedChildStartsOnceAndReleasedFenceIsNotArmedAgain` uses a custom `dispatchInstruction`.
- `testRecoveryTrackedParentStartCommitsChildAndLinkBeforeTheScopedStart` uses a custom `startRun`.

Neither reaches `mcpDispatchInstruction` → `submitUserTurnAdmittingRecoveryInput` → `isStillCurrent`. The Codex driver's `isStillCurrent` is not reached either. Those predicates now also require `MCPDelegatedChildIdentity(child) == identity`.

**Failure scenario:** if mandatory admission for the child, or the submit path, changes any captured fact before calling `isStillCurrent`, every linked child start is refused after its intent is admitted. Examples would be a lane re-claim, persistence-state adoption, or a binding transition. I don't see such a change in the visible code, so this is a coverage gap, not an observed defect.

**Smallest fix:** add one positive case: real starter, no `dispatchInstruction` override, the noop Codex or Claude fixture already in the suite. Assert `.submitted` and exactly one handoff under a linked fence.

## P3

- **R1-B-N3:** `AgentComposerUIModels.swift`, the `AgentRecoveryListRowProps.text` doc comment ("The original input (View), when the row is held input.") is out of date now that run rows carry delegated-child status text there. Update the comment to cover viewable status text.

## Not raised

- When `persistenceWorkspace` is nil, every item that has a workspace ID is classed as "other workspace". That is the conservative direction: no Open action and a correct instruction, so it is not a defect.
- Durable links left behind by an after-link cancellation or reset are the documented "may remain unused, never replayed" behaviour.
