# Pre-live acceptance guidance — OracleB

Scope: read when the task touches the externally coordinated lossless restart live-acceptance plan.
Authority: Reference
Last-verified: 2026-10-24

Main requested independent fresh OracleA/OracleB planning together with identical controlled context and verbatim review policy, then continued each lane with the same source-audit corrections. Returned preset UUID/name matched OracleB (7CDD523E-1D7C-47EA-98FE-D5FEA24D2D8C); continuation inherited the same preset. Full replies were read. These are planning opinions, not executed validation or permission to launch.

The follow-up supersedes initial unsupported assumptions. In particular, Step 4c already resolved the helper policy; dirty-tree validation is useful when labeled; whole-app qualification and deterministic crash cuts are not existing CLI capabilities. No source tooling, production activation, clean-worktree rebuild or lifecycle action was adopted now. The owner-facing handoff selects baseline launch approval first, not blanket crash permission. Initial proposals remain verbatim below for traceability.

## Initial guidance

# Oracle Plan



# Acceptance plan: non-lifecycle validation now, minimal plan for the restart boundary

## Summary

The running app can't qualify the current code. Process 8017 started on Oct 20. The installed bundle (`8033b458-dirty`, built Oct 23) is newer than that process, and HEAD `e7ac41e4` (Oct 24) is newer than both. Production qualification is empty by design. So everything meaningful that can run now is static or fixture work:

- the full test suite and packages;
- checking where the scratch build came from;
- checking which code paths can reach the production gates;
- a static isolation audit for a disposable macOS account;
- a list of the 13 runtime/provider pairs and what each one needs to run.

Live acceptance needs builds where the gates are on. That doesn't need a new override mechanism. It needs **candidate builds**: local branches that change only the two existing `production` constants. They run only inside a disposable macOS account, driven by a coordinator that runs in a terminal outside CE and keeps an append-only log. Your CE (process 8017) is never stopped, so a CE-hosted main agent survives the whole run. Nothing here claims the feature is complete.

Evidence labels used throughout:
- **[PREP]**: preparation, not evidence.
- **[FIXTURE]**: tests, fakes, static audits.
- **[DESIGN-LIVE]**: isolated CLI captures like O16–O21. These count as design evidence only, as the spec says.
- **[LIVE-ACCEPT]**: the real app, through the real shims, in an isolated instance, built from a known tree.

## Current state

- **Gates.** `AgentRuntimeQualification.production` has empty `families`, with no environment or defaults override. `activatesRegistration` requires `supportedPairs.allSatisfy(covers)` across all 13 pairs:
  - Claude: the native standard variant, the compatible variants, and headless for every variant;
  - Codex: app-server and exec;
  - one pair for each `ACPProviderID`.

  `allowsFreshSessionID` also needs `activatesRegistration`. All four `AgentRecoveryActionQualification` flags are false, and they also depend on registration. `recoveredStop` has no production signalling, and the armed-helper-stop policy is unresolved (O14).
- **The live binding is stale.** The process, the installed bundle and HEAD are three different builds. Any probe against process 8017 or window 2 only shows that the old build works.
- **Unsafe tooling.** `make dev-smoke` hard-codes window 1 and switches workspaces, so it can't be used against your real windows.
- **Isolation.** The spec (O3) says roughly ten stores hard-code `Application Support/RepoPrompt CE`. A second instance in the same account, or a temporary workspace, is not isolated. A disposable macOS account isolates `$HOME`, the login Keychain and per-user launchd namespaces. Socket paths, CLI symlinks and anything system-wide are not yet audited.
- **No UI driver.** There is no computer-use tool, Codex.app is not installed, and the capabilities of Claude.app and ChatGPT.app can't be assumed. UI-only steps must be done by you, or by `osascript` once you grant Automation permission.

## (1) What runs now, and what to cut

### Run now (no lifecycle actions)

