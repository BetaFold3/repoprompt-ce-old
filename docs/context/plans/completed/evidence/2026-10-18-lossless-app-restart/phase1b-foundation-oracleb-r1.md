# Phase 1b foundation re-review — OracleB

Scope: read when the task touches lossless restart lifecycle foundation re-review evidence.
Authority: Reference
Last-verified: 2026-10-21

Preset identity verified: `7CDD523E-1D7C-47EA-98FE-D5FEA24D2D8C` (OracleB). Round 1/2; supplied validation, independent code inspection.

# Lossless restart Phase 1b foundation: re-review, round 1

## Summary

This round fixes my earlier F1 and several cheap items, and changes the creation design:

- **F1 fix:** after a successful creation, `ensurePersistenceState` now keeps the authority whenever the exact originating owner binding is still in place. Only the return value is gated on whether the persistence context is current.
- **Exclusive creation:** the hard-link primitive is gone. Exclusivity now comes from the existing per-session gate plus the normal atomic writer, and the cross-service guarantee was removed from the contract.
- **Path aliases:** `canonicalSessionFileKey` now resolves the parent directory with `realpath`, so two spellings of one directory share one stamp and cache identity.
- **Deleted sessions:** an editable or hydration load of a session with a committed tombstone returns `nil`. An unreadable tombstone still throws.
- **Repeated deletes:** only the delete that commits the tombstone bumps the deletion generation and posts the notification.
- **Smaller fixes:** `rawLastRunState` now checks the tombstone, hidden residue is logged once per session, and the scheduled-send comments are corrected.

I traced each fix against the current snapshot. **F1 is fixed:**

- Adoption requires all of: the same tab object, the same `persistentSessionBindingIdentity`, the same active session ID, and not revoked.
- An existing state is never replaced.
- A later save finds the state through `persistenceState(for:)`, because the stamp's `workspaceID` matches the original workspace.
- The new test covers this.

The other fixes also hold up:

- **Tombstone handling:** F3, F7 and F12 behave as described. The `.committed` branch of `deleteAgentSession(ifCurrent:)` no longer re-publishes. After a restart, `tombstoneState` reads the tombstone from disk, so `newlyCommitted` stays false.
- **Creation under the gate:** creation is still race-free within one service. `prepareInitial…` checks that the file is absent under the gate, and `saveAgentSessionLocked` checks again while still holding it.
- **F4 (scheduling a never-persisted session):** confirmed by the corrected comment and the existing coalesced-creation test.

I have no open P0/P1. The realpath key change did introduce one P2 regression, and the F1 and F3 fixes leave two P2 edge cases nearby.

---

## P2

### R1-A: Metadata-index cache splits between the realpath'd and standardized folder keys (regression from the alias fix)
**Evidence:**
- `canonicalSessionFileKey` now resolves the parent directory with `realpath`, and every stamp's `fileURL` is that resolved key (`persistenceState(...)`, `deletionCandidates`).
- Several paths derive their metadata folder from the stamp: `saveAgentSessionLocked` (`agentSessionsFolder = fileURL.deletingLastPathComponent()` when authority is a persistence state), `performScheduledSendMutation`, `prepareScheduledSendRecoveryLocked`, and `deleteAgentSession(ifCurrent:)`.
- They then call `upsertMetadataRecordReporting` or `removeMetadataRecords`, both keyed by `canonicalMetadataFolderKey(folder)`, which is still `standardizedFileURL`, with no realpath.
- Listings, `prepareInitial…`, loads and compatibility saves reach the same index through `ensureAgentSessionsFolder`, which returns the unresolved spelling.

**Scenario:** the storage path contains a symlink. That is every test temp directory (`/var` → `/private/var`), any symlinked custom storage path or symlinked Application Support, and possibly a case mismatch, since macOS `realpath` returns the on-disk case.
1. A persistence-state save or schedule CAS updates `metadataIndexCacheByFolder[/private/var/…]` and writes the disk index.
2. Sidebar or fast-metadata reads keep serving the stale `metadataIndexCacheByFolder[/var/…]`.
3. The next write through the unresolved key (a load rewrite, a compatibility save, or `upsertMetadataRecordIfIndexPresent`) writes the stale cache back to disk. That overwrites the newer name, item count, sort date and `scheduledSendSummary`.
4. Reconciliation runs only once per process (`metadataIndexReconciledThisProcess`), so the index stays stale until the next launch's delayed rebuild.

**Impact:** stale or regressed sidebar and history metadata, including scheduled-send summaries, within the session. Session files remain authoritative, so this is not data loss. Before this round both keys were `standardizedFileURL`, so they matched.

