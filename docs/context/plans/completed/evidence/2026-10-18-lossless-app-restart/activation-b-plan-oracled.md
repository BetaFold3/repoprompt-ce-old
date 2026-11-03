# Step 9-activation-b plan check — OracleD

Scope: read when the task touches Check confirming crash holds from process-registry proof (Step 9-activation-b).
Authority: Reference
Last-verified: 2026-10-27
Covers: OracleD's plan check of activation-b-design-worker.md: tightened proof, mark provenance, cuts, refusal texts and tests.

# Plan check — Step 9-activation-b (Check confirms crash holds from registry proof)

## Summary

The proposal is sound in shape: the only thing that makes a registry-backed confirmation safe is positive evidence that the held run's launches were registered (the run-start mark), plus a registry read that shows no non-terminal previous-instance process attributable to the session. Two things need tightening before it is implementable at full rigor (this is the one write that can re-admit sends into a worktree a stray process may still be editing): (a) the safety half of the registry query is scoped too narrowly (by the run's `appInstanceID` and by exact session+incarnation association) and should be generalized to "any non-terminal previous-instance record that could belong to this session", which is both simpler and stricter; and (b) the mark's provenance is left undefined ("launch authority is `.registry`") — it must be derived from the launcher's resolved authority for that spawn, by one helper, with tests that prove it is absent when activation is off or the provider is uncovered. All three proposed cuts are right; I recommend cutting condition 2's intent/instance logic entirely (subsumed by the first cut) and not deferring the header wording.

## Current-state analysis (what the proof rests on)

