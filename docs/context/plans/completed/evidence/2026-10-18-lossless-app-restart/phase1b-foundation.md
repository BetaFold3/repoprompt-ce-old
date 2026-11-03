# Lossless app restart — Phase 1b durable lifecycle foundation evidence

Scope: read when the task touches the lossless-restart Phase 1b lifecycle foundation: the version-7 `lifecycle` member, legacy migration, exclusive initial creation, durable reset receipts, UUID-wide tombstones, or the DataService save/recovery fences.
Authority: Reference
Last-verified: 2026-10-21

Implementation evidence for the "durable lifecycle foundation" package of the Phase 1 scope (Oracle plan export `prompt-exports/oracle-plan-2026-10-20-230525-restart-phase-1-scop-cc4a.md`). The Oracle recommendations were adopted as reversible assumptions, not owner Decisions. Status, allowlist and reviews belong to the plan owner. This is fixture evidence from XCTest against temporary storage, not live acceptance.

## Current contract

`AgentSessionDataService` remains the sole writer and gate. It adds no cross-service or multi-process locking.

**Lifecycle member**
- The session envelope has an optional `lifecycle` member (`AgentSessionLifecycle`: schema 1, `incarnationID`, `transcriptResetGeneration: UInt64`, `lastTranscriptResetReceipt`).
- Decoding is typed-or-unreadable and presence-sensitive:
  - an absent member is legacy;
  - `null`, an unknown schema or member, a malformed identity, an invalid generation/receipt pairing, or any non-exact round-trip is `.unreadable`;
  - an unreadable member is re-encoded verbatim and never treated as authority.
- Serialization versions `0...7` are supported. A future or negative version throws `unsupportedSessionEnvelope`, and an unreadable lifecycle throws `unreadableLifecycle`. Neither is ever normalized or rewritten (load, editable load, compatibility save, stub recovery).

**Migration**
- A legacy envelope receives `.fresh()` lifecycle only in a gate-held rewrite. This covers full load, editable load, hydration, and the stub metadata-recovery rewrite when persisted.
- Authority (stamp, cache, and stub lifecycle) is issued only after the write commits.
- A failed migration write leaves the bytes unchanged and issues no authority.

**Stamps**
- `AgentSessionPersistenceStamp` carries `incarnationID`.
- Editable authority always has one. It is `nil` only for deletion candidates of legacy or unreadable files.

**Exclusive creation**
- `prepareInitialAgentSessionPersistence(initialSession:for:preparation:trustedCanonicalItemCount:)` requires:
  - a lifecycle-absent session;
  - the same workspace (or `nil`);
  - not a non-empty list stub;
  - no tombstone;
  - no file.
- Exclusivity comes from the app contract, not from a filesystem primitive. DataService (`.shared`) is the sole session writer, and the per-session gate is held from the absence check through the existing atomic writer. Two independent creators of one UUID through that service serialize: one commits, and the other gets `sessionAlreadyExists`. The call returns an editable load.
- Independent service instances or processes writing one storage directory are outside this contract. No hard-link, `renamex_np` or fallback primitive is used.
- A compatibility save creates a file only for a genuinely new, lifecycle-absent session with `.createIfMissing`.
- VM adoption (`ensurePersistenceState`): after creation commits, the state is adopted whenever the exact originating owner holds (the same `AgentTabSession` in its tab, the same binding identity and generation, the same active session ID, not revoked), even if the persistence context is no longer current. Only the state returned for the current save is gated on context currency. A replaced tab, a rebinding (including to the same ID) or a revoked lifetime never adopts it, and no existing file is ever adopted from creation.
- Creation outcome (`acquirePersistenceState`, wrapped by `ensurePersistenceState`): it also reports whether this call durably created the file. After creation commits, the VM save captures one fallback outcome: `.written` with `projectionClean: false` at the save token's revisions. Every later exit that writes nothing more returns it instead of `.notWritten`. That covers an unusable state (stale context or replaced owner), the post-acquisition and before-write owner checks, a coalesced `resetAlreadyCommitted`, and every catch, including the second write's failure. The deletion and stale-reset handlers still run, the projection stays dirty, and a clean receipt still requires the full write. Removal settlement is unchanged, because a `.written` receipt only settles a projection that is not dirty.
- Restored deleted binding: hydration that finds no payload for a durably tombstoned UUID (`isAgentSessionDeleted`) is neither declared loaded nor treated as a `.noPayload` creator. It returns `.unresolved` and runs the existing `finalizeDeletedAgentSessionReferences`, which CAS-clears only bindings still naming that UUID. In the same synchronous step, with no suspension after the binding scan, it detaches each live owner still bound to the UUID from its tab, together with that tab's scoped state. A tab hosting another owner is untouched. The awaited teardown then runs only on the detached objects, using the workspace-switch discard pattern: no MCP publication, Codex/Claude tab state released only for the captured run, and run routing by the captured run ID. The final tab reprocessing is skipped if a replacement owner appeared meanwhile. The tab then starts under a fresh identity. Stale-reset recovery keeps its retained "missing file" outcome.

