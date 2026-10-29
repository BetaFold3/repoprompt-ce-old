# Phase 3 registry — OracleB first re-review

Scope: read when the task touches Phase 3 registry first re-review findings for frozen tree `1862f178b341897ebdf83fa6053df8150d6117a2`.
Authority: Reference
Date: 2026-10-22

Preset identity verified: OracleB, `7CDD523E-1D7C-47EA-98FE-D5FEA24D2D8C`, explicit selection. Chat `lossless-restart-phase-3-E1037B`. No live validation was performed by the reviewer.

# Oracle Review



# Re-review round 1/2: Phase 3 process registry (tree `1862f178`)

**Summary.** The delta targets my three P1s:

- **P1-1:** observed Claude session IDs are now associated with the launch. Authorize-only writes (replies, interrupts) are checked against that associated conversation.
- **P1-2:** after a failed birth commit, the launch keeps the exact spawned pid. Only a confirmed `waitpid` of that pid counts as reap evidence. A runtime with no recorded root process can resolve only after that confirmed reap and complete qualified discovery.
- **P1-3:** cleanup of the previous runtime is now retained and joined in several places: the Claude stdout-EOF reap, Codex transport cleanup and Codex controller retirement (per tab), and the ACP wait task.

It also contains other-lane and optional fixes, such as:

- active runtimes of the same session now exclude each other;
- discovery treats processes with unreadable ownership evidence as making it incomplete;
- tools are classified only from an explicit list;
- Stop re-checks each process group before signalling it;
- Codex replies carry receipts;
- Codex thread methods are treated as writes by default.

Verdict: P1-1 and P1-2 are closed. P1-3 is closed for same-provider relaunches but still open for successions across providers. The new same-session exclusion widens that remaining window. I also found two regressions caused by this delta that need fixing.

## Status of my required findings

### P1-1: CLOSED
- **Association.** `ClaudeNativeProcessSessionController.associateObservedConversationIfNeeded()` runs after every handled stdout line (`handleStdoutChunk`) and after `initialize` returns a session ID. It associates the ID durably, under the latest owner scope or else the launch's own scope, before the next line is processed. If association fails, the transport shuts down.
- **Fence.** `fenceRuntimeWrite` now authorizes authorize-only writes against `runtimeAssociatedConversationID`, never against an ID that was observed but not yet associated.
- **Test.** `testClaudeObservedFreshConversationIsAssociatedBeforeItsPermissionReply` covers exactly my scenario: a permission reply, then an acknowledged interrupt that creates no association, then a further owner write with no shutdown.

### P1-2: CLOSED
- `registerSpawn` sets `spawnedPIDs[id]` before its await. Both failure branches (identity unavailable, storage error) record `uncommittedLaunches`.
- `rootReaped` accepts uncommitted launches and late confirmed reports. It records `rootReaped` only when the reap is confirmed and the pid is the exact child.
- `classifyObservation` requires `root != nil || rootReaped`. After that, `family.isComplete` still decides.
- Every launcher that reaps after a commit failure now reaps the exact child itself, so the report is normally `confirmed: true`: `CLIProcessRunner.commitLaunchOwnership`, the ACP start path, and Claude's single owned reap via `pendingRootReaps[pid] ?? ownedRootReap`.
- `testRootlessFailedCommitResolvesOnly…` covers both cases: a confirmed reap with incomplete then complete discovery, and an unconfirmed reap that stays unresolved.
- This closure is only as strong as `isComplete`. See R-1, which can make `isComplete` permanently false.

### P1-3: OPEN (narrowed to succession across providers or coordinators)

**What is fixed.** Same-provider relaunches are now properly joined:
- Claude EOF reap: shutdown, a concurrent shutdown and the next registered `startProcess` all join it.
- Codex: `stop()` and `startProcess` join `pendingTransportCleanups`. `startCodexNativeSession` joins `retiringCodexControllerShutdowns[tabID]`.
- ACP: shutdown joins `waitTask`.

