# 9-live fix 5 (Codex turn ID): OracleA review, round 0

Scope: read when the task touches how recovery identifies the interrupted Codex turn, the run attempt's provider turn ID, or the Codex history matcher's text.
Authority: Reference
Last-verified: 2026-10-28
Covers: the OracleA review (round 0) of the Step 5 diff, copied from its export; the fixes are in fix-9live-codex-turn-worker.md


## Verdict

**One P1 ordering issue to address before approval.** The diff otherwise adds appropriate user-kind and ownership guards and keeps persistence off the awaited event-handling path.

This review uses the supplied diff only; reported test results were not independently verified.

### P1 — Last write wins, but writes are not ordered by authoritative-turn installation

**Evidence**

- `CodexAgentModeCoordinator.recordCodexProviderTurn` creates an independent `Task { @MainActor … }` for each authoritative identity.
- `AgentRecoveryStore.recordRunProviderTurn` unconditionally replaces any different recorded ID. It has no authoritative-turn sequence check.
- `performRecoveryResumeAction` prefers that recorded value over the transcript span.
- The new liveness test waits until `"user-turn-1"` is persisted **before** installing `"user-turn-2"`, so it cannot catch competing writes.

Main-actor isolation prevents simultaneous execution; it does **not** guarantee that independent tasks enter the recovery lane in creation order. The lane’s serialization cannot correct submissions that arrive in the wrong order.

**Failure scenario**

1. User turn T1 becomes authoritative; its persistence task is scheduled.
2. An accepted steer installs T2; another persistence task is scheduled.
3. T2’s task reaches and completes the lane write before T1’s task.
4. T1’s later write overwrites T2.
5. After restart, recovery explicitly selects T1, although T2 was running at the kill.

Recovery can consequently import the older turn or use its completion to resolve the wrong interrupted run. This is a missing ordering guarantee, not a claim that reordering was observed.

**Smallest fix**

Chain these writes in authoritative-install order: each scheduled task awaits the preceding write’s completion before entering the lane. Establish the chain synchronously at installation, retain the existing ownership checks, and never await it from event handling.

Alternatively, atomically reject older authoritative-generation numbers in the store. Merely checking the current identity before an asynchronous lane call does not protect against changes during suspension.

**Required regression**

Use controlled barriers to keep T1’s write pending while T2 becomes authoritative—without first waiting for T1 to persist. Drain both writes, reload the record, and assert that recovery requests T2. Avoid timing-based sleeps.

### P2 — “Contains tool calls” asserts more than the observation establishes

**Evidence**

`CodexRecoveryAdapter.unusableObservationText` checks only whether `observation.turnID` exists:

```swift
observation.turnID == nil ? noMatchingTurnText : unsupportedTurnItemsText
```

That establishes “turn found,” not “tool calls found.” The updated reconciliation test explicitly expects the tool-call message for an observation with `items: nil`, without supplying a reason.

The report says missing/empty item arrays also produce this state; that parser implementation is not included, so that particular mapping remains unverified here.

**Failure scenario**

A matching interrupted turn has unavailable or empty items. Recovery tells the user it contains tool calls despite having no such evidence.

**Smallest fix / answer to the implementer**

**Yes, worth fixing cheaply, but not an activation blocker.** Use reason-neutral wording:

> Codex's record of the interrupted turn was found, but its items couldn't be imported; nothing was imported.

Keep `isUnconfirmedObservation: true`. If the exact tool-specific wording is required, carry an explicit unsupported-item reason rather than inferring it from a non-nil turn ID.

## Other requested checks

- **Compaction/review:** The explicit `.user` guard excludes both.
- **Wrong session/run:** The captured ownership, identity-attempt equality check, store ownership validation, and transcript-generation check provide visible safeguards. No contrary path is demonstrated by this diff.
- **Blocking/failing event handling:** The write runs in an unawaited task; a returned failure is logged rather than propagated into event handling.
- **Resend:** No new dispatch or resend path appears in this change. The unconfirmed-observation behavior remains unchanged.
- **Lookup:** Record-first with span fallback matches the plan, subject to the ordering defect above.

## Recommendations

1. Order persistence by authoritative-turn installation and add a deterministic overlapping-write regression.
2. Replace the unsupported-items message with reason-neutral wording.
3. Add a cheap lookup test with **conflicting recorded and span IDs** to pin record precedence explicitly.