# Phase 3 registry — OracleB final re-review

Scope: read when the task touches Phase 3 registry final re-review findings for frozen tree `c25b94f0c854aee8577495d9f71ed6cfc247863d`.
Authority: Reference
Date: 2026-10-22

Preset identity verified: OracleB, `7CDD523E-1D7C-47EA-98FE-D5FEA24D2D8C`, explicit selection. Chat `lossless-restart-phase-3-7444D4`. This is text-only review; no live validation by the reviewer.

# Oracle Review



# Phase 3 registry: final re-review, round 2/2 (tree `c25b94f0`)

**Verdict: closed.** None of my P0 or P1 findings remain open, and the delta introduced no new P0 or P1.

**What the delta does.** It addresses my round-1 findings with these changes:
- **Joined retirement across providers (P1-3).** Each tab's `AgentTabSession` now keeps the cleanup of controllers it retires, for any provider. Registered Claude, Codex and ACP starts wait for that cleanup before they reserve. Provider switches away from Codex, Claude or ACP now hand their cleanup to this mechanism.
- **Discovery and Stop ignore some unreadable processes (R-1).** Discovery no longer treats an unidentified zombie, or a process born more than 300 s before the family, as a sign that discovery is incomplete. Stop now ignores a zombie whose process group can't be read.
- **Two cheap fixes I asked for.** The unresolved-worktree block now applies only when some restriction carries a worktree. Interrupts are exempt from the cancellation check that runs after the fence.

It also adds Claude hardening that other lanes asked for:
- buffered inbound lines are bound to the transport that delivered them;
- automatic replies are queued and pass the registry fence;
- a start cancelled while its reservation is pending releases it;
- a user turn cancelled during its admission check writes nothing.

I checked these for regressions. The paths with registration off are unchanged in behavior: the queue only fills on managed transports, and `nil === nil` keeps the per-line guard passing.

## My round-1 items

| Item | Disposition | Evidence |
|---|---|---|
| P1-1 | Closed in round 1. No regression. | The per-line `originLaunch` binding narrows association further: `associateObservedConversationIfNeeded(originLaunch:)`. |
| P1-2 | Closed in round 1. Still holds. | R-1 is fixed, so `isComplete` can be true again (one cross-boot gap remains: R2-B). |
| P1-3 (provider switch) | **Closed.** | Codex → Claude: `retireCodexController(_:session:)` keeps the cleanup and `startOrResumeWithFallback` joins it before reserving, then rechecks that the run is still current. Switches away from Claude or ACP keep their cleanup too: `handleProviderIdentityTransitionSync` and `retireRegisteredACPControllerOnProviderSwitch`. The ACP runner and Codex starts both join. The contrast test (joined vs. unjoined) is sound. A same-provider replacement path (conversation reset) is still not joined: R2-A. |
| R-1 | **Closed.** | The zombie and earlier-born exemptions only exclude non-members; neither is treated as exit evidence. Stop skips only a zombie whose group can't be read, so a live process with an unreadable group still refuses Stop. Four new tests cover root, rootless, the within-margin contrast and Stop. Two residual gaps: R2-B and R2-C. |
| R-2 (my own "plausible, verify") | **Accepted as no-issue.** | Nothing inside `handleProcessExit` calls `shutdown()`. If an outside consumer calls `shutdown()` after the events stream finishes, it runs on a different task. That call joins a wait task that is only blocked on MCP and provider cleanup, which never wait on shutdown, so no cycle exists. I am not contesting. |
| Scheduler with activation off | **Closed.** | `runtimeBlocksAutomaticWork` now blocks an unresolved worktree only when some restriction carries a worktree. Global uncertainty still blocks everything. Both new tests are correct. |
| Interrupt dropped after cancellation | **Closed.** | `sendControlRequest` exempts the `interrupt` subtype, and the contrast test shows other cancelled control requests still write nothing. |
| `spawnedPIDs` note | **Accepted.** | The comment correctly explains why the entry is kept for a late confirmed report. |

## New findings (P2/P3: listed, not looped on)

### P2

**R2-A: some Claude replacements still don't keep their cleanup for the successor to join (P1-3 residual, gated by activation)**
- **Scenario.** With registration on, the user resets the conversation and sends right away, or an MCP-driven reset is immediately followed by a send.
  1. `prepareForConversationResetSync` detaches the controller and runs `Task { await cancelClaudeRun(session, oldController: detached) }`. That task is not kept for joining.
  2. A new Claude controller reserves for the same `sessionID`.
  3. Meanwhile the old record is still in `activeLaunches`, or in its post-reap discovery pass.
  4. `writerConflict` → `overlapsSession` refuses the new reservation with `.ownershipConflict`.