| ID | Work | Label | Notes |
|---|---|---|---|
| N1 | Finish the in-flight unfiltered root tests and the RepoPromptCore and RepoPromptAgentProviders package tests | [FIXTURE] | Record the SHA, toolchain, command, pass/fail/skip counts and any flaky reruns. Don't filter. |
| N2 | Check the scratch packaging artifact | [PREP] | It must come from a clean `git worktree` at `e7ac41e4`, not your dirty tree. If its provenance says "dirty", it is not an acceptance artifact; rebuild it in a clean worktree. Record the bundle SHA-256, `CFBundleIdentifier`, provenance string, `codesign -dv` output, and that the CLI is `rpce-cli-debug` with no `rp-cli-debug`. Don't open the app and don't copy it to `/Applications`. |
| N3 | Static gate-reachability audit | [FIXTURE] | Find every place that constructs `AgentRuntimeQualification` or `AgentRecoveryActionQualification`. Confirm only `.production` reaches app or executable targets, and that no environment, defaults or launch argument is read. Cite file:line. If no test asserts that production is all-off and `activatesRegistration == false`, list that as a P3 gap. Don't add tooling. |
| N4 | List the pairs and their prerequisites | [PREP] | For each of the 13 `supportedPairs`: the binary or shim, the account or backend it needs, and whether you already have it. Names only; don't inspect credentials. This feeds the coupling decision (Q-B). |
| N5 | Static isolation audit for the disposable account | [FIXTURE] | Cover the App Support stores, MCP socket paths (per-user, or fixed names under `/tmp` or `/Users/Shared`?), Keychain service names, CLI install or symlink locations (`/usr/local/bin` is shared between accounts), LaunchAgents and login items, Sparkle auto-update for the dev lane, XPC or Mach service names, and how discovery identifies processes (marker only, or by name?). The output is an isolation verdict with file:line evidence, plus what the coordinator must avoid. |
| N6 | Crash-point and fault-injection inventory | [PREP] | Find existing DEBUG hooks or named functions where each crash cut (C1–C8) can be hit. Also find existing ways to make quit Stage A or Stage B fail. If none exist, plan for `lldb` symbol breakpoints and a read-only store directory instead of new hooks. |
| N7 | Write the runbook, scenario matrix, log format and status lines into the plan's evidence directory | [PREP] | These are docs and need no review. |
| N8 | Optional: prepare the candidate qualification branches (see section 3) | [PREP] | Only after you answer Q-B. Never merge them, and never build them into your account's `/Applications`. |

### Cut (invalid or redundant)

- Retrying `dev-smoke`: it targets window 1 and switches your real window's workspace.
- More `rpce-cli-debug` probes, MCP probes or timing measurements against process 8017: the binding is stale. The one ping already done proves CLI connectivity only.
- More throwaway-parent marker or process-tree experiments: the spec says these are design evidence only.
- More fake-controller or reconciliation fixtures meant to stand in for live acceptance.
- A same-account second instance or a temporary-workspace "isolation" run.
- More Claude CLI captures beyond O21, unless a specific open design question names one. The same goes for a Codex CLI `thread/resume` capture: it is optional [DESIGN-LIVE] and only worth running if a design question needs it.
- Using Claude.app or ChatGPT.app as drivers. They can still answer your questions as advisors.
- Installing any scratch bundle over `/Applications/RepoPrompt CE Dev.app`.
- Anything involving `rp-cli-debug`.

## (2) Coordinator outside CE

### Roles

| Role | Where it runs | Responsibilities | Must never |
|---|---|---|---|
| Main (this agent) | Your account | Owns the plan, decisions, candidate branches, staging, ingesting evidence, and all OracleA/B calls | Act as the coordinator, or touch the disposable account directly |
| External driver | Terminal in the disposable account. You start it. | Follows the runbook: launches and kills the app by exact process ID, takes snapshots, writes the log | Edit source, call Oracles, push, use credentials, or touch your account |
| You | Either account | The bootstrap and approvals listed below, and UI clicks when asked | (none) |

