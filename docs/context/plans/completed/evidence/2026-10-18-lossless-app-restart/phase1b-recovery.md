# Lossless app restart — Phase 1b recovery store and composer controller evidence

Scope: read when the task touches the lossless-restart Phase 1b recovery record model, `AgentRecoveryStore`, the composer persistence controller, or the `AgentSessionDataService` recovery gate, discovery, and deletion cleanup.
Authority: Reference
Last-verified: 2026-10-21

Historical implementation evidence for the initially inactive recovery-persistence package of [the plan](../../2026-10-18-lossless-app-restart-spec.md) (R1, R1a, R2, R5, R9) and the [Phase 1 scope](phase1-scope.md). Planning guidance: `prompt-exports/oracle-plan-2026-10-20-231739-restart-phase-1-scop-2479.md`, corrected by `prompt-exports/oracle-plan-2026-10-21-002948-restart-phase-1-scop-335e.md`. The plan controls. This is XCTest evidence against temporary roots, not live acceptance.

## Historical isolation before the production cutover

The bullets below describe this package's original isolation, not current production composition. The [production input cutover](phase1b-cutover.md) now installs the store and composer lanes, send/queue producers, scheduler barrier, startup reconciliation and recovery UI. Complete quit/window-close preservation remains a separate unfinished package.

- `AgentSessionDataService.shared` is constructed without a recovery store. Discovery returns `[]` and deletion runs no recovery cleanup.
- Nothing constructs `AgentRecoveryStore`, `AgentRecoveryComposerPersistenceController` or `AgentSessionRecoveryLifecycleGate`.
- There are no send, queue-drain, scheduler, UI, shutdown, terminal-barrier producer or startup hooks.
- Activation stays coupled to the complete send/drain/schedule cutover.

## Current contract

**Storage and revisions**
- Record path: `AgentRecovery/v1/sessions/<sessionID>.json`. Managed images live in `AgentRecovery/v1/attachments/<sessionID>/`. XCTest processes get a temporary default root.
- Writes are atomic replacements through an injectable `FileOperations` seam.
- Record and composer revisions are opaque UUID tokens, used only for equality and CAS.

**Record contents**
- Record: `incarnationID`, latest `transcriptResetGeneration`, an optional composer snapshot, and three collections: `intents`, delivery `attempts`, and `runAttempts`.
- The composer snapshot carries its own `transcriptResetGeneration`, so a carried-forward snapshot is never relabelled.
- Intent fields: ID, `userItemID`, origin, and a captured `target`, which is `session` or `liveRun(runAttemptID, processRunID?, providerConversationID?)`. Also owning instance, reset generation, state, payload, optional schedule reference, `staleTargetMarkedAt` and `withdrawnAt`.
- Delivery attempt fields: `attemptID`, `intentID`, `userItemID`, optional `runAttemptID`, optional `transcriptTurnID`, instance, outcome, and `supersededOutcome`.
- A run attempt is keyed by the existing `AgentRunOwnership.attemptID`. It holds the reset generation, optional `processRunID` and `transcriptTurnID`, terminal evidence, and shutdown evidence.
  - Terminal evidence comes from `AgentRunTerminalCommitRevision`: `commitID`, a terminal `AgentSessionRunState`, and `expectedRunID`.
  - Shutdown reasons are `appQuit`, `windowClose`, `safeRestart` and `providerProcessLost`.
  - One run attempt can carry several deliveries.

**Codec**
- Unknown members are preserved at every object boundary and matched by identity on rewrite. Boundaries now include the target and its run, the superseded outcome, run attempts, terminal and shutdown.
- A record is decoded as supported only if it re-encodes exactly. Anything else is preserved byte-for-byte and is never writable:
  - a future schema;
  - a missing or ill-typed member, or an explicit `null`;
  - a non-canonical UUID or a fractional number;
  - an unknown variant (state, target kind, shutdown reason, non-terminal run state);
  - a broken invariant (open-attempt counts, acceptance, withdrawal, superseded-outcome, unique run attempts, composer generation ≤ record generation).