The joined-versus-unjoined contrast test and the private `/bin/cat` EOF test are sound evidence for these paths.

**What is still open.** The Codex join runs only inside `startCodexNativeSession` (`CodexAgentModeCoordinator.swift` ≈L3570).

**Failure scenario:**
1. `handleProviderSwitch` (≈L3517) retires the Codex controller with `retireCodexController(controller, tabID:)`.
2. The next start for the same tab and session is a Claude or ACP start, which never joins Codex retirements.
3. While the Codex shutdown is still in flight, its record is still active.
4. `writerConflict` now applies `overlapsSession` to active records too. That line was changed in this delta; before it, only a non-active old record blocked the new session.
5. So the Claude reservation fails with `.ownershipConflict`. The registry never falls back automatically, so the user sees the run fail.

The same holds during the old runtime's post-reap discovery pass. It probably also applies to Claude → Codex and ACP → X switches, if those coordinators don't await their own shutdown on a switch (not visible in the delta).

**Smallest fix.** Move the per-tab retirement join into one place that every coordinator's registered start uses:
- either have Claude and ACP starts await `joinRetiringCodexControllers(tabID:)`, with symmetric retention for their own retirements on a provider switch;
- or make the provider switch await the old controller's shutdown when `joinsRetirementBeforeSuccessor` is true.

**Test.** Add a contrast row that switches Codex → Claude on one session while the old controller's shutdown is held: the new reservation must wait, then succeed.

## Required regressions caused by this delta

### R-1 (P1): one unreadable process anywhere makes discovery permanently incomplete

**Where.** `AgentProcessRegistry.discoverFamily`, the new block after the marker and parent-link loop (≈L441–L449). If any unidentified inventory process has an unavailable `environment`, it sets `decisive = false`.

**Why this breaks.** Every same-user zombie hits this rule. `KERN_PROCARGS2` has no exec string area for a zombie, and `ProcessInspection` still returns `.observed` for it (that is what `isZombie` exists for). Two examples:
- A long-lived app that never reaps a child keeps that zombie forever.
- RepoPrompt's own just-exited children (git, CLI helpers) are zombies until reaped, so they hit this rule briefly but often.

**Failure scenario:**
1. While any such process exists, every runtime classifies as `unknown`.
2. No runtime ever reaches `exited`, including the rootless case fixed by P1-2.
3. With the new active-or-not same-session exclusion, every relaunch of a session that ever had a runtime is refused, and worktrees stay blocked.

There is no polling, so a pass that coincides with a transient zombie leaves the record `unknown` until a manual Refresh. This is the same class of permanent block as P1-2, re-introduced in qualified mode.

**Smallest fix.** Skip two kinds of process in that rule:
- `observation.isZombie`: a zombie runs no code, and its children reparent and are observed themselves.
- Processes born before the runtime: compare against the record's root birth time in the same boot session. For records with no root, compare against `createdAt` with a margin. A process started earlier cannot be a descendant. The parent-link check already relies on this ordering.

Apply the same zombie exemption to Stop's new rule that "unreadable group membership anywhere → `.refusedUnsafeGroup`". `getpgid` fails for zombies too.

**Test.** One unrelated same-UID zombie with an unavailable environment, plus a process born earlier with an unavailable environment: an exited family must still classify `exited`.

### R-2 (P1, plausible; verify): ACP shutdown can await its own wait task

**Where.** `ACPAgentSessionController.shutdown()` now runs `await waitTask?.value` whenever `launch != nil` (≈L1736). The wait task's body (`startProcessWaitTask`, ≈L1813–L1826) calls `rootReaped` and then `await handleProcessExit(...)`.

**Failure scenario.** If `handleProcessExit`, or anything it awaits, calls `shutdown()` while the state is not yet `.closing`, then `processWaitTask` is the task currently running. Shutdown then awaits its own value and hangs. The controller stays in `.closing` and the run never finalizes. Only registered mode is affected. Existing ACP tests run with registration off, so `launch` is nil and the join never runs.

