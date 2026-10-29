# Phase 1b foundation review — OracleB

Scope: read when the task touches lossless restart durable lifecycle foundation review evidence.
Authority: Reference
Last-verified: 2026-10-20

Preset identity verified: `7CDD523E-1D7C-47EA-98FE-D5FEA24D2D8C` (OracleB). Initial independent code review; validation evidence supplied, not independently executed.

# Review: lossless restart Phase 1b durable lifecycle foundation

## Summary

This delta moves session identity from process-local state into a durable `lifecycle` member inside the v7 session envelope. `AgentSessionDataService` owns it, and the change covers:

- **Incarnation and reset identity:** the new member carries `incarnationID`, the reset generation and the latest reset receipt.
- **Migration:** legacy files gain identity in one gate-held rewrite, and authority is issued only after the write commits.
- **Exclusive creation:** the first session file is written to a staging file and hard-linked into place, so exactly one creator wins.
- **Fail-closed envelopes:** unsupported versions and unreadable lifecycle are never rewritten.
- **Atomic, idempotent reset receipts:** the reset transcript, generation and receipt are written in one replacement.
- **Tombstone-first deletion:** a permanent, UUID-wide tombstone is the commit point, and every load, save, schedule, recovery and listing path checks it.
- **Missing-file reconstruction:** allowed only while this service still holds same-incarnation lifecycle state.

It adds no new writer or lock; every path reuses the existing per-session gate.

The core DataService contract looks correct. I traced the save fences, the reset predecessor rule, migration-before-authority, the stub rewrite guard and the reconstruction guard, and found no data-loss path. The main risk is in how the view model adopts the result of the new side-effecting creation call. The test-fixture changes are deliberate contract changes, not weakened assertions (see the last section).

---

## P1

### F1 — A dropped adoption after durable creation makes the tab unable to save
**File:** `AgentModeViewModel+ScheduledSend.swift`, `ensurePersistenceState`, post-`prepareInitialAgentSessionPersistence` guard

**Scenario**
1. A new tab's first save calls `prepareInitialAgentSessionPersistence`, which now commits the file.
2. While that call is suspended, `sessionPersistenceContextIsCurrent(context)` turns false (for example, a workspace switch flushes saves while this first save is in flight). The guard then returns `nil` without setting `session.persistenceState` or `persistedIncarnationSessionID`.
3. On the next save for the same `AgentTabSession`:
   - `persistenceState(for:)` is `nil`;
   - the creation guard passes;
   - `prepareInitial…` throws `sessionAlreadyExists`, the function returns `nil`, and the save prints "no captured persistence ownership".

From then on the tab can never save. Every later transcript change stays in memory only and is lost at quit unless something re-hydrates the tab.

**Why this is a regression:** before this delta, preparation had no side effect, so a dropped result could simply be retried. The new comment ("The file is committed: it is this owner's incarnation even if the owner moved on, so a later save never treats it as creatable again") claims the opposite of what the code does: neither field is set on the moved-on path.

**Severity:** P1 if `AgentTabSession` objects survive a context flip (workspace switch and back) without re-hydrating. P2 if that never happens.

**Smallest fix:** after a successful prepare, adopt the state whenever these all hold, independent of context currency:
- `sessions[session.tabID] === session`;
- `session.activeAgentSessionID == sessionID`;
- the session is not revoked;
- no existing state.

That means setting `persistenceState` and `persistedIncarnationSessionID`. Only then gate the *return value* on context currency. This is safe because the stamp carries its own `workspaceID`, and the first guard already rejects a workspace mismatch. Add a VM test using `test_initialPersistencePreparationHook` that flips the context during preparation and checks that the next save writes.

---

## P2

### F2 — Exclusive creation requires hard links
**File:** `AgentSessionDataService.createSessionFileExclusively`

**Scenario:** a workspace with `customStoragePath` on a filesystem without hard links, such as exFAT, some SMB/NAS shares or some FUSE/cloud mounts. `linkItem` fails, the target doesn't exist, and the raw error is rethrown. Every new session's creation then fails, `ensurePersistenceState` returns `nil`, and the session is never saved. The only signal is a console `print`.

**Smallest fix:** use `renamex_np(staging, target, RENAME_EXCL)`, which is atomic and exclusive. On `ENOTSUP`/`EPERM`/`EXDEV` from either primitive, fall back to an existence check plus an atomic write under the gate; DataService is the documented sole writer, so that is safe within one process. Alternatively, surface the error to the user instead of only printing it.