Driver choice: prefer **Pi**, if it can authenticate in that account, then the Codex CLI. Avoid the Claude CLI unless N5 shows discovery is marker-only. Otherwise the driver's own `claude` process could be mistaken for a surviving agent. Either way, the driver's processes double as scenario X1 ("an unmarked foreign process is not adopted").

### Your bootstrap and approvals (one sitting where possible)

1. **H1.** Approve O3 (disposable account) and create a standard, non-admin account, for example `rpce-accept`. Log in once with fast user switching. Your CE keeps running in your own session.
2. **H2.** Inside that account, log in to the providers for the pairs you choose under Q-B. You type the credentials; no agent sees them.
3. **H3.** Approve a spend cap for each provider and each stage.
4. **H4.** Grant permissions when macOS prompts:
   - Automation, for `osascript` quit;
   - Screen Recording, for `screencapture` (optional);
   - Developer Tools / `_developer` group membership, only if N6 chooses `lldb` (needs admin authentication once).
5. **H5.** Start the driver in Terminal with the inbox runbook path.
6. **H6.** Give one approval per stage (S0, S1, S2) before it launches. Don't approve per scenario.
7. **H7.** Do the UI actions the driver asks for: Resume, Edit first, Cancel quit, Retry flush, and Cmd-Q if Automation isn't granted. Report click counts.

### Handoff and logging

These survive restarts of both the app and the driver.

- **Inbox:** `/Users/Shared/rpce-acceptance/<run-id>/inbox/`, read-only for the driver. Main stages:
  - the candidate bundles;
  - a `manifest.json` with the bundle SHA-256, commit, tree hash, stage and gate values;
  - `runbook.md`;
  - `matrix.md`.
- **Outbox:** `/Users/Shared/rpce-acceptance/<run-id>/outbox/`, writable by the driver. No credentials or tokens; redact environment dumps down to the marker key names and values.
- **`ledger.jsonl` (append-only):**
  ```
  {seq, scenario, step, state: "intent"|"done"|"aborted", ts, app_pid, app_lstart,
   exe_path, bundle_sha256, stage, note}
  ```
  The driver writes an `intent` line before every launch, kill or UI request, and a `done` line after.
  - If a restarted driver finds an `intent` line with no matching `done`, it re-observes first: `ps -o pid,ppid,lstart,command`, then the registry and recovery files. It never repeats a kill blindly.
- **`owner.lock`:** the driver's process ID and start time. A new driver may take over only after confirming the previous one is gone.
- **Binding check at every launch:** the process's executable is inside the staged bundle path, its SHA matches the manifest, and its start time is after the `intent` line. This prevents another stale-binding situation like process 8017.
- **Ingest:** main copies the outbox into the plan's evidence directory and labels each result. Main owns the status lines.
- **Rules for the driver:** call the CLI only by absolute path inside the staged bundle (`.../Contents/.../rpce-cli-debug`), never via `PATH`. Never use `pkill`, or `killall` by name.

## (3) Safe ordering of provider and discovery qualification

**Is a bounded, isolated qualification build truly necessary?** Some build with non-empty qualification is necessary. Marker injection and registration are coupled to activation, so no live discovery or recovery evidence can exist without one. A new override mechanism is **not** necessary, and it would be wrong: it would contradict the "not overridable" contract and add a code path that needs its own review. The lean form is the candidate branches:

- Each branch edits only `AgentRuntimeQualification.production` (in `AgentProcessRegistrySupport.swift`) and, from S2, `AgentRecoveryActionQualification.production` (in `AgentRecoveryActionRunner.swift`).
- These diffs are the proposed reviewed changes, not fake qualification. They exist only on `candidate/*` branches and run only in the disposable account.
- If they pass, the same diff goes to main as a reviewed commit, backed by the evidence.

