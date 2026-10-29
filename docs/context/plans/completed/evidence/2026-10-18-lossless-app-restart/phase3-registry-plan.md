# Phase 3 registry implementation plan and activation boundary

Scope: read when the task touches the Phase 3 runtime registry, managed provider launch ownership, process discovery and survivor actions.
Authority: Reference
Last-verified: 2026-10-22

The original registry plan and its continuation were supplied by OracleA in the same planning workstream; preset identity `61D024A4-CCFB-4C9C-A614-CC65E0A1864C` was verified in the prior session's results. The continuation below supersedes the original plan's suggestion that registration alone could be active before qualification. One coupled worker implements the complete source path, with production activation off until family discovery is qualified. This is a reversible implementation assumption, not an Owner Decision. Phase 2 is committed as `93af6fb55a9044c7d8134e9c6be41c792db497d8` with a signature; O8's unsigned fallback was not needed. The original spec's architecture and O3 live-acceptance deferral remain in force.

## Bounded validation adjustment

Main permits the existing temporary `/bin/sh` fixture-executable pattern for tests of the actual CLI runner launch hooks and registered Claude EOF/root-reap cleanup. Existing shared `ProcessTermination` and CLI lifecycle suites may use their own private fixture children. This extension was made before the additional cleanup tests; the R1 worker had already run `ProcessTerminationExitStatusTests` under the narrower brief, which is recorded as a fixture-scope deviation, not as live qualification. This narrows the raw plan's no-process-operations recommendation: it avoids a generic spawn-mocking layer used only for tests. Registry inventory, watch and Stop tests keep scripted boundaries. No real providers, visible app lifecycle, provider-home/environment inspection or unrelated-process signalling is authorized. Fixture subprocess results do not qualify production behavior. This is a main-agent implementation assumption, not an Owner Decision.

## Original registry plan

# Oracle Plan

## Summary

Implement Phase 3 as **three sequential, coupled source packages after current ownership is released**: durable runtime registration, discovery/watch/classification, then provider and recovery integration. Reuse `AgentRecoveryStore` for atomic runtime-record storage; `AgentProcessRegistry` alone owns runtime decisions. Keep unqualified marker injection and fresh Claude `--session-id` disabled. Useful reservation, direct-child identity, and conservative blocking can operate without those features, but cannot be advertised as complete survivor discovery.

## Current-state analysis

The supplied source establishes the critical boundaries:

- Claude `startProcessIfNeeded` resolves environment and arguments, calls `ProcessLauncher.spawn`, installs `process`, then starts readers. Reservation must precede that spawn because startup hooks can execute immediately.
- Claude `buildArguments` currently supports `--resume`, not fresh `--session-id`; the controller also serves compatible backends.
- Codex `startProcess` is the shared transport spawn seam. Registration there covers late starts from model listing and goal operations—not just composer submission.
- Codex `startOrResume` creates or resumes a thread **after** starting the client. Runtime registration and conversation association are separate transactions.
- Codex `startUserTurn` performs `turn/start`; it needs a registered-runtime/conversation permit before issuing the request.
- `ProcessInspection` provides consistent sampled **birth identity**, not an atomic snapshot of executable, environment, and process group across `exec`. Environment absence is explicitly weak evidence.
- Platform `ProcessRegistry` remains an unrelated in-memory handle map. Do not modify its authority or persistence responsibilities.

Scout-only locations—headless spawning, fallback, disposal and additional starts—must be verified while implementing their adapters. Do not infer their ownership contracts from line numbers alone.

## Design

### 1. Durable runtime authority

Create `AgentProcessRegistry`, an app-scoped AgentCore actor, injected into managed local provider launch owners. It owns:

- runtime state transitions and launch reservations;
- conversation associations and writer exclusion;
- discovered families, watch handles and outstanding discovery tasks;
- recovery projections and worktree restrictions.

`AgentRecoveryStore` supplies serialized atomic record reads/replacements only. It must never call back into the registry.

Use independent files, not a session composer slot:

`AgentRecovery/v1/runtimes/<runtimeID>.json`

A version-1 record contains:

- `runtimeID`, `appInstanceID`, provider kind;
- provider home: known value or unresolved—not an assumed default;
- state: exactly `reserved`, `live`, `exited`, `stopped`, `detachedAtQuit`, `unknown`;
- root birth identity and process group when established;
- observed shim/CLI chain and descendants;
- associations containing existing session lifecycle bindings, run-attempt IDs and native conversation IDs;
- worktree bindings and permission mode;
- persisted Let-finish decision, when selected.

Process observations retain only birth identity, parent relationship, executable path, group, selected marker/home evidence and role classification. Never persist argv or full environments. Runtime identity describes a process lifetime; multiple threads/attempts can reference it.

Reuse opaque revision CAS and supported additive-field preservation. Future schemas, malformed required fields and unknown closed variants remain preserved/nonwritable. Unreadable records create scoped uncertainty where bindings can be established; unidentifiable records require a visible global recovery warning and disable actions whose safety depends on establishing their ownership.

**No GC in this package.** In particular, root exit does not retire a record with surviving or unverifiable descendants.

Conceptual interfaces:

- `reserveLaunch(context:) async throws → RuntimeReservation`
- `registerSpawn(reservation:observation:) async throws → RegisteredRuntime`
- `associate(runtime:association:) async throws`
- `authorizeWrite(runtime:conversation:owner:) async throws → RuntimeWritePermit`
- `observeTermination(runtime:launchToken:evidence:) async`
- `refresh(scope:) async → DiscoveryResult`
- `stop(runtime:expectedRevision:) async → StopResult`

These are domain operations, not arbitrary transaction closures.

### 2. Launch and ownership ordering

For every actual managed spawn:

1. Capture launch owner, provider, worktree and existing conversation association.
2. Commit `reserved`. Failure means **zero spawns**.
3. Revalidate cancellation/owner after awaiting.
4. Spawn, passing the explicit marker only when that launch family is qualified.
5. Immediately retain the returned handle in the existing controller/client cleanup ownership.
6. Inspect the child off the main actor.
7. Commit its birth identity as `live`.
8. Revalidate the exact launch token; only then permit protocol initialization and user writes.

Reader setup may precede registration completion to avoid blocked pipes, but must not authorize outgoing protocol work.

No registry lock spans network requests. The actor serializes reservation decisions; every suspension requires reservation/launch-token validation.

If inspection or live commit fails:

- never lose the spawned handle;
- deny further protocol/user work;
- invoke the existing owned-child termination/reaping path;
- retain the reservation as unresolved unless exit is positively established;
- propagate a visible startup failure.

Cleanup failure is not “spawn failed, therefore no process.” Late callbacks always reference the original runtime and launch token, never the controller currently occupying the session.

Add a small runtime-ownership observer dependency to native launch owners, not UI/store dependencies in providers. Its events cover spawned registration, conversation association and actual transport termination. Deinit cannot be relied on to finish durable work: unresolved disk state remains conservative until discovery.

### 3. Provider coverage

| Boundary | Contract |
|---|---|
| Claude native | Reserve inside `startProcessIfNeeded`, immediately before spawn. Each replacement/fallback launch receives a new runtime ID. Preserve current argument behavior until qualification. |
| Claude conversation | Associate observed IDs before subsequent user writes. For resumed sessions, register the requested conversation before spawning and verify returned identity. |
| Claude-compatible variants | Use their actual provider identity. Do not apply Claude `--session-id`, home discovery or writer-classification assumptions to GLM/other variants. Unknown classification remains blocking. |
| Codex client | Register inside `startProcess`, covering every `startIfNeeded` caller. The client owns the runtime; controllers contribute associations. Do not assume one client equals one thread. |
| Codex threads | Existing thread: acquire its reservation/fence before `thread/resume`. Fresh thread: associate the returned identity before subsequent thread mutations or `turn/start`. |
| Codex model/goal starts | Model-only transport may reserve without a session association, with its actual worktree/provider context. Goal operations must associate their thread before mutations. Sessionless does not mean unregistered. |
| Headless CLI | Add the same pre-spawn/registered-before-stdin boundary to `CLIProcessRunner` through optional typed launch hooks. AgentCore provider callers supply mandatory hooks; unrelated Platform callers retain current behavior. |
| Remote | Excluded from local process registry. Existing recovery-input protections remain unchanged. |

