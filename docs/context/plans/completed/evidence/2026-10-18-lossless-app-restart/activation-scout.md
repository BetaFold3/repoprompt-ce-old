# Step 9-activation scout plan (worker report)

Scope: read when the task touches turning recovery actions and process registration on in production (Step 9-activation).
Authority: Reference
Last-verified: 2026-10-26
Covers: the pair worker's verbatim read-only scout of what activation changes, the provider refusal audit, the Reconcile bound and the Stop entry point.

I made no edits. Activation is bigger than a flag flip: turning process registration on for production is currently all-or-nothing across all 13 provider pairs. So "Claude Code and Codex only" needs one small but deliberate design change. Plan below.

**1. What changes**

- **Action flags.** `AgentRecoveryActionRunner.swift:44-46`: set `production = .init(sameConversationResume: true, historyReconciliation: true)`; fresh Claude conversation and safe restart stay off. The O32 comment goes here. Also fix the stale "everything OFF" comments at :20-21 and :145-147.
- **Registration qualification.** `AgentProcessRegistrySupport.swift:60` gets real entries for four pairs:
  - `.claudeNative` and `.claudeHeadless`, provider `.claude(.standard)`;
  - `.codexAppServer` and `.codexExec`, provider `.codex`;
  - `markerPropagation` and `completeDiscovery` true; writer basenames `["claude"]` / `["codex"]`; tool basenames `[]` (unknown processes stay possible writers); `freshSessionID` false.
  - The writer names must match what V1's `ps` shows. A Claude install that runs as `node …/cli.js` would be named `node`, so these values depend on evidence.
- **Blocker: registration is all-or-nothing.** `activatesRegistration` (:78-80) needs every one of the 13 pairs covered (`supportedPairs` :65-72). `reserveLaunch` (`AgentProcessRegistry.swift:684`) throws `unqualifiedProvider` for any uncovered pair. Turning it on as-is means either claiming unverified evidence for the ACP and Claude-compatible backends, or refusing every OpenCode, Cursor, Oh My Pi, GLM, Kimi and custom launch. Smallest fix:
  - `activatesRegistration` becomes "at least one pair covered".
  - `AgentRuntimeLaunchAuthority.makeLaunch` (`AgentRuntimeLaunch.swift:97-100`) returns nil for an uncovered pair, so that launch runs unregistered exactly as it does today (inherited marker still stripped).
  - Add `isRegistrationActive(family:provider:)` and use it at `ACPAgentSessionController.swift:309` and `ClaudeNativeProcessSessionController.swift:1352/2151`. Otherwise ACP and compatible backends would start joining retirements and lose their warm controllers.
  - `verifyAllFamiliesStopped` (:1083) can no longer prove that unregistered families stopped, so safe restart must stay off. Record that next to the flag.
  - `live-acceptance-handoff.md:241` says "do not activate only a subset without a separate owner-approved design change". O32 has to be recorded as that approval.
- **One composition.** There is already a single registry (`AgentProcessRegistry.production`, :81). Three places choose qualification on their own: `AgentModeViewModel.swift:679-681`, `:690` and `AppRelaunchCoordinator.swift:189-190`.
  - Add an AgentCore `AgentRecoveryActivation.production` holding the registry, runtime qualification and action qualification.
  - `AgentProcessRegistry.production`, `AgentRuntimeLaunchAuthority.production` (`AgentRuntimeLaunch.swift:85`) and `AgentRecoveryAppComposition.swift:114` read from it.
  - `install(into:)` (:120) sets `viewModel.recoveryActionRunner` and `recoveryHistoryRegistry`. The lazy VM default becomes all-off, for tests only.
  - Row presentation (`+RecoveryActions.swift:55-104`) and Check (`+RecoveryCheck.swift:31`) already use the runner, so they follow automatically.

**2. Registration at launch once it's on (Claude standard and Codex only)**