**Smallest fix.** Before calling `handleProcessExit`, have the wait task clear its handle (`processWaitTask = nil`). Joining after that is unnecessary, because the reap report has already completed. Alternatively, skip the join when shutdown is running on the wait task.

**Verify.** Trace `handleProcessExit`. If it never reaches `shutdown()`, close this as no-issue.

## Optional findings (P2/P3, listed and not looped on)

**P2**
- **Scheduler change is visible in production with activation OFF.** `runtimeWorktreeIsUnresolved` and `worktreeUnresolved` take effect whenever `processRegistry != nil`, and `AgentProcessRegistry.production` is attached in production. Any scheduled session whose `effectiveWorkspacePath` throws now stays "busy" forever instead of failing visibly. Fix: block only when global uncertainty exists or some restriction carries worktree paths. Promote to P1 if that lookup throws in normal use, for example a worktree session before its worktree is created.
- **Interrupts can be dropped.** `sendControlRequest` now runs `try Task.checkCancellation()` after the fence (≈L1666). An interrupt issued from an already-cancelled task (a cancel or stop path) is then never written. Exempt the `interrupt` subtype.
- **Recovery starts may be refused by the new slot check.** `startCodexNativeSession` throws `CancellationError` when `codexControllerSlotHolds` fails. Confirm that the auth-recovery and unexpected-stream recovery paths put the successor in its slot before starting it. Otherwise registered-mode recovery always cancels. Those paths, which were the original P1-3 scenario, have no joined test.
- **Treating unknown thread methods as writes can fail background calls.** Background Codex calls that name a `threadId` without an owner scope now fail with `sessionContextUnavailable` under registration. Check which unlisted thread methods the app actually sends.
- **Same-session helper launches may now be refused.** A headless Claude or Codex-exec helper that inherits the session's TaskLocal scope is refused while the session's native runtime is active. Confirm that helpers pass an explicit `.sessionless` scope.

**P3**
- Claude auto-approve and unsupported-subtype replies now pass `writeOwner: receivingLaunch` synchronously but skip `authorizeWrite`. This is acceptable, but document it as the sanctioned reply exception.
- `ensureStarted` returns as soon as `hasStarted` is set, which can be before the first discovery pass finishes. It is conservative, but the doc comment overstates what it waits for.
- `codexReceipt` is not persisted, so a request rebuilt from a snapshot falls back to a wire-ID-only reply, which registered transports refuse.
- Pre-existing: the duplicate check on wire ID can drop a replacement transport's request that reuses the same ID.
- The registered EOF reap now sends SIGTERM to the process group after 2 s if the root is still alive. Before, it was a blocking reap with no signal. This is deliberate; note it in evidence.
- With the explicit tool list, unlisted Bash-tool descendants become `unknown` and block the whole session rather than just the worktree. This matters for the future qualification data, not for code now.
- `spawnedPIDs` leaks an entry when `registerSpawn` loses its race after the inspect await.

## Recommendations
1. Fix R-1: exempt zombies and processes born before the runtime, in discovery and in Stop's per-group check. Add the counterexample test. This one change also protects the P1-2 closure.
2. Close P1-3 for provider switches: join per tab across coordinators, or await retirement on a switch, and add a contrast row that switches Codex → Claude.
3. Resolve R-2 by tracing `handleProcessExit`. If shutdown is reachable from it, clear the wait-task handle before `handleProcessExit`. Otherwise record it as no-issue.
4. Cheaply, if possible: gate the scheduler's unresolved-worktree block on existing restrictions (production-visible), and exempt interrupts from the post-fence cancellation check.
5. Rerun `AgentProcessRegistryTests`, `RegisteredNativeTransportWriteFenceTests`, `AgentModeRunServiceLifecycleTests` and the ACP suites. Keep production qualification empty and Stop disabled. Nothing here requires live, provider or real-process qualification.