For a fresh Claude launch before `--session-id` qualification, conversation identity remains unresolved until observed. Its known session/worktree association blocks conflicting managed launches meanwhile. Do not mint a fake provider conversation ID.

`RuntimeWritePermit` is runtime-only, bound to runtime, conversation and owner generation. Retain the existing final synchronous owner/transport check immediately before writing. Registry failure must not be converted into automatic fresh-controller fallback.

### 4. Inventory, discovery and classification

Extend Platform inspection with one bounded same-UID inventory operation and a separate exit-watch helper. Neither imports session types.

Inventory returns observations **plus completeness/failure information**. Enumerate once per discovery and inspect candidates; do not run a polling loop.

Resolve families using:

- registered birth identities;
- parent links;
- matching runtime markers;
- previously observed descendant identities, including reparented processes.

A missing marker never excludes membership. An incomplete inventory cannot prove that a reservation never spawned or that all tools exited.

The effective-UID filter in current inspection requires care: inventory must identify its UID basis. If real/effective ownership or access restrictions prevent a complete same-owner view, return incomplete evidence. Do not reinterpret skipped processes as absent.

Classification is conservative:

- recognized launcher or provider CLI: writer/blocking launcher;
- positively qualified tool descendant: tool;
- ambiguous executable, provider variant, home or mixed sampled evidence: unknown, blocking.

Repeated path/environment samples cannot prove that no `exec` occurred. Therefore supporting-field changes or missing markers must never downgrade a possible writer to tool-only. Previously identified writers remain writers until **strong exit evidence for that lifetime**.

Strong exit evidence includes confirmed absence, boot change, or a complete observed birth-identity mismatch. It establishes exit of that recorded lifetime—not exit of its family. Inspection denial, inconsistent samples and missing fields mean unknown. Treat `isZombie` as supporting information; do not use it alone to clear ownership.

Unknown provider home cannot manufacture a distinct conversation key. Conservatively overlap matching provider/conversation or session/worktree associations until home is established.

### 5. Event watches

Implement one Platform `kqueue` owner with injected syscall seams:

- watch every identified live writer, launcher and blocking tool;
- associate registrations with birth identity and a watch-generation token;
- exit events trigger registry rediscovery, not direct “family exited” transitions;
- duplicate events coalesce; an event arriving during discovery schedules one further pass;
- close registrations and descriptors on replacement/disposal.

Registration failure leaves discovery incomplete and exposes Refresh. No polling fallback. Reinspect around watch installation to handle exit/PID-reuse races; stale events cannot retire a successor.

The registry retains watch ownership independently of VM/controller lifetime.

### 6. Stop and its unavoidable boundary

Stop is explicit and request/revision-bound:

1. Fresh discovery produces the preview.
2. On confirmation, rediscover membership.
3. Before **each** group signal, enumerate and revalidate every member’s birth identity, group and ownership—not just the group leader.
4. Refuse a group containing unknown/unowned members, changed membership or the app itself.
5. Send SIGTERM to verified groups; after three seconds, repeat discovery and all validation before SIGKILL.
6. Fresh family discovery determines completion. `EPERM`, uncertainty or survivors remain unresolved.

**POSIX limitation:** inspection followed by `kill(-pgid, …)` is not atomic. Another process can join or identifiers can change between them. Fixture tests and live qualification cannot prove this race nonexistent.

Implement the requested immediate-revalidation algorithm, but document that limitation explicitly. If R6 requires an absolute guarantee against signalling a newly joined unrelated process, group signalling cannot satisfy it with these APIs: keep Stop disabled pending an owner-approved change of signalling policy. Do not silently substitute PID signalling or claim stronger safety.

No automatic recovered-process killing is introduced.

### 7. Qualification and useful interim behavior

Keep qualification separate for each provider/backend/shim configuration:

| Gate | Blocks |
|---|---|
| Marker propagation through both shims, Claude Bash and Codex sandbox commands | Enabling marker-based family-completeness claims and dependent survivor actions |
| Claude 2.1.302 fresh `--session-id` through the actual shim | Enabling that fresh-launch flag |
| Real descendant home inspection, inventory/watch permissions and classification | Clearing affected ownership restrictions based on discovery |
| Explicit Stop qualification/authorization | Live recovered-process signalling |