**File identity**
- Every lifecycle, reset, schedule-authority and deletion cache, and every pinned stamp, is keyed by `canonicalSessionFileKey`: the `realpath(3)` of the existing parent directory plus the filename (the standardized URL when the directory cannot be resolved).
- Metadata-index caches, reconciliation tasks and the reconciled-this-process set use `canonicalMetadataFolderKey`, built from the same `resolvedExistingDirectoryKey` resolution.
- Two storage references that alias one directory (`/var` vs `/private/var`, a symlinked custom storage path) therefore share one authoritative entry. A reset or deletion through one spelling fences a stale save through the other. No filesystem watching was added.

**Saves**
- Compatibility saves of an existing file must carry the typed lifecycle they loaded, with the same incarnation and generation. Otherwise they fail with `missingLifecycle`, `unreadableLifecycle`, `staleIncarnation` or `staleTranscriptResetGeneration`.
- Compatibility saves reject reset receipts (`transcriptResetRequiresPersistenceState`).
- Persistence-state saves require:
  - the file to exist (`sessionNotFound` regardless of policy);
  - a matching durable incarnation;
  - the current generation.
- DataService always merges the durable lifecycle; it never takes the payload's lifecycle.

**Reset receipts**
- A reset writes the transcript, `generation + 1` and the receipt in one atomic replacement.
- Overflow throws and never wraps.
- A receipt equal to the persisted latest receipt returns `.resetAlreadyCommitted` without a write. This applies only when the caller's generation is current or the immediate predecessor; otherwise the generation must be current.

**Tombstones**
- Location: `<AppSupport>/AgentRecovery/v1/tombstones/<UUID>.json`, content `{schemaVersion:1, sessionID}`.
- They are permanent and UUID-wide across workspaces.
- Deletion order:
  1. Tombstone write (the commit point; on failure, nothing is published or unlinked).
  2. Clear caches. Only the call that newly committed the tombstone bumps the deletion generation and posts the notification, so each logical deletion is published once.
  3. Unlink. A failure here only leaves inaccessible residue and is logged.
  4. Metadata cleanup.