**Holds** (effective; derived where stated)
- `staleTarget`: the persisted marker, or a mismatch between the intent's generation and the authoritative one.
- `missingAttachment`: a referenced managed image is missing.
- `previousInstance`: derived; the intent's owner differs from the current launch.

**Transactions**

| Operation | Contract |
|---|---|
| `commitComposer` | Composer-revision CAS. The snapshot generation must equal the binding generation. Empty content removes the composer. A stored composer from another reset generation is held input: replacement and removal throw `heldComposerUnresolved` (category `heldInput`), even with a matching CAS. A same-generation replacement keeps unknown members of the composer, its content, and retained images, tagged files and workflow, matched by ID or workflow source. Known and supplied fields win, and an omitted entity is removed. |
| `commitQueuedIntent` → `AgentRecoveryQueueReceipt` | Persists `queued`, with conditional composer consumption in the same replacement. Only a same-generation composer is consumable, so a new intent commits and leaves a held draft intact. Receipts report `composerRevision` (current generation) and `heldComposerRevision` separately. An identical repeat reissues the receipt only while the intent is `queued` and unheld. |
| `commitDispatchingIntent` → `AgentRecoveryDispatchReceipt` | Persists `dispatching` and its attempt atomically. An identical repeat needs the same open attempt with the same run/turn association. |
| `issueQueueReceipt` | Read-only reissue for an unheld `queued` intent. |
| `beginDispatch` | `.liveQueue`: an unheld `queued` intent only. `.explicitUserAction`: may also dispatch `failed` or `deliveryUnknown` intents, and may claim only a `previousInstance` hold, never `staleTarget` or `missingAttachment`. The `userItemID` never changes. |
| `recordDeliveryOutcome` | Bound to the exact attempt. Identical evidence is `unchanged`. Acceptance refines `deliveryUnknown` or supersedes `failed` (kept as `supersededOutcome`). The intent then becomes `providerAccepted`, even when a newer attempt is open or the intent was settled or withdrawn. Recorded acceptance is never overwritten; other conflicts are rejected. |
| `settleToQueue` | Qualified no-handoff fallback. Needs exact-attempt `preHandoff` or `verifiedRejection` evidence. Closes the attempt and returns the same intent (same IDs, payload, target, holds) to `queued`. It is never applied to accepted or unknown delivery, so there is no unconditional rewind. |
| `markTargetStale` | Persists the hold idempotently. Rejected for accepted or withdrawn intents. |
| `withdraw` | From `queued`, `failed` or `deliveryUnknown`. Keeps the payload. |
| Run evidence | `ensureRunAttempt` (fill-in only; conflicts fail), `attachDeliveryAttempt`, `recordRunTerminal` (identical repeat `unchanged`, a different commit fails) and `recordRunShutdown` (the first reason is kept). Ownership whose `binding.persistentSessionID` is not the binding's session fails with `runAttemptConflict`. Never touches deliveries or the composer. |

**Attachments**
- Import copies into the managed directory before any reference, using `AgentAttachmentStore` validation.
- A source already in this session's managed directory is referenced in place, without a copy. If that file is missing, the import throws `attachmentUnavailable`.
- Rewrites never delete files: a record reference is not proof of global non-use.
- `managedImageRecordReference` reports a reference only.
- Files are removed only by `removeDataForDeletedSession` after a tombstone. A supported record and the attachment directory are removed. Unreadable or future record bytes, and their attachments, are preserved.

**DataService gate, discovery and cleanup** (Core integration)
- `recoveryLifecycleGate(for: AgentSessionPersistenceState)` returns `AgentSessionRecoveryLifecycleGate`. `performRecoveryTransaction` then:
  1. acquires the existing per-session gate;
  2. validates the stamp (service and deletion generation);
  3. requires no tombstone, an existing file, and a `.v1` lifecycle with the same incarnation and an equal reset generation;
  4. awaits the body while holding the gate, and releases on every path.