Tests inject qualified capabilities; production defaults remain unqualified unless recorded evidence matches the launch configuration. No inferred qualification from older unrelated experiments.

Before qualification, reservation and direct-child identity registration can still protect normal launches. Preserve existing fresh/resume arguments. After a crash, unresolved reservations or families block only associated conversations/worktrees; unrelated sessions continue. Offer explanation and Refresh, not an ineffective “force” override.

Because `runtimeID: nil` intentionally preserves the environment, remove inherited `RPCE_RUNTIME_ID` at the **app-owned launch-environment boundary**, before any managed child launch. Explicit qualified injection then replaces it. Do not change Platform’s nil contract or indiscriminately modify unrelated callers’ dictionaries.

Request owner authorization when live qualification becomes the remaining dependency. O3 crash-test deferral neither grants that permission nor waives these gates.

## File-by-file impact

- **New `AgentMode/Runtime/Recovery/AgentProcessRegistry.swift`**: authority, reservations, associations, discovery/watch ownership and restrictions.
- **New runtime-record model file; existing `AgentRecoveryStore`**: independent runtime files and semantic preservation.
- **Platform `ProcessInspection.swift` plus small inventory/watch files**: same-UID inventory and exit events; reuse existing single-PID inspection.
- **Claude native controller**: pre-spawn registration, launch-token ownership, conversation association and qualified arguments.
- **Codex client/native controller**: central transport registration and thread/write barriers.
- **Verified headless provider declarations and `CLIProcessRunner.swift`**: optional Platform hooks, mandatory managed-provider wiring.
- **Existing native coordinators**: exact-runtime disposal/fallback association; no automatic bypass after registry refusal.
- **App composition/recovery coordinator/shared scheduler**: one registry, startup discovery, recovery items, closed-session/worktree restrictions and Refresh/Let finish/Stop UI.
- **Existing process/provider/recovery fixture suites**: tests below.
- **Evidence directory**: qualifications, exclusions and outcomes. No speculative plan prose or Owner Decisions.

## Implementation order and acceptance

Use one worker sequentially after Core/App ownership release.

1. **Registry storage and launch lifecycle:** reservation failure causes zero spawns; registration precedes writes; failed birth commit retains cleanup ownership; stale cleanup cannot retire a successor; sessionless and multi-thread clients work.
2. **Discovery/watch/Stop engine:** scripted PID reuse, boot change, denial, mixed exec evidence, missing marker, incomplete inventory, reparented/separate-group tools, stale watch events and unknown group members. Assert no unsafe eligibility or signal calls.
3. **Provider/composition integration, landed atomically:** every native/headless/model/goal start crosses reservation; fresh/resume flags remain exclusive; cold hydration starts no provider; unknown families restrict affected scheduling; unrelated work remains usable.
4. **Fixture-only review and validation:** no real spawn, inspection, provider call or signalling. Mark source implementation complete separately from each blocked live qualification.

## Recommendations

Build the complete source path, but **cut active unqualified marker/session-ID behavior and unsafe survivor actions**, not registration coverage. Defer Phase 4 history/Resume and R4 shutdown integration entirely.

Keep conservative unresolved records rather than adding a second registry, polling service or cleanup framework. Obtain owner permission only for live qualification and any necessary change to the group-signalling safety contract.

## Activation clarification

# Oracle Plan

## Summary

**Keep the coupled Phase 3 production activation off until the relevant live qualifications pass.** Complete its source implementation and fixture validation now, including ACP launch coverage. Do not activate registration alone while leaving every unqualified family permanently blocking: that creates a real workflow regression, not merely a disabled unsafe action. Existing Phase 1/2 behavior remains active, explicitly retaining its interim crash-confirmation limitation rather than claiming R6 protection.

## Current-state analysis

The independently checked Claude and Codex seams support the adopted ordering: reservation before actual spawn, immediate ownership of the returned handle, and durable birth registration before outgoing initialization/user writes.

The unresolved issue is **family completeness**, not root identity:

