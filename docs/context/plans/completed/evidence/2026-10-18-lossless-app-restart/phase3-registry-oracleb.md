# Phase 3 initial OracleB review

Scope: read when the task touches Phase 3 process-registry review findings.
Authority: Reference
Last-verified: 2026-10-22

Frozen tree: `aaa821b7755edc7fb9520b7b52efc93328913c53`. Complete initial response; identity verified. Findings await main disposition and independent lane completion.

# Oracle Review



# Phase 3 process registry: initial review

## Summary

This package adds `AgentProcessRegistry`, the single authority for agent process ownership. Its records are stored in `AgentRecoveryStore` under `runtimes/<id>.json`. It also adds:

- **Platform process tools:** a same-user process inventory, a Dispatch-based exit watch, and optional launch-ownership hooks in `CLIProcessRunner`.
- **Launch fences:** reserve before spawn, commit the birth identity, associate the conversation and authorize each write. These now cover Claude native and compatible backends, headless Claude, Codex app-server and exec, ACP, model discovery and Oracle print mode.
- **Ownership capture:** a task-local `AgentRuntimeOperationOwner` carries the session context through suspensions, retries and detached work.
- **Recovery integration:** admission, scheduler and worktree restrictions, catalog and banner rows, Refresh and Let finish, a Stop engine that production leaves disabled, and stripping of an inherited `RPCE_RUNTIME_ID` at every managed launch boundary.

Production stays inert, as designed:

- Qualification is empty, so `.production` resolves to `.activationOff`.
- No reservation, marker or `--session-id` is produced.
- Startup loads runtime records without spawning anything. With no records it doesn't even take an inventory.

I found no P0, and no regression in today's production behaviour. Three defects (P1) break the fixture-enabled contract and would break normal workflows as soon as the coupled activation is turned on.

---

## Required (P1)

### P1-1: A fresh Claude native conversation can't reply to an approval during its first turn

**Scenario.** Registration is on and fresh `--session-id` is off (the activation plan explicitly allows that combination). The steps:

1. A fresh launch reserves with no conversation ID.
2. The first `sendUserMessage` associates with `conversationID: nil`.
3. The CLI then reports its `session_id`, and `recordObservedSessionID` stores it in `sessionID`. Nothing associates it with the launch.
4. The CLI asks for permission (`can_use_tool`). `respondToPermissionRequest` runs `fenceRuntimeWrite(association: nil)`, which calls `authorizeWrite(conversationID: sessionID)`.
5. The registry throws `.ownershipConflict(nil)` because the record's `conversationIDs` doesn't contain that ID.
6. The issuing launch is still current, so the catch block calls `failProtocolAndShutdown`.

Interrupts (`sendControlRequest` with no association) fail the same way. The failure lasts until the next owner write associates the ID, so the whole first turn is exposed.

**Impact.** Every fresh Claude conversation dies at its first tool approval, and Stop/interrupt fails during that turn.

**Evidence.**
- `ClaudeNativeProcessSessionController.swift` ≈L970–L998: the reply fence, then `failProtocolAndShutdown`.
- ≈L1554–L1576: `fenceRuntimeWrite` captures `sessionID` and calls `authorizeWrite(conversationID:)`.
- ≈L3749 (`recordObservedSessionID`): no association.
- `AgentProcessRegistry.authorizeWrite` (≈L767): rejects an unknown conversation.
- `RegisteredNativeTransportWriteFenceTests` never sets a `sessionID`, so this path is untested.

**Smallest fix.** When a managed transport first observes or changes its session ID, await `runtimeLaunch?.associate(conversationID:)` in the stdout handling path, before any later write. That uses the launch's own captured scope. If it fails, shut down. Add a registered-mode test: observe a session ID, then reply to an approval and send an interrupt.

### P1-2: A reservation that never got a committed birth identity blocks forever

**Scenario.** The birth commit fails. Causes include:
- `ProcessInspection` returns `inconsistentObservation` or a denial;
- a transient storage error;
- the child exits during the commit await, so the Claude EOF path's `rootReaped` removes the active launch first.

What happens next:
- `registerSpawn` sets `activeLaunches[id] = nil` and leaves `root == nil` (state `unknown`, or `reserved` and unpersisted).
- The launcher then terminates and reaps the exact child. Its `rootReaped` is a no-op because the token is no longer active, so no evidence is recorded and no refresh runs.
- `classifyObservation` returns `.unknown` whenever `root == nil`, even with complete, qualified, marker-propagating discovery that finds no marker.

A fresh Claude or Codex reservation has no conversation, so `blocksSend` blocks every send in that worktree and that session (`conversationIDs.isEmpty && overlapsWorktree`, plus `overlapsSession`). No GC exists, and Refresh can't clear it.

