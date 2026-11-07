# Claude delegated-session reliability plan

Scope: read when the task touches delegated/MCP-originated Claude runtime retention, completed-session release, admission-pressure reconnects, or standalone CLI bootstrap diagnosis.
Authority: Authoritative
Last-verified: 2026-11-06
Status: item 1 implemented and owner-approved after independent OracleA and OracleB approval; bounded live idle-release/follow-up/user-control acceptance passed on `b0580cb8` (§1 status line). Items 2–3 remain design only. Item 4 has CLI phase diagnostics and a read-only admission audit (2026-11-07); the owner-approved 20-process quiet-host live check passed. App-side decoupling and load qualification remain deferred.

## 0. Decisions, boundaries and implementation order

Correctness disposition is closed: two RepoPrompt defects were fixed by `f8c2ae62` and `ae2ca61f`; the remaining audited Sonnet answer/patch failures are model-side under byte-correct delivery. Historical MCP startup failures remain reliability failures, not wrong answers. Do not reopen the Sonnet investigation here.

Implement in this order, because a clean measurement environment first needs bounded resource demand, then explicit release, then stable admission:
1. A 300-second idle shutdown for delegated/MCP-originated Claude sessions only.
2. Runtime release for completed `agent_manage.stop_session` targets, and release-before-delete ordering for cleanup.
3. Option A: intentional retirement of server-proven completed-owned idle admission victims, rather than a reconnectable socket close.
4. Recheck standalone CLI bootstrap after items 1–3; defer timeout/retry policy changes unless the problem persists.

