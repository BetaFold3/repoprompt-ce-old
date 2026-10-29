# Shutdown admission and clean-exit boundary decision

Scope: read when the task touches the R4 shutdown admission seal or delayed clean-exit acknowledgement.
Authority: Reference
Last-verified: 2026-10-21

Planning consultation, not an independent review round. OracleA preset identity verified (`61D024A4-CCFB-4C9C-A614-CC65E0A1864C`), continuing chat `restart-phase-1-scope-an-DABF9B`. Main adopts pre-admission refusal and distinguishes delayed acknowledgement from actual preservation failure; no owner exception for false-clean termination is assumed. The recommended boundary is implemented and both independent re-review rounds are complete; no P0/P1 remains. Live acceptance is still pending.

# Oracle Plan

## Summary

**Seal application-window admission at the point of no return, before any clean authorization.** A later SwiftUI window may exist as an inert shell, but must not enter `allWindows`, consume restoration state, accept input, or become an application participant. This removes the concrete invalidation race instead of attempting to undo an atomic replacement already executing.

Keep the existing coordinator, store, and clean gate. A delayed clean write whose complete preservation proof remains valid is different from an obsolete clean write.

## Current-state analysis

The current registration order admits the newcomer too early:

`allWindows.append → participantRegistered → restore/listeners/layout persistence`

Freezing it after insertion prevents input but does **not** preserve its newly admitted layout. Consequently, `lateParticipants` correctly invalidates the current proof—but `revoke()` cannot stop `writeAtomically` once `begin()` succeeds.

The second-Quit-Anyway escape then permits termination despite an unconfirmed correction. Its warning also contradicts the environment’s unconditional claim that quitting “marks this exit as interrupted.”

No cancellation token can repair this persistence limitation.

## Design

### 1. Make registration an admission decision

Add a synchronous coordinator query used **before `allWindows.append`**, with these outcomes:

- **Admit:** no app quit, or app quit remains in Stage A.
- **Refuse during termination:** app quit has crossed its point of no return.

Stage A admissions retain the current behavior: synchronously freeze, join participants, invalidate the preparation snapshot, and require Retry or Cancel.

At the point of no return, latch application admission closed **synchronously on the main actor**, before calling `beginIrreversible`. Keep it closed through Stage B failures, retries, completion, and the interval before process exit. Do not derive this solely from `!request.isFinished`.

For a refused window:

- Do not append to `allWindows`.
- Do not notify successful window-open waiters.
- Do not install persistence/focus/workspace listeners.
- Do not consume `restoreQueue` or `pendingURLs`.
- Do not attach scheduler hosts, claim recovery lanes, hydrate sessions, or enable editing.
- Show an inert “RepoPrompt is quitting” shell, or dispose of that unadmitted shell through existing window plumbing. Do not run session teardown for it.

No deferred-window queue is needed: Stage B cannot return to normal operation. Existing window-close-only requests do **not** seal application-wide admission.

**Required boundary validation:** registration must precede activation, not merely restoration. If `WindowState` initialization or its SwiftUI task currently performs those effects earlier, move those existing activation calls behind the registration result. Do not label a window “unadmitted” after it has already accepted input or claimed ownership.

This is not a clean proof over a subset: **every admitted application window remains covered; rejected window creation never becomes application state.**

### 2. Preserve a stable clean proof

Immediately before authorizing clean exit, retain the existing checks:

- all admitted participants passed preparation;
- teardown and terminal work completed;
- final transcript/recovery flushes succeeded;
- layout preservation succeeded;
- no unfinalized window close exists;
- authorization occurs before the absolute deadline.

The admission seal then prevents this particular proof from becoming obsolete.

Keep `AgentRecoveryCleanExitGate`’s start-of-write fence. Do not change its documentation to imply it can revoke an executing replacement.

Distinguish two outcomes:

**Actual preservation failure or changed admitted state:** no valid clean proof. Revoke unstarted authorization; an executing obsolete clean write requires confirmed correction.

