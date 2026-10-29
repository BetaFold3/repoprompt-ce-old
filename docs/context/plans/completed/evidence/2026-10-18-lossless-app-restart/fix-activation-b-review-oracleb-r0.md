# Step 9-activation-b review round 0: OracleB

Scope: read when the task touches crash-hold confirmation from process-registry proof, the run-start registration mark, or Step 9-activation-b of the lossless app restart plan.
Authority: Reference
Last-verified: 2026-10-27
Covers: OracleB round-0 review

# Step 9-activation-b review, round 0: Check confirms a crash hold from process-registry proof



## Summary

This step lets Check and resolve confirm a crash hold ("Sending paused") when process records prove every process of the held run exited:

- **Run-start mark.** A mark (`runtimeRegistration = "registry"`) is captured on `AgentRunOwnership` at run start. `AgentRuntimeLaunchAuthority.runStartRegistrationMark` derives it, and only the two run-start dispatch creators persist it. The terminal, shutdown and child-link writers pass `nil`.
- **Registry query.** A new actor query, `crashHoldExitProof`, applies the F1-generalized safety half (any earlier-launch, non-terminal record that names the session, names no session, or shares its keys). It also checks a completeness half: each held attempt must be named by an earlier-launch record.
- **Coordinator path.** `confirmCrashHoldFromRegistryProof`:
  - refuses unless the hold is run-attempts-only and every attempt carries the mark;
  - sets `.working` and `workStarted` before its first suspension;
  - checks the adopted snapshot (F8 lag);
  - writes the exact acknowledgement through the live lane or the closed-session gate, retrying a revision conflict up to 3 times with re-checks;
  - publishes through one helper shared with "It stopped".
- **Text.** The header, help and new pre-run notice name crash-hold confirmation (F6).

The design meets Recommendation 1 and F2–F8 in substance. I found no P0 or P1. The remaining items are a dependency that breaks landing this step on its own, two places where code and comments claim more than they do, a few soundness hardening/validation gaps, and test gaps against the plan's list.

## Findings

### P2

**A1 — The new file depends on the out-of-scope deletion change, so this step won't build if committed alone**
- **Where:** `AgentRecoveryCoordinator+CrashHoldProof.swift:141` (`!deletedSessionIDs.contains(hold.sessionID)`).
- **Scenario:** `deletedSessionIDs`, `noteSessionDeleted` and `retireStartupState` belong to the other worker's F8 deletion hunks, which aren't in `actb-r0.diff`. Following the review policy ("stage only this step's hunks"), the staged step fails to compile.
- **Impact:** The commit workflow breaks, or the step has to be committed together with unreviewed work.
- **Smallest fix:** Drop the clause. It's redundant: `retireStartupState` already clears `crashHolds[sessionID]`, so `crashHold(for:) == hold` fails after a deletion. Otherwise, record a landing-order dependency on the F8 change in the status line.

**A2 — "Stopped before confirming." never reaches the user through Check, and the report text is wrong in that case**
- **Where:** `+CrashHoldProof.swift:137-138` and `+Check.swift:~269-283`, `:153`.
- **Scenario:**
  - Stop always finishes the wait first. The confirmation's own `.couldNotCheck(stoppedBeforeConfirming)` is therefore always a discarded late result; it is only visible on a direct call, which is how `testStopBeforeTheCommitWritesNothing` asserts it.
  - The report instead shows `abandonedText`: "Stopped while checking. Its check continues; the card shows the result."
  - When Stop lands before the commit, nothing continues and no result follows.
- **Impact:** Misleading report wording at the moment the user stopped a write that can re-admit sends. It also departs from F5's test-list expectation.
- **Smallest fix:** Pick one:
  - Use wording that is true on both sides of the commit for crash-hold items, e.g. "Stopped while confirming. If it was saved, sending resumes on its card." Select it via an `AgentRecoveryCheckItemWait` flag set by the crash-hold branch.
  - Or state in the plan that the late text is internal only, and drop the claim from the doc comment at `:44-47`.

