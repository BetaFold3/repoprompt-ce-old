# Phase 1b foundation final re-review — OracleB

Scope: read when the task touches lossless restart lifecycle foundation final re-review evidence.
Authority: Reference
Last-verified: 2026-10-21

Preset identity verified: `7CDD523E-1D7C-47EA-98FE-D5FEA24D2D8C` (OracleB). Round 2/2; independent code inspection, supplied validation.

# Lossless restart Phase 1b foundation: re-review, round 2 of 2

**Summary.** This round makes three fixes, and I traced each one:

- **R1-A is fixed.** `canonicalMetadataFolderKey` and `canonicalSessionFileKey` now share one helper, `resolvedExistingDirectoryKey` (DataService, around line 883). It resolves a directory with `realpath`, and covers the index cache, reconciliation tasks and `metadataIndexReconciledThisProcess`.
- **R1-B is fixed.** `acquirePersistenceState` now reports `createdDurably` separately from the state it returns. When creation committed, every later exit that writes nothing more returns `.written(projectionClean: false)`. The misleading "unowned" log now runs only when nothing was created.
- **R1-C is fixed.** On cold restore, a binding with no payload whose UUID has a tombstone now returns `.unresolved` without declaring the tab loaded. Cleanup goes through the existing `finalizeDeletedAgentSessionReferences`. The stale-reset retained-view path is excluded on purpose.

None of these introduces a P0/P1 regression:

- **Alias handling.** A stamp-derived folder that is already resolved resolves to itself. `ensureAgentSessionsFolder` always creates the folder before any key is taken, so the standardized fallback for an absent folder never splits a live folder's cache. The extended alias test now asserts that both spellings read the renamed record.
- **Creation outcome.** The creation snapshot is exactly the `agentSession` that the second write would write, minus the reset/removal lifecycle bookkeeping. So `.written(clean:false)` with the save token's revision describes durable content correctly. The deletion, stale-reset and missing-file handlers still run, and the projection stays dirty.
- **Deleted binding.** The deletion check runs only when there is no payload. It fails closed on an unreadable tombstone, and it re-checks transition and attempt currency after its await. The cleanup it starts is keyed by UUID and only touches tabs and bindings that still name that UUID, so a rebind in the meantime is safe and running it twice is harmless. A genuine creator (never deleted) and an accidental missing file still take the old no-payload path.

The remaining findings are P2/P3 only.

---

## P2

### R2-A: A committed creation whose owner was rebound reports `.written` to a caller that no longer owns the file (verify only)
- **Evidence:**
  - `acquirePersistenceState` returns `(nil, true)` when the adoption guard fails (`sessions[tabID] !== session`, a binding-identity change, or a different active ID).
  - `saveSessionDetailed` then returns `.written(projectionClean: false)` (AgentModeViewModel, around line 14620).
  - Before this round, the same case returned `.notWritten`, and the scheduled-send install fallback rolled back `session.scheduledSend` when it saw that.
- **Scenario:**
  1. During the first save of a scheduled install, the same `AgentTabSession` object is rebound to a new UUID Y (remote pickup, handoff, or a new session on the tab).
  2. File X now durably holds the schedule. If the install path keys only on `didWriteDurably`, the in-memory `scheduledSend` stays on a session now bound to Y.
  3. Y's first save copies that member into file Y, so the same schedule ID ends up in two files.
- **Impact:**
  - The trigger needs a rebind in the middle of the first save, so it is contrived.
  - Orphan X has no owning tab, so automatic dispatch from it seems unlikely. I could not confirm this from the visible source.
  - The result is a possible duplicate visible schedule, not data loss.
- **Smallest fix:**
  - Confirm that the install/CAS creation branch also checks `session.activeAgentSessionID == sessionID` and `persistedIncarnationSessionID == sessionID` before it keeps the schedule. If it does, close this.
  - Otherwise add that guard. Alternatively, return `.notWritten` only for the not-adopted sub-case and keep `.written` for the adopted-but-context-stale case.

---

## P3
- **R2-B, no follow-up save on some creation exits.** After a creation, the generic-error and `sessionNotFound` catches return `.written(clean:false)` without calling `requestFreshSaveForCurrentOwner`. The coalesced-token exit does call it. Nothing is lost, because the creation already holds the same snapshot and the dirty flag plus the in-flight defer drive the next save. Still, confirm that the debounce, max-wait and retry logic does not treat `didWriteDurably` as permission to stop retrying until the next mutation.
- **R2-C, test gap for the durable unbind.**
  - `testRestoredBindingToADeletedSession…` asserts that the session is torn down and that a fresh ID saves.
  - If the harness has no `workspaceManager`, only `lastKnownWorkspaceSnapshot` is cleared. The compare-and-set clear of the durable binding is then never exercised, and that clear is what stops this from repeating on every launch.
  - Fix: if the harness supports it, assert that the compose tab's `activeAgentSessionID` is `nil` after cleanup.
- **R2-D, missing assertion in the failed-second-write test.** `testInitialCreationStaysDurable…` (the failing half) does not check that the file contains "created before the full write failed". That is the claim that makes `.written` honest, so it is cheap to add.
- **R2-E, stale-reset view of a deleted session.** Excluding stale-reset recovery from the deletion check is deliberate. The side effect is that a stale-reset view of a session that was actually deleted still says "missing file" rather than "deleted". This is cosmetic.
- **Carried over:** every first save writes the session twice (creation, then an identical full write). This predates the round. A creation with no reset receipt and no removals could return clean directly.
- **Carried over:** each canonical-key call is now a `realpath` syscall, several per save. Not measurable at current scale.

---

## Fixtures and assertions
- No required assertion was weakened.
- The R1 test now expects a durable but not clean outcome and a dirty projection, which is the intended contract.
- The new owner-rebind and failed-second-write tests inject at the right points, after creation and before the full write.
- The injector on `.shared` is cleared both inline and in teardown.
- The deleted-binding test models the crash window correctly: the tombstone is committed through the data service while the workspace binding remains.

## Recommendations
1. No P0/P1 is open, so nothing here blocks the commit. Committing is still blocked by credentials.
2. Close R2-A by checking the install/CAS creation branch in source. Add the binding guard only if it is missing.
3. Add the cheap assertions for R2-C and R2-D if convenient. Otherwise list R2-A to R2-E as deferred, without another round.
4. If R2-A needs a code change, rerun the focused scheduled-send dispatch and persistence suites plus the caller aggregate. Validation so far is adequate for this snapshot.