Order:

1. **Q0, now:** N1–N7. You decide Q-B (coupling). **Stop for approval of H1–H6.**
2. **S0, HEAD build with gates off (the baseline):**
   - B1: the binding check.
   - B2: no marker variables in provider children, no registry records, no recovery actions offered, and every pair launches unregistered as it does today.
   - Any C1–C7 cuts whose persistence is already active at HEAD. N6 or source reading must confirm which are active; if Phase 1 persistence is off at HEAD, those cuts move to S1.
   - This stage tests the harness and driver cheaply.
3. **S1, candidate R:** all 13 pairs set `supportsCompleteDiscovery`, recovery actions off.
   - Covers L1–L6, L8 for every pair, C8, X1, and O1 (what to do with surviving processes).
   - **If any pair fails or can't be credentialed: stop, and you decide.** Partial activation is impossible by design.
4. **S2, candidate R+A:** `sameConversationResume` and `historyReconciliation`, then `freshClaudeConversation` and the per-family `freshSessionID`. You can split S2a and S2b in the same sitting if it helps tell failures apart.
   - Covers U1–U3, L6, L7, F1, F2 and C1–C7 with actions on.
5. **`safeRestart`:** **blocked.** The armed-helper-stop policy and `recoveredStop` signalling are unresolved. Don't build or test it. It is an owner question.
6. **After everything passes:**
   - Send the candidate diffs plus the evidence to OracleA and OracleB, then commit to main.
   - Rebuild from a tree identical to the candidate's tree hash. If main has moved, rerun a reduced S1/S2 smoke on the rebuilt bundle.
   - Freeze source changes to the recovery modules during the run to avoid that.

## (4) Scenario matrix (every scenario recorded)

Every scenario records: the bundle SHA and stage, process ID and start time before and after, recovery records, transcript IDs, marker files, click counts, a log excerpt and the expected result. Rows are [LIVE-ACCEPT] only when run as specified. Timing rows are advisory because the host is noisy.

| ID | Scenario | Stage | Driven by | Pass when |
|---|---|---|---|---|
| B1 | Launch binding check | All | Driver | Executable path, SHA and start time match the manifest |
| B2 | Gates-off behavior | S0 | Driver | No markers, no records, no actions offered |
| C1 | Kill before intent commit | S0/S1 | `lldb` or driver | No success acknowledgement was sent |
| C2 | Kill after commit, before acknowledgement | S0/S1 | `lldb` | One recoverable intent |
| C3 | Kill after acknowledgement, before queue drains | S0/S1 | `lldb` | The full payload survives |
| C4 | Kill just after a direct Send | S0/S1 | `lldb` or driver | Held, or `deliveryUnknown` |
| C5 | Kill between scheduled-send transfer steps | S0/S1 | `lldb` | No duplicate |
| C6 | Kill mid-stream | S1 | Driver | Interruption recorded; staleness within the measured maximum |
| C7 | Kill during quit Stage A, then during Stage B | S1 | Driver + `osascript` quit | A: the app stays usable. B: the next launch treats sessions as uncertain |
| C8 | Kill after `reserved`, before identity is filled | S1 | `lldb` | Ownership unresolved |
| F1 | Stage A failure → Cancel quit → interact → quit | S2 | Fault from N6 + you | The app recovers and the second quit is clean |
| F2 | Stage B failure → Retry flush | S2 | Fault from N6 + you | The flush succeeds and nothing is lost |
| L1 | Claude foreground tool, then a new tool | S1 | Driver + provider | Discovered and registered; no orphan |
| L2 | Claude with a background child | S1 | Driver | The child is discovered at relaunch |
| L3 | Claude with an unanswered stdio permission request | S1 | Driver | Behavior recorded; this sets O1's advice |
| L4 | Claude mid-call to a RepoPrompt MCP tool | S1 | Driver | Interruption recorded correctly |
| L5 | Claude startup hooks | S1 | Driver | Markers survive the hooks |
| L6 | `claude --resume` with a dangling `tool_use` | S1/S2 | Driver + you | The resume path is correct |
| L7 | Codex command in progress, then `thread/resume` | S2 | Driver + you | Correct reconciliation |
| L8 | Marker propagation, for each of the 13 pairs, through both shims and the providers' tools | S1 | Driver | Every pair passes. One failure blocks activation |
| L9 | Cmd-Q with several running sessions | S1/S2 | You or `osascript` | Quit latency recorded (advisory) |
| X1 | The driver's own unmarked provider process | S1 | Driver | Not adopted or discovered |
| U1 | Resume card: sends immediately; text visible and editable | S2 | You | Matches O2 |
| U2 | Edit first | S2 | You | The text goes to the composer |
| U3 | Unsent message moved to the end (O11) | S2 | You | Same ID; stays unsent if the send fails |
| P1–P2 | Intent commit p95 ≤ 50 ms; composer never blocks typing | S1 | Driver | Advisory |