**A3 — Check (e) isn't re-checked before the commit, although the header says everything is**
- **Where:** `+CrashHoldProof.swift:3-5` (the comment says "(all must hold, re-checked after every await and before the commit)") versus `:94-98`, which runs once before the loop. The loop at `:101-106` re-checks only (f) and the write destination.
- **Scenario:** `runtimeRestrictions` can gain global uncertainty or a send restriction while the code is suspended at the test hook, at a retried commit, or across revision-conflict retries. The commit then proceeds anyway.
- **Impact:** Low. Earlier-instance records can't leave `.exited`/`.stopped`, so the registry proof stays valid. Still, the code doesn't do what its own contract says.
- **Smallest fix:** Move the two synchronous (e) checks into the loop next to `crashHoldCheckRefusal`. That is cheap and makes the header true. Alternatively, narrow the comment to "(e) once, (f) before every commit attempt".

**A4 — F2 partly met: the mark is derived from a parallel copy of the launch authority, not from the launchers' resolved authority**
- **Where:** `AgentTabSession.swift:~829-832` (`runtimeLaunchAuthority = .production`, "they default to the same `.production` value; tests inject both"), `:~2012-2016`, and `AgentRuntimeLaunch.swift:~115-126`.
- **Scenario 1 — divergence:** `session.runtimeLaunchAuthority` and the launchers' authority are separate stored values that agree only by convention. Two ways they can split:
  - Composition injects a different authority into the launchers.
  - `.production` becomes runtime-togglable after 9-flip, and it flips from on to off between run start and spawn.

  Either way, the run gets `"registry"` while its spawn ran unregistered. The empty or terminal registry then "proves" exit. This is the one false-confirmation path.
- **Scenario 2 — unsupported families:** `serving` only considers `AgentRuntimeQualification.supportedPairs`. If any *unsupported* family can serve the provider (a fallback route), the mark is still stamped.
- **Impact:** Latent today: activation is `.off` and both values default to `.production`. It is a correctness trap for 9-flip.
- **Smallest fix:**
  - Give the session one authority that its managed launchers read (or have the launchers expose the authority they resolved), so the mark and the spawn can't disagree. In tests, inject it once.
  - Assert in a comment, plus a one-line test or precondition, that no family outside `supportedPairs` can launch a covered provider.

**A5 — The session's touched keys ignore record-level keys of records that name the session**
- **Where:** `AgentProcessRegistry.swift:~169-172`.
- **Scenario:**
  - `conversations` and `worktrees` are widened only from `association.conversationID` / `association.worktreePath`.
  - Suppose a record names the session but its association lacks `worktreePath`, while the record-level `worktreePaths` has it (for example, keys set at reservation and the session association merged later).
  - Then a live earlier-launch record of another session sharing that worktree isn't caught.
  - For a closed session, `query.worktreePaths` is empty (no window hosts it), so check (e) doesn't catch it either.
- **Impact:** The kind of confirmation F1 exists to prevent: a possible writer in the same worktree. The tests always seed identical association-level and record-level keys, so this gap is untested.
- **Smallest fix:** For every record with an association naming `query.sessionID`, also union `record.conversationIDs` and `record.worktreePaths`. Alternatively, have the coordinator pass the session's worktree and conversation from `reconciliation.resolution(for:)`, as F1 suggested.

**A6 — F4 is validated only with seeded records, not across a real intermediate launch**
- **Where:** `AgentRecoveryCrashHoldProofTests.swift` `testMixedInstanceHoldIsConfirmed`.
- **Scenario:** The test seeds run A's and run B's records directly into the final launch's root. In practice, launch 2's registry ran its startup and discovery over run A's records. If any launch prunes or compacts `.exited`/`.stopped` earlier-instance records, a later launch finds no record naming A, the result is `.runNotRecorded`, and the feature is dead for that session after a second crash. That is the exact failure F4 was meant to remove.
- **Smallest fix:** Point to the code showing that terminal earlier-instance records are retained across launches. Or extend the test so launch 2 starts a real registry (`startedCoordinator(second, …)`) before run B is opened.

