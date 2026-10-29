# Step 9-activation-b design proposal (worker, read-only)

Scope: read when the task touches Check confirming crash holds from process-registry proof (Step 9-activation-b).
Authority: Reference
Last-verified: 2026-10-27
Covers: the worker's read-only design for registry-proven crash-hold confirmation (file:line references at 6f8d1edb), with §2 rewritten to the proof as implemented.

I've written the design proposal below and made no edits. In brief: Check can safely confirm a crash hold only with one new piece of evidence, a mark written at run start. The registry today can't tell "this run's launches were registered" apart from "this run was never registered".

## 1. How the pieces link today

- **Crash hold:** `AgentRecoveryCrashHold` (`AgentRecoveryCoordinator.swift:345`) is built at startup by `deriveCrashHolds` (`:962-991`). It holds the session's incarnation and reset generation, the open run attempts (no terminal evidence), any earlier-instance intents still `dispatching`/`deliveryUnknown`, and legacy interrupted turns. Holds whose stored acknowledgement matches exactly are confirmed again at `:929-933`.
- **Run attempt:** `AgentRecoveryRunAttempt` (`AgentRecoveryModels.swift:738`) records `appInstanceID` and the `providerKind` extra (written at `AgentRecoveryStore.swift:1207`). It records nothing about process registration.
- **Registry link:** one runtime record per spawn. Its associations carry `AgentRuntimeSessionAssociation(sessionID, incarnationID, generation, runAttemptID?, processRunID?)` (`AgentRuntimeRecordModels.swift:87`). The run attempt is captured from the owner's scope (`AgentTabSession.swift:836-843`). Exited records stay on disk and are never examined again (`AgentProcessRegistry.swift:316-320`). They are, however, left out of `restrictionSnapshot()` (`:100-152`), so the coordinator's adopted `runtimeRestrictions` cannot show that a run *had* registered processes.
- **The "It stopped" write:**
  - window: `confirmRecoveryCrashHold` (`AgentModeViewModel+RecoveryList.swift:1341`) opens the session when no lane exists, then calls
  - `coordinator.confirmCrashHold(hold, lane:)` (`:1553`), which calls
  - `lane.recordCrashHoldAcknowledgement` (`:3012`), which calls
  - `store.recordCrashHoldAcknowledgement` (`AgentRecoveryStore.swift:1570`).
  
  The only thing it needs from the open session is the lane's `binding` and transaction. The closed-session Dismiss path already gets both without a lane: `reconciliation.resolution(for:).binding` plus `dataService.performClosedRecoveryTransaction` (`AgentRecoveryCoordinator.swift:809-853`, `AgentSessionDataService.swift:3474`).

## 2. Proof as implemented (rewritten after OracleD's plan check, Recommendation 1)