- A reaped direct child proves that child exited—not that its writer descendants exited.
- Clean application shutdown and a `cleanExit` mark do not supply missing process-family evidence.
- Without qualified marker propagation and classification, discovery may miss reparented writers or cannot distinguish writers from tools.
- Therefore, “root exited; no other matching process observed” cannot safely release ownership.

Consequently, active registration with conservative discovery **can leave ordinary cleanly closed conversations blocked indefinitely**. Refresh cannot promise resolution while the evidence needed to prove completeness remains unavailable.

## Design

### 1. Production activation boundary

Use the existing production composition point for **one coupled Phase 3 activation**, not independent switches for registration, enforcement, and discovery.

| Mode | Behavior |
|---|---|
| Before qualification | Existing Phase 1/2 production behavior. No Phase 3 reservations, marker injection, registry restrictions, or fresh Claude `--session-id`. |
| Fixture-enabled Phase 3 | Entire registration/discovery/fencing path with injected qualification results and fake OS/provider boundaries. |
| Qualified production Phase 3 | Mandatory reservation and registration across enabled managed launch paths; discovery before admission; enforce registry ownership independently of recovery confirmation. |

Do not perform shadow production reservations that later become unexplained blocking records.

This is a **deferred guarantee**, not an ownership override: before activation, report “Phase 3 source complete; production ownership enforcement pending qualification.” Do not advertise the interim crash confirmation as satisfying the two-writer contract.

Once Phase 3 activates:

- No missing dependency or inspection failure falls back to legacy sending.
- Unknown ownership blocks affected conversations/worktrees.
- Unrelated sessions remain usable.
- Confirmation, Dismiss, clean shutdown, and root exit cannot release unknown family ownership.
- Existing registration evidence must never be ignored merely because qualification later becomes unavailable.

### 2. What qualification must establish

The activation prerequisite is evidence sufficient to distinguish:

1. exited writers/launchers;
2. surviving writers or unresolved ownership;
3. positively identified tool-only survivors.

Test through the **actual configured shim/backend paths**:

- marker inheritance through launcher, provider, and spawned tools;
- discovery of reparented and separate-group descendants;
- selected home/ownership inspection and classification;
- ordinary teardown followed by discovery, demonstrating that normal completed sessions become eligible without mistaking unseen writers for absence.

No qualified CLI versions or results are assumed.

**Fresh Claude `--session-id` remains a separate dependent gate.** Registry activation need not wait for it if qualified discovery can conservatively protect a fresh runtime through its session/worktree association until the real conversation ID is observed. Keep existing arguments unchanged until that flag is independently qualified.

Recovered **Stop** may remain disabled while registration, watching, Let finish, and fencing operate. Its signalling qualification and inspect-then-signal limitation do not justify disabling safe observation—but lack of family completeness does block useful enforcement activation.

### 3. ACP and compatible backends

**Include ACP’s direct spawn in the source implementation.** Do not omit it because provider-history/Resume qualification is deferred.

At `ACPAgentSessionController`:

- reserve before spawn;
- retain the exact spawned handle immediately;
- commit birth identity before initialization;
- associate existing session/run identities;
- report actual root termination without declaring family exit.

Classify unqualified ACP/OMP and Claude-compatible descendants conservatively. Do not apply native-Claude argument, home, or conversation assumptions.

Registration qualification is distinct from Phase 5 recovery/Resume qualification. ACP can receive generic lifecycle/marker qualification without implementing Resume. Until that happens, do not quietly activate universal R6 while exempting ACP.

**Recommended minimum:** leave the single production cutover off until the managed launch families in its coverage are qualified. If the owner wants earlier partial activation, explicitly choose the provider scope and disclose that excluded providers remain on the interim contract; do not introduce that exception implicitly.

### 4. Preserve the adopted implementation boundaries

Keep:

- `AgentProcessRegistry` as the sole AgentCore runtime authority;
- runtime files in `AgentRecoveryStore`;
- Platform `ProcessRegistry` as the unchanged child-handle map;
- no polling, alternate store, daemon, retention work, or Resume implementation.

At managed launch-environment boundaries, strip inherited `RPCE_RUNTIME_ID` before explicit qualified injection. Preserve `ProcessLauncher(runtimeID: nil)` semantics for other callers.