- Lock order: gate → store.
- The body is not reentrant: calling a gated operation for the same session from inside it deadlocks. Imports run outside the gate and are not lifecycle-validated.
- Race contract:
  - A recovery commit linearized before a delete or reset keeps its valid historical receipt.
  - A stale-authority write linearized after a delete or reset is rejected before the body runs.
- `discoverRecoveryRecords(for:)` classifies each raw entry under its session gate, rereading the record. The result is one of:
  - `.eligible(record, binding)`, with holds computed against the authoritative generation;
  - `.tombstoned` (committed or unreadable tombstone, whether or not cleanup ran);
  - `.nonactionable`, with reason `sessionFileUnavailable`, `authorityMismatch`, `authorityUnreadable` or `unreadableRecord`.
- Deletion calls `removeDataForDeletedSession` under the gate, after the tombstone and the session-file unlink. A cleanup failure is logged; it never reverses deletion, and a repeated deletion retries the cleanup.

**Controller** (`@MainActor`)
- Each change produces an immutable snapshot under a new revision, with the binding generation.
- Deadlines are absolute `ContinuousClock.Instant` values: a 300 ms debounce and a 2 s maximum from the first uncaptured mutation. Sleep and clock are injected.
- `submitQueued` and `submitDirect` return the store receipt with guarded consumption. Newer typing is never consumable.
- `loadRestorableComposer` validates the read and sets the baselines inside the serialized operation:
  - `durableComposerRevision` is the current-generation CAS baseline;
  - `heldComposerRevision` is never a write or consumption baseline.
- It then returns `.superseded` if typing occurred during the read (the next write replaces the stored composer), or `.heldForOtherGeneration` for a composer from another reset generation.
- After a successful write, issued revisions before the committed one are trimmed and `heldComposerRevision` is cleared (a write succeeds only when no held composer is stored).
- Submissions keep the call-time consumption cutoff. Inside serialization they also add a same-generation baseline learned by a preceding restore if it is still the stored composer: this controller did not issue it, so it predates the submitted edit. A newer revision this controller wrote never qualifies.
- Producer contract (N-3, documented on the controller): restore before forwarding edits, or pass the discovered baseline to `init`. A write serialized before the first restore fails with `composerRevisionConflict` and is retried only on the next edit or flush.
- All store calls run inside the lifecycle gate.

## Files

- New Core:
  - `Models/AgentRecoveryModels.swift`;
  - `Runtime/Recovery/AgentRecoveryRecordCodec.swift`;
  - `Runtime/Recovery/AgentRecoveryStore.swift` (includes the gate protocol);
  - `Runtime/Recovery/AgentRecoveryComposerPersistenceController.swift`;
  - `Runtime/Recovery/AgentSessionRecoveryLifecycleGate.swift`.

  All paths are under `Sources/RepoPromptAgentCore/AgentMode/`.
- Changed Core:
  - `Runtime/AgentAttachmentStore.swift`: adds a caller-root import overload.
  - `Runtime/AgentSessionDataService.swift`: an optional injected `recoveryStore` (default `nil`), the gate and transaction, discovery, and deletion cleanup.
- Tests, under `Tests/RepoPromptTests/AgentMode/Recovery/`:
  - `AgentRecoveryTestSupport.swift`;
  - `AgentRecoveryStoreTests.swift` (17);
  - `AgentRecoveryComposerPersistenceControllerTests.swift` (15);
  - `AgentSessionRecoveryIntegrationTests.swift` (5, real DataService).
- No VM, `+ScheduledSend`, foundation test, plan, ledger or index file was edited.

## Initial review

Reviews: [OracleA](phase1b-recovery-oraclea.md) (REC-01–03) and [OracleB](phase1b-recovery-oracleb.md) (F-1–F-8).