This section replaces the original proposal. It was rewritten when Step 9-activation-b was implemented following [OracleD's plan check](activation-b-plan-oracled.md). §3 and §4 below are the original proposal and are kept as history. Check confirms a crash hold only when every condition holds. A refusal is `Needs you: Confirm the previous run stopped (<reason>)` unless noted.

- **(a) Checks active and registry healthy.** Before activation, Check confirms nothing. The registry query (`AgentProcessRegistry.crashHoldExitProof`) requires all of the following, otherwise "process ownership is uncertain":
  - the registry has started and has no storage failure;
  - the registry's store has the same `appInstanceID` as the coordinator's (F8);
  - no unidentified preserved record;
  - no preserved record that names the session or overlaps its conversations or worktrees.
- **(b) Runs only.** The hold has at least one run attempt, no intents and no legacy turns. Otherwise "it has a saved message or an older interrupted turn". Every held attempt carries the run-start mark `runtimeRegistration: "registry"`, otherwise "it started before process checks were active". There is one source for the mark (F2): `AgentRuntimeLaunchAuthority.runStartRegistrationMark`. It returns the mark only when the run's authority is the registry and every supported family serving the run's provider is covered. The mark is captured once on the run's ownership (`AgentTabSession.beginRunAttempt`). Only the run-start dispatch creators write it (`commitDispatch`, queued-input dispatch); terminal, shutdown and delegated-link creators pass `nil`. A non-creating `ensureRunAttempt` never changes the mark.
- **(c) Completeness.** For each held attempt, an earlier-instance runtime record has an association naming the same session, incarnation and run attempt. Otherwise "no process record names this run". Records of the current instance never count; for example, a Codex Reconcile associates the held attempt in this launch.
- **(d) Safety (F1).** No earlier-instance record is non-terminal if it could belong to the session. That covers records that are sessionless, have no association, name the session at any incarnation, or share one of the session's conversation IDs or worktree paths. The session's keys are the window's ownership keys plus, for every record with an association naming the session, that association's keys and the record's own conversation IDs and worktree paths (round-0 review B A5). Only `.exited` and `.stopped` count as terminal, and only if their state was persisted; `toolsRemaining`, `detachedAtQuit`, `unknown` and live states all refuse with "an agent process may still be running". The mixed-instance cut is dropped (F4): every earlier launch is held to the same rule. Terminal earlier-launch records are kept across launches: `loadRecords` loads every record, discovery skips `.exited`/`.stopped`, and nothing deletes runtime files.
- **(e) The adopted snapshot agrees.** A send restriction from an earlier instance gives "process ownership is still being updated", so a lagging snapshot refuses until it is adopted. A send restriction from the current instance gives "an agent process may still be running". Global uncertainty gives "process ownership is still being updated".
- **(f) Currency.** The hold must still be current and unconfirmed, and the catalog item's acknowledgement and payload unchanged; otherwise `Could not check: It changed since the check started. Review it again.` A recovery-action hold gives `Could not check: Another action on this session is in progress.` (f) runs before the query and after it; (e) and (f) run again before each commit attempt. The write itself also passes the captured card's key and freshness, and the store refuses it (`.cardChanged`, reported as changed) when that card was dismissed meanwhile, atomically with the write (round-0 review A P1-01).
  - Once Check starts the work, the row is `.working` until the confirmation ends; Stop doesn't clear it. A Stop before the commit writes nothing; a commit already in flight finishes and is published (F5). Either way the report says `Could not check: Stopped while confirming. If it was saved, its card shows sending resumed.`
- **Write (F7).** An open session writes through its live lane; a lane whose incarnation or generation differs refuses as changed. A closed session writes through `performClosedRecoveryTransaction` with its resolution's binding. Without a resolution, binding or workspace the result is "open this session to confirm it".
  - A revision conflict retries up to 3 times, re-running the currency checks each time.
  - Both paths and "It stopped" publish through the same `publishCrashHoldConfirmation`.
  - Success is `Resolved: Process records show every process of the interrupted run exited.`; a write failure is `Failed: The confirmation couldn't be saved.`
- **`.stopped` (F3).** `stop()` writes `.stopped` only after a fresh refresh and inventory show the family complete with no live identity, writers and tools included (`AgentProcessRegistry.swift:1110-1116`). So it is verified-terminal and accepted alongside `.exited`.
- **Wording (F6).** The Check header and the Needs Attention sheet show the same sentence before a run: "Checks process ownership and provider history, and confirms a paused session stopped when process records prove its processes exited. Clearing a restriction or confirming a paused session may let already-authorized scheduled sends run."

## 3. Smallest implementation

- **Store:** an optional run-start parameter (like `providerKindRaw`) that writes the `runtimeRegistered` extra. It is forward-compatible, with no schema change.
- **Registry:** `AgentProcessRegistry.crashHoldExitProof(sessionID:incarnationID:runAttemptIDs:appInstanceID:) -> proven | notProven(reason)`.
- **Coordinator:** `confirmCrashHoldFromRegistryProof(_ hold:) async -> AgentRecoveryCheckOutcome` in `+Check.swift`. It re-checks items 5–7 after each await, then:
  - with a live lane matching the hold's binding, it reuses `confirmCrashHold(hold, lane:)`;
  - otherwise it adds a lane-free variant of the same function that writes `store.recordCrashHoldAcknowledgement` inside `performClosedRecoveryTransaction`, retrying on revision conflict like `acknowledgeClosedCard`. The session is never opened.
  
  After the commit it publishes `confirmedCrashHolds` and calls `postCoordinatorDidChange()`.
- **Hook:** in `checkOutcome`, a `.crashHold` branch placed before the run-card guard (`+Check.swift:351`). Everything else is unchanged.
- **Concurrency:**
  - Open session: the lane transaction serializes with composer and question writes.
  - Session opening mid-check: `performClosedRecoveryTransaction` validates the binding under the same gate and lock order as live lanes. Its `revisionConflict` is retried, and any other failure reports Failed.
  - Scheduled sends: confirming lifts the workspace-busy state via `unresolvedSessionSummary` (`:1503`). The header text "Clearing a restriction may let already-authorized scheduled sends run." already covers this. I'd keep the wording and add "or a confirmed crash hold" only if the owner wants it.
  - Stop: unchanged. The write runs inside the item's unstructured task, and a late commit reaches only the row.
- **Row and report:**
  - Success: "Resolved: Process records show every process of the interrupted run exited." The row leaves "Needs action" through the normal confirmed-hold projection.
  - Refusal: "Needs you: Confirm the previous run stopped (…reason…)". Example reasons: "it started before process checks were active", "an agent process may still be running", "process ownership is uncertain".
- **Tests:**
  - Extend `testCheckBeforeActivationReportsNotActiveAndWritesNothing` (no acknowledgement written) and `testCheckClassifiesRepresentativeItems`.
  - In `AgentRecoveryRuntimeOwnershipTests`, extend `testCheckRefreshesOwnershipFirstAndReportsAProvenExit` with a confirmed-hold case.
  - New: a closed-session confirm without opening (with a store round-trip and a re-startup hold check, mirroring `testCrashHoldsCoverOpenRunsAndUncertainDeliveryAndConfirmOnlyTheExactHold`).
  - New: a table of refusals (missing mark, missing record, one live record, `toolsRemaining`, unreadable record naming the session, storage failure, legacy turn, mixed-instance intent, changed hold, busy, write failure, an open lane confirming through the lane).
  - New: confirmation unblocks a workspace schedule only after commit (extend `testCrashHoldBlocksNewSessionSendNowUntilItStoppedThenDispatchesOnce`).

## 4. Risks and cuts

- **Risk:** association completeness. The proof assumes every write for a covered pair is fenced by an association carrying the run attempt. Associations that merge with a nil run attempt (`AgentProcessRegistry.swift:851-890`) can attach it late. Live acceptance (9-live) should check that each Claude-standard and Codex run leaves a record naming its run attempt.
- **Risk:** the closed-session write path is new for this kind of write, so it needs the same tombstone and incarnation checks; `performClosedRecoveryTransaction` already provides them.
- **Cut:** holds with uncertain intents. Confirming only holds that contain run attempts alone is simpler and safer. Most crash-mid-send holds would then still need "It stopped", which is acceptable.
- **Cut:** accepting `toolsRemaining`.
- **Cut:** any fallback that treats "a record exists" as proof when the run-start mark is missing.
- **Defer:** changing the header wording.