### F3 — Editable and hydration loads throw `sessionDeleted` where other lookups return `nil`
**Files:**
- `loadAgentSessionForEditing` and `loadAgentSessionForHydration` call `requireNoTombstone` before the `fileExists → nil` check.
- `loadAgentSession(id:)` and `metadataRecordForSessionID` return `nil` for the same state.

**Scenario:** a tab whose persisted tab state references a session that was deleted (via MCP or the sidebar) is restored at launch. Before this delta, hydration returned `nil` (file absent). Now it throws `sessionDeleted`. If the VM's hydration error path keeps the tab in an error or retry state instead of treating it like a missing session, the user gets a stuck tab.

**Smallest fix:** for `.committed`, return `nil` in these two loaders and keep the throw for `.unreadable`. Otherwise, confirm the VM hydration caller maps `sessionDeleted` the same way as `nil`. The new test asserting a throw from `loadAgentSessionForEditing` would need updating either way.

### F4 — Need to confirm the scheduling path for never-persisted sessions
**File:** `+ScheduledSend.commitScheduledSendDetailed` (the excerpt cuts off at the `ensurePersistenceState` call)

**Scenario:** before this delta, the CAS path's `ensurePersistenceState` (without `initialSession`) returned create-only state for a never-persisted session. Now it returns `nil`. If `commitScheduledSendDetailed` asks for state *before* its "fall back to a full save, then re-run the CAS" branch, scheduling a send on a brand-new tab fails with "could not be saved".

**Evidence:** the doc comment describes a full-save fallback, `hasPersistableConversationContent` includes `scheduledSend != nil`, and the dispatch tests passed. That is suggestive but not conclusive from the provided text.

**Smallest fix:** confirm the ordering. Add or point to a test: new tab with no prior save → schedule → durable CAS commit.

### F5 — Tombstones silently hide sessions restored from backup
**Files:** `tombstonedSessionIDs` and `excludingTombstoned`, plus all the listing filters

**Scenario:** the user deletes a session by accident and restores `AgentSessions/` from Time Machine. The restored file is permanently invisible and unloadable, and there is no log and no documented recovery step. The bytes are kept, so this is recoverable but surprising. The same applies to cross-workspace copies with the same UUID, which the `AgentStaleResetOwnershipTests` change demonstrates.

**Smallest fix:**
- When a listing skips an on-disk file because of a tombstone, log once per session with the tombstone path.
- In the evidence doc, document "delete `<AppSupport>/RepoPrompt CE/AgentRecovery/v1/tombstones/<UUID>.json` to restore". Under the rigor policy, failing loudly with recovery steps is a full remedy.

### F6 — Rename can overwrite a newer transcript (pre-existing; becomes relevant now)
**File:** `renameAgentSession` calls `loadAgentSession(id:)` (gate released) and then `saveAgentSession` (a second acquisition)

**Scenario:** an MCP rename runs while a tab is streaming:
1. Rename loads snapshot T0.
2. The VM saves T1 and marks itself clean.
3. Rename writes T0 with the new name. The lifecycle fence passes because the incarnation and generation are unchanged.

T1 is now missing on disk while the VM believes it is saved. The new lifecycle catches only an intervening *reset*, not ordinary edits.

**Smallest fix (deferrable, not introduced here):** do the load and save inside one gate acquisition using `loadAgentSessionLocked` and `saveAgentSessionLocked`.

---

## P3

