# Phase 1b foundation review — OracleA

Scope: read when the task touches lossless restart durable lifecycle foundation review evidence.
Authority: Reference
Last-verified: 2026-10-20

Preset identity verified: `61D024A4-CCFB-4C9C-A614-CC65E0A1864C` (OracleA). Initial independent code review; validation evidence supplied, not independently executed.

The foundation adds durable lifecycle identity to v7 sessions, gate-held migration and exclusive creation, atomic reset receipts, and UUID-wide tombstone-first deletion. The fixture changes generally reflect the intended contract rather than weaken assertions: stale snapshots retain their stale contents, and the cross-workspace cleanup test still checks unchanged file bytes. Two ownership/fencing issues remain. This review is based on the supplied source and index-relative diff; tests were not independently executed.

## P1 — Should fix

### F1 — Initial creation can commit successfully but lose its owner’s persistence authority

**Evidence:** `AgentModeViewModel+ScheduledSend.swift:1046–1073`, `ensurePersistenceState`.

- **Scenario:** The first save awaits `prepareInitialAgentSessionPersistence`. While DataService commits the file, the workspace context changes. The post-await context guard returns `nil`, discarding the newly issued state before assigning either `persistenceState` or `persistedIncarnationSessionID`.
- **Impact:** If that same in-memory session remains or becomes current again, subsequent saves attempt initial creation, receive `sessionAlreadyExists`, and refuse to adopt it. The owner can no longer save newer edits without a reload—even though it created the file itself. The comment claiming that the committed incarnation remains recorded when the owner moves on is not implemented.
- **Smallest fix:** Retain the successful creation result for the exact originating session lifetime independently of whether its workspace context remains active. Still reject adoption by a replaced or revoked owner, and keep UI publication/current-save checks context-sensitive. Do not fix this by adopting arbitrary existing files.
- **Targeted test:** Suspend initial persistence after its file commit, invalidate the context while retaining the same owner, restore that context, and verify newer edits save using the original creation authority.

## P2 — Consider

### F2 — URL aliases can retain conflicting “authoritative” lifecycle caches

**Evidence:** `AgentSessionDataService.swift:1413–1415` (`canonicalSessionFileKey`), `currentDurableLifecycle`, and the reset-cache updates in `saveAgentSessionLocked`; the attached foundation evidence confirms `/var` versus `/private/var` aliases occur.

- **Scenario:** One DataService acquires editable states through two workspace storage references resolving to the same file but using different symlink spellings. Both cache generation zero. A reset through one spelling updates only that cache entry. A subsequent save through the other spelling gets a **cache hit** for generation zero and can overwrite the reset transcript and durable generation.
- **Impact:** The documented “cache miss → durable header read or fail closed” explanation does not cover stale cache hits. This is an uncommon path-alias configuration, but it defeats the reset fence without another writer or process.
- **Smallest fix:** Use one stable file identity for all lifecycle, reset, schedule, and deletion caches and pinned stamps—for example, resolve the existing parent directory’s symlinks before constructing the session-file key.
- **Targeted test:** With one service and two aliases of one temporary directory, reset through one captured state and assert that a pre-reset save through the other is rejected.

## Recommendations

Fix F1 before accepting this foundation. Address F2 with shared key normalization and an alias regression test if practical; otherwise explicitly defer it as a reset-fencing limitation, not merely a safe cache miss. Rerun affected lifecycle and VM ownership suites; neither a full-root pass nor live-app testing is necessary solely for review completeness.