| Finding | Disposition |
|---|---|
| REC-01 / F-1 held draft lost | Fixed, using the minimal fail-closed option (not a `heldComposers` collection). Store: held replacement and removal throw `heldComposerUnresolved`, and a held draft is never consumed. Controller: held and current baselines are separate. Tests: held → type/flush and held → submit (queued and direct), each reloaded through a second store, prove the text, workflow, tagged files and image survive. |
| REC-02 / F-2 restore race | Fixed: the baseline is learned inside the serialized restore. Test: a nonempty stored composer, typing during a paused restore, then a successful flush and reload. |
| REC-03 extras lost on edit | Fixed in `commitComposer` (centralized, matched by identity). Test: a real controller text edit after restore keeps composer, content, image, tag and workflow extras; an explicitly removed tag stays removed. |
| F-3 re-import copies | Fixed. Test: file count and path stay stable; missing managed file; missing external source; another session's file is copied. |
| F-4 coverage | Covered by the tests above. |
| F-5 `issuedRevisions` growth | Fixed: trimmed after a successful write. This is safe because submissions capture consumption at call time and pre-committed revisions can no longer be stored. |
| F-6 foreign ownership | Fixed, with a test of a foreign and a spoofed owner. |
| F-7, F-8 | Deferred (see Pending). F-8 call discipline is documented on `AgentRecoveryLifecycleGate`. |

## Re-review 1

Reviews: [OracleA R1](phase1b-recovery-oraclea-r1.md) and [OracleB R1](phase1b-recovery-oracleb-r1.md). REC-01, REC-03 and F-1 to F-6 were closed.

| Finding | Disposition |
|---|---|
| REC-02a: a submission enqueued during a paused restore captured consumption before the restore learned R0 | Fixed with `effectiveConsumption`, as described under Controller. Tests (queued and direct): R0 is stored, the restore pauses, R1 is typed and its submission is confirmed enqueued before release, then R2 is typed. A fresh reload shows the R1 intent and no stored composer; R2 stays pending, then flushes and reloads. A separate test shows that a newer stored revision is never consumed. With the fix disabled, both race tests fail (job `b00077a5-985c-4c79-9005-498cec2b57e3`). |
| N-1: a live reset blocks saves until resolution | Production-cutover blocker (see Pending). Nothing carries a held draft forward or retargets it automatically. |
| N-2: stale `heldComposerRevision` | Fixed. Test: once the held composer is gone, the next successful write clears it. |
| N-3: a write before the first restore | Producer contract documented (see Controller). |

Core integration (gate ordering, tombstone-first cleanup, unknown-record preservation) is unchanged, and production stays inactive.

## Validation

- Re-review 1 fixes, job `5b7f6138-a940-44a5-a436-feb826432e89`: the same filter ran 37 tests (store 17, controller 15, integration 5) with 0 failures. `make dev-lint` job `db3f7200-e97e-489a-83ab-cdf0b696e906`: 0/2097 files require formatting.
- Initial-review fixes, job `742755a2-2081-44e3-bd86-1fb51d30fcc9`: the same filter ran 34 tests (store 17, controller 12, integration 5) with 0 failures. `make dev-lint` job `6c73f96d-7875-4229-a6ad-1d553396395e`: 0/2097 files require formatting.
- Before review: `RPCE_ALLOW_UNKNOWN_FILTER=1 make dev-test FILTER="'AgentRecoveryStoreTests|AgentRecoveryComposerPersistenceControllerTests|AgentSessionRecoveryIntegrationTests'"`, final job `d06be25f`: 28 tests, 0 failures. The full test target compiled.
  - The override is needed because the preflight checks only a single unledgered name.
- `make dev-lint`: 0/2097 files require formatting. Lint findings were fixed by hand.
- Not run: the full suite, packaging, app lifecycle.