## (5) Realistic blocking risks

1. **Coupled activation across all pairs (most likely to block).** If any of the 13 pairs can't be credentialed or installed (compatible backends, ACP backends), `activatesRegistration` can never become true. That keeps fresh session IDs and every recovery action off. The options are your call (Q-B):
   - (a) get access for every pair;
   - (b) a reviewed scope change that removes unsupportable pairs from `supportedPairs`. Under the review policy, removing a feature counts as a fix. Those providers would then be refused when activation is on, because `covers()` refuses uncovered pairs;
   - (c) leave activation off for good.
   - None of these is a gate rearchitecture.
2. **Disposable-account leaks.** Fixed `/tmp` socket names, shared CLI symlinks in `/usr/local/bin`, Sparkle, and system-wide managed-policy hooks (still not ruled out) could cross accounts. N5 must clear them before H1.
3. **Precise crash cuts.** Without existing hooks, C1–C5 and C8 need `lldb`, which needs developer-tools authorization. Timed kills are not exact. If neither works, those rows stay "not run". Don't approximate them with fixtures.
4. **Evidence binding.** A dirty-tree build, or main moving after the candidate build, breaks the link between evidence and the commit you review. Use clean worktrees, record tree hashes, and freeze the recovery modules during the run.
5. **Process-name discovery.** A coordinator based on the Claude or Codex CLI could interfere with discovery if discovery matches names. N5 should check this, and X1 turns the risk into a test.
6. **Spend and policy.** Provider login in a new account may trigger organization or managed policy, or cost money. Caps go in H3.
7. **`safeRestart` and O14.** These stay blocked until you decide on the armed-helper-stop and `recoveredStop` signalling. The feature can't be called complete without them.

## Files affected

- **No source changes now.**
- **`docs/context/plans/2026-10-18-lossless-app-restart-spec.md`:** add the status lines and a pointer to the runbook. Your choices go in Decisions only as one-line answers; my recommendations go under `assumed:` or in the owner questions.
- **Plan evidence directory:**
  - `acceptance/runbook.md`, `matrix.md`, `ledger-format.md`;
  - the N1–N6 results, each labeled with how it was obtained;
  - the OracleA/B findings when they exist.
- **`candidate/R` and `candidate/RA` branches (local only, after Q-B):** only the two `production` constants change. Never merged before evidence and review.

## Implementation order

1. N1 and N2. Use the in-flight worker; rebuild in a clean worktree if the provenance is dirty.
2. N3–N6 static audits, done in parallel by read-only workers.
3. N7: the runbook, matrix, log format and status lines (for example `Step A0 — doing | rounds 0/2 | open: | … | assumed: driver=Pi`).
4. Send the owner questions:
   - Q-A: O3 disposable account;
   - Q-B: coupling path (a/b/c);
   - Q-C: driver choice;
   - Q-D: spend caps;
   - Q-E: `lldb` developer-tools authorization;
   - Q-F: the `safeRestart` policy.
   Continue with whatever doesn't depend on the answers.