Owner authorization (2026-11-06): finish and commit item 1, merge `dev/v1.0.29-remote-client-models` (including `b7baf605` and `09d8d43b`), and prepare a clean, signed daily debug bundle without launching it. The owner subsequently reported relaunching that bundle and approved a bounded live item-1 smoke check: delegated idle shutdown, one follow-up, and user-created control tabs. That check is complete; further model attempts, relaunch, push, cap mutation and process cleanup are not authorized by this record. Savings, cost-gate and promotion remain deferred. Future measurement is governed by [code-mode plan §13](2026-10-03-code-mode-readiness-and-git-narrowing-plan.md#13-future-re-measurement-protocol-not-authorized-to-run).

Source references below were checked in the worktree at `9f78a54b` (code unchanged from `e24e593c`); line numbers supersede the older handoff's offsets. File aliases expand to these repository-relative paths:

| Alias | File |
|---|---|
| C | `Sources/RepoPromptAgentCore/AgentMode/Runtime/Claude/ClaudeAgentModeCoordinator.swift` |
| X | `Sources/RepoPromptAgentCore/AgentMode/Runtime/Codex/CodexAgentModeCoordinator.swift` |
| R | `Sources/RepoPromptAgentCore/AgentMode/Runtime/Runners/ClaudeIntegratedAgentModeRunner.swift` |
| V | `Sources/RepoPrompt/Features/AgentMode/ViewModels/AgentModeViewModel.swift` |
| S | `Sources/RepoPromptAgentCore/AgentMode/Runtime/Session/AgentTabSession.swift` |
| A | `Sources/RepoPrompt/Infrastructure/MCP/Agent/AgentManageMCPToolService.swift` |
| M | `Sources/RepoPrompt/Infrastructure/MCP/MCPConnectionManager.swift` |
| B | `Sources/RepoPrompt/Infrastructure/MCP/BootstrapSocketConnectionManager.swift` |
| H | `Packages/RepoPromptCore/Sources/RepoPromptMCPCore/RepoPromptMCPCore.swift` |
| I | `Packages/RepoPromptCore/Sources/RepoPromptMCPCore/Interactive/InteractiveMCPClientSession.swift` |

## 1. Delegated Claude idle shutdown — first implementation

Step 1 — done | rounds 2/2 | open: none; owner-approved implementation | downgraded: none | assumed: none | deferred: broader live cancellation/race and resource-pressure coverage; OracleB P2-7 (tested handoff overload); N2/N3 (unproven caller/rare fresh-ID ordering), N4 (retirement-stop diagnostics), N5 (fixture fidelity), N6/R2-4 (single runner/probe invariant); two documented pre-existing lifecycle failures. Evidence: `evidence/2026-11-06-claude-delegated-session-reliability/validation.txt`, `oracle-a-round2.txt`, `oracle-b-round2.txt`, and `live-idle-b0580cb8-20261106.txt` in that directory.

### Current behavior and authority

- R:479–488 returns `shouldShutdownSession: false` for completed, cancelled and failed turns, retaining the controller. This is not evidence that the run is still active.
- X:467 sets the Codex idle default to 300 seconds; X:9694–9746 schedules, cancels and rechecks an idle controller before shutdown. Mirror the bounded-timer pattern, not its broader provider eligibility.
- C:3107–3151 is the existing `shutdownClaudeSession(_:clearTabScopedCoordinatorState:detachedRunID:)` release primitive. It waits for resume transfer, detaches/retires the exact controller, captures provider identity, clears run state and releases tool tracking. Reuse it; do not kill arbitrary PIDs.
- Existing view-model callers are V:4102 (window-close/app-quit teardown), V:8682 (worktree transition), V:14239 (archive/stash path), V:23184–23188 (detached deletion finalization), and V:23269 (live deletion). Keep their ownership semantics.
- S:290–296 derives MCP provenance from `origin`; S:1769 carries parent lineage. Eligibility must use authoritative provenance, not a title, tool-supplied flag, or parent ID alone. A user-owned tab stays excluded even if it has conversation lineage. Existing `isMCPOriginated` semantics include the eligible remote-origin category; do not silently broaden beyond that authority.
- S:185–245 supplies question state and aggregate notification. `hasPendingQuestionUI` does not include approvals, permissions or edit reviews; checking that property alone is insufficient. S:223–232 also carries queued interactions and creation/resolution reservations; S:279–288 carries pending MCP follow-up/dispatch.

### Proposed contract

1. Schedule one cancellable, generation-fenced 300-second timer after an eligible Claude run has published its terminal state and finished terminal persistence/accounting. Require an owned retained controller and actual quiescence, not just an observed result event. Do not change the runner to unconditional immediate shutdown.
2. Cancel/invalidate before accepting a new turn or steer, before queued follow-up dispatch, and whenever a question/approval/permission/edit review is pending, queued, being created or being resolved. Cancel on provider/location change, reset, deletion, workspace detach and coordinator teardown. Superseding completions, pending handoff delivery, active tool work and undrained background output also prevent retirement. Once these settle, start a fresh full interval from quiescence, not the original deadline.
3. At expiry revalidate the exact session object, durable session ID, controller identity, run/attempt and timer generation, provenance, terminal state and all interaction/work fences. A later owner, resumed run or replacement controller must survive. Recheck across awaited retirement boundaries; a cancelled old timer must not remove a successor timer's slot.
4. Call the existing shutdown primitive and preserve transcript, usage, persisted session, worktree binding, owner lineage and pending payload/delivery IDs. This releases runtime resources; it does not archive/delete the session or convert a completed answer to failure. Record bounded lifecycle diagnostics (scheduled, cancelled, released or stale; reason/generation, no prompts/secrets).
5. On a later follow-up, start a fresh runtime/conversation and carry the established transcript through the existing handoff machinery. Intentional idle retirement must use truthful idle-continuation wording, not “native resume failed.” Keep the prior provider identity for history/provenance, but do not accidentally select it as the launch resume target for this intentional fresh-start case. Use the smallest explicit idle-retirement state needed to select that path; preserve existing pending payloads and their delivery identifiers.
6. This differs from today's ordinary start path: C:1498–1535 passes the saved provider ID to `startOrResume`; genuine failed-resume fallback starts fresh at C:1665–1673 and stages a guarded handoff at C:1697–1724. Reuse that handoff construction/ownership contract without manufacturing a resume failure. V:19118–19180 protects existing payloads, creates delivery IDs and rechecks ownership after suspension. Fresh sessions must still receive no bogus recovery wrapper; genuine recovery behavior remains unchanged.
7. User-owned tabs keep existing runtime retention, background output and resume behavior. Do not cancel unrelated agents, scan/kill all Claude processes, or treat “no tool in flight” as proof of terminality.

### Acceptance and validation

- Deterministic fake-clock/controller tests: eligible terminal session releases exactly once at 300 seconds, not earlier; user-owned and active sessions never release; completion with superseding work does not arm.
- Exercise every cancellation/rearm edge: new turn, steer, pending/queued question, approval/review, handoff delivery and background work. Cover expiry racing with a replacement session/controller, delayed shutdown, tab reuse, workspace detach, and an old timer's cleanup after a new timer is installed.
- Verify shutdown uses the existing retirement path, preserves history/usage/binding and does not mark the answer failed. Test follow-up fresh launch plus exactly one truthful handoff, preserved pending payload/delivery ID, and unchanged genuine-resume/fresh-worktree regressions.
- Add focused coverage in the existing Claude coordinator/runtime and lifecycle test areas; use injected time and controllable suspension gates, not real 300-second sleeps. Run coordinated `make dev-test FILTER=<new-suite>`, the affected coordinator recovery/lifecycle suites, `AgentPendingHandoffStageOutcomeTests`, and `AgentRunWorktreeStartTests`; run `make dev-lint`. Never update the frozen XCTest ledger or weaken existing failures.
- Obtain independent concurrency/ownership review before declaring implementation complete. A live app is required to prove actual provider/helper processes and sockets exit, retained-resource counts stabilize, a later follow-up works, and a user-owned tab remains unaffected. Mocked shutdown calls alone do not establish process release; no live acceptance is claimed here.

### Implementation status (item 1, 2026-11-06)

Implemented in `8728a2c9` and integrated in `b0580cb8`. Owner-approved bounded live acceptance passed on the clean signed `b0580cb8` daily bundle: two idle releases, one fresh-conversation follow-up with truthful handoff, and two unchanged user-owned controls. This is not live race or resource-pressure qualification. The C/R/V/S line references above predate this change; C owns the `Delegated idle runtime release` section. Validation and review narrative lives in the local evidence directory (`docs/context/plans/evidence/2026-11-06-claude-delegated-session-reliability/`), not here.

**Arming.** `scheduleIdleRuntimeReleaseIfEligible(for:reason:committedAttemptID:)` is the single entry point.
- It requires all of the following:
  - an `isMCPOriginated` session that is the live `viewModel.sessions[tabID]` object;
  - a Claude session with a non-empty `providerSessionID`;
  - an owned controller with no active run, attempt or retiring release;
  - the committed attempt's `lastTerminalCommitRevision`, with `lastTerminalPublicationResult == .accepted` and `runState == revision.terminalState`.
- It validates before it cancels: a request that cannot arm, such as a late call for a superseded attempt or an unaccepted publication, leaves an armed successor interval untouched.
- It is called from these places:
  - R's run-task `defer`;
  - between-run background output;
  - between-run `runtimeInit`, after the new conversation ID is persisted;
  - S's `onClaudeTerminalPublicationAccepted`, fired on the transition to `.accepted`, so a barrier retry that later accepts arms the release. It is skipped only while the accepted commit's own run task is alive (that task's run end arms it). Another live runner, such as a superseded attempt still publishing, never suppresses it; the expiry-time runner fence keeps the runtime until that runner returns;
  - `rearmIdleRuntimeReleases`, called from `setAgentModeActive(true)` for unarmed delegated tabs, because `coordinator.stop()` cancelled them.
- User-owned tabs never arm.
- `session.isDirty` defers release as `persistence-pending`; the production clean-save receipt clears it.
- The delay is 300 s (`delegatedIdleRuntimeReleaseDelayNanos`).

**Owner and activity.**
- The timer captures `IdleRuntimeReleaseOwner`:
  - the session object, durable binding and `bindingTransitionGeneration`;
  - the controller and `runAttemptGeneration`;
  - the runID and terminal commit;
  - origin, provider, conversation ID and worktree bindings.
- Any mismatch ends the timer as `stale:<reason>`.
- Blocker fields in S fire `onClaudeIdleActivity` synchronously from `didSet`. This covers every field in `hasBindingBlockingInteraction`, plus reservations, follow-up and dispatch, steering, superseding turns, terminal commit, `worktreeBindingTransitionInProgress`, location transitions and the pending handoff.
- `bindingTransitionInProgress` is not a notifier: it is sampled at expiry, and the owner's `bindingTransitionGeneration` makes any completed rebinding stale.
- R's router `onInboxChanged` reports only a held between-run approval request and a dropped approval/cancellation pair. Delivered output re-arms through the between-run handler, and undelivered output is fenced at expiry.
- Any such activity cancels the armed interval and re-arms a fresh full interval or goes stale. A blocker that settles before the original deadline therefore never lets that deadline release.
- Armed (cancellable) and retiring (joined, never cancelled) slots are separate. Every removal is generation-matched.

**Expiry.**
- The coordinator's own fences are sampled at expiry. These include runtime preparation, dispatch reservations, MCP tools or child waits, the runner fence, controller preparation, resume transfer, retirement, fallback or recovery, and a pending interrupt.
- The provider's `hasTurnInFlight` is always awaited before any restart or release. While it is busy, the timer records `deferred` once and probes every 5 s.
- Only an observed `false` together with a clean recheck starts a fresh full interval (`rearmed:<reason>`) or releases.

**Release (idle path of `performClaudeSessionShutdown`).**
- Before any marker, provider-ID or save mutation, it requires the full owner check (`.releasable`) and an unchanged activity generation, with no intervening await.
- It sets the fresh-start marker, then detaches and retires the exact controller.
- Capturing the provider session ID is gated by `mayCaptureProviderSessionID`. That gate rechecks the exact owner (`idleRetirementOwnerLoss`: owner, liveness, successor run/attempt/preparation/dispatch) and that the conversation ID is unchanged.
- An owner lost after the await returns without touching the successor. The marker is cleared only for its own released ID on rebinding or replacement.
- Tool tracking is released only through the detached controller. Tab-keyed tracker slots are never cleared on the idle path.
- Explicit `shutdownClaudeSession` callers keep their existing semantics.
- Transcript, usage, bindings, lineage and the completed result are preserved.

**Follow-up.**
- The memory-only `claudeIdleReleasedConversationID` is consumed only for exactly that conversation, on a still-`isMCPOriginated` session, and starts fresh with a nil resume target.
- The guarded V handoff (`RecoveryHandoffReason.idleRuntimeRelease`, "Nothing failed") is staged, and real host stage consumption (`recordPendingHandoffStageOutcome`) clears it after one send.
- An existing payload keeps its payload and delivery IDs.
- These still resume: a delivery hold, pending MCP recovery, a suppressed fallback, and any start after an app relaunch.

**Diagnostics.** The `ClaudeIdleRuntime` log category records `scheduled`, `not-armed`, `cancelled`, `deferred`, `rearmed`, `released`, `stale` and `fresh-start`, each with a reason, tab and generation prefix. No prompts or secrets are logged. Per-event background-output re-arms and `not-armed` records log at debug level; bounded interaction activity and other lifecycle events log at info.

**Tests.** `Tests/RepoPromptTests/AgentMode/ClaudeCompatible/ClaudeDelegatedIdleRuntimeReleaseTests.swift` contains the `AgentModeRunServiceLifecycleTests.testClaudeDelegatedIdle*` tests. They use a fake controller, manual clock and host-consumed handoff staging.

**Remaining gaps.**
- Live evidence covers two ordinary idle intervals and one follow-up only. Owned wrapper/Claude/helper processes and helper connections exited; user-owned Haiku and Sonnet controls remained retained. Cancellation/stale-owner races and preservation of an already-pending payload/delivery ID remain deterministic-test evidence, not live coverage. Longer-run/global resource stabilization is unqualified on the shared host.
- The superseded-attempt late request is exercised directly. The A5 overlap is exercised through a gated real terminal publication and the barrier's real duplicate-commit retry.
- The at-expiry matrix omits `pendingAskUser`, `pendingWorktreeMergeReview` and composer submission; these rely on the shared predicate.
- A permanently dirty session is never released.
- A delivery hold resumes rather than starting fresh.
- Coordinator-owned fences are sampled rather than notified.

## 2. Explicit completed-session release and cleanup ordering

**Evidence:** A:947–993 resolves and authorizes a live target, but only calls cancellation when `runState.isActive` (A:974–978). A completed target returns `stop_requested=false` without releasing its runtime. This is the confirmed no-op.

**Smallest change:** retain delegated-control authorization and active-run cancellation semantics. For a completed eligible target, await an idempotent VM/coordinator runtime release using item 1's ownership fences, without deleting transcript or changing the completed result. For an active target, let terminal settlement finish before release and protect a newly started successor. Preserve the meaning of `stop_requested` (whether cancellation was requested); report runtime release separately rather than falsely claiming cancellation. Repeated stop on an already-released target is successful and non-destructive. Do not broaden automatic idle policy to user tabs.

**Cleanup distinction:** cleanup is already provenance-scoped and skips effectively active targets (A:1042–1062,1124–1143). Open targets go through `deleteSession` before persisted deletion (A:1161–1174); V:23245–23281 already awaits Claude shutdown before deleting persisted state. Detached owners are released at V:23167–23194 during finalization, but A:1187–1205 can delete persisted data before that finalization. Require release/detach-and-await before durable deletion for any remaining live owner, with the existing exact-owner protection; do not add a second shutdown to the already-correct open path. Persisted-only sessions with no owned runtime need no synthetic controller. If release is unresolved or a target becomes active, report skipped/pending and preserve recoverable state rather than claim deletion completed.

**Validation:** completed retained/released target, repeated stop, active cancellation, successor racing with release, unauthorized scope, user-origin cleanup exclusion, open and detached cleanup ordering, shutdown failure and persisted-only deletion. Use existing AgentManage and deleted-session ownership test seams with fake controllers; live acceptance must verify actual runtime release and history retention for stop, and no leaked helper after explicitly authorized deletion. Cleanup remains destructive and needs explicit action authorization when exercised live.

## 3. Admission eviction/reconnect loop — option A

### Mechanism and smallest correction

The local pressure investigation recorded 130 owned evictions across 50 unchanged helper identities, with repeated connection UUIDs and 62–85 second recurrence; this is archived evidence, not a new live observation. Source still explains the mechanism:

- M:18779–18805 commits a per-client victim removal with a diagnostic reason, then requests ordinary removal rather than typed retirement. Global admission paths must receive the same policy audit, not just the per-client branch.
- B:296–305 stops/disconnects without notification; B:308–319 explicitly sends termination before disconnect.
- H:504–550 retries generic server-close/reset failures but does not retry the top-level `terminatedByServer` disposition. Do not confuse that terminal wrapper with an unclassified nested socket error.
- M:7592–7593 and17832–17833 create new per-connection stats. M:18636–18667 grants viable never-called connections 60 seconds of fresh startup priority. The same retained helper can reconnect, regain grace and displace another used idle helper. Ordinary backoff/ranking tweaks alone do not remove excess retained demand.
- M:8251–8275 distinguishes `idleTimeout` soft semantics from dashboard boot's client-wide kill/cooldown. M:8429 uses the typed termination call. Preserve the no-client-wide-cooldown intent.

Implement option A only for a **server-proven completed-owned, idle** victim: intentionally retire its exact transport/runtime through existing typed termination, using idle-timeout semantics where sufficient. Reuse item 1's terminal/provenance proof and existing connection identity, lifecycle generation, active-call/scope, replacement-credit and capacity rechecks. A running model between tools is not eligible; do not blindly replace every eviction's stop with terminate. Unknown/external/active ownership must not acquire a new destructive retirement policy.

Typed notification is best effort and may require a completed handshake. Prove the selected helper stops retrying and its host does not immediately respawn it. If that cannot be guaranteed, hold this item incomplete and design only the narrow server-owned capacity-park/demand-driven reacquisition disposition needed; do not pretend plain EOF or a larger cap fixes it. Keep no-replay/ambiguous-work ledger protections. No caller-supplied PID, “idle” bit or prompt text authorizes retirement.

### Validation and operations

Deterministic tests must cover typed terminal versus transient closure, active-between-tools exclusion, pending work/credit protection, stale identities/generations, admission races, failed notification, and multiple idle contenders under both caps without cyclic readmission. Use MCP admission tests and core proxy/ledger tests through coordinated `make dev-test` / `make dev-core-test`; build app/helper products if their seam changes. Live validation is still required for helper/host termination or respawn, pending startup behavior and stable connection counts under real pressure.

The campaign temporarily used **200 per client / 200 global**. Before the owner-authorized b0580cb8 pilot on 2026-11-06, the owner restored the default configuration: preflight found both persisted override keys absent, resolving to source defaults **64 / 128** (M:2743–2757), with ample observed headroom. Existing diagnostics do not expose effective in-memory caps, so this is preference-plus-source verification, not direct runtime-cap proof. The pilot made no cap change or process cleanup. Preserve this distinction in later preflights; never lower caps blindly while retained demand remains.

## 4. Standalone CLI bootstrap timeouts — phase diagnostics implemented; quiet-host check passed

Pre-change source baseline (the I line offsets below predate item 4's diagnostics):
- `Packages/RepoPromptCore/Sources/RepoPromptShared/MCP/MCPBootstrapMessages.swift:26–28`: 5-second initial response/write budgets.
- I:496–504: separate 10-second MCP initialization budget; I:565–568 maps its timeout to the same `bootstrapResponseTimeout` error.
- `Packages/RepoPromptCore/Sources/RepoPromptMCPCore/Interactive/InteractiveMCPService.swift:52–58` connects once; the `-c` interactive single-shot path has no outer startup retry.
- The sidecar documents existing exec-mode bounded connect-wait and reuse of an accepted interactive connection. Neither proves a failing fresh bootstrap is healthy, nor does tool timeout extend startup budgets.

**Pilot recurrence (2026-11-06):** the owner-authorized b0580cb8 Q/T pilot stopped under its frozen two-event rule after two fresh standalone diagnostic CLI startup timeouts, before attempt 163 and after attempt 172. All 172 paid rows remained correct and usage-complete; these were control-path startup failures, not failed model answers. Prior-batch delegated Claude drain checks had passed; the first-event inspection found ample headroom, and no eviction loop was observed. The second timeout prevented a successful final connection inspection. Exact events and scope are recorded in the [code-mode plan §13](2026-10-03-code-mode-readiness-and-git-narrowing-plan.md#13-re-measurement-protocol--bounded-pilot-stopped-full-gate-not-authorized) and its local pilot evidence. Idle release did not prevent two further timeouts; whether they share a cause is unknown. The pilot's generic errors cannot retrospectively identify their phase or cause.

The owner-supplied [stall export](evidence/2026-10-03-code-mode-readiness-and-git-narrowing/pilot-b0580cb8-2026-11-06/main-thread-stall-export.txt) records event 1 at 20:59:44.976 local (13:59:44.976Z), its estimated 20:59:39.9–20:59:44.9 bootstrap-response window alongside the 20:59:40.1–20:59:47.3 main-thread stall, and event 2 at 21:33:39.678 with its 21:33:34.7–21:33:39.7 window overlapping stalls at 21:33:33.0–21:33:37.0 and 21:33:39.0–21:33:42.9 from the controller's own 2,925-activity turn (O(final-turn) transcript re-derivation, investigated separately); this temporal correlation remains a hypothesis, not causal attribution. The 2026-11-07 audit below confirms awaited main-actor work, primarily in MCP initialize; it does not identify which phase failed in the pilot. These are estimated five-second windows, not measured phase starts (event 1's estimated window starts slightly before the 20:59:40.092 stall).

**Disposition:** timeout increases and retry-policy changes remain deferred. Only CLI-side attribution/cleanup and tests are implemented here. The owner subsequently approved the bounded live check below and performed the rebuild/relaunch themselves. No app-side decoupling, cap change, process cleanup, further relaunch or additional live check is authorized by that acceptance. Never automatically replay a tool mutation or an ambiguous request, and do not infer a necessary relaunch from a startup timeout.

### CLI diagnostic contract (2026-11-07)

`InteractiveMCPClientSession.startupTimings` records at most four payload-free observations per attempt: `connect`, `bootstrap_write`, `bootstrap_response`, and `mcp_initialize`. Each reports `outcome` (`completed`, `timed_out`, `cancelled`, or `failed`), UTC `started_at_utc`, monotonic `elapsed_s`, `budget_s`, and `budget_kind`. A timeout/cancellation phase ends at its settlement timestamp, before cancellation drainage; UTC start plus monotonic duration anchors the interval for log correlation (subject to wall-clock adjustment). Connect retains its OS-controlled blocking semantics and reports `budget_s=none`; no connect deadline was invented. Bootstrap write retains its **5 s inactivity** budget, response its **5 s deadline**, and initialize its **10 s deadline**. Response deadline accounting now uses the same monotonic clock as the observations.

Both CLI services print timings on startup failure and on successful verbose startup, to stderr only. The `bootstrapResponseTimeout` case, its description, the “RepoPrompt did not respond to the bootstrap handshake” prefix and exit-code-1 path are unchanged. Write/connect errors retain their existing cases. Cancellation remains cancellation, not timeout. Initial tool-catalog fetch and post-connect dispatch are outside these four phases. Existing exec connect-wait policy is unchanged; no retry was added.

Socket-backed tests exposed an existing initialize cancellation hole: cancelling the SDK connect task alone does not drain its pending response continuation. The timeout/caller-cancellation winner now also disconnects that attempt's transport and drains its owned cancellation task before returning through normal client cleanup. This closes only the CLI's own failed attempt, not any app/provider process or unrelated connection. The timeout budget is unchanged.

### Read-only app admission audit

All app source offsets below were checked at `4b61024b`; no app source was edited. M means `Sources/RepoPrompt/Infrastructure/MCP/MCPConnectionManager.swift`; BS means `BootstrapSocketServer.swift`, BC means `BootstrapSocketConnectionManager.swift`, SC means `ServerController.swift`, and MS means `MCPService.swift`, all in that same directory.

| Path / await boundary | Isolation and phase consequence |
| --- | --- |
| BS:784–975 `handleNewConnection` → BS:983–1022 request read | BootstrapSocketServer actor; blocking read is dispatched to `handshakeIOQueue`, not MainActor. Handler awaits M:6812–7028. Accepted-response write at BS:1085 onward is socket I/O on the server actor; **accepted is sent before** postAccept at BS:970. Abort callbacks reach reservation rollback, not UI approval. |
| M:6900 policy readiness → M:9582–9644 | Actor-local name/PID/policy checks; the only production suspension in the 2 s loop is 50 ms sleep. Synchronous predicate M:9553–9580 reads actor-owned policies/affinity and bounded process ancestry (M:9724 onward), not MainActor. Ordinary RepoPrompt CLI identity is not an agent-provider identity (M:4732–4741), so this gate is not required. |
| M:6944 capacity → M:7028–7073 → M:18810–19065 eviction | With headroom this stays actor-local. Under pressure, awaits limiter actors and connection viability/activity (M:18465–18629; BC:347–353), then exact-victim removal. Removal **does await MainActor**: cancellation scan M:3153–3182 and tab cleanup M:8822–8893, called at M:9051–9067; Claude mapping cleanup M:8901–8914 is conditional. Thus pressure can put main-actor cleanup inside the **bootstrap-response** phase. This branch is not evidence of pilot pressure. |
| M:7142–7345 commit; M:7510–7634 prepare/register/start | Normal publication has no suspension; preparation deliberately avoids global settings. Failed/stale branches await BC.stop through M:7434–7449 or rollback M:2678–2695; BC:296–306 stops the SDK server and transport, not MainActor. Replacement cleanup M:7383–7432 is a separate task, as are dashboard notification (SC:114–120) and window-count capture (M:7624); they are not awaited admission barriers. |
| BC:182–196 registerHandlers → M:15144–15153 | **Unconditional MainActor hop** to read `mcpStructuredResultsMode`, before `server.start`. The remaining registration awaits install SDK method closures; main-actor work inside tool/resource handler bodies is invoked later, not during registration. This hop delays **MCP initialize**, after bootstrap accepted. |
| BC:187–196 initialize hook → M:7742–7945 approval | The SDK awaits this hook before returning Initialize.Result (local patched swift-sdk `Sources/MCP/Server/Server.swift:1325–1356`). SC:137–220 first awaits slot reservation M:17686–17830 (pressure prune/eviction uses the removal path above), then identity/allow-list approval. Bundled-CLI verification SC:354–374 awaits peer PID and checks the executable path; no UI hop there. But successful auto-approval with the attached MCPService awaits MS:160–166 `clientConnectedSuccessfully`, whose error-banner clearing **awaits MainActor**. A non-auto-approved client legitimately waits for user approval; this must not be bypassed. |
| M:7862–7920 policy admission/application | The 2 s policy loop (M:9645–9720) sleeps and reads actor state. Pending-policy installation additionally awaits main-actor tab/run mapping (M:14924–14978, M:4326), commit checks M:14532 and rollback M:14699, routing-record updates M:17899–17938, and SDK tool-list notification. Companion attachment M:3959–3977 can await stale-companion removal M:3776–3805. These authorization/ownership branches cannot safely be detached wholesale. |
| M:14293 fallback → M:14011–14045 → M:17978–18059 | Even a fresh ordinary CLI with no matching route reaches `preferredWindowID`, which calls `pruneRoutingRecords` **before** checking for candidates. Its M:17860 MainActor window snapshot is unconditional. Existing-affinity branches also await run/tab mapping and routing persistence. This is a third ordinary-path **initialize** dependency. |
| M:6215–6245 waiter notification; M:7915–7932 catalog preparation | Waiter notification is synchronous. Window binding, catalog readiness and cache warming run in an unawaited task after policy admission, so they are not initialize response barriers. The interactive CLI's later tools/list can still wait on MainActor; that is post-initialize work, not one of these startup timeouts. |

**Finding and smallest proposed decoupling — not implemented; owner approval required.** First remove the three incidental ordinary-CLI initialize dependencies: (1) publish the structured-results setting into a synchronized non-main snapshot at settings load/change, retaining one immutable value per admitted connection; (2) enqueue cosmetic connection-error clearing rather than await it on the approval result; (3) return no routing candidate from actor-owned data before requesting a live window snapshot, and move unrelated record pruning out of the fresh-token critical path. Preserve current-setting semantics, approval decisions, real candidate validation, generation fences and all agent policy/run ownership checks. Capacity teardown needs separate ownership review and is not an excuse to implement items 2–3 here. None of these source findings proves the pilot's two failures were initialize timeouts or caused by the recorded stalls.

### Bounded live check — owner-approved and passed (2026-11-07)

The owner approved **at most 20 sequential fresh** processes, with no model calls, parallel clients, connect-wait option or retry, stopping at the first failure/unexpected approval or after five minutes. Corrected command: `rpce-cli-debug --verbose -c __repoprompt_debug_diagnostics -j '{"op":"connections"}'`; `connections` is a diagnostics operation, not a standalone tool name. The separately proposed 30 s per-invocation ceiling was not used. The five-minute harness bound did not fire.

The first preflight stopped before any probes because the running bundle still contained `4b61024b`. After the owner rebuilt/relaunched again, `/usr/local/bin/rpce-cli-debug` resolved to `/Applications/RepoPrompt CE Dev.app/Contents/MacOS/repoprompt-mcp`, paired with app PID 19190. Bundle provenance reports `4a83f4dd`, `debug-optimized-incremental`, **dirty=true**, built at 15:49:03 local; process start was 15:49:08, strictly after executable mtime/ctime and build time. Before/after PID/start time, executable stat/hash, helper hash and provenance were identical. The lane is bundle-provenance evidence, not an extra runtime `ping` (none was run).

**Results:** 20/20 exit-zero successful `connections` results from 20 distinct CLI PIDs, with 80 completed phase records and unchanged budgets, during **15:51:41.220–15:52:43.311 local (08:51:41.220–08:52:43.311Z)**. Connection snapshots consistently contained four connections and zero active tool scopes. This is a short operationally quiet capture, not a controlled CPU-load qualification.

| Phase | Median | p95 | Maximum |
| --- | --- | --- | --- |
| Connect | 0.000 s reported | 0.000 s reported | 0.000 s reported |
| Bootstrap write | 0.000 s reported | 0.000 s reported | 0.000 s reported |
| Bootstrap response | 0.000 s reported | 0.000 s reported | 0.000 s reported |
| MCP initialize | 2 ms | 14 ms | 14 ms |

The three-decimal zero readings mean below the diagnostic rounding resolution, not literally zero duration. Whole-process wall time was median 133 ms, maximum 134 ms. The successful unified-log export for 15:51:40–15:52:44, using `subsystem == "com.repoprompt.app" AND category == "main-thread-stall"`, returned **zero records**; there were no recorded stalls to correlate with phase intervals. No model dispatch, app lifecycle action, process cleanup, cap mutation, retry or automatic replay occurred during the check.

Raw local evidence remains untracked under `docs/context/plans/evidence/2026-11-07-cli-bootstrap-live/20261107T085141Z/`: per-attempt stdout/stderr and timestamps/PIDs, phase timings, before/after identity, log export, and `summary.json`. Do not stage it. This passes only the approved quiet-host check on the dirty optimized-incremental bundle. It neither qualifies load behavior nor retrospectively attributes the pilot, and it does not authorize the proposed app-side decoupling.

**Validation:** socketpair-backed delayed bootstrap response and delayed initialize, cancellation in both waiting phases, descriptor cleanup, and successful post-connect tool dispatch are covered in `InteractiveMCPClientSessionConnectTimeoutTests`; the existing initialization settlement tests remain. Final `make dev-core-test` passed all 76 tests (7 startup tests), ticket `a1123326-6e26-42aa-b23e-667b0841ef72`. Two further focused `make dev-core-test FILTER=InteractiveMCPClientSessionConnectTimeoutTests` runs passed 7/7 each (`66fab618`, `92651f44`). `make dev-lint` passed (`32d571a3`); `make dev-swift-build PRODUCT=repoprompt-mcp` passed (`e47e4f71`). The first run hit the 180 s XCTest watchdog on real initialize cancellation; after fixing cancellation drainage, the next run exposed a descriptor-number reuse issue in the test oracle, corrected by allocating the observed socket above incidental low-FD allocations and awaiting deferred closure with a bounded yield loop. Neither failure was hidden or skipped. `Scripts/test-check-agent-context` passed 23 tests. `Scripts/check-agent-context` and `make guardrails` are blocked by three pre-existing missing local evidence links in this merged checkout (`protocol.md`, `report.md`, and `main-thread-stall-export.txt`), rather than the original worktree's protocol header error; those files were not copied or edited. One fresh independent OracleA diff review completed (`item-4-cli-bootstrap-ind-4A10FD`). Both required findings were applied: settlement-time endpoints exclude teardown latency, and descriptor assertions await asynchronous final close. The optional findings were also addressed: cancellation is gated on actual initialize receipt, fixture read failure releases the timer gate, and phase starts carry UTC timestamps. The final tests/build/lint above ran after these fixes; the fake-clock test advances through 20 s of drainage while asserting only 10 s of initialize elapsed time. No second review was requested. No app-side suite was changed, so no root `make dev-test` suite ran; no app package or release build was run by the agent. The later owner-approved fresh-process live result is recorded above; load behavior and historical timeout attribution remain unverified.

## 5. Evidence, safety and completion

Local supporting evidence is under `docs/context/plans/evidence/2026-10-03-code-mode-readiness-and-git-narrowing/`: `postfix-fc32eea8-2026-11-05/claude-runtime-retention-audit.txt`, `pressure-reconnect-investigation.txt` in that same subdirectory, and `codex-current-prompt-2026-11-05/cli-bootstrap-sidecar.txt`. These files are untracked and are not guaranteed in another checkout; this plan preserves the actionable mechanism and source anchors independently. Do not stage raw evidence without owner approval.

Maintainer-guidance check: the user impact is retained runtime pressure and unstable startup; retention/reconnect mechanisms are confirmed, timeout cause remains unknown. Coordinator/session ownership and server admission state are authoritative. Main risks are dropping in-flight work, retiring a replacement owner, losing history, or recreating demand through host respawn. Keep the change bounded to eligible sessions and observable through lifecycle reasons; no broad lifecycle framework, model-policy change or larger caps.

The pre-existing `AgentModeRunServiceLifecycleTests.testClaudeSkippedMessageAloneStoppedIsNotAcceptedOnAnUnrelatedResult` and `testClaudeUnstartedTurnStoppedWithAcknowledgedInterruptAndProviderCancelledResultSettlesAccepted` failures remain disclosed and unresolved. Do not hide them by filtering an acceptance claim or alter them incidentally; distinguish known failures from any new regression.

Done means each implemented item has deterministic evidence, required independent review and explicit live acceptance or a clearly stated live-validation blocker. Implementation of item 1 alone is not permission to run a benchmark, claim the pressure loop solved, or mark the whole plan complete.