**Impact.** One transient inspection or storage hiccup permanently pauses all sending in a worktree, including after restarts. This contradicts the acceptance criterion "Qualified complete evidence releases exited writers". `testCommitFailuresLeaveOwnershipUnresolvedAndFenceEveryWrite` and `testRootlessReservationStaysUnresolvedWithoutMarkerEvidence` currently lock this behaviour in.

**Evidence.** In `AgentProcessRegistry.swift`:
- `registerSpawn` (≈L632–L665): clears `activeLaunches` on failure.
- `rootReaped` (≈L777): guards on the active token.
- `classifyObservation` (≈L455): `guard record.root != nil else { return .unknown }`.

**Smallest fix.**
- On commit failure, keep the token in a "reaping" set and persist the spawned PID as unverified evidence. Don't drop it before `rootReaped`.
- Let `rootReaped` record that the launcher reaped this child.
- In `classifyObservation`, treat a rootless reservation as `exited` only when all three hold: the launcher reaped the child, the inventory is complete, and the family is qualified for marker propagation with no marker match. Otherwise keep it `.unknown`.

### P1-3 (plausible): Relaunching the same session can collide with the app's own just-ended launch

**Scenario.** Two windows exist.

- **Window 1, before the reap is reported.** Some launchers report the reap asynchronously:
  - Claude's EOF handler uses `Task.detached { reapChildStatus; rootReaped }`.
  - Codex goes through `scheduleTransportCleanup` → `finishTransportTermination`, which waits out `terminateAndReap`.
  - ACP uses `processWaitTask`.

  While the old launch is still active, `writerConflict` refuses any conversation overlap. A Codex recovery that `thread/resume`s the same thread gets `.ownershipConflict`.
- **Window 2, during the post-reap discovery.** `rootReaped` sets `activeLaunches[id] = nil` *before* `await refresh()`. During the refresh's inventory and inspect awaits, the record is still `.live` and non-active, so `blocksSend` matches through `overlapsSession`. A Claude fresh fallback, or any reservation for the same session, is refused. The coordinator also briefly projects a "started by this launch" banner and restriction.

The plan says a registry refusal never falls back automatically, so the run fails visibly.

**Impact.** Codex crash recovery and Claude resume-to-fresh fallback fail intermittently once registration is active.

**Evidence.**
- `AgentProcessRegistry.rootReaped` (≈L777–L788): clears the active token, then awaits refresh.
- `writerConflict` (≈L542–L560): `blocksSend` for non-active records includes `overlapsSession`.
- `ClaudeNativeProcessSessionController.swift` ≈L3013–L3023: detached reap.
- `CodexAppServerClient.swift` `scheduleTransportCleanup` / `finishTransportTermination`.

**Context gap.** I can't see whether these coordinator paths await the old controller's `shutdown()` first.

**Smallest fix.**
- (a) `reserveLaunch` and `associate` first await any in-flight `refreshTask`, then decide synchronously.
- (b) A launch reaped by this instance stays non-restricting until its post-reap pass has classified it.
- (c) Same-session relaunch paths await the previous launch's reap report. Store the detached reap task and await it before a restart.

---

## Optional (P2 / P3)

**P2-1: Buffered and streaming `CLIProcessRunner` error paths skip `rootReaped`.**
- **Scenario:** a timeout, cancellation or wait error rethrows without reporting the reap.
- **Effect:** the launch stays in `activeLaunches` for the rest of the instance. Its record stays `live`, is never reclassified, and its active conversation overlap still refuses a later resume of a conversation it observed.
- **Evidence:** `CLIProcessRunner.swift` ≈L455–L459 (`throw error` before `rootReaped`), and the `waitTask` catch in `runStreaming`.
- **Fix:** report `rootReaped` on every path where the exact child was reaped, for example from the cleanup closure when the registry removal succeeds.

**P2-2: The Codex request fence allowlists write methods instead of denying by default.**
- **Scenario:** a thread-scoped mutation outside the hard-coded set (`runtimeThreadWriteMethods` plus the `turn/` prefix), such as `review/start` or `thread/archive`.
- **Effect:** it bypasses association and authorization. Only the committed-generation check protects it.
- **Evidence:** `CodexAppServerClient.fenceRuntimeRequest` (≈L1060–L1100).
- **Fix:** any request carrying `threadId` associates and authorizes unless it is on an explicit read allowlist.