- Hold derivation: `deriveCrashHolds` (`AgentRecoveryCoordinator.swift:962-991`) from open run attempts, earlier-instance uncertain intents, legacy turns. Confirmation = exact acknowledgement (`AgentRecoveryCrashHold.isCovered(by:)`, `:375`), re-applied at startup (`:929-933`). The acknowledgement never closes a run or settles an intent — confirming only lifts admission (`admissionRefusal` → `blockingCrashHold`, `:1512`) and the workspace-busy extension (`unresolvedSessionSummary`, `:1503`).
- Evidence available today: `AgentRecoveryRunAttempt.appInstanceID` + `providerKind` extra (`AgentRecoveryStore.swift:1198-1207`). Nothing says "this run's spawns went through the registry". Registry records: one per spawn, associations carry `(sessionID, incarnationID, generation, runAttemptID?, processRunID?)`; `runAttemptID` can be merged in late (`AgentProcessRegistry.swift:851-890`), and `.exited/.stopped` records are never re-examined (`:316-320`) and never appear in `restrictionSnapshot()` (`:100-152`).
- Only write path today: `confirmCrashHold(hold, lane:)` → `lane.recordCrashHoldAcknowledgement` → `store.recordCrashHoldAcknowledgement` (`AgentRecoveryStore.swift:1570`), which revalidates binding incarnation/generation and that every named run attempt and intent still exists. A lane-free write already exists for Dismiss: `acknowledgeClosedCard` via `dataService.performClosedRecoveryTransaction` (`AgentRecoveryCoordinator.swift:874-900`).
- Check today (`+Check.swift`): crash-hold items fall through `checkOutcome(of:)` to `current.checkOutcome(unresolvedRun:)` → `.needsYou("Confirm the previous run stopped")` (`:351` guard, `:410`). Stop semantics assume the only started work is a Reconcile (`reconcileStarted`, `:40`, `:239-262`).
- Invariant worth stating explicitly in the brief: `.exited` is set only by a discovery pass proving the tree gone and is never reverted; therefore a stale registry read can only cause a false *refusal*, never a false confirmation. The proof's soundness then rests on exactly two things: every spawn of the held run has a record (the mark + launch authority), and the record's `.exited` is trustworthy (activation's `completeDiscovery`/`markerPropagation` claims, owned by 9-live, not this step).

## 1. Is the proof sufficient and necessary?

Sufficient only with the fixes below; conditions 1, 3, 6, 8 and the "mark required, no fallback" rule are correct and necessary.

**F1 — P1 — Safety condition too narrowly scoped (`activation-b-design-worker.md` §2 item 4; `AgentProcessRegistry.swift:851-890`, `AgentRuntimeRecordModels.swift:87`).**
Item 4 requires that "every record from the run's `appInstanceID` associated with this session and incarnation" be terminal. Two realistic gaps:
- A spawn for this session whose association was reserved without a session (conversation- or worktree-only keys, or sessionless) and whose session association was to be merged later, exactly as `runAttemptID` is merged late in `merge(_:into:)`. Such a record is non-terminal, from the crashed instance, and invisible to item 4. Whether condition 5 catches it depends on what `sessionOwnershipKeys(sessionID)` matches and whether a sessionless previous-instance writer raises `hasGlobalUncertainty` — neither is visible in the cited code.
- A non-terminal record naming the session under a *different incarnation* (session reset after the run started, record from an older instance). Same dependency on condition 5.
Impact: a confirmation while a possible writer for the session's conversation/worktree is alive.
Smallest fix: make the registry query's safety half independent of condition 5: refuse if any record with `appInstanceID != current` is non-terminal (not `.exited`/`.stopped`) and either (i) has an association naming `sessionID` at any incarnation, (ii) has any association with `session == nil`, or (iii) shares any of the session's conversation IDs or worktree paths (the query takes those as inputs, from `reconciliation.resolution(for:)`). Keep condition 5 as belt-and-braces. This is strictly stronger and removes the `appInstanceID`-per-run and mixed-instance special cases (see F4).

**F2 — P1 — The mark's provenance is undefined (`AgentRecoveryCoordinator.swift:3003`, `AgentRecoveryStore.swift:1207`).**
"Stamped … only when launch authority is `.registry` and `coversProvider` is true" names a predicate but not who evaluates it. The mark is the single piece of evidence that turns "registry is empty/terminal" into "every process exited"; if any creator of a run attempt computes it from `AgentRecoveryActivation.production.coversProvider(provider)` while the launcher actually routed that spawn through an unregistered path (different family for the provider's mode, a non-managed launcher, the `.off` activation), the proof is false. `ensureRunAttempt` records extras "only when this write creates the attempt", and there are several creators (dispatch path, `attachDeliveryAttempt`, Codex `observeRecovery`-adjacent paths).
Smallest fix: one helper that returns the run-start extras from the *launcher's resolved authority for this run* (the same object the registry-backed launcher consults, not a re-derivation from `production`), passed by the creator that precedes the first spawn; every other creator passes `nil`. Tests: activation `.off` → no mark; activation `.claudeAndCodex` with an uncovered provider/mode → no mark; covered → mark; a second `ensureRunAttempt` on an existing attempt never adds or removes it. Also validate the ordering: if for some provider the attempt is created only after the first spawn, a crash in between leaves no attempt (hold from the intent instead) → refused under the intent cut; that is conservative and fine, but the brief should name it so nobody "fixes" it by stamping late.

**F3 — P2 — `.stopped` accepted as terminal without a stated guarantee (`AgentProcessRegistry.swift:316-320`).**
Discovery skips `.exited` and `.stopped` alike, but the cited code doesn't show that `.stopped` is written only after a verified tree exit (vs. "stop requested"). If it is the latter, accept `.exited` only. Validation: read the stop entry point's state transition; add a test with a `.stopped` record whose members are still in the inventory and assert refusal (or that the state can't arise).

**F4 — P2 — Mixed-instance refusal makes the feature permanently dead for a session after any second crash (`AgentRecoveryCoordinator.swift:962-991`).**
Confirmation never closes run A; after the user continues and the app crashes again, every later hold is {A, B} with different `appInstanceID`s and the design refuses forever. With F1's generalization (safety over *all* previous-instance records; completeness per held attempt: a previous-instance record names it and that attempt carries the mark), mixed instances need no special case. Drop condition 2's instance logic.

**F5 — P2 — Stop semantics don't cover the new write (`+Check.swift:40-44`, `:239-262`, `:289-291`).**
The crash-hold branch runs in the item's unstructured task. With the design as written: `reconcileStarted` stays false, so Stop reports "Stopped before checking this item" while the confirmation may still commit and re-admit sends; and nothing sets `.working` on the row, so a concurrent "It stopped"/Dismiss from a window isn't refused as busy (it is only caught by the revision conflict). Fix: rename `reconcileStarted` → `workStarted` and mark it in the crash-hold branch before its first suspension; set `.working` on the item for the duration (cleared in `defer`), so the existing Stop cleanup at `:258-260` applies; and before the commit begins (after the last re-check), refuse with `couldNotCheck("Stopped before confirming.")` if `recoveryCheck?.cancelRequested == true` or the wait is finished. A commit already in flight is allowed to finish (same as Reconcile).

**F6 — P2 — Authorization text (`+Check.swift:143-149`, `:1-21`; synthesis "Check and resolve").**
The settled constraint is that the user is told what Check may clear. The header says "Checks process ownership and provider history. Clearing a restriction may let already-authorized scheduled sends run." A confirmed hold additionally lifts admission on the held session itself, so a schedule *on that session* may fire. Don't defer: change the header to name crash-hold confirmation ("…and confirms a paused session stopped when process records prove its processes exited. Clearing a restriction or confirming a paused session may let already-authorized scheduled sends run."), and update the file header comment at `:17-19`, which currently states Check never confirms a crash hold. Validate where `headerText` is displayed — if only in the post-run report, the sheet's pre-run text must carry the same sentence (that is the actual authorization moment).

**F7 — P2 — Closed-session write path details (`AgentRecoveryCoordinator.swift:874-900`, `:1553`).**
- `performClosedRecoveryTransaction` needs `resolution.workspace`; a hold whose session has no workspace resolution (workspace failure, nonactionable) must refuse with a named reason ("Open this session to confirm it").
- The retry-on-`revisionConflict` loop must re-run the currency checks (hold unchanged, not busy, not cancelled) between attempts; `recordCrashHoldAcknowledgement` only revalidates existence of the named attempts/intents, not the user-visible state. Bound to 3 like `acknowledgeClosedCard`.
- Post-commit publication must be identical to `confirmCrashHold(hold, lane:)`: extract whatever `:1553` does after the lane write (update `confirmedCrashHolds`, `postCoordinatorDidChange()`, any `requestIndexedScheduleRefresh`/scheduler wake) into one shared function used by both paths. Validate by reading `:1553-1600`.
- A lane that exists but whose `binding.incarnationID` differs from the hold's → refuse "changed" (don't fall through to the closed path).

**F8 — P3 — Identity and staleness details.**
- Validate that the registry's `store.appInstanceID` (`AgentProcessRegistry.swift:124`) and the recovery store's `appInstanceID` are the same value; if not, the "previous instance" test misclassifies (safe direction — everything refuses — but the feature is dead). One test with both stores.
- Condition 5 reads the adopted `runtimeRestrictions`, which lag the registry via the change handler; the query may read "exited" while the snapshot still restricts → refusal that passes on the next Check. Acceptable; name it in the refusal text ("process ownership is still being updated") and in a test.
- Record file deletion by external interference can hide a spawn (only contrived; fits "unidentified" when corrupted, but not when deleted). Not worth guarding; note as accepted.
- Extras value: store a string (e.g. `"registry"`) rather than a bool so a later authority kind can be distinguished without a schema change.

**Current-instance exclusion (item 4 note):** correct and necessary — Codex `observeRecovery` associates the held attempt with a current-instance record (`CodexAgentModeCoordinator.swift:4759`), and current-instance processes cannot be the crashed run's. With F1 the exclusion is simply "`appInstanceID == current` records are ignored for the safety half, and don't count for the completeness half".

**Races:** session opening mid-check is handled by `performClosedRecoveryTransaction`'s gate; a new run can't start on the session while the hold is unconfirmed (admission), so the hold is its own lock; concurrent "It stopped" writes an identical acknowledgement (unchanged); concurrent Dismiss changes the card acknowledgement → re-check 6 refuses or the revision conflict retries into the re-check. No gap found beyond F5.

## 2. Cuts

Agree with all three: holds with uncertain intents (an intent without a marked run attempt could have spawned under no mark; the intent card stays needs-you either way, so nothing is lost), `toolsRemaining` (tools write), and any no-mark fallback (an empty registry proves nothing before activation — this is the whole premise).

Also cut:
- Condition 2's intent/instance logic entirely (subsumed by the intent cut and F1/F4): the hold must have ≥1 run attempt, no intents, no legacy turns; nothing else.
- Per-run-`appInstanceID` scoping of the registry query (F1): "previous instance" is the only partition needed.
- The separate `unpersisted` clause: previous-instance records come from disk, so `unpersisted` can only hold current-instance records; keep it only as part of the generic "registry healthy" precondition (started, no `storageFailure`, `unidentifiedRecordCount == 0`, no `preserved` record naming the session) rather than as a session-specific rule.
- Any new refusal taxonomy beyond one `needsYou` string with a parenthesised reason; reasons are a fixed small set (see §3).

Keep (not cuttable): the lane path reuse, the closed path, condition 5, re-check after every await.

## 3. What the brief must add

**Ordering / landing:**
1. Store + `ensureRunAttempt` run-start parameter + the one provenance helper (F2) + creator-site audit + tests. Independent of activation; must ship no later than 9-flip or the first post-flip runs simply refuse (acceptable, but say so).
2. Registry query (actor method) with F1 semantics + tests (fixture registry states).
3. Coordinator: shared post-commit publication extracted from `confirmCrashHold(hold, lane:)`; closed write; `confirmCrashHoldFromRegistryProof`; `.crashHold` branch in `checkOutcome` placed before the `isRunCard` guard at `+Check.swift:351` and after the `checksActive` and `isDismissed`/`automaticClear` checks; Stop changes (F5). Land 3 atomically with the `+Check.swift` header comment and `headerText` change (F6).
4. Docs: the design doc's §2 rewritten to the generalized proof; plan status line.

**Refusal texts (fixed set, all `needsYou("Confirm the previous run stopped (<reason>)")`):** "it started before process checks were active" (no mark); "no process record names this run" (completeness); "an agent process may still be running" (any non-terminal previous-instance record per F1, incl. `toolsRemaining`, `detachedAtQuit`, `unknown`); "process ownership is uncertain" (storage failure, unidentified/preserved, condition 5); "it has a saved message or an older interrupted turn" (intent/legacy cut); "it changed since the check started" → use the existing `couldNotCheck` wording; "another action on this session is in progress" → `couldNotCheck`; "open this session to confirm it" (no workspace resolution). Success: `.resolved("Process records show every process of the interrupted run exited.")`. Write failure: `.failed("The confirmation couldn't be saved.")`. Stopped before commit: `.couldNotCheck("Stopped before confirming.")`.

**Tests beyond the design's list:**
- Mark provenance (F2): off/uncovered/covered; non-creating `ensureRunAttempt` never alters it; two stores agree on `appInstanceID` (F8).
- F1 table: live previous-instance record that is sessionless; one that names the session at another incarnation; one sharing only the worktree; one sharing only the conversation — each refuses even when the adopted snapshot would not restrict the session.
- Current-instance live record naming the held attempt (Codex observeRecovery shape) → still confirms when all previous-instance records are terminal; a hold whose attempt is named *only* by a current-instance record → refuses (completeness must be previous-instance).
- Mixed-instance hold {A from instance 1 marked, B from instance 2 marked}, all records terminal → confirms (F4).
- Stop before commit → no acknowledgement written, row cleared of `.working`, text "Stopped before confirming." (F5); Stop after commit started → commit lands, report says abandoned.
- Concurrent Dismiss between re-check and commit (revision conflict) → retry re-checks and refuses "changed" with no write.
- Snapshot lag: registry terminal, adopted snapshot still restricting → refuses; after adoption → confirms (F8).
- Closed-session confirm, then re-startup: hold covered, admission open, no second ask; schedule on the held session dispatches once only after commit (extend `testCrashHoldBlocksNewSessionSendNowUntilItStoppedThenDispatchesOnce`).
- `.stopped` semantics per F3 outcome.
- Header text contains the crash-hold sentence; `+Check.swift` comment updated (doc-only, no test).

## Recommendations

1. Approve the step with the proof restated as: (a) checks active and registry healthy; (b) hold = run attempts only, each carrying the run-start mark; (c) for each attempt, a previous-instance record names it; (d) no non-terminal previous-instance record names the session (any incarnation), is sessionless, or shares the session's conversation/worktree; (e) adopted snapshot agrees; (f) hold unchanged, not busy, Check not stopped — re-checked after every await and before commit.
2. Fix F1 and F2 before writing code (both are design changes, both shrink the design); treat F3 as a validation gate on `.stopped`; fold F5–F7 into the brief as specified; F8 items are validations and tests.
3. Accept all three proposed cuts plus the extra cuts in §2; do not defer the header wording.
4. Land in the order above; step 1 may land ahead of 9-flip, step 3 must not land before step 2 and must land with the comment/header change.
5. Record under `assumed:` that `.stopped` is verified-terminal pending F3, and that `completeDiscovery`/`markerPropagation` soundness is owned by 9-live, not this step.