The registry must continue treating supporting evidence conservatively:

- absent marker is not exclusion;
- effective-UID filtering or denied inspection makes inventory incomplete;
- mixed executable/environment samples cannot demote a possible writer;
- strong birth-identity exit evidence applies to that lifetime, not automatically its family.

## File-by-file impact and worker order

Assign **one coupled worker after Phase 2 releases Core/App**, using these internal cuts—not separately reviewed inactive milestones:

1. **Storage and launch**
   - Runtime model/codec, `AgentRecoveryStore`, `AgentProcessRegistry`.
   - Claude controller/compatible adapter, central Codex client and factories, both `CLIProcessRunner` APIs and managed callers, ACP controller.
   - Verify scout-only callers while editing; use actual source contracts over scout line numbers.
   - Preserve handles on failed birth commit; no protocol write or fallback bypass.

2. **Inventory and watching**
   - Platform inventory/watch helpers extending existing inspection.
   - Registry discovery, classifications, exact-lifetime exit handling, event coalescing and resource disposal.
   - No actual process operations in validation.

3. **Production integration**
   - Existing app composition, recovery catalog/coordinator, provider authorization, and scheduler restrictions.
   - Implement the coupled activation path, **default off pending qualification**.
   - Existing application behavior remains unchanged while off.

## Acceptance tests

Use fixtures to establish:

- Reservation failure causes zero spawns; registration failure retains cleanup ownership and permits zero writes.
- Codex model/auth/goal/sessionless starts, replacements, headless APIs, and ACP cannot bypass launch registration.
- Root exit plus incomplete family discovery remains blocking—even after a clean launch mark.
- Qualified complete evidence releases exited writers; verified tool-only survivors retain worktree restrictions.
- Missing markers, denied inspection, mixed samples, stale watch events and PID reuse never permit a second writer incorrectly.
- Activation off preserves existing production wiring; enabled fixtures exercise mandatory enforcement with no permissive fallback.
- Fresh Claude arguments remain unchanged without their separate qualification.

## Recommendations

Finish one coupled source package and its normal reviews; **do not activate registration-only production behavior**.

The owner-only dependency is authorization for bounded live qualification. Recommended default: request it when source validation is ready, while leaving current functionality intact. O3’s deferred app-crash acceptance neither authorizes these calls nor satisfies them.

Report source completion, production activation, and live acceptance separately. No new architecture or optional polish is needed.


## Required association closure before initial review

OracleA continued the existing planning workstream; returned preset identity was verified. This amendment closes the draft's reported omissions, not an additional review round or Owner Decision. Main verified the draft's compile-only build, lint and 13 source-validating suites (177 tests) by exact Conductor tickets/log summaries. `make guardrails` and `Scripts/check-agent-context` passed, with the existing route-count warning. No source checkpoint is claimed before this closure and independent reviews.

# Oracle Plan

## Summary

**Close these gaps before initial review.** Lifecycle/run associations, actual provider identity, permission context, and observed headless conversation IDs are required registry data—not optional factory polish. Extend the existing launch context and association methods; do not introduce another service. Keep coupled production activation OFF and existing runtime evidence restrictive.

## Current-state analysis

The supplied source confirms the omissions:

- `AgentRuntimeLaunch.makeLaunch` captures only family, worktree and conversation.
- `AgentRuntimeRecord` cannot associate a runtime with a durable session or logical run attempt.
- `AgentRuntimeOwnershipKeys.overlapsConversation` lacks provider identity; session identity cannot restrict a writer before its conversation ID is known.
- Reusable Codex transports already collect multiple conversation IDs, but need corresponding per-operation ownership—not one mutable “current session.”
- `AgentRuntimeProviderService.makeProvider` knows the actual `AgentProviderKind`; flattening it downstream is unnecessary.
- Registered-mode Claude/ACP fence behavior remains untested. Off-mode regression tests do not exercise those guards.

Retain the existing registry actor, store, launch owner, Platform hooks, and qualification boundary.

## Design

### 1. Add one typed context and durable association shape

Extend `AgentRuntimeLaunch.swift` with immutable, `Sendable` value context. Keep session semantics in AgentCore.