5. After Q-B: prepare the candidate branches, build them in clean worktrees, and stage the inbox with the manifest. [PREP]
6. **Stop.** Wait for you to do H1–H6. Lifecycle work is not authorized now.
7. Then run S0, S1 and S2 in that order, ingest and label the evidence, run OracleA/B on the candidate diffs, commit, and confirm the rebuild.

## Recommendations

- **Now:** finish N1–N7. Cut `dev-smoke` retries, probes against process 8017, throwaway-parent experiments, more fixtures and same-account instances. Report all results as [FIXTURE] or [PREP]. Never call them live passes.
- **Isolation:** use a disposable macOS account (O3) after N5 clears it. Your CE stays running.
- **Driver:** a terminal-based CLI driver (Pi, then Codex CLI) inside that account, using the append-only log, the lock file and a binding check at every launch. You give one approval per stage, plus the credential and permission steps you must do yourself. Main remains the only caller of Oracles and the only author of status.
- **Qualification:** use candidate branches that change only the existing `production` constants. Don't build any override mechanism. Order: S0 (gates off) → S1 (registration, all 13 pairs) → S2 (actions). `safeRestart` stays blocked.
- **Decide Q-B first.** It is the most likely hard blocker. Without access for all 13 pairs, or a scope change you approve, live activation can't happen at all.
- **Stop points:** before H1, before each stage launch, at any pair failure, and at `safeRestart`. Until all of S1 and S2 pass on a build tied to the reviewed commit, the feature stays not complete and the recovery gates stay off.

## Follow-up after source audit (controlling guidance)

# Oracle Plan

# Is the current stopping boundary honest and sufficient, and what is the next authorization package?

## Is the boundary honest and sufficient?

**Yes, with three conditions.**

1. **Label the dirty-tree results exactly.** Record HEAD `e7ac41e4` plus a hash of `git status --porcelain` and `git diff`. Also list which dirty paths, if any, touch the recovery or registry modules.
   - If there is no overlap, the results are fixture evidence for HEAD behavior.
   - If there is overlap, they are fixture evidence only for "HEAD plus the owner's changes".
   - The packaging artifact is a scratch build from dirty inputs. Don't install it, launch it or treat it as an acceptance artifact.
2. **The lifecycle status must name the unmet prerequisites, not just "pending".** Suggested line:
   `Step L — blocked | rounds 0/2 | open: | assumed: live acceptance pending; dirty-tree tests are [FIXTURE] | deferred: isolated candidate composition + deterministic boundary control (unreviewed, needed only by specific scenarios); safeRestart Stage-B "Exit — may reopen" needs LIVE verification`
3. **Nothing may describe `supportsCompleteDiscovery` or any recovery action as observed.** The O16–O21 CLI captures stay design evidence. Everything else stays fixture evidence.

It is sufficient for "do it all until the app has to stop or relaunch". After the full tests, the scratch package, the source audits and the saved plan, every remaining scenario needs either a visible launch or kill, or a build where the gates are on. Neither is authorized.

**Corrections I accept from your audit:**
- The armed-helper policy was already decided in Step4c `cb15d40f`. `safeRestart` moves from an owner question to live verification. My earlier plan was wrong to call it blocked on a policy decision.
- My earlier "only edit the two constants" candidate plan isn't a proven route to testing the gated paths. The relevant code doesn't share one entry point:
  - `AgentRecoveryAppComposition` (line 44) takes a registry but no action qualification;
  - the view model (line 677) uses `.production` and the registry singleton;
  - `AgentRuntimeLaunch` (line 85) reads the production registry on its own;
  - `WindowStateManager` (line 233) uses the default `AppRelaunchCoordinator.production`.

  Whether any candidate can actually reach the gated UI is an open question for that later review. I'm not promising it.