**Only the clean-write acknowledgement exceeds the deadline:** all preservation work already succeeded and remains frozen. The timer ends the attempt and presents Stage B actions, but it does not establish unsaved data or invalidate that proof. Keep ownership of the write. Retry joins it before initiating another write; Quit Anyway may terminate without waiting beyond the bounded attempt:

- If clean committed, the preserved-state claim is true.
- If it did not, the previous unclean mark remains conservative.

Do not enqueue an unclean correction merely because this final acknowledgement was late. No automatic completion occurs after timeout; the user still chooses Retry or Quit Anyway.

Also fix the directly relevant existing omission: `runPreparation` currently discards the outcome of `recordLaunchState(.shutdownInProgress)`. **Await and check it within the same deadline before crossing Stage A.** Otherwise an unclean baseline is not actually established.

### 3. The unavoidable contract limit

For the stated newcomer case, refusal before admission resolves the problem without sacrificing typed input. The rejected window’s new layout is not saved because its creation was refused; previously durable sessions remain untouched.

For a **genuine invalidation after clean replacement begins**, these three requirements cannot all hold under failed/stalled correction:

1. guaranteed unclean disk state;
2. unconditional bounded Quit Anyway;
3. no additional durable mechanism.

A second confirmation cannot change that fact.

**Recommended owner-dependent fallback, only if this remains reachable:** preserve the no-false-clean requirement and do not authorize termination until correction is confirmed; each Retry remains bounded, without a hanging wait. This necessarily limits Quit Anyway in that exceptional condition.

The alternative requires an explicit owner exception allowing termination with potentially misleading clean state. Do not adopt the current second-click override as an implementation assumption.

Likewise, if R4 is intended to require an unclean mark for **every final-write timeout even when preservation is complete**, that literal requirement conflicts with bounded unconditional termination. Recommend the narrower distinction above: timing failure alone is not uncertainty about already-preserved sessions. Record the interpretation in evidence, not as an owner Decision.

## File-by-file impact

- **`App/AgentLifecycleShutdownCoordinator.swift`**
  - Add the persistent post-point-of-no-return registration seal.
  - Replace normal late-participant handling with pre-admission refusal.
  - Separate preservation-proof invalidation from clean-acknowledgement timeout.
  - Await the Stage A launch-mark result.
  - Remove the second-click correction bypass unless explicitly authorized.

- **`App/WindowStateManager.swift`**
  - Check registration admission before insertion or side effects.
  - Return an explicit result to the window activation caller.
  - Preserve existing admitted-window enumeration and layout semantics.

- **`WindowState` / existing SwiftUI activation caller**
  - Gate existing initialization effects on successful admission, only where currently necessary.

- **`App/WindowStatesManager+LifecycleShutdown.swift`**
  - Make alerts truthful: distinguish incomplete preservation, unconfirmed correction, and delayed clean acknowledgement. Never promise an unclean mark without evidence.

- **`AgentRecoveryStore.swift`**
  - No new persistence format or replacement protocol.

## Implementation order and focused tests

1. **Admission boundary:** gate clean replacement, register a newcomer, and verify no participant/layout/restore/lane/input effects. Release the write: clean remains justified.
2. **Stage A arrival:** admit a newcomer before sealing; the old attempt cannot cross the boundary. Retry covers it; Cancel restores usability.
3. **Delayed clean only:** expire the original deadline while replacement is gated. Verify no corrective write, no automatic late termination, bounded user response, and no duplicate finalization.
4. **Failure boundary:** failed Stage A launch mark prevents teardown. Inject genuine proof invalidation and failed correction; verify no second-click termination bypass under the recommended strict fallback.

Use fixtures only. No additional review round or live lifecycle action is implied.

## Recommendations

**Reject late window admission rather than trying to correct clean state afterward.** Keep the admitted participant set sealed until exit, distinguish delayed acknowledgement from invalid preservation, and obtain an owner decision only if unconditional Quit Anyway must override an uncorrectable false-clean condition.