- Before the spawn, `reserveLaunch` writes `<App Support>/RepoPrompt CE/AgentRecovery/v1/runtimes/<runtimeID>.json` in state `reserved` (`AgentRecoveryStore+Runtimes.swift:12-17,98`).
- The child's environment gets `RPCE_RUNTIME_ID=<uuid>` (`ProcessLauncher.swift:56,80`).
- `registerSpawn` inspects the child and rewrites the file as `live` with its birth identity and Claude home, then installs exit watches (`AgentProcessRegistry.swift:756-800`).
- Each operation's association and each write fence (:804, :900) also write that file.
- **Yes, a failure blocks the send, by design.** It fails closed on storage failure, ownership conflict, missing session scope (`.unavailable`), or a failed identity inspection. The child is then terminated and zero bytes are written.
- **Today, with it off:** `.activationOff`, no reservation, marker or fence. Runtime records already on disk are still enforced.
- **Other new costs on normal sends:**
  - Every Claude Code send first takes a pre-send history baseline (`+RecoveryActions.swift:874-1020`): a full JSONL read plus a forced session save. A failed save returns `.refused` and the send is denied (:839-842, :858). Expect extra latency on long histories.
  - An unreadable runtimes directory becomes app-wide uncertainty and blocks ownership-dependent work.
  - The Codex agent-mode client defaults to `.unavailable` (`CodexAppServerClient.swift:552`; VM :2406 relies on scope captured by the owning operation). The verifier should watch for refused Codex launches.

**3. Refusal audit, once activated**

Today only `.claudeCode` and `.codexExec` have a history performer (`+RecoveryActions.swift:305`). Every other kind gets `reconcile = nil`.

| Provider | Continue | Reconcile | Send saved / Send answer as message | It stopped | Let finish | Stop |
|---|---|---|---|---|---|---|
| Claude Code | Reconcile first; dispatch only after an unconfirmed observation (`AgentRecoveryActionRunner.swift:265-304`). Runs started before activation have no baseline, so it refuses with `.associationUnavailable(.baselineUnavailable)` (:1110-1121). | Same fences; no baseline gives the same refusal. | No reconcile; fences, then settlement | Unchanged (`+RecoveryList.swift:1341`) | Only for registered survivors (:431, :822) | Not offered (:834) |
| Codex | Reconcile first. Refuses at :1305 if the turn ID is missing. Pre-activation the observation threw `registeredTransportRequired` (`CodexNativeSessionController.swift:1816`); after activation it may cold-start a temporary app-server. | Same | Same | Unchanged | Same | Not offered |
| Claude-compatible (GLM, Kimi, custom) | **Sends silently with no reconcile:** runner :182 skips the nil performer, `stopBeforeDispatch` :275 falls through, and the process isn't registered, so ownership is unproven. | Recorded as `notDispatched`, "Provider history is unavailable." (:206-208). That writes a durable action for nothing; Check shows `couldNotCheck`. | Dispatches with ownership unproven | Unchanged | Rows never appear | Not offered |
| ACP (OpenCode, Cursor, Oh My Pi) | Same silent-send problem | Same | Same | Unchanged | Rows never appear | Not offered |

- No path reports "nothing imported" for a missing history provider. The only `nothingImported` results are real Codex or Claude observations (:1153, :1206, :1226).
- **Fix:** in `perform` (runner :167-169), before any reservation, refuse when the target's provider kind isn't covered by the composition's qualification or has no history performer. Suggested text: "Recovery for <Provider> isn't qualified yet: RepoPrompt can't verify its process ownership and provider history. Nothing was sent." The buttons stay visible, per "available for every provider", so V9 sees this refusal.

**4. Reconcile bound: let Check's Stop abandon the current item**