- Because the "machine" locks are per user, the disposable account must build into, or copy into, its own home folder. It must never share a bundle or build output with your account.
- The CLI must be called by its absolute path inside the bundle, never through the global `/usr/local/bin` link, which points into your account.
- The coordinator must never kill processes by name. It must never touch `repoprompt-mcp` or anything else unless it matches a recorded process ID and start time.

## Should source tooling be cut now?

**I agree with cutting it.** Nothing in your current request needs it:
- Crash-cut toggles, a candidate composition and boundary controls only serve scenarios that need a lifecycle action, and those aren't authorized.
- Building them now means code with no user, which still needs OracleA/B review and might never match the scenarios that turn out to matter.
- The one thing I flagged earlier, the lack of a test asserting that production qualification is fully off, is a P3 test gap. It isn't tooling, and it isn't required.

## Testing a hypothesis in an isolated candidate vs. faking production qualification

**Legitimate: testing a hypothesis in an isolated candidate.**
- It is a separately reviewed composition on a local branch that is never merged. It is built and run only in the disposable account, and normal builds keep the gates off.
- The manifest labels it `candidate` and records its tree hash.
- Results are written as "Hypothesis H (for example, pair P supports complete discovery) was observed or not observed under conditions C on candidate tree T." Each result covers only the pairs actually tested.
- A passing result only justifies proposing a production change. That change gets its own review, rebuild and smoke test.

**Fraudulent: faking production qualification.**
- Turning on `production` qualification in the normal build.
- Recording a gate as qualified based on fixtures, fake controllers or CLI captures.
- Attributing candidate results to a different tree, or to production behavior.
- Presenting results for some pairs as if they covered all 13 coupled pairs.

## The one next authorization package to show the owner

**Package L0: disposable-account baseline. Gates off, no source changes, gated paths not tested.**

One-time setup by the owner:
1. Create a standard, non-admin account and log in to the providers there as normal.
2. Start a coordinator in Terminal inside that account (Pi, or the Codex CLI). Optionally it can use whatever computer-use capability is already available there for UI steps. No capability is assumed, and the fallback is the owner clicking when asked.

**The single just-in-time approval** allows the coordinator, inside that account only, to:
- build or copy the HEAD gates-off build into that account's own home;
- launch it;
- kill only the recorded process ID and start time;
- relaunch it.

**Identity record:** an append-only log entry before and after every action, with:
- process ID, start time, executable path and bundle SHA;
- a check that the running binary matches the build;
- a fresh look at running processes and stored files before any action taken after a coordinator disconnect or restart. No blind retries.

**What L0 shows:**
- the binding check works;
- with the gates off, there are no markers, no registry records and no recovery actions offered;
- coarse kill-and-relaunch behavior for whatever persistence HEAD already has turned on;
- the coordinator's own provider processes are not adopted.

**What L0 doesn't show:** discovery, the recovery actions, or anything about qualification.

If the owner declines, the honest alternative is to leave live acceptance pending. Never run crash tests in the owner's own account instead.

## Recommendations

- Collect the dirty-tree full-test and packaging results. Label them with the HEAD SHA, the diff hash and any overlap with the recovery modules, as [FIXTURE] or [PREP] and never clean-HEAD acceptance. Don't run a clean-worktree build just for form.
- Save the compact external-terminal plan and the blocked status line. List the candidate composition and boundary control as unmet prerequisites, to be reviewed only when a specific scenario needs them.
- Change the `safeRestart` status to "decided in `cb15d40f`; live verification pending".
- Build no source tooling now; nothing in the current request needs it.
- Show the owner only Package L0: one account setup, provider logins, an external coordinator, and one just-in-time lifecycle approval with the identity record and re-check. State plainly that it qualifies nothing.
- Stop before any launch. If L0 is declined, leave live acceptance pending rather than crash-testing in the owner's account.