**A7 — Test gaps against the plan's list (some confirmed by the worker)**
- **Revision-conflict retry:** `testCardChangedBeforeTheCommitRefusesWithoutWriting` dismisses *inside the hook, before the re-check*, so it exercises re-check (f), not the `.revisionConflict` → `continue` → re-check path at `:120-121`. On the closed path, `currentRevision` is read inside the gate, so a conflict needs interleaving inside the store. Either test the branch with a store stub, or say it is effectively unreachable.
- **Busy refusal** (`hasRecoveryActionHold`), **write failure** (`.failed(saveFailed)`), and a **`toolsRemaining`** earlier-launch record (should give `mayBeRunning`): none are tested.
- **Schedule after commit:** the plan item "schedule on the held session dispatches once only after commit (extend `testCrashHoldBlocksNewSessionSendNowUntilItStoppedThenDispatchesOnce`)" is missing. This is the user-visible consequence the header warns about.
- **F8 agreement:** the claim that the production registry and coordinator share `AgentRecoveryStore.production` has no test. Only the mismatch refusal is tested. One composition-level assertion would pin it.

### P3

**A8 — Stop releases `.working` while a commit may still be in flight**
- **Where:** `+Check.swift:~280-282` with `+CrashHoldProof.swift:70-75`.
- **Scenario:** After Stop, the row is no longer busy, so a second Check can be started immediately. It runs the proof concurrently with the first one's in-flight write. Both write the identical acknowledgement; the second then reports "It changed since the check started" once the first publishes.
- **Impact:** Harmless but confusing.
- **Fix:** For crash-hold work, leave `.working` cleanup to the work's own `defer`: drop the `!wait.isFinished` condition, keeping the `== .working` check.

**A9 — `testStopAfterTheCommitStartedLetsItLand` depends on main-actor scheduling order**
- The cancel is enqueued with `Task { @MainActor … }` and must run after the synchronous re-checks but before the commit's first suspension.
- If `await test_crashHoldProofBeforeCommit?()` ever hops on return, the test flips to "stopped before confirming" and `waitUntil` times out.
- **Fix:** Add a second DEBUG hook that runs inside the commit (after the re-check), or press Stop from a store-side suspension.

**A10 — Minor duplication and hygiene**
- The captured-card equality check is done twice: `+Check.swift:~366-368` and again in `crashHoldCheckRefusal`. The first can go.
- `confirmCrashHoldFromRegistryProof` relies on its caller for "checks active" (proof condition (a)) but is callable internal API. Add a `checksActive` parameter or a doc precondition.
- The reflowed doc line in `waitForCheckOutcome` (`+Check.swift:~302`) exceeds the file's comment width.

## Recommendations

1. **Approve the design for this step.** The proof matches Recommendation 1 (a)–(f). F3 is settled by `AgentProcessRegistry.swift:~1105-1112`: `.stopped` is written only after a complete fresh inventory shows nothing alive. No P0 or P1 is open.
2. **Fix the cheap P2s before commit:**
   - A1: drop the redundant `deletedSessionIDs` clause so the step builds alone.
   - A3: move (e) into the commit loop.
   - A5: union record-level keys of records that name the session.
   - A2: choose Stop wording that is true either side of the commit.
3. **A4:** fix now by giving the session and its launchers a single authority source. If deferred, record under `deferred:` with an explicit gate: it must be resolved before 9-flip, along with confirming that no unsupported family can launch a covered provider.
4. **A6:** answer with a code pointer showing terminal earlier-instance records are retained across launches, or extend the mixed-instance test with a real intermediate launch.
5. **A7:** add the busy, write-failure, `toolsRemaining` and schedule-dispatch-after-commit tests. Either exercise the revision-conflict branch or mark it unreachable.
6. **Status line:** record under `assumed:` that `.exited` soundness (`completeDiscovery`/`markerPropagation`) is owned by 9-live. Record the P3s (A8–A10) under `deferred:`.