- A repeated delete, by ID or through the conditional path's `.committed` branch, retries cleanup without publishing again.
- An unreadable tombstone fails closed (`unreadableTombstone`) and is never replaced.
- A tombstone fences:
  - creation, full loads by file, stub loads, saves, schedule CAS/finalization, recovery preparation, and conditional delete (throw `sessionDeleted`);
  - optional lookups, which return `nil` for a committed tombstone:
    - `loadAgentSessionForEditing` and `loadAgentSessionForHydration` (so `preparePersistedHydration` takes the VM's existing not-found path);
    - `loadAgentSession(id:)`, `metadataRecordForSessionID` and `rawLastRunStateForAgentSession`;
    - an unreadable tombstone still throws `unreadableTombstone` from the editable and hydration loads;
  - listings: `listAgentSessions`, `agentSessionFiles`, metadata/fast/sidebar records.
- When a file scan hides on-disk residue of a tombstoned UUID, the service logs the file and tombstone path once per UUID.
- A live tombstone must never be deleted to "restore" a session. It is the UUID-wide retirement record, and removing it would re-enable stale owners of that incarnation, including restored backups and cross-workspace copies of the UUID. Offline recovery of residue content requires a deliberate repair under a new session identity. No restoration feature is provided.

**Recovery**
- Context captures `incarnationID` and the durable reset generation; a tombstone → `.explicitlyDeleted`.
- Existing file: the incarnation must match, and the accepted item is suppressed after a later durable reset.
- Missing file: reconstruction requires this service's cached lifecycle for the same incarnation (and the reset snapshot if the generation advanced). Otherwise it fails with `AgentScheduledSendRecoveryError.lifecycleAuthorityUnavailable`.

**Test isolation**
- `AgentSessionDataService(tombstoneRoot:)` is injectable.
- In DEBUG XCTest processes the default root is a per-instance temporary directory (`RepoPromptCE-XCTest/AgentRecovery-<UUID>/v1/tombstones`), following the `GlobalSettingsStore` precedent. So `.shared` and default-constructed services in tests never write live Application Support.
- Consequence: within a test process, a tombstone is visible only to the service instance that wrote it, unless tests share an injected root. No live files were touched.

## Changed files

**Product**
- `Sources/RepoPromptAgentCore/AgentMode/Runtime/AgentSessionLifecycle.swift` (new): lifecycle, member, tombstone and state types.
- `AgentSession.swift`: `lifecycle` member, `supportedSerializationVersions`.
- `AgentSessionDataService.swift`: all of the contract above, plus the DEBUG seams `test_setTombstoneWriteFailureInjector`, `test_setSessionWriteFailureInjector`, `test_forgetLifecycleAuthority` and `test_tombstoneRoot`.
- `Scheduling/AgentScheduledSendRecovery.swift`: receipt `Codable`, context `incarnationID`, `.lifecycleAuthorityUnavailable`.
- `Scheduling/AgentScheduledSendCoordinator.swift`: maps the new error to `.destinationUnavailable` (switch exhaustiveness only).

**App**
- `AgentModeViewModel+ScheduledSend.swift`:
  - `ensurePersistenceState` creates only through `prepareInitialAgentSessionPersistence` with the full initial session, and adopts the committed authority for the exact originating owner independently of context currency.
  - Every creation error, including `sessionDeleted`, returns `nil` there. The `.sessionDeleted`/`.staleIncarnation` catches that revoke ownership are in `commitScheduledSendDetailed`'s CAS and in the VM full-save path, not in `ensurePersistenceState`.
- `AgentModeViewModel.swift` (Phase 1a-staged file; worktree edit only, maxwait untouched):
  - the save path passes `initialSession` and its trusted count;
  - the full save is always `.requireExisting`;
  - the deletion catch list adds `.sessionDeleted` and `.staleIncarnation`;
  - DEBUG seam `test_initialPersistenceCommittedHook` (after the creation commit, before adoption).

## Caller inventory

**Creation**
- `prepareInitialAgentSessionPersistence`:
  - `AgentModeViewModel+ScheduledSend.ensurePersistenceState`, which is reached from the VM save path with `initialSession`;
  - the `+ScheduledSend` discard-unreadable, CAS and recovery-stamp sites pass none and return `nil` if never persisted;
  - `commitScheduledSendDetailed` handles a never-persisted session by running the full save (`flushSaveDetailed`) first, which creates the file and adopts its authority. Only then does it call `ensurePersistenceState` for the CAS. First-schedule-on-a-fresh-tab coverage: `AgentScheduledSendDispatchTests.testCoalescedSaveDuringInitialCreationKeepsScheduleInstalledAndDurable` and `testFailedInitialWriteRetriesCreationUnderThePreparedAuthority`.
- The test hook `AgentScheduledSendDispatchTests` calls `ensurePersistenceState`.

**Persistence-state save**
- The VM full save, including the only reset caller.

**Compatibility save (must carry loaded lifecycle or create new)**
- `renameAgentSession` (load by ID, then a separate gate acquisition for the save; see deferred F6);
- `AgentModeViewModel+StressHarnessSupport` (fresh creation);
- test fixtures.

**Deletes**
- VM `deletionCandidates`, conditional delete, `deleteAgentSession(id:)`;
- `AgentManageMCPToolService` delete paths.

**Recovery**
- Preparation: `+ScheduledSend` recovery stamp.
- Finalization: `AgentScheduledSendCoordinator`.

**Listing consumers (now tombstone-filtered)**
- `AgentScheduledMessagesViewModel`;
- `AgentManageMCPToolService.listAgentSessionsMeta`;
- `DataService+Restore` sidebar, fast-metadata and hydration paths.

**Unchanged**
- `AgentTabSession` (it holds `AgentSessionPersistenceState?`).

## Tests

**New suite**
- `Tests/RepoPromptTests/AgentMode/Recovery/AgentSessionLifecyclePersistenceTests.swift` has 14 tests. All use an injected tombstone root and temporary storage, with fresh services as restarts.
- Coverage:
  - codec strictness and verbatim round-trip;
  - unsupported, future or unreadable envelopes failing closed without rewrite;
  - legacy migration (unversioned, v6, v7) staying stable across a restart;
  - migration write failure granting no authority;
  - hydration and stub migration;
  - exclusive creation by two independent creators through one service (the cross-service portion was cut with the hard-link primitive; see the dispositions);
  - save fences;
  - reset idempotency across a restart, with superseded-receipt rejection and an old-process stamp being invalid;
  - tombstone-write failure;
  - unlink-failure residue staying deleted across a restart, listings, recovery and other workspaces, with repeated delete;
  - unreadable tombstones;
  - schedule, finalization and hydration preserving lifecycle;
  - recovery after a durable reset;
  - missing-file reconstruction only with same-process authority;
  - review fixes: two storage-path aliases share reset fencing; unsupported/unreadable envelopes fail closed in overlapped and sequential hydration; a committed tombstone reads as `nil` from editable and hydration loads, while an unreadable one throws from both; tombstoned residue hides `rawLastRunStateForAgentSession`.
- VM regression `AgentScheduledSendDispatchTests.testInitialCreationKeepsItsAuthorityWhenTheContextChangesAfterTheDurableCommit`:
  - the context flips after the durable creation commit;
  - the owner retains its creation authority;
  - after the context returns, newer edits save to the same incarnation.
- `AgentScheduledSendPersistenceTests` unlink-failure test: a repeated delete posts no second notification and does not bump the generation.

**Existing fixtures updated — deliberate contract changes, not product regressions**
- `AgentScheduledSendPersistenceTests`:
  - The new prepare API is used.
  - Same-ID recreation after delete now expects `sessionDeleted` (3 tests, renamed where the old name asserted recreation).
  - An unlink failure after the tombstone is now logical success: residue stays inaccessible, a stale save gets `sessionDeleted`, recovery gets `.explicitlyDeleted`, and a repeated delete cleans up.
  - Six stale-snapshot tests now carry the loaded lifecycle through the `carryingLoadedLifecycle` helper, which adopts only the lifecycle and leaves the stale schedule/items intact.
  - The cached-authority test reloads before corrupting.
  - Resets go through the persistence-state overload.
- `AgentStaleResetOwnershipTests.testWorkspaceChangeAfterCommitUsesCapturedCleanupResourcesOnly`:
  - The fixture deliberately reuses the deleted session's UUID in another workspace. With UUID-wide tombstones, that ID is logically retired everywhere.
  - The assertion "cleanup never targets the newly active workspace" is now checked on disk: the foreign file's bytes are unchanged, not unlinked. `load` now returns `nil`.

**Commands and results**
- `make dev-swift-build PRODUCT=RepoPrompt`: succeeded.
- `make dev-test FILTER=AgentScheduledSendPersistenceTests`: first 7 failures, all from the fixture contract changes above (6 lifecycle-less stale compatibility saves → `missingLifecycle`; 1 same-ID recreation → `sessionDeleted`). After the fixture updates, 34/34 passed.
- Broad job `99dd6afc`: `make dev-test FILTER="'AgentScheduledSend|AgentToolResultPersistencePolicyTests|AgentTranscriptRefreshDiagnosticsTests|AgentStaleResetOwnershipTests|AgentModeChatSwitchActivationTests|AgentTranscriptSaveMaxWaitTests|AgentSessionDataService|AgentScheduledMessages'`.
  - 291 tests ran, 2 skipped. The only failure was `AgentStaleResetOwnershipTests.testWorkspaceChangeAfterCommitUsesCapturedCleanupResourcesOnly`, the UUID-wide tombstone fixture change above.
  - Make exited 1 for that failure. An earlier unquoted-regex attempt exited 127 from the shell and did not run.
- `make dev-test FILTER="'AgentSessionLifecyclePersistenceTests|AgentStaleResetOwnershipTests'"`: 53 tests, 2 skipped, 0 failures.
  - Before this, one new-suite failure was a test-seam keying error: listing URLs `/private/var/…` vs the context's `/var/…`, which standardize to different keys. The test now passes the context's pinned URL; there was no product change.
- Full root `make dev-test` (job `63580fd4`): **cancelled, incomplete, not passed.**
  - Main's scope decision cut it; it was cancelled with `./conductor job cancel` (state `canceled`, exit 130) after about 205 suites.
  - Its only recorded failure was `AgentRunWorktreeStartTests.testManualFirstSendCreatesAndBindsNewWorktreeAcrossNewAndLinkedRoutes`, which threw `managerNotFullyStopped`. That error comes from `MCPConnectionManager`'s DEBUG bootstrap-socket namespace install, before any session persistence runs. It is not attributed to this change and was not fixed or rerun.
- Aggregate of changed-writer/caller suites (job `36bc84db`): `make dev-test FILTER="'AgentManageMCPToolServiceForkTests|AgentManageMCPToolServiceResumeTests|AgentModeChatSwitchActivationTests|AgentModeViewModelDelegatedQuestionTests|AgentScheduledSend|AgentScheduledMessages|AgentSessionLifecyclePersistenceTests|AgentSessionProfilePersistenceTests|AgentSessionWorktreeBindingPersistenceTests|AgentSessionWorktreeMergePersistenceTests|AgentSessionMetadata|AgentStaleResetOwnershipTests|AgentToolResultPersistencePolicyTests|AgentTranscriptBackgroundRefreshDeferralTests|AgentTranscriptRefreshDiagnosticsTests|AgentTranscriptSaveMaxWaitTests|AgentUsagePersistenceTests|AgentUsageRuntimeIntegrationTests|AttentionNotificationAdmissionTests|RemoteAgentClientFixesTests|RemoteAgentSessionTests|RemoteWorkspaceSidebarTests'"`.
  - The suites are every test file calling save, delete, prepare-initial, hydration, editable-load, rename, metadata-listing or `flushSave` APIs, plus scheduled messages and metadata.
  - Result: 610 tests, 2 skipped, 0 failures.
- `make dev-lint`: first run, 4 files needed formatting (redundant `Sendable`, hoisted `try`/`await`, a wrapped reset-retry condition). After fixes, 0/2088. The reset-retry condition was rewritten as the equivalent `expected <= current && current - expected <= 1`.
- After the lint fixes (job `2c81ea92`): `make dev-test FILTER="'AgentSessionLifecyclePersistenceTests|AgentScheduledSendPersistenceTests|AgentScheduledSendDispatchTests|AgentStaleResetOwnershipTests'"` gave 136 tests, 2 skipped, 0 failures.
- `Scripts/check-agent-context` and `make guardrails` fail only on this document's reachability (no inbound link). Linking it from the plan's evidence index or spec is the plan owner's edit. The route-count warning on `AGENTS.md` predates this change.

**Review-fix validation (2026-10-21, on the stable tree after the recovery worker's compile/lint passed)**
- A first focused attempt (job `ad24b276`) did not compile. Every error was in the concurrently edited, untracked recovery files, so no tests ran; it is not evidence.
- Focused (job `885e3fd5`): `make dev-test FILTER="'AgentSessionLifecyclePersistenceTests|AgentScheduledSendPersistenceTests|AgentScheduledSendDispatchTests|AgentStaleResetOwnershipTests'"`. Result: 138 tests, 2 skipped (opt-in Phase 0 reports), 0 failures. Both new regressions (F1 VM, A F2 alias) passed.
- Aggregate (job `e09f2a07`): the same 22-suite filter as job `36bc84db`. Result: 612 tests, 2 skipped, 0 failures.
- `make dev-lint` (job `e31cadd5`): exit 0.
- Not run: full root, packaging, app lifecycle, providers, live acceptance.

## Independent review and current disposition

Initial reviews: [OracleA](phase1b-foundation-oraclea.md) and [OracleB](phase1b-foundation-oracleb.md), both requested preset identities verified. Main dispositioned the findings; these are implementation decisions, not owner Decisions. Main added the evidence inbound link; `Scripts/check-agent-context` and `make guardrails` passed with the existing route-count warning. The fixes below need fresh independent re-review before acceptance. Commit signing remains blocked pending owner credentials.

**Fixed**
- **F1 (both reviews), creation authority dropped after commit:** fixed in `ensurePersistenceState` (contract above), with the VM regression.
- **A F2, path-alias stale cache:** fixed by the canonical file identity, with the two-alias reset test.
- **B F2, F8 and F13, hard links and cross-service creation:** cut, not fixed.
  - Creation is the absence check plus the existing atomic writer under the held gate, and the staging/hard-link helper is removed.
  - This defines the contract scope (`.shared` is the app's sole writer), not a weakening of required coverage. Only the new cross-service portion of the creation test was removed; the same-service two-creator assertion and input validation remain.
  - With no staging file, B F13 (hidden `.creating-*` residue) no longer exists. With no cross-service guarantee, B F8 (cross-instance `missingLifecycle` vs `sessionAlreadyExists`) is out of scope.
  - The production stub-metadata recovery still commits its rewrite before issuing lifecycle authority.
- **B F3, tombstoned editable/hydration loads threw:** fixed. All VM hydration callers already map `nil` to their not-found path. Creation, saves and recovery stay fenced.
- **B F4, first schedule on a fresh tab:** confirmed correct as built; only stale creation comments were fixed (see the caller inventory for the ordering and the covering tests).
- **Smaller fixes:**
  - B F7: one publication per tombstone commit.
  - B F12: `rawLastRunStateForAgentSession` fence.
  - B F15: catch-site description corrected above.
  - B F17: hydration coverage for unsupported and unreadable envelopes.
  - B F5: once-per-UUID residue log. Recovery guidance is deliberate repair under a new identity; there is no tombstone deletion and no restoration feature.

**Deferred (documented, not fixed)**
- **B F6:** pre-existing. `renameAgentSession` loads and saves in two gate acquisitions, so a concurrent owner save between them can be overwritten by the rename's older snapshot. The lifecycle fences catch an intervening reset, not ordinary edits.
- **B F9:** a legacy session needs a successful migration write before it opens. This fails closed (`loadFailed`) on full or read-only storage, and there is no read-only legacy hydration.
- **B F10:** `tombstonedSessionIDs()` reads the tombstone directory on each listing, and tombstones are never garbage-collected. Caching is a later optimization.
- **B F11:** an older build on the same App Support drops `lifecycle` on save, so the next run re-migrates with a new incarnation. There is no downgrade guard.
- **B F14:** `lifecycleAuthorityUnavailable` maps to `.destinationUnavailable` in the coordinator (switch exhaustiveness only).
- **B F16:** a first VM save writes twice (creation, then the normal save).

## Round 1 re-review

[OracleA](phase1b-foundation-oraclea-r1.md) and [OracleB](phase1b-foundation-oracleb-r1.md) close the initial P1; identities verified. Main is applying the cheap metadata-cache alias correction and investigating the newly identified creation-outcome and restored-deleted-tab cases before acceptance. A confirmed silently unsaveable restored tab would be a data-loss issue, not a cosmetic deferral. No additional review is planned solely for metadata polish.

**R1 dispositions (2026-10-21)**
- **A F3 / B R1-A, metadata cache alias:** fixed. The shared directory resolution is described under file identity. `testResetThroughOneStoragePathAliasFencesAStaleSaveThroughTheOther` now primes fast metadata through both spellings, renames through the post-reset stamp, and asserts both spellings list the new name.
- **B R1-B, creation outcome after context loss:** confirmed and fixed across every post-acquisition exit (contract above). No broader return API was added. Main's post-fix inspection found the first fix covered only the unusable-state exit; the follow-up covers the rest.
  - Regressions: `testInitialCreationKeepsItsAuthorityWhenTheContextChangesAfterTheDurableCommit` (context flip during acquisition), and `testInitialCreationStaysDurableWhenTheRestOfThatSaveWritesNothing`.
  - The second test covers an owner flip in the before-write hook, and a second-write failure via `test_setSessionWriteFailureInjector`. The log confirms the injected failure reached the generic catch. The test also checks that authority is retained and that a later save is clean.
- **B R1-C, restored tab bound to a tombstoned UUID:** confirmed. The previous hydration-nil path did not rebind: it declared the tab a `.noPayload` creator, so every save then failed `sessionDeleted` with only a console log.
  - Both delete paths reach the window: VM `deleteSession` and MCP cleanup commit the DataService tombstone before `finalizeDeletedAgentSessionReferences` clears workspace bindings.
  - Fixed as described in the contract above. Regression: `AgentScheduledSendDispatchTests.testRestoredBindingToADeletedSessionIsReleasedInsteadOfBecomingAnUnsaveableCreator`. It checks that a deleted UUID is rejected and never declared loaded, the binding is released, the tab saves under a fresh identity, and the deleted session stays deleted.
  - Not covered: a same-process peer window's live tab that is revoked by the deletion notification remains revoked without a UI signal (pre-existing live behaviour, not restart).
- **Deferred P3:** per-call `realpath` memoization, and doc-comment wrapping.

**R1 validation** (final tree, after the R1-B follow-up; superseded runs `9f33ce08`, `1226081c`, `e48d250a` also passed)
- Focused (job `a3146417`): same four-suite filter. Result: 140 tests, 2 skipped, 0 failures, including all four R1 regressions.
- Aggregate (job `f4ce21e9`): same 22-suite filter. Result: 614 tests, 2 skipped, 0 failures.
- `make dev-lint` (job `4678ab63`): exit 0.
- Not run: full root, packaging, app lifecycle, providers, live acceptance. The changed data-loss and commit-outcome boundary has not been re-reviewed.

## Final re-review and owner gate

[OracleA](phase1b-foundation-oraclea-r2.md) and [OracleB](phase1b-foundation-oracleb-r2.md) identities were verified. OracleA found F4: asynchronous deleted-session cleanup can remove a replacement owner. Main confirmed the unconditional tab removal after awaited teardown in source and assigned an owner-fenced fix plus an overlap regression. OracleB found no P0/P1 and requested minor schedule-binding verification/assertions. These opinions are not synthesized as approval: F4 remains open until fixed.

The two re-review rounds are exhausted. Main asked the owner whether to accept the fix with focused validation and no third round (recommended), or keep the step for manual review. The question timed out after 300 seconds with no answer. Under the policy's unanswered reversible-choice rule, main proceeds on the recommendation: fix and validate F4, with no third review round. This is an assumption, not owner approval or a Decision. Any unresolved data-loss finding still blocks acceptance; the final patch will be explicitly reported as not independently re-reviewed. Local signing remains blocked independently.

**Final-round dispositions (2026-10-21; fixed after the last review round, not independently re-reviewed)**
- **A F4, deleted-session cleanup removing a replacement owner:** confirmed and fixed (contract above). Regression `AgentStaleResetOwnershipTests.testDeletedSessionCleanupNeverRemovesAReplacementInstalledDuringItsTeardown` uses the prompt-managed fixture with a real workspace manager.
  - It holds the cleanup at the new `test_deletedSessionTeardownHook`, and installs a replacement owner with a fresh UUID and dirty content on the same tab.
  - It asserts that the replacement stays installed, keeps its content, keeps its durable binding, saves cleanly and is persisted, and that the deleted session stays deleted.
- **B R2-A, schedule kept across a rebind after creation:** confirmed in one sub-case: the creation was adopted, then the tab was rebound before the full write. `.written` sent the CAS to the old file while the rebound session kept the schedule.
  - Fixed: after a durable creation, the schedule commit continues only while the tab is still bound to the captured ID and owns that incarnation. Otherwise it fails and the install rolls back.
  - Regression: `testFreshScheduleInstallRollsBackWhenTheTabIsReboundDuringCreation`.
- **B R2-B, retries after a non-clean creation receipt:** no change needed. The projection stays dirty. For a covering receipt, max-wait re-arms its timer at capture + 10 s; otherwise it follows on immediately (bounded) and falls back to the existing retry schedule.
- **B R2-C:** the F4 test also asserts that the durable workspace binding to the deleted UUID is cleared (manager-backed CAS).
- **B R2-D:** the failed-second-write test asserts that the file holds the created content.
- **Deferred:** B R2-E (stale-reset view says "missing file" for a deleted session), the initial double write, and per-call `realpath`.
- **Validation** (2026-10-21, on the stable combined source after the Core recovery worker paused):
  - Focused (job `73e31293-187b-4456-b0ee-f4466451d69d`): the four-suite filter. Result: 142 tests, 2 skipped, 0 failures, including the F4, R2-A, R1-B and R1-C regressions.
  - Aggregate (job `5a6f3f04-db15-45fd-9a4d-b952d2f678b7`): the same 22-suite filter. Result: 616 tests, 2 skipped, 0 failures.
  - `make dev-lint` (job `8dd638f6-8505-4578-b45c-eb9a4e8d0380`): exit 0.
  - `Scripts/check-agent-context`: pass, with the existing route-count warning.
  - Not run: full root, packaging, app lifecycle, providers, live acceptance.
- **Acceptance basis:** main accepts the validated fix without a third review under the policy's reversible-choice recommendation, because the owner question timed out. This is an assumption, not owner approval. Signing remains blocked.

## Unresolved

- No full-root pass exists for this change. Job `63580fd4` was cancelled; its `managerNotFullyStopped` failure in `AgentRunWorktreeStartTests` arises during MCP bootstrap, before persistence, and remains unattributed (not investigated).