**Launch context:**
- actual provider identity;
- worktree path, optional only when genuinely absent;
- requested conversation ID, optional;
- optional managed-session association;
- captured permission configuration.

**Managed-session association:**
- `AgentRecoveryLifecycleBinding`;
- existing `AgentRunOwnership.attemptID`, when an attempt already exists;
- existing process-run ID, when available.

A session-bound launch may precede run-attempt creation: retain its lifecycle binding and attach the actual attempt before managed user handoff. Never invent an attempt ID.

Use an explicit optional association argument **without a default** at the relevant factory/request boundary. Polling, model discovery, auth and genuinely sessionless operations pass `nil` deliberately. Missing context on an Agent Mode handoff is an error, not an inferred sessionless operation.

Persist `associations` in `AgentRuntimeRecord`, each containing:

- optional session association;
- optional native conversation ID;
- applicable worktree path;
- permission snapshot;
- supported extras.

Associate by existing lifecycle/run/conversation identities; do not allocate another association authority. Retain earlier run associations when a transport is reused. The existing `conversationIDs` and `worktreePaths` may remain conservative unions maintained by the registry, not independently supplied competing state.

### 2. Provider and permission identity

Keep `AgentRuntimeFamily` for transport mechanics. Add actual provider identity separately, using existing identifiers:

- native/headless Claude: `ClaudeCodeRuntimeVariant`;
- Codex app-server/exec: Codex;
- ACP: `ACPProviderID`.

Native and headless routes for the same provider must produce the same provider identity. Do not use display names, command basenames, credentials or full configuration objects.

For permissions, use a small tagged snapshot of existing policy values:

- Claude: configured permission mode;
- Codex: approval policy and sandbox policy;
- ACP: selected session mode and auto-approve setting;
- unavailable/not applicable: explicitly represented, never interpreted as permissive.

Reuse existing typed values and serialization where available. The excerpt does not supply all concrete permission declarations; the worker must map these named fields to those declarations during editing.

Store the **requested configuration**, not an unsupported claim that the provider applied it. Before a permission-changing request, persist the requested snapshot on the exact association; failure prevents that request. Preserve associations for different threads/runs independently.

Qualification must not accidentally treat qualification of one ACP or compatible backend as qualification of every backend sharing its family. Narrow the existing qualification lookup to family plus actual provider identity; keep production qualification empty.

### 3. Capture once; update at the actual operation boundary

Extend the existing APIs conceptually:

- `makeLaunch(family:context:)`
- `associate(context:) async throws`
- `authorizeWrite(context:) async throws`

`AgentRuntimeLaunch` continues supplying runtime ID and launch token internally.

**Initial launch**
1. The owning coordinator captures lifecycle and existing immutable run ownership.
2. Pass that value through the existing factory/request.
3. Reservation persists it before spawn.
4. Birth registration completes before initialization or stdin.

**Reused transport**
1. Capture the new operation’s context at its owner.
2. Persist its association before the conversation-changing/user request.
3. Revalidate existing lane/run/transport ownership after awaiting.
4. Perform the existing final synchronous write fence.

Do not keep a shared mutable “current context” on a multi-thread client. Codex requests carry their own context; responses to `thread/start`/`thread/fork` associate the returned ID with the captured request context before returning to callers or issuing subsequent mutations.

Claude and ACP reused controllers attach the next actual run attempt without replacing prior associations. Delayed callbacks retain the captured launch and operation context, never consult whichever session currently occupies the controller.

For headless Claude, retain the specific `AgentRuntimeLaunch` alongside the invocation. At the existing decoded session-ID event/completion boundary, await association of the observed ID with that launch and captured context. Do not change an already affirmative delivery outcome to rejection if association fails: preserve the runtime’s restrictive state and report the persistence failure. Apply the same update to buffered print mode when its response exposes a session ID.

### 4. Make associations affect restrictions

Extend `AgentRuntimeOwnershipKeys`, restriction projections and preserved-binding extraction with actual provider identity and session lifecycle references.