**P2-3: Provider home comes from the wrong process and then makes conversations look distinct.**
- **Scenario:** `registerSpawn` records `CLAUDE_CONFIG_DIR` from the *root* (the rotator shim, which the spec says can't carry the real home) and never corrects it. Discovery picks the first "writer" in dictionary order. `isClaude` also covers headless GLM/Kimi.
- **Effect:** `overlapsConversation` treats two different known homes as different conversations, which is the permissive direction.
- **Evidence:** `AgentProcessRegistry.registerSpawn` (≈L655), `discoverFamily` step 3 (≈L395), `AgentProcessRegistrySupport.overlapsConversation`.
- **Fix:** accept a home only from a member whose executable basename qualifies it as the provider CLI, and only for the standard Claude provider. Until then, a known home never separates conversations.

**P2-4: Sessionless, non-writing launches fall under the worktree rule.**
- **Scenario:** model listing, auth, health checks or Oracle print mode with a working directory.
- **Effect:** `writerConflict` refuses them while any unassociated unresolved runtime sits on that worktree. This is worse combined with P1-2.
- **Fix:** apply the worktree clause only to session-bound launches.

**P2-5: Reservations fail before startup discovery finishes.**
- **Scenario:** early model polling at app launch, before recovery startup has run `start()`.
- **Effect:** `reserveLaunch` throws `.ownershipUnknown` (`guard hasStarted`).
- **Fix:** `prepareSpawn` awaits the registry's start.

**P2-6: Inventory method cost.**
- **Problem:** each pass inspects every same-user PID through `ProcessInspection.inspect`. That allocates and zero-fills a `KERN_ARGMAX` (≈1 MB) buffer per process, on a blocked cooperative thread, and every exit of any watched member triggers another full pass. This is a design inefficiency, not a measured target.
- **Evidence:** `ProcessInventory.swift` ≈L70 and ≈L98; the existing `processArguments` backend.
- **Fix:** size `KERN_PROCARGS2` with a NULL query, or use a small bounded buffer, and coalesce event-driven passes.

**P2-7: The scheduler's worktree key isn't conservative.**
- **Scenario:** `effectiveWorkspacePath` throws inside `try?`.
- **Effect:** the worktree key becomes nil, so tool-only and unassociated survivors on that worktree no longer pause automatic work.
- **Evidence:** `AgentModeViewModel+ScheduledSend.swift` ≈L2444.
- **Fix:** when the worktree can't be resolved, treat the session as blocked.

**P2-8: Recovery rows omit fields R6 requires.**
- R6 says each item shows elapsed time, permission mode, the session, and the discovered descendants.
- `recoveryListRuntimeText` shows only a process count, the first worktree and the first conversation, although `createdAt` and `associations` are already available.
- **Evidence:** `AgentModeViewModel+RecoveryList.swift` ≈L656–L700.

**P3-1: Unwatchable members cause rewrites and over-restriction.** `markUnresolved` on an unwatchable member flips the record `unknown` → `live` → `unknown` on every refresh, rewriting it each time. It also turns a `toolsRemaining` record into a possible writer.

**P3-2: Double reap when the child exits during commit.** If the Claude child exits during the commit await, the detached `reapChildStatus` and the catch-path `terminateAndReap` both target the same PID. There is a tiny window in which a reused PID could be signalled. Gate the catch path on "not already reaped".

**P3-3: Teardown now waits on a full discovery pass.** `rootReaped` awaits a complete pass inside every shutdown, Codex teardown and headless completion path.

**P3-4: Some Claude control responses aren't bound to the issuing launch.** Replies sent through `sendLine(payload)` with no `writeOwner` (≈L1651; for example `mcp_message` or hook callbacks) only check that the transport is committed. If they await before replying, a replacement transport could receive them.

---

## Context gaps

- **Callers outside the diff may never bind an owner scope**, for example Claude live permission-mode toggles, Codex controllers created by other factory paths, and `thread/rollback` callers. Under registration these fail closed (`.sessionContextUnavailable`). That is safe, but could break workflows I can't enumerate from the diff.
- **Not all `CLIProcessRunner` callers are covered.** Other AgentCore callers, such as auth or version probes, may still launch without hooks.
- **Claude `session_id` timing.** Whether Claude emits `session_id` before the first user message affects the size of the P1-1 window but not whether it exists. Whether `--resume` keeps the same ID matters too.
- **`unresolvedPriorExecution` and the tool-only Resume confirmation** are absent. I treated them as Phase 4 Resume scope.
- **Validation is fixture-only, as stated.** The 406 focused tests do not qualify anything live, and no live claims are made.

## Recommendations

1. Fix P1-1 through P1-3 before committing this step. Each is local:
   - associate the observed Claude ID;
   - give rootless reservations a path to resolution when the launcher reaped the child and discovery is complete;
   - order reap reporting and conflict checks so the app never conflicts with its own ended launch.

   Update the two tests that currently enforce the permanent-unknown behaviour, and add registered-mode tests for "approval after observed session ID" and "same-session relaunch during the post-reap pass".
2. Take P2-1, P2-2 and P2-4 cheaply in the same pass: report the reap on all reaped paths, deny-by-default for Codex thread methods, and skip the worktree clause for sessionless launches. List the remaining P2/P3 items as deferred.
3. Keep production activation, fresh `--session-id` and recovered Stop off. Record "source complete; enforcement pending qualification" separately from live acceptance (O3).
4. In re-review, check that fixes for P1-2 and P1-3 don't weaken the conservative rules: a missing marker and denied inspection must still never count as proof of exit.