| ID | Issue | Smallest fix |
|---|---|---|
| F7 | Deleting an already-tombstoned session (repeated `deleteAgentSession(id:)`, or the `.committed` branch of `deleteAgentSession(ifCurrent:)`) bumps the deletion generation again and posts `agentSessionDeletionDidCommit` again. | Skip the generation bump and notification when `commitTombstone` found it already `.committed`; just retry the unlink and metadata cleanup. |
| F8 | Cross-instance creation race: if another instance links the file between `prepareInitial…`'s existence check and `saveAgentSessionLocked`'s re-check, the loser gets `missingLifecycle`, not `sessionAlreadyExists`. This can make the two-service test flaky; production uses `.shared`, so it is test-only. | In the compatibility branch, map `fileExists && session.lifecycle == nil && .createIfMissing` to `sessionAlreadyExists`. |
| F9 | Legacy sessions now *require* a successful write before they can be opened at all (full disk, read-only or locked custom storage). This is fail-closed by design, but the user just sees a `loadFailed`. | Document it; optionally hydrate read-only without authority later. |
| F10 | `tombstonedSessionIDs()` reads the whole tombstone directory on every listing (sidebar stream, fast metadata, file scans), and tombstones are permanent and never garbage-collected. | Cache the directory listing and refresh it on this service's own `commitTombstone` plus a directory-mtime check. |
| F11 | An older build (upstream CE) on the same App Support drops `lifecycle` on save, so the next run re-migrates with a new incarnation. That is harmless now but will orphan Phase 1b recovery records later. | Note it in the evidence; consider a version-guarded warning. |
| F12 | `rawLastRunStateForAgentSession` still reads tombstoned residue. | Add a tombstone check returning `nil`. |
| F13 | A crash between staging write and link leaves a hidden `.AgentSession-….creating-*` file forever. | Sweep `.creating-*` files older than N minutes during the folder scan. |
| F14 | `lifecycleAuthorityUnavailable` maps to the `.destinationUnavailable` attention reason, which misleads: the folder exists, but identity can't be proven. | Use a dedicated reason or `.invalidAcceptanceEvidence("lifecycle authority unavailable")`. |
| F15 | The evidence doc says `ensurePersistenceState` "catches `.sessionDeleted` and `.staleIncarnation`". It doesn't; those catches were added to `commitScheduledSendDetailed` and the VM save path. `ensurePersistenceState` sends them to the generic print → `nil`. | Correct the doc. |
| F16 | First VM save writes twice (creation, then the normal save). This is known; the cost is two encodes, two metadata upserts and two diskWriter/link writes for a small first transcript. | Have the save skip the second write when preparation just committed this exact snapshot, e.g. a `createdFromThisSnapshot` flag returned from `ensurePersistenceState`. |
| F17 | Test gaps: no VM-level test for the F1 race; no hydration test for unsupported or unreadable envelopes (only editable and general load are covered); no test for hard-link failure (F2). | Add them. |

---

## Fixture changes: checked for assertion weakening

None found.

- **`carryingLoadedLifecycle`:** it adopts only the lifecycle and is always called *before* the competing mutation, so the stale-snapshot semantics are preserved. Its full load refreshes the schedule-authority cache, but at that point the cache already equals the disk state, so the protection scenarios aren't pre-satisfied.
- **Delete, recreate and unlink-failure tests:** they now assert stronger outcomes (refusal, an inaccessible residue with unchanged bytes, terminal recovery, cleanup on repeated delete). The old "reset tombstone survives a failed unlink" coverage is moot under tombstone-first deletion, and stale-snapshot non-resurrection is still covered by `testIntentionalFinalizedItemRemoval…` and `testMatchingFinalizationRetry…`.
- **`testCachedScheduleAuthority…`:** it now reloads before corrupting the file, and the save then also relies on the lifecycle cache. It still proves the corrupt file is never re-parsed.
- **`AgentStaleResetOwnershipTests`:** the bytes-unchanged check keeps the "cleanup never targets the active workspace" property. The `nil` load encodes the assumed UUID-wide retirement; it is a contract change, not a weakening.

## Recommendations

1. **Fix F1 before committing.** The fix is cheap, and the regression is directly caused by making preparation side-effecting. Add the race test.
2. **Resolve F3 and F4 by reading the callers** (`loadAgentSessionForEditing`/hydration in the VM, and `commitScheduledSendDetailed`'s ordering). Fix only if confirmed.
3. **Decide on F2** based on where the owner's workspaces actually live. If any custom storage might be on a filesystem without hard links, add the `RENAME_EXCL` primitive with its fallback now; otherwise defer it with a note.
4. **Apply the cheap fixes:** F5 (log plus recovery doc), F7, F12 and F15. Defer F6 (pre-existing), F9–F11, F13 and F16 as listed.
5. **No full-root or live run is needed for this foundation.** The `managerNotFullyStopped` failure happens during MCP bootstrap, before any session persistence runs, so it plausibly isn't from this change. A single targeted rerun of `AgentRunWorktreeStartTests` on the Phase 1a index would settle attribution cheaply.