- Bounding Reconcile itself isn't smaller. Codex `client.startIfNeeded` and `associateObservedConversation` (`CodexNativeSessionController.swift:1826-1837`) take no deadline. The cold-path cleanup awaits `observing.result` before `shutdown` (`CodexAgentModeCoordinator.swift:4810-4825`). The Claude read (:1270) can't be cancelled. A timeout would still have to abandon work.
- **Proposed change** in `AgentRecoveryCoordinator+Check.swift`:
  - At :197-203 and :224-251, run `reconcile(item)` in an unstructured main-actor task and await whichever comes first: its result or a stop signal fired by `requestRecoveryCheckCancel` (:211).
  - On Stop, record `.couldNotCheck("Stopped while checking. Its check continues; the card shows the result.")`, count the rest as not checked, and call `setCatalogActionState(nil, for: item.id)`.
- **Why it's safe:**
  - The coordinator's action hold (runner :171-195) stays until the stuck task ends, so sends into that session keep being refused.
  - Clicking the row's Reconcile again joins the same request rather than reserving a new one (:233-240).
  - The VM's late `setCatalogActionState` (`+RecoveryCheck.swift:98`) then shows the real outcome.
- **Leftover risk:** a stuck Codex cold start still holds that one session until quit. That was already true of the row's Reconcile; Codex start deadlines would be a follow-up.

**5. Stop entry point:** there isn't a reviewed one, so Stop stays unwired. The engine exists (`previewStop` `AgentProcessRegistry.swift:955`, `stop(preview:)` :991), but production supplies no `AgentProcessStopActions` (`AgentProcessRegistrySupport.swift:149`; registry built at :81-83 without them) and no row or VM action calls it. 9-stop stays blocked and V3 is skipped.

**6. Tests**

Contract tests to update deliberately (these are contract changes, not weakened assertions):
- `AgentRecoveryActionTests.swift:399-410, 479` and `AgentRecoveryCoordinatorTests.swift:2602`: production allows resume and reconcile, not fresh conversation or safe restart; baselines are captured only while registration is active.
- `AgentProcessRegistryTests.swift:100-125, 798-801`: activation by subset; uncovered pair gives a nil launch (runs unregistered), not a refusal.

New tests:
- The production qualification equals the four O32 pairs. This is a pure value test, since XCTest has no production registry.
- The runner refuses each of the six unqualified provider kinds before reserving anything, with no record write. Row text, and the Check report shows `couldNotCheck` with that text.
- Check's Stop abandons a fixture reconcile that never returns: the report finishes, `.working` is released, and a second dispatch is still refused.
- ACP and compatible launches spawn with the marker stripped and no runtime file.
- `install(into:)` injects the runner and registry.

Suites: the touched Recovery suites, plus `AgentProcessRegistryAssociationTests`, `AgentRecoveryRuntimeOwnershipTests`, `AgentRecoveryReconciliationTests`, `AgentRecoveryStartupCompositionTests`, `ClaudeNativeRuntimeSessionArgumentsTests`, `CodexAppServerRuntimeFenceTests`, `RegisteredNativeTransportWriteFenceTests`, `ProcessLauncherRuntimeMarkerTests`, `AppRelaunchCoordinatorTests` and `AgentScheduledSendNonCodexMandatoryTests`. Then `make dev-build`, `make guardrails` and `Scripts/check-agent-context`.

**7. Larger than flag flip plus wiring — proposed splits**

- **9-activation-a** (this change): the subset design change from §1, flags, one composition, provider refusal, Check abandon, comments, plus updating the spec status line and the handoff's "do not narrow" rule.
- **9-activation-b:** Check confirming a crash hold automatically when the registry proves every process exited. The synthesis and the 9-check line moved this into activation, but it's new write behaviour.
- **Separate follow-ups:** Codex start/associate deadlines; showing versus hiding refusing buttons.
- **For the verifier:**
  - Claude Continue and Reconcile (V5/V6) only work for runs started after the activated build; older runs refuse because they have no baseline.
  - Writer process names need V1 `ps` evidence before they are trusted.
  - Watch normal Claude send latency, since every send now takes a baseline.

**Decision for you:** does O32 count as the owner approval to register only Claude Code and Codex? Today's design requires all 13 pairs, and the handoff forbids a subset without a separate owner-approved design change.