**Coverage added this round**
- Real gate races (event log plus latches held inside the gate):
  - recovery first, then delete: the historical receipt is valid; deletion removes the record; a later stale write is rejected;
  - delete first: the recovery body never runs and nothing is written;
  - recovery first, then reset: the commit is at generation 0 and the old gate is retired; the new gate writes; the pre-reset intent is held `staleTarget` with its target intact;
  - reset first: the old gate is rejected without a write, and restore returns `heldForOtherGeneration`.
- Relaunch discovery:
  - cleanup-failure residue → `tombstoned`;
  - future bytes kept through deletion → `tombstoned`, bytes unchanged;
  - another workspace → `sessionFileUnavailable`;
  - a stray file → nonactionable;
  - a live session → eligible with `previousInstance`;
  - successful cleanup removes the record and the attachment directory;
  - repeated deletion retries the cleanup;
  - a tombstoned session yields no editable authority.
- Store:
  - a persisted stale target blocks live-queue drain, explicit dispatch and receipt reissue across reload, while withdrawal is allowed;
  - settle-to-queue keeps the same intent and item IDs, and the queue receipt is reissued;
  - accept-then-reconciliation-failure is never queued, and unknown delivery cannot be settled;
  - late acceptance with a newer attempt open, failed → accepted, and withdrawn → accepted, each with history kept;
  - run evidence: a shared run, a terminal without an envelope, idempotent and conflicting commits, a shutdown conflict, turn fill-in;
  - target and run extras;
  - rewrites never delete attachments.

## Final re-review

[OracleA R2](phase1b-recovery-oraclea-r2.md) closed REC-02a with no new findings. [OracleB R2](phase1b-recovery-oracleb-r2.md) found no open P0/P1. Main verified both returned preset identities. The two-round re-review limit is exhausted.

Cheap final cleanup: clarified the submission baseline comment and renamed the newer-self-written-revision test to describe its actual protection; no behavior or assertion changed. The controller has an internal enqueue counter for deterministic test synchronization, not a production recovery hook.

Production prerequisites include exactly one live composer controller per durable session, with old ownership retired before replacement; restore before forwarding edits (or inject the validated baseline); and explicit held-draft resolution. No automatic carry-forward is authorized by this review.

Final comment/test-name cleanup validation: `make dev-test FILTER=AgentRecoveryComposerPersistenceControllerTests`, job `63a938e1-7d63-4e58-a0b7-b34b3687cb73`, passed 15 tests with zero failures. `make dev-lint`, job `9f209ab2-642e-4e5e-a840-07460827037c`, passed. `make guardrails` and `Scripts/check-agent-context` passed with the existing route-count warning. Guardrails must run again after these currently untracked files are staged; this run does not establish staged allowlist coverage.

Local commit remains blocked by the configured 1Password SSH signing failure. The existing Phase 1a index snapshot remains separate; this package is unstaged. No signing bypass or push was performed.

## Pending (reported, not substituted)

- **Producers:** capture of provider-acceptance evidence immediately after a successful return; `NativeSendOutcome` / `CodexSteerAckTracker.TerminalState` mapping (`.durablyQueued` is not acceptance); receipt-bearing queue acks on both queue paths; drains; the scheduler; the terminal-barrier hook; shutdown reasons.
- **R9:** receipt kinds and the startup barrier are not modelled.
- **Held composer resolution (cutover blocker, N-1):** a held draft blocks new-generation composer writes until it is resolved. An explicit user resolution (discard, or an explicit carry-forward for live reset-rebind) and its UI must land with or before any producer that constructs this controller. Nothing carries it forward or discards it automatically.
- **Failed-write retry (F-7):** a failed composer write is retried only on the next mutation or flush.
- **Gate/API restructuring (F-8):** only call discipline is documented. Imports and direct store calls remain ungated.
- **Attachments:** comprehensive ownership across live input and schedules is not modelled, so there is no deletion other than whole-session cleanup.
- **GC:** record garbage collection is not implemented.
- **Origin set:** inferred from "Done when" 1.
- **`interviewFirst`:** the snapshot records only the producer-supplied value.
