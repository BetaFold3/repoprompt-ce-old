# Lossless app restart — Phase 3 process-registry evidence

Scope: read when the task touches the lossless-restart R6 runtime-ownership registry (`AgentProcessRegistry`, runtime records, managed launch fences, operation-owner capture, recovery admission/scheduler restrictions, Refresh / Let finish, or the disabled Stop engine).
Authority: Reference
Last-verified: 2026-10-22

Implementation evidence for Phase 3 (R6 process registry) of [the spec](../../2026-10-18-lossless-app-restart-spec.md). Base HEAD `93af6fb55a9044c7d8134e9c6be41c792db497d8`; nothing staged or committed. Sources:

- Authoritative package plan: [phase3-registry-plan.md](phase3-registry-plan.md), including its "Activation clarification".
- Planning guidance: Oracle export `prompt-exports/oracle-plan-2026-10-21-224553-restart-phase-1-scop-425e.md`.
- Navigation only: the scout export.
- Main-agent coverage probe: `prompt-exports/agent-run-2d54ad1dc1e4-8a993fd1.md`.

This document records what was built and tested. It makes no review-approval claim; no review of the closure round has been run by this package.

## Status in three separate dimensions

| Dimension | Status |
|---|---|
| Source completeness | Registry, records (provider identity, per-operation associations, `detachedAtQuit`), launch fences, operation-owner capture, discovery/watches, recovery integration, Refresh / Let finish and the Stop engine are implemented for the launch boundaries listed under [Coverage](#coverage-and-association-outcomes). The earlier open contract gaps are closed in source (see [Closure of the earlier gaps](#closure-of-the-earlier-gaps)). |
| Activation | **OFF.** `AgentRuntimeQualification.production` qualifies no family, so `AgentRuntimeLaunchAuthority.production` is `.activationOff`. No production launch reserves, marks or fences. Existing on-disk records are still loaded and enforced when a registry is attached. Production Stop is disabled. Fresh Claude `--session-id` is a separate gate, also OFF, keyed by family **and** provider. |
| Live acceptance | **Not done.** No real provider was launched, qualified, inspected, watched or signalled. All evidence is XCTest over injected process boundaries, pipe-only fixture transports with DEBUG fence checkpoints, and `/bin/sh` fixture executables for the CLI-runner hook tests. |

## Implementation and anchors

### Records and storage

- **Record model:** `Sources/RepoPromptAgentCore/AgentMode/Models/AgentRuntimeRecordModels.swift`.
  - `AgentRuntimeRecord` is schema 1, with additive fields.
  - States: `reserved`, `live`, `toolsRemaining`, `exited`, `stopped`, `unknown`, `detachedAtQuit`. `mayHoldWriter` is true for `reserved`, `live`, `unknown` and `detachedAtQuit`.
  - `detachedAtQuit` is a compatible variant with **no producer**. Discovery keeps it while the family is alive and moves it to `exited` once the family is proven gone.
  - Families: `claudeNative`, `claudeCompatible`, `claudeHeadless`, `codexAppServer`, `codexExec`, `acp`.
  - `provider: AgentRuntimeProvider?` is the actual provider identity. Raw values are `claude.<variant>`, `codex` and `acp.<providerID>`. An unknown raw value is preserved and treated as unknown; a legacy record without one decodes as `nil`. Both are conservative.
  - `associations: [AgentRuntimeAssociation]`, one per owner operation. Each carries:
    - `session: AgentRuntimeSessionAssociation?` (`sessionID`, `incarnationID`, `transcriptResetGeneration`, `runAttemptID`, `processRunID`); `nil` only for genuinely sessionless work;
    - `conversationID`, `worktreePath`;
    - `permission: AgentRuntimePermissionSnapshot`, one of:
      - `.claude(permissionMode:)`;
      - `.codex(approvalPolicy:sandbox:)`;
      - `.acp(sessionModeID:autoApproveAllToolPermissions:)`;
      - `.unavailable`.
  - Other fields: `providerHome` (nil = unresolved), root birth identity and group, `rootReaped`, members (`identity`, group, `role`), `conversationIDs`, `worktreePaths`, `letFinish`, `extras`.
  - `AgentRuntimePreservedBindings` carries what an unreadable record still reveals: conversations, worktrees and session IDs.
- **Codec:** `AgentRuntimeRecordCodec.swift`.
  - It uses opaque revision CAS and preserves additive fields.
  - Future schemas and unknown closed variants stay preserved and nonwritable.
  - Argv and environments are never persisted (tested by a codec round-trip).
- **Store:** `AgentRecoveryStore+Runtimes.swift`, under `AgentRecovery/v1/runtimes/<UUID>.json`, in the existing `AgentRecoveryStore`.

### Registry

`Sources/RepoPromptAgentCore/AgentMode/Runtime/Recovery/AgentProcessRegistry.swift` (actor), with `AgentProcessRegistrySupport.swift`.

**Launch lifecycle:**
- `reserveLaunch(AgentRuntimeLaunchContext)` reserves `family`, `provider`, the reserving `session` scope, `worktreePath`, `conversationID` and the requested `permission`. It checks the two-writer rule (`writerConflict`).
  - A refusal means no record and no spawn.
  - A `.unavailable` session scope (an Agent Mode caller that lost its context) is refused and writes nothing.
  - `.sessionless` reserves with `session == nil`.
- `registerSpawn` commits the birth identity.
- `spawnFailed`.
- `associate(runtimeID:launchToken:association:)` appends or merges one operation's association, checked for conflicts.
- `recordObservedConversation(runtimeID:launchToken:association:)` records a conversation observed on headless output, even after the root was reaped.
- `authorizeWrite` checks the exact `(runtimeID, launchToken)`.
- `rootReaped` is root-lifetime evidence only.

**Restriction predicates:**

| Predicate | Rule |
|---|---|
| `overlapsConversation` | Provider-aware: an equal conversation ID under a different known provider does not overlap. An unknown or missing provider overlaps. |
| `overlapsSession` | Same Agent Mode session ID, across transcript resets and incarnations. |
| `blocksSend` | Conversation overlap, or session overlap, or an unassociated record on an overlapping worktree. |
| `writerConflict` | Conversation overlap only, for active launches; the full `blocksSend`, for inactive ones. |

**Discovery:**
- `start` / `refresh` take a bounded same-owner `ProcessInventory` snapshot.
- `discoverFamily` follows marker and parent links. Earlier-born processes and the app itself are excluded.
- `classify` is conservative.
- `installWatches` / `watchFired` deliver exit events through `ProcessExitWatch`. Rediscovery is coalesced (`refreshRequestedDuringPass`). There is no polling.

**What never proves exit:** root exit, a clean exit mark, a missing marker and denied inspection all leave the family not proven exited. An incomplete inventory keeps a record `unknown`.

**Other operations:**
- `letFinish` uses revision CAS and is persisted.
- `previewStop` / `stop` run the engine with injected `AgentProcessStopActions`. `isStopEnabled` is false in production.

### Launch fence

`AgentRuntimeLaunch.swift`:

- **`AgentRuntimeLaunchContext`:** `family`, `provider`, `session: AgentRuntimeSessionScope`, `worktreePath`, `conversationID`, `permission`.
- **`AgentRuntimeLaunchAuthority`:**
  - `production`;
  - `makeLaunch(_ context:)`;
  - `allowsFreshSessionID(_ family:, provider:)`, where qualification is keyed to the actual provider;
  - `strippingInheritedMarker`.
- **`AgentRuntimeLaunch`** (actor, `ProcessLaunchOwnership`) has one owner per actual spawn. Its methods:
  - `prepareSpawn`, `commitSpawn`, `spawnFailed`, `rootReaped`;
  - `associate(session:conversationID:worktreePath:permission:)`;
  - `associate(conversationID:)`;
  - `recordObservedConversation(_:)`;
  - `authorizeWrite(conversationID:)`.
- **`AgentRuntimeOperationOwner`:**
  - `@TaskLocal static var session: AgentRuntimeSessionScope?`;
  - `current` returns that value, or `.unavailable` when unbound.
- **`AgentRuntimeSessionScope`** has three cases:
  - an Agent Mode session association, captured once;
  - `.sessionless`, an explicit non-Agent-Mode context;
  - `.unavailable`.

### Platform

- `ProcessLaunchOwnership.swift`: optional prepare / commit / failed / reaped hooks.
- `ProcessInventory.swift`: bounded listing, `ProcessExitWatch`.
- `CLIProcessRunner.swift`:
  - Both `run` and `runStreaming` prepare before the spawn and commit before stdin.
  - A commit failure reaps the exact root and delivers no stdin.
  - `additionalRemovedKeys` lets unmanaged callers strip the inherited marker.
  - Unrelated Platform callers keep their current behavior.

### Recovery integration

- `AgentRecoveryCoordinator+RuntimeOwnership.swift`:
  - `attachProcessRegistry`, `startRuntimeOwnership`;
  - pull-based restriction adoption, where the latest pull wins;
  - `runtimeSendRefusalReason`, `runtimeBlocksAutomaticWork(sessionID:additionalKeys:)`, `runtimeBlocksAutomaticWork(worktreePath:)`, `runtimeSendRestriction`, `refreshRuntimeOwnership`, `letRuntimeFinish`.
- `AgentRecoveryCoordinator.swift`: shared admission.
- `AgentRecoveryCatalog.swift`: never-dismissible `survivingProcess` items and the global `runtimeOwnershipUnknown` item.
- `AgentModeViewModel+RecoveryList.swift` and `AgentRecoveryListBanner.swift`: the list and banner.
- `AgentModeViewModel+ScheduledSend.swift`: scheduler gating. `runtimeOwnershipKeys(for:)` derives keys from the session object, so sessions no window hosts are still restricted.
- `Sources/RepoPrompt/App/AgentRecoveryAppComposition.swift`: composition.

**Restriction rules:**
- A send is blocked by a possible writer of the session's conversation or of the same session, including before any conversation is known.
- A send is also blocked by an unassociated possible writer on an overlapping worktree.
- Automatic work is additionally blocked by any overlapping worktree.
- Global uncertainty (unidentifiable records or a storage failure) blocks everything.

## Operation-ownership capture and write fences

**Contract.** Ownership is captured at the operation's owner, as an immutable value, and never read from a live session source when a write happens. No session-source type or setter exists, and the Codex client keeps no mutable "current session". These rules hold in every family:

- **Detached work** re-binds the scope its owner captured when it was scheduled.
- **Callbacks, replies, cancellations and interrupts** never associate. They only authorize on a conversation an owner operation already associated, so a late callback cannot be attributed to a later run.
- **Missing context.** An Agent Mode path with no captured scope sees `.unavailable`, and an owner write then fails.
- **Sessionless paths.** Genuinely sessionless paths pass `.sessionless`, which is explicitly nil.
- **No fabricated IDs.** Session, attempt and conversation IDs are never invented.

### Where each family captures the owner

**Agent Mode tab session.** `AgentTabSession.withRuntimeOperation(processRunID:)` synchronously captures `runtimeSessionScope` (session, incarnation, reset generation, active run attempt and process run). It then runs the body under `AgentRuntimeOperationOwner.$session.withValue`.

**Codex coordinator (`CodexAgentModeCoordinator`):**
- Turn start, steer, interrupt, resume and goal paths run inside `session.withRuntimeOperation`.
- Send and retry capture `sendRuntimeOwner` once, before the first attempt. Every retry re-binds that same value.
- Thread-name sync captures `runtimeOwner` when it is enqueued (`PendingCodexThreadNameSync`), and the sync loop re-binds it.

**Codex native controller (`CodexNativeSessionController`):**
- `operationRuntimeSession` reads the calling task's immutable binding only after `useOwnerCapturedRuntimeSessions()`. Non-Agent controllers pass `nil`, which selects the client's fixed default scope.
- The detached memory-mode retry (`scheduleBackgroundThreadMemoryModeDisable`) captures `operationRuntimeSession` synchronously when it is scheduled. It then passes that value to `client.request(..., runtimeSession:)`.

**Codex client default scope.** `CodexAppServerClient.defaultRuntimeSession` is an immutable `let`:
- `.sessionless` for model, auth, health and chat clients (`CodexProviderHelpers`);
- `.unavailable` otherwise.

**Claude:**
- `ClaudeAgentModeCoordinator` binds `runtimeOwner` around start, resume and turn dispatch.
- `AgentModeProviderBindingService` binds `runtimeOwner` around provider binding.
- The controller reads `AgentRuntimeOperationOwner.current` at the start of the owner operation: user turn, reservation and `set_permission_mode`.

**ACP:**
- `ACPIntegratedAgentModeRunner` binds `runtimeOwner`.
- `ACPHeadlessAgentProviderBridge` binds `request.runtimeSession`.
- `ACPRunRequest` and `AgentMessage` default to `.unavailable`.
- Owner requests use `.associate(.owner(AgentRuntimeOperationOwner.current, permission:))`.

### Codex app-server fence (`CodexAppServerClient`)

1. **Capture before the first await.** `request(...)` checks the process, then synchronously captures:
   - `RuntimeWriteOwner(generation: transportGeneration, launch: runtimeLaunch)`;
   - the owner-captured `session` (`runtimeSession ?? defaultRuntimeSession`);
   - the requested permission (`runtimePermission(fromParams:)`: `approvalPolicy`, `sandbox`, `sandboxPolicy.type`).

   Nothing suspends before this capture. The DEBUG `ownerCaptured` checkpoint is the first possible suspension point.
2. **Fence on the captured launch (`fenceRuntimeRequest`):**
   - `thread/resume` associates its thread before the write.
   - `turn/*` and the thread write set associate, then authorize. The thread write set is `thread/goal/set`, `thread/goal/clear`, `thread/memoryMode/set`, `thread/name/set`, `thread/compact/start` and `thread/rollback`.
   - `turn/interrupt` only authorizes (`runtimeAuthorizeOnlyMethods`).
   - An ownerless turn or thread write (no `threadId`) only authorizes.
   - Reads and thread creation pass through.
3. **Revalidate after every await.** `associateRuntimeConversation` and `authorizeRuntimeWrite` both check `isCurrent(owner)` right after their await; `isCurrent` requires process present, same generation and same launch identity.
4. **Final synchronous write.** `sendRequest` → `sendJSONLine(owner:)` refuses the write if the transport is no longer `isCurrent(owner)`. A registered transport also refuses until `runtimeCommittedGeneration == transportGeneration`.
5. **Thread creation.** `thread/start` / `thread/fork` associate the returned thread with the same captured owner, after their response and before returning.
6. **Replies to server requests.** `inboundServerRequestOwners[id]` records the issuing owner. `serverRequestReplyOwner(for:)` removes it, and when a registry launch exists it requires `isCurrent(issued)`. A reply to a replaced transport throws and writes nothing.

### Claude native fence (`ClaudeNativeProcessSessionController`)

1. **`fenceRuntimeWrite(association:)`:**
   - captures `runtimeLaunch` (it must be `runtimeCommittedLaunch`) and the known `sessionID` before the first await;
   - an owner write (`.owner(scope, permission:)`) then associates and rechecks `process != nil && runtimeLaunch === launch && runtimeCommittedLaunch === launch`;
   - every write then authorizes and rechecks the same condition.

   It returns the captured launch.
2. **Owner writes:**
   - user turns (`.owner(AgentRuntimeOperationOwner.current)`);
   - `set_permission_mode`, whose requested `.claude(permissionMode:)` is persisted before its single write.

   All other control requests (initialize, flag settings, model, interrupt) only authorize.
3. **Final synchronous write.** `sendLine(_, writeOwner:)` writes only while `runtimeLaunch === runtimeCommittedLaunch` and `writeOwner === runtimeLaunch`. That also covers non-suspending replies to CLI-initiated control requests on a managed transport.
4. **Permission replies.** `PendingPermissionRequest.issuingLaunch` is captured when `can_use_tool` arrives. `respondToPermissionRequest` then requires `writeOwner === issuingLaunch`.
   - On failure, if `runtimeLaunch !== issuingLaunch`, the reply is logged (`approval.response.dropped`) and dropped.
   - A stale reply never shuts down or fails the replacement. Only a failure on the issuing transport itself still calls `failProtocolAndShutdown`.

### ACP fence (`ACPAgentSessionController`)

1. **`fenceRuntimeWrite(association:)`:** the same capture-then-recheck sequence as Claude (capture the committed launch, optionally associate, authorize, recheck after each await). It returns the launch.
2. **`sendRequestResponse(..., fence:)`:**
   - covers initialize, authenticate, session new/load, `set_config_option`, `set_mode` and model;
   - owner requests pass `.associate(.owner(current, permission:))`;
   - `session/prompt` keeps its own fence (`runtimeAuthorized: true`, with no suspension between fence and write).
   - `requestedSessionModeID` is recorded before the mode request, so its permission snapshot is persisted first.
3. **Final synchronous write.** `sendJSONLine` refuses every write unless the committed launch still owns the transport. That covers `session/cancel`, local permission cancellation, auto-approval and unsupported-method replies.
4. **Permission replies.** `PendingPermissionRequest.issuingLaunch` is bound to the issuing launch. A stale reply is dropped (`Dropped ACP approval reply ...`) and never fails the replacement.

### Conservative choices inside the contract

- **Rejected writes still associate.** A suspended owner write may complete its association on its own captured old launch before the recheck fails. That records ownership on the old runtime and writes zero bytes to the replacement.
- **Codex reply binding** is enforced only when a registry launch exists. While activation is OFF, replies keep the previous behavior.
- **`providerSessionID` restriction keys** use a nil provider, which overlaps any provider.
- **While activation is OFF:**
  - `runtimeManagedTransport` is false and every fence returns without suspending;
  - arguments, the environment (apart from marker stripping) and write ordering are unchanged.
- **DEBUG checkpoints** (`ownerCaptured`, `launchCaptured`, `associated`, `authorized`) suspend only when a test installs one.

## Coverage and association outcomes

| Boundary | Anchor | Pre-spawn reservation; commit before first write | Write fence | Association |
|---|---|---|---|---|
| Claude native and its compatible fallback | `ClaudeNativeProcessSessionController.startProcessIfNeeded` | Yes. Every replacement or fallback spawn gets a new runtime, with provider `.claude(<variant>)`, the owner-captured session and attempt, and the `.claude(permissionMode:)` snapshot. A registry refusal suppresses the fresh retry (`ClaudeAgentModeCoordinator`). | See the [Claude native fence](#claude-native-fence-claudenativeprocesssessioncontroller). | Resume ID and owner session at reservation. The observed session is associated with the owner before each owner write. |
| Claude headless (streaming / print / Oracle / connection test) | `ClaudeCodeAgentProvider`, `ClaudeCodeProvider.runPrintMode` | Yes, via `CLIProcessRunner` hooks, with the actual provider variant. The marker is stripped. | Stdin is written only after commit. | Resume ID at reservation. A fresh observed conversation is recorded with `recordObservedConversation`, even after the root is reaped. |
| Claude model-discovery control start | `ClaudeCLIModelDiscoveryProbe.run` | Yes: `.claudeHeadless`, `.sessionless`, no worktree, no conversation (`--no-session-persistence`, private temporary directory). Commit before the initialize stdin; the marker is stripped. | Covered by the runner. | None (explicitly sessionless). |
| Codex app-server (models / auth / control / sessionless / goal / multithread) | `CodexAppServerClient.startProcess` | Yes, with provider `.codex` and the client's fixed default scope or the start operation's captured scope. A refusal throws, and there is no unregistered fallback. A commit failure invalidates the transport. | See the [Codex app-server fence](#codex-app-server-fence-codexappserverclient). | One association per owner operation and thread on the reused transport, each with its own session, attempt and permission. |
| Codex exec | `CodexExecAgentProvider` | Yes, per retry, via the runner. | Stdin only after commit. | Worktree, provider `.codex` and the message's owner-captured session. Permission is `.unavailable`: exec requests none, and no thread ID is parsed from its output. |
| ACP (interactive / headless / polling) | `ACPAgentSessionController.bootstrap` | Yes, with provider `.acp(<providerID>)` (Cursor / OMP / OpenCode / others). Commit before `initialize`. | See the [ACP fence](#acp-fence-acpagentsessioncontroller). | Resume ID at reservation. The `session/new` result is associated before any prompt. Mode and auto-approve go into the permission snapshot. |

### Administrative exclusion: `claude mcp add/remove`

`ClaudeCodeIntegrationConfiguration.installInClaudeCode` runs `claude mcp add`, `remove` and re-add. The callers are the onboarding wizard and MCP Settings. These commands are **not registered** as managed runtimes:
- they are user-initiated, short-lived configuration commands;
- they never open, resume or write a provider conversation or worktree, and hold no writer;
- they finish within their 15–30 s timeouts.

Each of the three runs passes `additionalRemovedKeys: [ProcessLauncher.runtimeMarkerEnvironmentKey]`, so the inherited marker is stripped.

## Closure of the earlier gaps

These were open in the previous round of this document.

- **Lifecycle / run attempt / permission in the record:** closed in source.
  - Reservations and associations carry the owner-captured session association and the requested permission snapshot.
  - A session-associated writer restricts its session before any conversation is known.
  - Tests:
    - `testSameSessionWriterRestrictsBeforeAnyConversationIsKnown`;
    - `testSessionAssociatedWriterRestrictsItsSessionBeforeAnyConversationIsKnown`;
    - `testReservationCarriesProviderLifecycleAttemptAndRequestedPermission`.
- **Flattened provider identity:** closed. Records carry `AgentRuntimeProvider`; conversation overlap and fresh session-ID qualification are keyed by it.
- **Fresh headless Claude conversations:** closed. They are recorded after observation (`testObservedHeadlessConversationIsRecordedEvenAfterTheRootIsReaped`).
- **Reused transports:** each operation gets its own association on the shared Codex runtime (`testReusedTransportKeepsDistinctThreadAssociationsAndPermissions`).
- **`detachedAtQuit`:** added as a compatible state with no producer.
- **Administrative marker:** stripped; still not registered.
- **Registered-mode Claude / ACP controller tests:** added, through production send, fence and reply methods over a pipe-only fixture transport. See [Closure tests](#closure-tests).

## Closure tests

| Suite | What it proves |
|---|---|
| `AgentProcessRegistryAssociationTests` (new, 8) | Codec round-trip of provider, associations and `detachedAtQuit`; unknown provider preserved; legacy record decodes conservatively. `detachedAtQuit` is kept while alive and becomes `exited` when gone. Same-session restriction before any conversation, across resets. Provider-aware conversation overlap. Reservation contents; `.unavailable` refused; sessionless is nil. Reused-transport associations. Observed headless conversation after reap. The owner scope is captured once, and a detached late write keeps the first attempt. |
| `CodexAppServerRuntimeFenceTests` (8) | Includes `testReplacementDuringTheFirstAwaitReceivesZeroBytes`. It cuts at `ownerCaptured` (`turn/start`, `model/list`) and at `associated` (`turn/start`, `thread/resume`), replaces the transport during the suspension, and asserts zero frames on the replacement. Also `testOwnerlessThreadWritesAreRefusedAndInterruptsOnlyAuthorize` and `testServerRequestRepliesGoOnlyToTheIssuingTransport`. |
| `RegisteredNativeTransportWriteFenceTests` (new, 8) | **Claude:** a user turn writes once, only through its committed owner, after associating. A replacement at `launchCaptured`, `associated` or `authorized` receives zero bytes. An ownership conflict prevents the write. `set_permission_mode` persists its permission before its single write. A permission reply goes only to its issuing transport. **ACP:** an owner request associates its permission and writes once, only when committed. Replacement cuts at each checkpoint give zero bytes. A permission reply goes only to its issuing transport. |
| `AgentRecoveryRuntimeOwnershipTests` (8) | Adds `testSessionAssociatedWriterRestrictsItsSessionBeforeAnyConversationIsKnown`. |

The narrow tests drive production methods. They use DEBUG-only seams:
- Claude: `test_installRuntimeLaunch`, `test_setRuntimeFenceCheckpoint`, `test_detachFixtureTransport`, `test_applyInitialPermissionMode`.
- ACP: `debugAttachTestTransport`, `debugInstallTestRuntimeLaunch`, `debugSetRuntimeFenceCheckpoint`, `debugHandlePermissionRequest`, `debugSendOwnerRequest`.
- Codex: `debugSetRuntimeFenceCheckpoint`.

The fixture transport has the placeholder PID `pid_t.max` and is never signalled.

## Qualification gates and limitations

**Source evidence versus qualification.** Everything above is source-level evidence: XCTest over injected boundaries, pipe transports and DEBUG checkpoints. It does not qualify any provider. Activation requires every family to have `markerPropagation && completeDiscovery` (coupled activation), and no family has been qualified against a real provider. These remain unqualified:
- marker propagation;
- complete descendant discovery;
- writer basenames;
- tool-process classification;
- fresh `--session-id` per provider.

**Production Stop and the POSIX race**
- Production Stop is disabled. The engine is tested only with injected actions, and there is no Stop UI.
- POSIX inspect-then-signal is inherently racy: between the final identity inspection and `kill`, the PID could be reused. The engine re-inspects immediately before each signal and refuses unsafe groups (the app's own group, a changed identity, incomplete discovery). It cannot close the race.

**Restriction scope**
- Global uncertainty blocks all ownership-dependent work.
- Worktree-only blocks apply to automatic work, not sends, except for unassociated writers.
- Let finish keeps restricting until the family exits.
- Catalog runtime items are app-scoped (no `sessionID`).

**Records and discovery**
- `detachedAtQuit` has no producer; quit-time detach is out of this package's scope.
- Probes and administrative commands are unmanaged, except the model-discovery probe.
- A `registerSpawn` failure leaves the record `unknown`.
- No GC.

**Test coverage**
- Scheduler wiring in the view model is tested at the coordinator level only.
- There is no direct test of the headless provider pass-through.
- The registered-mode controller tests use pipe fixtures, not real provider processes.

**Out of scope:** Phase 4 Resume, the remote registry, provider credential/home reads and live acceptance.

## Validation

All tickets are `make dev-*` conductor jobs, with one test suite per command. Short IDs are from earlier rounds; this closure round lists full ticket UUIDs.

**Earlier rounds (superseded by the closure round below):**
- **Build:** `68c0c17e` failed (`Int32` not `Error`; fixed). `b11167b9`, `c6b5d2d0` and `4e28241d` passed.
- **Lint:** `281ff42f` failed and was fixed by hand; `28eee480` passed.
- **Suites:**
  - `88aeb8b4` (24);
  - `befceaf2` (5);
  - `3e571c39` (4);
  - `78d6ccb2` (3);
  - `c9c8972a` (6);
  - `65d2ae81` (45);
  - `908245bd` (12);
  - `65311b95` (6);
  - `754e90f8` (8);
  - `c5e84030` (8);
  - `fcd490f5` (2).
- **Previous round:**
  - build `c62afe81`;
  - suites:
    - `1296e40f`, `652a34d1`, `750c3c15`, `19628a84`, `7507cf63`;
    - `85e65bc7`, `e11986d9`, `fdb8d8d9`, `f769aea0`, `30a6d6ff`;
    - `bea20768`, `d79ea24f`, `093e6a5f`;
  - lint `356f7895`.

**Closure round (full ticket UUIDs):**

| Ticket | Command | Result |
|---|---|---|
| `a9108fa6-c206-470d-9ec2-afabf41e7d97` | `make dev-swift-build PRODUCT=RepoPrompt` | passed |
| `30bb32f8-d84d-4c93-9178-804f78b7ce22` | `make dev-swift-build PRODUCT=RepoPrompt` | passed |
| `f94d6868-f450-489e-bf48-d86d030c162a` | AgentProcessRegistryTests | 24/24 |
| `bcedc7d3-c63c-40a4-8584-887e09a7a676` | AgentProcessRegistryTests | 24/24 |
| `60df2507-c594-4119-95ed-20e42efec3bb` | AgentProcessRegistryAssociationTests | 8/8 |
| `6c6ed2ad-6014-4b88-b46c-a91d10131d15` | AgentProcessRegistryAssociationTests | 8/8 |
| `18962ba5-ea44-4785-ab41-429bafb8b874` | CodexAppServerRuntimeFenceTests | **failed**: `ownershipConflict`. A released client's teardown reaped a conversationless launch whose worktree blocked the next cut. The test was fixed with per-cut worktrees and clients kept alive; no assertion was weakened. |
| `2f2872a8-a7bc-4357-bd72-ccac091ba303` | CodexAppServerRuntimeFenceTests | 8/8 |
| `6e7bd4ee-2a6c-4065-9cf0-93e6eead8964` | CodexAppServerRuntimeFenceTests | 8/8 |
| `35cc8146-cd1c-4f01-b60a-356da9c78393` | RegisteredNativeTransportWriteFenceTests | **failed / deadline**: an ACP replacement cut reused one conversation, which the previous cut's suspended write had already associated on its old launch. Fixed with a distinct conversation per cut and bounded arrival waits. |
| `9c7eb9a1-bbab-423c-9b7e-1d312517468c` | RegisteredNativeTransportWriteFenceTests | 8/8 |
| `8fd70db2-8397-4c0a-ba7e-5342b9db0c6b` | AgentRecoveryRuntimeOwnershipTests | 8/8 |
| `d6b518bf-4b19-4449-b46a-0e08c6d5a2d5` | ClaudeNativeRuntimeSessionArgumentsTests | 3/3 |
| `1000eacc-0ebd-4a71-921f-e5e426345f7d` | CLIProcessRunnerLaunchOwnershipTests | 4/4 |
| `3b130e4a-4277-44b7-96cb-88350d7e00fe` | ClaudeNativeApprovalAndResumeTests | 8/8 |
| `670988b5-26ad-4c4c-a0dd-8c9246b16ffb` | ClaudeAutoPermissionPresentationTests | 12/12 |
| `a1298daf-d416-4599-a9f2-cea7b7d892f0` | ACPSynchronousMCPStartupTests | 3/3 |
| `7d51469c-0c37-43ce-9c11-d29ab81369e3` | ACPProviderSessionIdentityTests | 5/5 |
| `49d1aee2-7fe9-42ab-a9ff-9b4cc76d6384` | ACPAgentSessionControllerModeConfigTests | 51/51 |
| `30d7660a-0c26-4c82-ab8a-5990729868f4` | ClaudeCLIModelDiscoveryTests | 8/8 |
| `fb2434c9-bdca-4479-8cf3-fc70d65a0858` | ClaudeCodeProviderPrintModeTests | 22/22 |
| `01ba3b79-8f39-406a-b762-6b2edaa6aa5e` | AgentScheduledSendNonCodexMandatoryTests | 2/2 |
| `d65ef03d-260e-4574-96e2-a39b6bf441ee` | AgentRecoveryCoordinatorTests | 45/45 |
| `859bac99-1aa4-45a5-85bc-c2ae9614aaf2` | AgentRecoveryStartupCompositionTests | 12/12 |
| `eae359b8-85bd-43bb-92d4-e93259341bed` | CodexFallbackFIFOTests | 38/38 |
| `c09e81a7-46b6-4fc5-b8a2-363507397a9d` | CodexAgentModeCoordinatorLivenessTests | 55/55 |
| `04a9e81b-fa00-4d4c-992e-789cae732d51` | CodexNativeSessionControllerInterruptTests | 2/2 |
| `8dec57ec-a4df-4949-9b00-a1da5f0462dd` | CodexNativeSessionControllerTurnDispatchTests | 9/9 |
| `acc0ca00-6881-4f41-9de1-5220e62e568a` | CodexNativeSessionControllerGoalConfigTests | 16/16 |
| `d26e6519-a1b2-41aa-b81c-fa1522d322a0` | CodexNativeSessionControllerEventRecoveryTests | 35/35 |
| `c2f63940-8619-4236-b698-294cb5449936` | CodexGoalSupportDefaultTests | 20/20 |
| `a35d9f7d-b36d-42a8-802f-084343a8bccd` | `make dev-lint` | **failed**: `redundantSendable` ×4, `trailingCommas` ×2, `wrapLoopBodies`, `extensionAccessControl`. All fixed by hand; `dev-format` was not run. |
| `cc4332ba-71c6-4bdf-9e3c-137a23a97c76` | `make dev-swift-build PRODUCT=RepoPrompt` (after lint fixes) | passed |
| `2fea929e-3587-4a80-b024-bc8f2ecf801d` | `make dev-lint` | passed (0/2152 files require formatting) |
| `14d86387-4d3c-41a3-8cef-f70aec428c03` | AgentProcessRegistryAssociationTests (after lint fixes) | 8/8 |
| `3b81dcd4-bd7f-4028-9e6f-85c176ab1da8` | RegisteredNativeTransportWriteFenceTests (after lint fixes) | 8/8 |
| `62615440-7dfd-4b84-b240-15b941380976` | CodexAppServerRuntimeFenceTests (after lint fixes) | 8/8 |
| `be7fe496-70b1-4025-953d-ac4362df7c28` | AgentProcessRegistryTests (after lint fixes) | 24/24 |

The new suites are absent from the frozen XCTest ledger, so conductor runs them with default deadlines. The ledger was not modified.

`git diff --check` is clean, scoped to `Sources`, `Tests` and this evidence directory, plus a no-index check of every untracked source and test file.

`Scripts/check-agent-context` passed with one warning: the existing AGENTS.md route count of 24 direct routes, which this package did not change. The orphan error the previous round reported is no longer raised.

**Not run:**
- the full test suite;
- `make guardrails`;
- any packaged-app, `dev-build`, `dev-run` or live-provider check.

## Main-agent frozen review boundary

Initial independent reviews use base `93af6fb55a9044c7d8134e9c6be41c792db497d8` and immutable tree `aaa821b7755edc7fb9520b7b52efc93328913c53`: 60 intended source/test/allowlist files, 7,096 insertions and 162 deletions. A temporary Git index captured new files without staging the real index; the original unrelated dirty files are excluded. The identical controlled packet contains the complete frozen diff, R6, the adopted plan/amendments, Platform birth-inspection context, policy verbatim, and validation results. Selection was cleared and fresh reviews explicitly target OracleA and OracleB. Both complete initial preset identities were verified. [OracleB completed](phase3-registry-oracleb.md); [OracleA's first response ended mid-finding](phase3-registry-oraclea-initial-incomplete.md), and its [one permitted same-preset retry completed](phase3-registry-oraclea.md) on the unchanged snapshot. Main accepts OracleA P3-R01–P3-R11 and OracleB P1-1–P1-3 for repair. OracleB P1-3's caller-context gap was investigated by a read-only probe (`prompt-exports/agent-run-2d54ad1dc1e4-0f9b970f.md`); main checked the unretained Claude EOF reap, Codex cleanup scheduling and coordinator shutdown task against source. A complete ordinary Claude shutdown joins cleanup, but EOF fallback and Codex replacements can race it; merely awaiting an already-existing refresh cannot cover a reap not yet reported. Main also spot-checked the ID-keyed approval-owner overwrite, exclusion-based tool classifier, incomplete supporting-field handling and nonempty-only qualification gate. Required repairs are pending, with no review approval claimed. Optional UI detail/retention/performance polish remains deferred; small safety/coverage fixes may join the same pass.

Main verified exact Conductor tickets and log summaries: the latest successful run per 24 source-validating suites totals **406 tests**, all passed; final build `cc4332ba-71c6-4bdf-9e3c-137a23a97c76`, lint `2fea929e-3587-4a80-b024-bc8f2ecf801d`, and four post-lint registry/fence suites (48 tests) passed. `make guardrails`, frozen `git diff --check`, and `Scripts/check-agent-context` passed with the existing route-count warning. The earlier main progress message's 504-test count was an arithmetic error, corrected to 406. Main recovered the earlier failed lint ticket as `a35d9f7d-b36d-42a8-802f-084343a8bccd`. Full-root, packaging, live-provider and live-app acceptance remain unrun.

## R1 remediation pass (initial review findings)

One bounded pass over the accepted findings, in existing actors, store, controllers and callers: no new daemon, authority, transaction or transport framework. Production activation, fresh Claude `--session-id` and recovered Stop stay **OFF**. Legacy (registration-off) behavior is preserved: every new join, receipt check, authorization and refusal applies only to registered launches. This section records repairs and validation only. **No review of this pass has run, and no approval is claimed.**

### Dispositions — OracleA (required)

| Finding | Disposition | Repair (source) | Regression |
|---|---|---|---|
| P3-R01 birth-only observations | Fixed | After the membership fixpoint, discovery is not decisive while any non-member observation's environment (marker) is unreadable, so the family can't be declared exited. Implemented in registry discovery; `ProcessInventory` incompleteness is unchanged. | `testUnreadableOwnershipEvidenceNeverProvesFamilyExit` |
| P3-R02 exclusion-based tools | Fixed | `AgentRuntimeFamilyQualification.toolExecutableBasenames` (explicit, default empty) replaces `toolClassification`. A new member is `.tool` only on a basename match with a readable environment; otherwise `.unknown`. Writers are never demoted. | `testUnfamiliarDescendantsAreUnknownNotTools`; fixtures name `node` explicitly |
| P3-R03 Stop revalidation | Fixed (Stop still disabled in production) | Before **each** group signal: recheck the record and active state; take a fresh complete inventory; any unreadable process group refuses; every in-group process must be a classified, non-`unknown` member and not the app; expected members must be gone or in the same group. Reviewed groups must match the preview (a member seen in another group returns `changed`), and the root uses its observed group. The POSIX inspect-then-signal race is documented, not claimed closed. | `testStopRevalidatesEveryGroupMemberImmediatelyBeforeSignalling` |
| P3-R04 reused request IDs | Fixed | Immutable `CodexServerRequestReceipt` (client instance, transport generation, wire ID) on `ServerRequest`. Owners are keyed by receipt and recorded only when registered. The receipt is carried on Codex approval, user-input, elicitation and permissions requests, through the controller, coordinator and view model. Receipt replies verify client, generation and pending entry, remove the entry, authorize against the issuing launch and recheck before the write. A wire-ID-only reply is refused while registered. | `testServerRequestRepliesGoOnlyToTheIssuingTransport` (wire ID 77 reused on the replacement) |
| P3-R05 / B P1-1 fresh Claude conversation | Fixed | `associateObservedConversationIfNeeded` runs after `initialize` and after every stdout line. It associates the observed ID with the current committed launch, for the latest owner scope or else the launch scope. Failure shuts the still-current transport down. Authorize-only writes use the associated ID. | `testClaudeObservedFreshConversationIsAssociatedBeforeItsPermissionReply` |
| P3-R06 suspension points | Fixed | `CLIProcessRunner.run`/`runStreaming` recheck cancellation after `prepareSpawn`, then close via `spawnFailed`, releasing the gate in the streaming path. Claude `sendUserMessage` rechecks cancellation and the owner's `AgentRuntimeOperationOwner.writeAdmission` after the fence; the Claude coordinator binds it to `dispatchReservationIsCurrent && sessionOwnsClaudeController`. Claude `sendControlRequest` checks cancellation after its fence. Codex `startProcess` joins prior cleanup, then rechecks cancellation and slot after the reservation. | `testCancellationDuringReservationSpawnsNothingAndReleasesTheReservation`; `testClaudeOwnerWriteRechecksItsOperationAdmissionAfterTheFence` |
| P3-R07 same-session exclusion | Fixed | `writerConflict` checks conversation **and** session overlap against every record, active launches included, excluding only the runtime itself. | `testActiveSameSessionRuntimesExcludeEachOtherBeforeAnyConversationIsKnown` |
| P3-R08 authorize all outgoing writes | Fixed | Every registered request is authorized against its captured launch: models, auth, control, reads and requests that name no thread. Thread creation validates the owner session **before** the write. `notify` (now async) and receipt replies authorize too. Unlisted thread methods are writes (deny by default, B P2-2). | Reaped-launch test extended to `model/list`, `thread/start`, `thread/read`, `notify` and a receipt reply; `testThreadCreationValidatesSessionContextBeforeTheWrite`; `testThreadRequestsAreWritesByDefaultAndOnlyNamedReadsSkipAssociation` |
| P3-R09 per-thread worktree | Fixed | Each request captures its own `cwd` before any await and passes it to association, including created threads; there is no transport-wide current-context shortcut. | `testEachThreadOperationAssociatesItsOwnWorktree` |
| P3-R10 coupled activation | Fixed | `supportedPairs` (every Claude variant, Codex, every `ACPProviderID`) must all be covered for activation. `reserveLaunch` rejects an uncovered pair with `.unqualifiedProvider` before spawn, with no legacy fallback. | `testNarrowedProviderQualificationDoesNotActivateRegistration` |
| P3-R11 storage retry | Fixed | Recovery Refresh calls `refreshRetryingStorage()`. It re-reads the runtime directory and merges supported records without replacing in-memory launch ownership, recomputes the preserved/unidentified counts, and clears the failure only after a successful read. | `testRefreshRetriesAFailedRuntimeDirectoryRead` |

### Dispositions — OracleB

| Finding | Disposition | Repair / note |
|---|---|---|
| P1-1 fresh Claude approval | Fixed with P3-R05 | — |
| P1-2 rootless reservation blocks forever | Fixed | `ProcessLaunchOwnership.rootReaped(pid:confirmed:)`: `confirmed` is true only when the caller's own `waitpid` returned that PID (`ProcessTermination.*ReportingRoot`). ECHILD, wait errors and timeouts are unconfirmed. A rootless failed commit records the exact spawned PID; only a confirmed exact-child reap persists `rootReaped`. Resolution still requires complete qualified discovery; marker absence alone or an unconfirmed reap is not exit proof. Regression: `testRootlessFailedCommitResolvesOnlyOnAConfirmedExactReapAndCompleteDiscovery`. |
| P1-3 same-session relaunch vs. own just-ended launch | Fixed by joining exact owned cleanup, not hiding writers | Claude: one retained, bounded owned root reap per PID (`ownedRootReap`). This replaces the unretained EOF reap; it waits 2 s, then escalates, and reports confirmed/unconfirmed. `shutdown` and the next registered `startProcessIfNeeded` join it before `prepareSpawn`, then revalidate. Codex: registered transport cleanup is retained, and `stop()` and `startProcess` join it. The coordinator retains registered controllers' retirement shutdowns per tab (`joinsRetirementBeforeSuccessor`), and `startCodexNativeSession` joins them, then rechecks cancellation and slot ownership. ACP `shutdown` joins its process-wait task. `prepareSpawn` awaits `ensureStarted()` (B P2-5). Ended or unresolved writers are never hidden; the R4 absolute deadline is unchanged. |
| P2-1 CLI error paths skip `rootReaped` | Fixed | Wait errors report `rootReaped(confirmed: false)`; the cancel path reports the observed result. No new test: forcing a wait error needs a non-fixture boundary. |
| P2-2 Codex allowlist | Fixed with P3-R08 | — |
| P2-3 provider home separates conversations | Fixed | `overlapsConversation` no longer compares `providerHome` (untrusted shim/compatible home evidence). |
| P2-4 sessionless launches and worktree rule | Fixed | Reservation keys carry the worktree only for session-bound launches. |
| P2-5 reservations before startup | Fixed | `prepareSpawn` awaits `registry.ensureStarted()`. |
| P2-6 inventory cost | **Deferred** | Performance polish; not a correctness gap. |
| P2-7 scheduler worktree key | Fixed | `runtimeWorktreeIsUnresolved(for:)` (the lookup throws), passed as `worktreeUnresolved` to `runtimeBlocksAutomaticWork`. It blocks only while a registry is attached; legacy is unchanged. Regression assertions are in `AgentRecoveryRuntimeOwnershipTests`. |
| P2-8 recovery row fields | **Deferred** | UI detail polish. |
| P3-1 unwatchable member rewrites | **Deferred** | Retention/rewrite polish; the behavior stays conservative (unresolved). |
| P3-2 double reap during commit | Fixed | The Claude commit catch joins an existing owned reap for the PID instead of starting a second. |
| P3-3 teardown waits on discovery | **Deferred** | Accepted cost: joins now intentionally include post-reap discovery for registered launches only. |
| P3-4 unbound Claude control replies | Fixed | `handleControlRequest` captures the receiving launch and passes it as `writeOwner` to its synchronous replies. |
| Retention | **Deferred** | Unchanged. |

### Fixture updates required by the repaired contract

P3-R07 now forbids one session on two live runtimes. Four replacement fixtures previously reused one owner session across independent cuts, or wrote the replaced transport's session through the replacement while the replaced launch was still live. Each cut now uses its own session. `testClaudeReplacementDuringAnyFenceAwaitGetsZeroBytes` and `testACPPermissionReplyGoesOnlyToItsIssuingTransport` retire the replaced launch before the same session is served again: they remove its scripted root and report a confirmed reap. No assertion was removed or weakened.

The CLI runner fake records `confirmed`, and successful and commit-refused launches assert `confirmed: true`.

### Validation (exact Conductor tickets)

**Failures, in order:**
- Build `d2ea9dfd-806a-4be6-9bcd-618533699c59` failed: a compiler crash diagnostic in `ownedRootReap`'s `if`-expression closure. The closure was rewritten as plain statements.
- `AgentProcessRegistryTests` `cb069e2c-532a-4c97-8fe5-daf06b783cfa`: 2 failures. Stop signalled a root that had moved group after the preview; fixed in source by comparing against the reviewed groups.
- `CodexAppServerRuntimeFenceTests` `825f4205-03c1-40b8-aced-4291f8042f15` (4 failures) and `RegisteredNativeTransportWriteFenceTests` `5a91f3c0-5e5e-49ce-a5f4-d37e55b39aff` (7 failures): same-session fixtures (see above).
- Lint `a1fd1add-3494-4c26-bc62-ae5a5f32f3dd` failed with two `wrapPropertyBodies` errors in a protocol-extension default; fixed.

**Passing.** The latest run of each suite totals **332 tests in 18 suites**, all passing:

| Suite | Ticket | Tests |
|---|---|---|
| `AgentProcessRegistryTests` | `12dcf42e-64c2-42a2-8131-df3a2da1c222` | 31 |
| `CodexAppServerRuntimeFenceTests` | `dc572af6-b25f-4db8-8ba3-c4c23eee85bf` | 11 |
| `RegisteredNativeTransportWriteFenceTests` | `d2b6e395-5c2e-40d8-bb92-ddfb2c962d5b` | 10 |
| `CLIProcessRunnerLaunchOwnershipTests` | `4ebeb63c-63e6-4f52-a878-b558ce80a97f` | 5 |
| `AgentProcessRegistryAssociationTests` | `f12cf7e4-2635-47f3-8d42-29683d9d2c5e` | 8 |
| `AgentRecoveryRuntimeOwnershipTests` | `6cc6b378-eba6-40bd-9999-e21164c17614` | 8 |
| `CodexNativeSessionControllerEventRecoveryTests` | `c001c54a-2d1d-4e43-8183-d4b7423265b5` | 35 |
| `CodexNativeSessionControllerInterruptTests` | `ac3fc7ed-8e37-4149-9565-0e0e7d5a6ad9` | 2 |
| `CodexNativeSessionControllerTurnDispatchTests` | `41ac65f7-392d-4cc7-91aa-d67e7aa64588` | 9 |
| `CodexAgentModeCoordinatorLivenessTests` | `9ac0e143-4ad6-46d9-922a-b8d430288700` | 55 |
| `AgentRecoveryQuestionPersistenceTests` | `77571367-85d8-40e4-b392-50dd538b6ee9` | 14 |
| `AgentRecoveryResetBoundaryTests` | `3e47278d-49d4-4f5e-a2a4-c90d0fbd3442` | 22 |
| `ProcessTerminationExitStatusTests` | `3da67b6d-d0c5-4983-97f5-abb441d7e924` | 4 |
| `ACPAgentSessionControllerModeConfigTests` | `e96e63a8-f537-4175-bf00-21f44ab1cd3d` | 51 |
| `ClaudeNativeTurnTeardownTests` | `5d301bb7-ed87-44eb-83f8-d26468cf97df` | 3 |
| `ClaudeNativeApprovalAndResumeTests` | `eb9c1ee9-9f55-4bf2-a6db-23cc582d24db` | 8 |
| `ClaudeNativeRuntimeSessionArgumentsTests` | `ca4528a9-c9f7-4bc9-9f35-7b6f8fa746ab` | 3 |
| `AgentScheduledSendDispatchTests` | `bebe3811-6198-475b-9519-416f5fab4228` | 53 |

**Build and lint:**
- Compile-only builds `df62fc1c-cefe-425c-b8b8-02a7f2b14bb7` and `6268e4dc-c3f8-43ca-a0e3-0db47f2e565a` passed.
- Lint `162c0c2d-b44e-4f4b-b411-c982ac71ac02` passed.
- The final build after the lint fix, `cc7d9f9d-d7d6-426c-82dd-7743cde98976`, passed. The suites were not rerun after that formatting-only fix.

**Other checks:** `git diff --check -- Sources Tests` was clean. `Scripts/check-agent-context` passed, with only the existing AGENTS.md route-count warning.

**Not run:**
- the full test suite and `make guardrails`;
- every other suite that compiles against the changed protocols, whose fakes rely on the new default extensions;
- packaged-app, `dev-build`, `dev-run`, live-provider and live-app acceptance.

### Regression-gap closure before the R1 freeze

This is still part of the same initial remediation pass (R1 rounds remain 0/2). It added tests only: no production source changed.

**1. Codex retirement join.**
- Test: `AgentModeRunServiceLifecycleTests.testRegisteredCodexSuccessorStartsOnlyAfterItsRetiredPredecessorShutdownCompletes`.
- Fixture: the shared `LifecycleNoopCodexController` gained three opt-in fields: a settable `joinsRetirementBeforeSuccessor` (default `false`), a `shutdownGate` (the existing `LifecycleAsyncGate`) and a `lifecycleLabel` for labelled start/shutdown-complete events. Defaults leave every other test's events unchanged.
- Path: a permission-profile change replaces the ready controller, so the production `invalidateCodexControllerForReconnect` → `retireCodexController` path retires the gated predecessor.
- Registered row (`true`): while the predecessor's shutdown is held, the successor records no `startOrResume` and sends nothing. After release, the order is `codex:start:predecessor` → `codex:shutdown-complete:predecessor` → `codex:start:successor`, and the successor sends.
- Contrast row (`false`): the successor starts and sends while the predecessor's shutdown is still held. This shows the join, not timing, orders the registered row.
- Not covered: user Stop awaits its controller's `shutdown()` inline (`prepareCodexCancellationTeardown`) rather than through retirement.

**2. Claude authorize-only interrupt.**
- Test: `RegisteredNativeTransportWriteFenceTests.testClaudeObservedFreshConversationIsAssociatedBeforeItsPermissionReply` now issues `interruptTurn(reason:)` with no owner scope after the observed-ID association and the permission reply.
- Asserts:
  - exactly one `control_request` frame with `subtype: interrupt` and the given reason;
  - the acknowledged outcome after a fixture `control_response`;
  - unchanged associations (the interrupt creates no ownership);
  - the owner's next turn is still written, so nothing shut the session down.

**3. Claude EOF owned-reap barrier.**
- Test: `RegisteredNativeTransportWriteFenceTests.testClaudeStdoutEOFReapIsRetainedAndJoinedByShutdownUntilTheExactRootIsReaped`.
- Fixture: a private owned `/bin/cat` child, spawned with the existing `ProcessLauncher.spawn` machinery, stands in for the registered root. It is committed under the registry's scripted boundary.
- Path: the controller enters the production EOF handler through the existing DEBUG hook `test_handleStdoutEOF(launchToken:)`. No new hook was needed.
- Gate: the child's stdin. `shutdown()` is held for a bounded 200 ms, well under the reap's 2 s wait before escalation, so nothing is signalled. Meanwhile it has not returned, no reap is reported and the record stays `live`.
- After the test closes stdin:
  - `shutdown()` returns only after the controller's own wait reaped the exact root (`rootReaped == true`);
  - post-reap discovery has resolved the record to `exited`;
  - a later `waitpid` gets `ECHILD`.
- Teardown is signal-free: it closes stdin, then runs a bounded `waitpid` loop.
- Not covered: the successor-start join in `startProcessIfNeeded`, which would need a real provider launch.

**4. P2-1 CLI wait-error path.** Still deferred: it would need a new injection seam.

**Fixture scope.**
- Main explicitly extended the permitted fixtures to private owned children for the Claude EOF/root-reap test and the existing ProcessTermination/CLI lifecycle tests.
- `ProcessTerminationExitStatusTests` (`3da67b6d-d0c5-4983-97f5-abb441d7e924`, 4 tests) had already run before that extension. It used only owned fixture children and is not provider or live qualification.
- No real providers, provider homes, environment inspection, unrelated signals or app lifecycle were involved.

**Validation (all passing):**

| Check | Ticket | Result |
|---|---|---|
| `RegisteredNativeTransportWriteFenceTests` | `6829a030-4b88-44d1-bea4-8e783969cdf7` | 11 tests, 0 failures (new EOF test 0.227 s) |
| `AgentModeRunServiceLifecycleTests` | `6eaa1436-9ad3-4572-8527-0018fcb9006b` | 185 tests, 0 failures (new retirement test 0.249 s) |
| `CLIProcessRunnerLifecycleTests` | `8bfb5e8c-85d9-4dd5-b96b-034f16f1584d` | 4 tests, 0 failures |
| Lint | `67eeda58-b14a-4fc6-8f33-6ed6f77656f2` | passed |

`git diff --check` was clean. No product build ran because only test files changed this round; both suites above compiled the test target.

**Final job state:** `./conductor job list` showed no running or queued jobs.

### Limits of this pass

- **Codex retirement join.** Covered for the replacement path (see above); the Stop path shuts down inline instead.
- **Claude EOF owned reap.** Covered for the `shutdown()` join with an owned child; the `startProcessIfNeeded` join has no test.
- **P2-1 error-path reporting.** No regression, as noted above.
- **Stop.** Validation narrows, but cannot close, the POSIX inspect-then-signal window. Production Stop remains disabled.

## Main-agent R1 frozen boundary

Main verified the remediation and additional regression tickets/log summaries: the latest successful run per 20 affected source-validating suites totals **522 tests**, all passed. Final production-source build `cc7d9f9d-d7d6-426c-82dd-7743cde98976` passed before the final test-only additions; those additions compiled the test target. Lint `67eeda58-b14a-4fc6-8f33-6ed6f77656f2`, `make guardrails`, frozen whitespace checks and context checks passed (existing route-count warning only). Main read the concrete receipt type, same-session conflict guard, observed-ID association, private-child EOF assertions and joined/unjoined coordinator contrast test. The four current registry/support/launch/inventory context files were hash-matched to the frozen Git objects.

The first bounded re-review uses initial tree `aaa821b7755edc7fb9520b7b52efc93328913c53` and repaired tree `1862f178b341897ebdf83fa6053df8150d6117a2`: the complete unified-20 delta is 27 files, 1,610 insertions and 221 deletions. Fresh OracleA and OracleB chats received the same frozen delta, current core context, original/adopted contract, policy verbatim and verified validation, plus only their own required findings verbatim and their own dispositions. Shared selection was cleared. No combined worker findings document was included. Both responses completed and their explicit preset identities were verified. No final approval is claimed. Optional row-detail, performance and retention work remains deferred, and live acceptance remains pending.

## First re-review result and main disposition

[OracleA first re-review](phase3-registry-oraclea-r1.md) closes nine initial required findings, leaves P3-R05 (buffered inbound output crossing transport replacement) and P3-R06 (native Claude cancellation windows) open, and adds P3-R12 (automatic replies missing registry authorization). [OracleB first re-review](phase3-registry-oracleb-r1.md) closes P1-1 and P1-2, narrows P1-3 to cross-provider retirement, and raises R-1 (unrelated zombie/older unreadable processes cause uncertainty) and R-2 (possible ACP wait-task self-join, expressly requiring a caller trace).

Main accepts the concrete required repairs and sent the same Pair worker both exact exports. R-2 must be established or closed with direct call-path evidence, not treated as a proven deadlock. Main spot-read the buffered-line loop and association await, reservation without cancellation check, admission await without a later cancellation check, unidentified-process uncertainty rule, ACP wait-task body and Codex-only retirement join. Cheap scheduler OFF-gate regression and interrupt cancellation handling are included; optional presentation/performance/retention remain deferred. No downgrade or rejected required finding is claimed. The next submission is normal final re-review round 2/2; the earlier Phase 1b third-round authorization does not apply here.

## R2 remediation report (worker evidence, independently checked where noted)

The following is the Pair worker's report. Main verified the exact 12 final suite tickets and their log summaries: **440 tests**, all passed, plus compile-only build `ce36674c-ef01-4355-97c7-71b2ed451130` and lint `6d282067-9975-4e98-8b04-9ed76e7cf33e`. Main read the per-tab retained retirement implementation, the Codex-to-Claude contrast test, the captured inbound-loop origin and authorize-only queued-reply path, birth-order exclusion, ACP exit cleanup and the single ACP shutdown declaration. Main found the initial cancellation test cancelled before reservation rather than during a suspension, and the automatic-reply test lacked the specifically requested revoked auto-approval row; the same worker is adding these bounded tests before the final snapshot. No review is submitted on the provisional tree `d7e3fbf90824bc68934d4d4c15db4f8b2fcf61ee`.

Main's first guardrails attempt failed because the new review evidence used an invalid Scope header; the next failed on an invalid Authority value. Main corrected both documentation headers. These failures did not indicate a source defect.

All required repairs from the first re-review are in. Every focused suite passes on the final source, and the build and lint are clean. Nothing is staged or committed, no jobs are running, and I didn't touch main-owned docs, the status or the allowlist.

## Fixes

**A05: buffered inbound lines are bound to their transport.** In `ClaudeNativeProcessSessionController.swift`:
- `handleStdoutChunk` (L1844–1886) captures `originLaunch` at L1872. Before each line it rechecks the stdout token and `runtimeLaunch === originLaunch`; if either changed, it logs `protocol.inbound.replacedTransportDiscarded` and stops.
- `associateObservedConversationIfNeeded(originLaunch:)` (L1945) only associates when the reporting launch is still current and committed. A DEBUG `observedAssociating` checkpoint sits before the registry call.

**A06: cancellation after reservation and after admission.**
- `reserveSpawn` (L2029): a start that loses the slot, or is cancelled once the reservation returns, calls `spawnFailed` and spawns nothing.
- `sendUserMessage` rechecks cancellation after the admission check (L948).

**A12: automatic replies.** All three automatic-reply sites go through `sendAutomaticReply` (L1919). On a registered transport the reply is queued, and `flushQueuedAutomaticReplies` (L1892) sends it in order: receiving launch still current, then an authorize-only registry check, then the final synchronous byte check. If the transport was replaced, the reply is dropped and logged. If the registry refuses it on the still-current transport, the transport fails. Unregistered transports write immediately, as before. This also resolves the P3 note that these replies skipped `authorizeWrite`.

**Interrupts are exempt from the post-fence cancellation check** (L1678), so a stop path running in an already-cancelled task still sends its interrupt.

**P1-3: retirement ordering across providers.**
- `AgentTabSession` has `retainRuntimeRetirement` and `joinRuntimeRetirements` (L1469, L1479).
- What gets retained there:
  - Codex: `retireCodexController` (L4651), which covers all three call sites.
  - Claude: the provider-identity retirement (L2261).
  - ACP: a registered controller retired on a provider switch, via the view-model helper (L8473, called at L324 and L8842).
- Registered starts join it first: Claude at L1237 (followed by the currency checks), Codex at L3572, ACP runner at L434.
- `joinsRetirementBeforeSuccessor` is now declared on the native runtime contract (L50, default false) and implemented on the Claude controller (L2044) and ACP controller (L308).

**B R1: zombie and earlier-born exemptions** in `AgentProcessRegistry.swift`:
- In discovery (L447), an unidentified process with an unreadable environment no longer makes discovery incomplete if it is a zombie or provably born before the family.
- `predatesFamily` (L501) uses a 300 s wall-clock margin (L495):
  - with a root: same boot only, and born more than the margin before the root;
  - without a root: only for a reservation made by this app instance (so the same boot), compared against its `createdAt` minus the margin.
- The doc comment states this only excludes non-members and is never exit evidence.
- Stop's "unreadable group → refuse" rule skips zombies only (L1016). A live process with an unreadable group still refuses.

**Scheduler gating** (`AgentRecoveryCoordinator+RuntimeOwnership.swift` L69): an unresolved worktree now blocks automatic work only when some restriction carries a worktree path. Global uncertainty still blocks everything. With production qualification and no records, nothing is held.

## Dispositions

- **B R2 (ACP self-join): not reachable.** `ACPAgentSessionController.swift` has no internal call to `shutdown()` at all. The wait task (L1817–1830) only awaits `ProcessTermination`, `launch.rootReaped` and `handleProcessExit`. `handleProcessExit` (L2112–2133) returns early when closing and otherwise awaits only `clearExpectedAgentPIDIfNeeded` (L2148, which calls the MCP host) and `cleanupLaunchArtifacts` (L3739, which calls the provider). `emit`, `emitTerminal` and `finishEventsIfNeeded` (L4082–4097) are synchronous yields. So `shutdown()`'s join at L1747–1749 always runs on a different task. No code change.
- **`spawnedPIDs` race: no issue; the edit was tried and reverted.** After the inspect await, the only way `registerSpawn` loses is this launch's own `rootReaped` (records are never removed, and nothing else clears the launch). A confirmed report already consumes the entry. An unconfirmed one deliberately keeps it for the launcher's later confirmed reap of the same child. Clearing it would break the P1-2 resolution. I left a comment at L744 instead.
- **Not inspected this round, deferred:**
  - the Codex recovery-start slot check;
  - unknown thread methods treated as writes;
  - same-session helper scope;
  - the `ensureStarted` doc wording;
  - the unpersisted `codexReceipt`;
  - the duplicate wire-ID check;
  - unlisted Bash descendants becoming unknown.
- **Evidence note:** the deliberate SIGTERM-after-2 s in the registered EOF reap is unchanged.

## Tests

New tests:
- **Write fence** (5): buffered lines after a replacement; automatic replies (authorized, dropped on replacement, refused on a revoked launch with zero bytes and the failure intercepted); cancelled reservation released; cancellation during the admission check; interrupt from a cancelled task with a cancelled permission change as the contrast.
- **Registry** (3): zombie plus earlier-born process with a within-margin contrast; the rootless `createdAt` anchor; Stop with a zombie.
- **Runtime ownership** (2): no records, and a restriction with no worktree.
- **Lifecycle** (1): the Codex → Claude switch with an unregistered contrast row.
- **Fixtures**: `zombie:` on the scripted observation, and `joinsRetirementBeforeSuccessor` on the Claude lifecycle fake.

| Check | Ticket | Result |
|---|---|---|
| `make dev-swift-build PRODUCT=RepoPrompt` | `ce36674c` | pass; no new warnings in changed files (the unused `input` already exists at HEAD) |
| RegisteredNativeTransportWriteFenceTests | `c2947e2a` | 16/16 |
| AgentProcessRegistryTests | `5aaaa34f` | 34/34 |
| AgentProcessRegistryAssociationTests | `5dcebcf1` | 8/8 |
| AgentRecoveryRuntimeOwnershipTests | `fa3e2515` | 10/10 |
| AgentModeRunServiceLifecycleTests (includes the Claude coordinator lifecycle extension) | `64f65ef2` | 186/186 |
| ClaudeNativeApprovalAndResumeTests | `7517e5c9` | 8/8 |
| ClaudeNativeTurnTeardownTests | `72d6e0ba` | 3/3 |
| ACPAgentSessionControllerModeConfigTests | `a4311e80` | 51/51 |
| CodexAgentModeCoordinatorLivenessTests | `1382cfb4` | 55/55 |
| CLIProcessRunnerLaunchOwnershipTests | `88a174ee` | 5/5 |
| AgentScheduledSendDispatchTests | `fdb3d4ff` | 53/53 |
| CodexAppServerRuntimeFenceTests | `aa95fbf5` | 11/11 |
| `make dev-lint` | `6d282067` | pass (0/2152 need formatting; strict SwiftLint clean) |
| `git diff --check` | — | clean |

Logs are under the Conductor jobs directory, by ticket.

## Failed attempts

1. A `FILTER='A|B|C'` run broke in the shell because the Makefile doesn't quote `FILTER`. `conductor job list` afterwards showed nothing queued or running, and I reran each suite separately.
2. Ticket `d43c4fda`, AgentRecoveryRuntimeOwnershipTests, 2 failures. My new test assumed a refresh picks up a runtime file seeded after startup. I split it into two tests with the record seeded before start; the gating logic itself was unchanged.
3. Ticket `8bdc10c1`, AgentModeRunServiceLifecycleTests, 5 failures, all in my new Codex → Claude test. `startRun` returns a Codex-only outcome (nil for Claude) and the Claude start runs after it returns. The test now waits for the recorded `claude:start` and `claude:send` events instead.

## Skipped

- No full-root, perf or `dev-build` runs, no artifact reruns, no app lifecycle.
- `ClaudeAgentModeCoordinatorLifecycleTests` isn't a standalone suite (Conductor rejected the filter); its tests ran inside the 186.
- I didn't revert source to prove each new test fails without its fix.
- No `make guardrails` and no `Scripts/check-agent-context` (no docs changed).
- The frozen ledger is unchanged. I didn't update `phase3-registry.md`; saving evidence and the final review is yours.

## Final R2 snapshot and validation

Both test gaps are closed. Only `Tests/RepoPromptTests/AgentMode/Recovery/RegisteredNativeTransportWriteFenceTests.swift` changed; no production source, docs, allowlist or status were touched. The write-fence suite passes 16/16 and lint is clean.

**A06, cancellation during a held reservation** (`testClaudeCancelledLaunchReservationIsReleasedAndSpawnsNothing`, around L593–645):
- **Seam:** I used the existing scripted boundary, `ScriptedProcessSystem.inventoryHook` with `InventoryGate`, instead of adding a checkpoint. A previous registry instance leaves a live record whose scripted root is then removed, so a new, unstarted registry's startup discovery has to call inventory. That discovery runs inside `prepareSpawn`, which is where the reservation is held.
- **Sequence:** start `test_reserveSpawn` in a task, wait (bounded) until the gate is reached, and assert there is no reservation yet. Then cancel the task while it's held and open the gate.
- **Result:** the reservation completes, then the controller's post-reservation check calls `spawnFailed` and throws `CancellationError`. The record ends `.exited`, and a later `commitSpawn` fails with `.staleLaunch`, so nothing can spawn.
- **Positive control kept:** it now runs after the cancelled case and ends `.reserved`.

**A12, revoked auto-approval** (in `testClaudeAutomaticRepliesPassTheRegistryFenceAndOnlyTheirReceivingTransport`): after the unsupported-control row, the same revoked launch gets a `can_use_tool` request for `mcp__RepoPromptCE__read_file`, the RepoPrompt auto-approval path. The transport receives zero bytes, and the second intercepted failure starts with "Failed auto-approving RepoPrompt Claude permission request". The test now covers both reply branches on a revoked launch.

| Check | Full ticket | Result |
|---|---|---|
| `make dev-test FILTER=RegisteredNativeTransportWriteFenceTests` | `68ff5638-72e2-4a76-98ff-52c5c3cdb565` | 16 tests, 0 failures |
| `make dev-lint` | `1ee52dd7-a4e4-4be8-b6bb-a556c353e77c` | completed; 0/2152 files need formatting; strict SwiftLint clean |
| `git diff --check` | — | clean |

**Failed attempt:** ticket `aadc7871-8d04-426e-9316-dc42ddc12431` failed (exit 70). My first version hung for the 180 s per-test limit in the cancelled-reservation test, and Conductor terminated it. With no unresolved records, startup discovery returns before calling inventory, so the gate was never reached. I fixed that by seeding the record from a previous registry. The wait is now bounded, so a future regression fails instead of hanging.

**Skipped:**
- No compile-only build, because no production source changed (the test run compiled everything anyway).
- No other suites.
- I didn't revert source to prove the new tests fail without the fix.

The frozen ledger is unchanged, nothing is staged or committed, and no Conductor jobs are running.

Main verified the two exact final tickets and log summaries above, then froze intended source/tests/allowlist in tree `c25b94f0c854aee8577495d9f71ed6cfc247863d` (65 paths against baseline `93af6fb5`). Delta from R1 tree `1862f178`: 17 files, 764 insertions and 61 deletions; complete unified-20 artifact `_git_data/repos/repoprompt-ce-personal-t-27030497/2026-10-22/1228/diff/all.patch`. Main hash-matched current full Claude controller and registry context to frozen blobs. The real index remained empty. All implementation workers and Conductor jobs were stopped before reviews.

Fresh OracleA/OracleB final re-review requests were issued together on the same frozen delta and controlled source/contract context, policy verbatim and exact validation; each received only its own R1 findings verbatim and dispositions. Shared selection was cleared. Both final responses completed with explicit matching preset identities, and both close every required finding in their bounded scope. Documentation-only guardrails/context/whitespace checks passed after header corrections, with the existing route-count warning. No production gates or acceptance claims changed.

## Final review disposition and checkpoint boundary

[OracleA final re-review](phase3-registry-oraclea-r2.md) closes P3-R05, P3-R06 and P3-R12. [OracleB final re-review](phase3-registry-oracleb-r2.md) closes its cross-provider P1-3 and R-1, accepts R-2 as no-issue without contest, and confirms the cheap scheduler and interrupt fixes. Initial review plus two re-review rounds are complete; no P0/P1 remains open. No third Phase 3 round is requested or implied by the earlier Phase 1b-only authorization.

Deferred nonblocking findings are retained verbatim in those files: A P3-R13 (wall-clock ordering under a backward jump); B R2-A (other Claude conversation-reset retirements), R2-B (cross-boot unreadable-process exclusion), R2-C (zombie family-member Stop escalation), R2-D (additional switch contrast rows), unbounded retirement joins and EOF-only final-line association, plus prior P2/P3 notes. Production registry/marker/fresh-session-ID/Stop activation is OFF, and these limits must be revisited before activation or live acceptance. Main deliberately preserves the reviewed snapshot instead of broadening a completed bounded review into activation qualification or optional hardening. No P2/P3 is represented as fixed.

The scoped read-only worker audited the complete frozen comparisons, reusing the initial audit and reading all remaining R1/R2 diffs: `prompt-exports/agent-run-2d54ad1dc1e4-f3338c3c.md`. It reports 65 intended source/test/allowlist paths, no removed/weakened existing assertions, skips or expected failures, no ledger/release/packaging changes and no original unrelated dirty paths. Main independently checked the empty real index, OFF qualification/default Stop boundaries earlier, and the exact frozen source hashes. Phase 4 planning preparation is deliberately excluded from the Phase 3 checkpoint.

## Signed checkpoint

Main created signed local commit `559ecd9d6d037ba762d8f4d2297d3c397a9d1f67` (`Track provider runtime ownership across app restarts`), 76 intended paths, 11,198 insertions and 239 deletions. The commit object contains a signature field; unsigned fallback was not used. All 64 source/test blobs were verified identical to reviewed tree `c25b94f0`. The staged boundary contained only intended Phase 3 source, tests, review/planning evidence and exact allowlist entries, plus the Phase 2 checkpoint-status reconciliation. Main excluded the Phase 4 plan, its original-spec status line and its allowlist line using per-file index content without modifying the working copy.

`make guardrails`, `.githooks/pre-commit` and staged whitespace checks passed (existing route-count warning). The real index was empty afterward, no Conductor jobs or workers were running, and original unrelated dirty files remained unstaged. No source changed during signing or checkpointing. Phase 4 implementation may now use the released interfaces.

## Deviations

- **Shell reads and edits.**
  - Earlier rounds used a shell `git grep` read of `Package.swift` and one shell `sed -i` rename.
  - The previous round used one `git grep | wc -l` count and shell `grep` over conductor job logs.
  - A stray `make -s` with no target ran the default `help` target, which only prints usage.
  - The R1 remediation pass, before the main agent's tool correction, read source and docs with shell `grep`/`sed`/`wc`, all read-only:
    - `grep rootReapConfirmed` in `ProcessTermination.swift`;
    - greps for callers of `rootReaped(pid`, for `rootReaped(runtimeID`/`toolClassification`, and for `providerHome`;
    - `grep -i home` over the recovery tests;
    - `grep discoverRuntimes` in the recovery store;
    - function-line greps of `CLIProcessRunner.swift` and `ClaudeNativeProcessSessionController.swift`;
    - `grep`/`sed` reads of `ACPAgentSessionController.swift` (`processWaitTask`, actor, `handleProcessExit`);
    - `wc`/`grep` over the prompt exports.
  - After the correction, every source, config and doc read used RepoPrompt `read_file`/`file_search`, and every edit used `apply_edits`. The shell was used only for Conductor commands and their logs, saved test output under `/tmp/rpce-r1-*.txt`, `git status`/`git diff --check`, and `Scripts/check-agent-context`.
  - All shell use was read-only apart from Conductor's own artifacts and those temporary output files.
- **Fixture processes.**
  - The CLI-runner hook tests spawn temporary `/bin/sh` fixture executables, which main permitted for runner-boundary tests.
  - The Claude EOF reap test spawns one private owned `/bin/cat` child, under main's explicit fixture-scope extension.
  - Registry, discovery, Stop and the other registered-mode controller tests stay on injected boundaries or pipe-only transports.
  - None of this is live provider qualification.
- **Regression-gap closure.** Every read and edit used RepoPrompt tools. The shell ran only Conductor commands, `grep` over Conductor job logs, `git status`/`git diff --check` and `./conductor job list`.