**Smallest fix:** canonicalize the metadata folder the same way, for example by sharing one `resolvedDirectoryKey(_:)` helper between `canonicalSessionFileKey` and `canonicalMetadataFolderKey`. That also covers the reconciliation-task and `reconciledThisProcess` keys. Add one assertion to the alias test: after the save through the stamp, `test_cachedMetadataIndexEntryCount` or `fastMetadataRecordsIfAvailable` through the other spelling sees the new name.

### R1-B: A committed creation with a stale context is reported as `.notWritten`
**Evidence:** in `ensurePersistenceState`, after `prepareInitialAgentSessionPersistence` succeeds and the authority is adopted, the final context guard returns `nil`. `saveSessionDetailed` then:
- returns `.notWritten`;
- logs `save.session.unowned` and prints "no captured persistence ownership… never overwritten from memory".

The new test even asserts `XCTAssertFalse(first.didWriteDurably)`.

**Scenario:** the context flips during the first save, which is what the new test does. The file now durably holds this snapshot, including any `scheduledSend` member. But `saveSessionDetailed` documents "`true` only when the session file was durably written by this call". Callers that depend on durable outcomes are told nothing was written:
- the scheduled-send install fallback, which reports "could not be created" and rolls back the draft while a durable schedule exists;
- removal final saves.

The diagnostic also blames ownership, which is wrong.

**Impact:** narrow window (the context must flip mid-creation). The worst case is a visible schedule the user was told failed, which needs a click to send, so it is not automatic duplication. The misleading log makes this harder to diagnose.

**Smallest fix:** have `ensurePersistenceState` tell the caller "created, but context stale", for example with a small enum or out-parameter. `saveSessionDetailed` can then return `.written(… projectionClean: false)`, as the coalesced-token path already does, and skip the "unowned" print. Change the test assertion to expect a durable but not clean outcome.

### R1-C: A tab bound to a tombstoned ID becomes silently unsaveable (follow-on from the F3 fix)
**Evidence:**
- Hydration and editable loads now return `nil` for a committed tombstone.
- On the next save, `ensurePersistenceState` calls `prepareInitial…`, which throws `sessionDeleted`.
- The generic `catch` only prints "could not create the initial session file" and returns `nil`.
- `saveSessionDetailed` then returns `.notWritten`, prints "no captured persistence ownership", and the tab stays dirty.
- `handleDurableSessionDeleted` is wired only to the full-save and CAS catch blocks, not to this path.

**Scenario:** a restored tab references a session whose deletion committed but whose tab state was not persisted, for example after a crash between the tombstone commit and tab-state persistence. The tab hydrates as empty, and the user keeps working in it. Nothing is ever saved, and the only signal is a console print.

**Impact:** new conversation content is lost at quit, but the trigger is a crash window. Same-UUID cross-workspace copies are out of contract.

**Smallest fix:** in `ensurePersistenceState`, catch `AgentScheduledSendMutationError.sessionDeleted` and route it through the existing `handleDurableSessionDeleted`, or the existing rebind-to-new-ID path, if that is what the deletion handler does. If the VM's hydration-`nil` path already rebinds tombstoned IDs, cite it and close this as not applicable.

---

## P3
- **Per-call `realpath`:** `canonicalSessionFileKey` makes a `realpath` syscall on every call, including several times per save and per listing filter. Not measurable at current scale. Either fold it into the R1-A helper with a small per-folder memo, or leave it.
- **Doc comment line length:** the `AgentSessionFileCreationPolicy.createIfMissing` doc comment has an overlong line after the edit. Cosmetic.

---

## Fixtures and assertions
I found no weakened required assertions:
- The removed cross-service test portion matches the narrowed sole-writer contract stated in the `prepareInitial…` doc comment.
- The same-service two-creator test is retained.
- The new tests (context flip after commit, alias stale-save fence, expanded hydration bad envelopes, repeated-delete publication) assert the intended behavior.
- The inverted-expectation notification check is sound, because the notification posts synchronously under the gate before `deleteAgentSession` returns.

## Recommendations
1. Nothing blocks the commit.
2. **R1-A:** fix it now. It is a cheap one-helper change, and it regresses behavior in exactly the alias configuration this round targeted.
3. **R1-B and R1-C:** fix if cheap, otherwise record them as deferred P2s with the scenarios above.
4. **Validation:** the stated runs (focused 138 tests, caller aggregate 612, lint) are adequate for this round. If you apply the R1-A fix, rerun the focused lifecycle and persistence suites.