- **Impact.** The run fails visibly. Retrying once the old shutdown finishes works, and production activation is off.
- **Evidence.** `ClaudeAgentModeCoordinator.prepareForConversationResetSync` (unchanged) versus the new kept branch in `handleProviderIdentityTransitionSync`.
- **Smallest fix.** Write one helper that keeps `cancelClaudeRun` as a retained retirement whenever `detached.controller.joinsRetirementBeforeSuccessor`. Use it at every place that calls `Task { await cancelClaudeRun(...) }`. This also removes the duplicated branch.

**R2-B: discovery doesn't treat a different boot as proof that a process can't be in the family (R-1 residual)**
- **Scenario.**
  1. The machine reboots while a record is live.
  2. On next launch, the root and members resolve as `.gone` because the boot session differs.
  3. Any same-UID, non-zombie process with an unreadable or malformed environment still sets `decisive = false`. The reason is that `predatesFamily` returns `false` when `observation.bootSessionID != root.bootSessionID`.
  4. The record stays `unknown`. Stop also refuses it because `isComplete` is false.
- **Impact.** Same-conversation Resume and the worktree stay blocked until that unrelated process exits. The confirmed new-conversation handoff still works.
- **Evidence.** `AgentProcessRegistry.predatesFamily`, the `guard observation.identity.bootSessionID == root.bootSessionID else { return false }` line.
- **Smallest fix.** Return `true` in that branch. A process from another boot can't be in the family, and R6 says a changed boot session proves the process is gone. Add a one-row test.

**R2-C: Stop's zombie exemption doesn't cover family members (Stop is off in production)**
- **Scenario.**
  1. After SIGTERM, a member (for example a tool) exits.
  2. Its still-live parent, another member that ignores TERM, hasn't collected it yet, so the tool is a zombie.
  3. In the SIGKILL pass, the "every expected member gone or unchanged" loop finds that zombie with no readable group and returns `.changed`.
  4. Escalation never happens, and the stuck parent survives.
- **Impact.** Stop doesn't escalate in exactly the case SIGKILL exists for. Even when everything exits, the final check keeps a zombie in `aliveIdentities` and reports `.unresolved`.
- **Evidence.** In `stop(preview:)`, the expected-member loop (`guard case let .available(observedGroup) … else { return .changed }`) and the final `family.aliveIdentities.isEmpty`.
- **Smallest fix.** Treat a zombie member as gone in Stop's membership checks and in its final verification. Add a test where a member turns into a zombie between TERM and KILL.

**R2-D: no tests for joining a kept Claude retirement, or for Claude/ACP → Codex**
- **What is tested.** Only Codex → Claude has a joined/unjoined contrast test.
- **Risk 1.** The kept `cancelClaudeRun` now always finishes before the successor rechecks that it is still current. If that cleanup changes session-level state (`runState`, `runID`, run attempt) instead of only touching the detached run, the successor would cancel itself as superseded on every switch away from Claude. If the cleanup waits on anything the successor holds, the two deadlock.
- **Risk 2.** The Codex join only runs when the `controller` argument of `startCodexNativeSession` is non-nil.
- **Fix.** Add one test row each for Claude → Codex and Claude → Claude-compatible variant. Confirm that a non-nil controller is passed on the fresh path after a provider switch.

### P3
- **Joins have no timeout.** `joinRuntimeRetirements` waits with no bound, so a cleanup that hangs blocks every later registered start on that tab. This is acceptable only if every retained cleanup is bounded. Check this for ACP `cancelPrompt()`, or document it.
- **Lines flushed at EOF aren't associated.** `handleStdoutEOF` runs the remaining lines through `handleLine` but never calls `associateObservedConversationIfNeeded`. A session ID first reported in that last unterminated line never reaches the record. Call it before `runtimeLaunch` is cleared.

## Recommendations
1. Nothing needs another round. Record R2-A through R2-D and the two P3s as deferred on the step's status line.
2. Before coupled activation or live acceptance, fix **R2-A** (keep every Claude cleanup through one helper) and **R2-B** (one-line boot check). Both are small, and they otherwise show up as refusals or blocks visible to the user once registration is on.
3. Fix **R2-C** before production Stop is enabled.
4. Add the **R2-D** test rows when Phase 3 next touches the coordinators.
5. Keep production qualification empty, and keep Stop, marker injection and fresh session IDs off. Nothing here was qualified live; the evidence is fake OS state and pipe fixtures only.

**Final verdict: CLOSED.** P1-1, P1-2, P1-3 (provider switch), R-1, the R-2 no-issue disposition and both cheap fixes are verified, and nothing from this lane goes to the owner.