- Known distinct providers do not collide solely on conversation text.
- Unknown provider/home identity remains conservative.
- An unresolved runtime associated with a session blocks that session even before a native conversation ID exists.
- Resetting the session must not evade a still-unknown owner: retain the original binding for evidence, but session-UUID overlap remains restrictive until ownership is resolved.
- Worktree restrictions remain independent; adding a conversation must not erase unresolved worktree ownership.
- Sessionless runtimes remain registered with whatever conversation/worktree context actually exists.

Catalog rows can now expose associated sessions and permission context. Do not add a new catalog or require every runtime to have a session.

### 5. State compatibility and exclusions

**Add `detachedAtQuit` to the record enum and codec now.** It is an agreed schema variant and a tiny compatibility change. Treat it as potentially holding a writer; implement no detach producer, action or shutdown integration. Keep `toolsRemaining` as the existing derived classification state.

Missing new fields in earlier draft records must not fabricate associations or provider certainty. Preserve them conservatively; do not delete records or guess that generic `.acp` means a particular provider. Preserve nested extras.

Exclude `claude mcp add/remove` from runtime registration if the worker confirms the stated configuration-only behavior. These commands do not own a provider conversation or worktree. **Still strip inherited `RPCE_RUNTIME_ID` from their child environment** so a configuration process cannot masquerade as a descendant of an unrelated registered runtime. This is an environment-copy change, not managed registration or a Platform nil-contract change.

## File-by-file impact

| Files | Minimal change |
|---|---|
| `AgentRuntimeRecordModels.swift`, runtime codec/store extension | Provider identity, association/permission fields, `detachedAtQuit`, conservative legacy decoding. |
| `AgentRuntimeLaunch.swift`, `AgentProcessRegistry.swift`, `AgentProcessRegistrySupport.swift` | Typed context, association writes, scoped restriction matching and qualification lookup. |
| `ClaudeAgentModeCoordinator.swift`, native controller/factory | Capture lifecycle/run context; pass through replacement launches; update reused-run associations. |
| `AgentRuntimeProviderService.swift`, headless Claude/Codex providers, `ClaudeCodeProvider.swift` | Pass actual provider and explicit session context; associate observed fresh conversations. |
| `ACPRunRequest` declaration, ACP controller and Cursor/OMP/OpenCode factories | Carry context through existing requests; polling/sweeps explicitly pass sessionless context. |
| Codex client/controller, VM factory and non-agent factories | Per-request association on reusable transports; explicit sessionless model/auth context. |
| Existing recovery projections/catalog | Consume session/provider/permission associations without new ownership state. |
| Claude configuration-command launcher | Strip inherited marker only; retain administrative exclusion. |

Update callers surfaced by required parameters. This is necessary plumbing, not permission for unrelated factory redesign.

## Implementation order and acceptance

Use the same Pair sequentially, with one shared-file owner:

1. **Model/context and registry changes.**
   - Round-trip all fields/extras.
   - Missing fields remain restrictive.
   - `detachedAtQuit` cannot release a writer.
   - Same-session unknown conversation and cross-provider identity tests.

2. **Factory/request plumbing and observed-ID updates.**
   - A reservation contains lifecycle, actual run attempt and permission context before fake spawn.
   - Reused Claude/ACP attempts and two Codex threads retain distinct associations.
   - Polling/auth/model calls explicitly carry nil session context.
   - Headless compatible identity and fresh Claude session-ID association reach the same runtime record.

3. **Registered-mode Claude/ACP write tests.**
   Add a narrow internal injectable final-byte writer, defaulting to the existing pipe writer, and use fixture registry authority. Reuse existing controller setup seams; if needed, add only a fixture initializer for committed transport ownership—not a general debug transport harness.

   Exercise the **production fence and send methods**:
   - registration absent/failed → zero bytes;
   - registry authorization suspended, then transport replaced → zero bytes;
   - valid registered ownership → one write;
   - permission/control request and response paths respect their required fence;
   - association failure → no conversation-mutating write.

No providers, live inspection or qualification are required. These tests establish registered-mode source behavior, not live readiness.

## Recommendations

Close the required data and caller plumbing before initial reviews; do not cut it as “too broad.” Keep administrative configuration commands outside registration, include `detachedAtQuit` without implementing detach, and add narrow registered-mode write tests.

Production activation remains OFF. Source completeness, initial review, qualification and live acceptance remain separate; no new owner product decision is needed.
