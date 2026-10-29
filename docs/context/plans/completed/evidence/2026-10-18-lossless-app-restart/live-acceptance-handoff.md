# Lossless restart — external-driver acceptance handoff

Scope: read when the task touches the remaining lossless restart validation, ordinary quit/relaunch preservation checks, optional isolated fault testing, or coordination across app stop/relaunch.
Authority: Reference
Last-verified: 2026-10-25

## Outcome and next boundary

**Bounded ordinary preservation acceptance passed on 2026-10-25:** two distinct unsent composer drafts and one managed image survived an approved normal quit/relaunch of the same current candidate, with exact persisted content, identities, attachment bytes and UI readback; no synthetic send attempts appeared. The 14.09-second request-to-observed-exit interval includes the owner's delay answering the quit dialog and is **not a valid application quit-latency sample**, not evidence of an 8-second deadline failure. Four focused persistence/shutdown suites passed 94/94 tests. Production recovery gates remain off; broader live acceptance is not complete.

Earlier non-lifecycle validation was **not all green**. [Full results](pre-live-validation-2026-10-24.md): unfiltered root 7,782 tests across 657 suites, with one suite still failing after retry and focused serial reproduction; core 66/66 and provider 35/35 passed; signed scratch packaging passed. No source was changed to hide the failure, and no new provider prompt was sent during this acceptance.

The remaining root failure is `MCPCodeStructureWorktreeTests.testRetainedProjectionPreloadStopsAfterIndexAdvanceAndForegroundRecoversOnce`, line 1805: projection preload did not observe the staged index change. It is a codemap-domain failure, but attribution to pre-existing code versus the restart series is **not proven**. The working tree includes an unrelated modified codemap test helper. No bisect, clean-baseline comparison or fix was done. Keep the full-suite gate failed rather than calling this a pass with exclusions. Do not modify the owner's unrelated codemap work without a scoped follow-up.

At the original preflight, live CE was **not the candidate**: PID 8017 began 2026-10-20 20:18:57 at `/Applications/RepoPrompt CE Dev.app/Contents/MacOS/RepoPrompt`; ping reported `debug-optimized-incremental`, whereas its installed bundle reported `8033b458`, dirty, lane `debug`. That old process has now exited after the owner-approved ordinary quit below. The current debug package has now completed a bound candidate-to-candidate ordinary preservation cycle (below); queued input, running-turn recovery and advanced acceptance remain pending.

**Owner correction (2026-10-24): no disposable-account requirement for ordinary acceptance.** Use the existing daily app with the external Terminal Pi coordinator. Diagnose the remaining test failure, bind a current candidate, prepare synthetic drafts/attachments/queued input and sessions through normal app paths, then request fresh approval immediately before normal quit/relaunch and verify exact restoration. Keep deliberate crashes and injected storage failures separate and unverified. Recovery actions remain disabled pending qualification; account isolation does not solve that limitation.

The completed bootstrap and candidate-preservation cycle are distinct: the old-build quit was not counted as candidate acceptance. Synthetic baseline data was prepared on the bound current candidate before its own normal quit/relaunch. Any additional lifecycle boundary still requires fresh approval; this handoff grants none.

## What ran, what did not

- Main independently checked all five conductor outcomes, root census, package test totals, the focused failure, and scratch deep-strict signature verification.
- Plain `make dev-smoke`, ticket `4f8574d1-c14e-4645-bc0e-55e252d9274f`, failed at missing window 1 before its workspace switch. Do not retry it against the owner's real window: the script switches workspaces.
- Read-only `rpce-cli-debug` version, matching-window roots and role inventory worked; main also repeated the diagnostics ping. Ping's binding was unbound, so it proves connectivity/lane only, not tab identity.
- Full-root retries recovered five other suites; this is not a first-attempt-clean run. See the validation report for names.
- Current-source ordinary composer/image preservation has passed, including accessibility readback. No provider interruption/resume, queued-send live recovery, crash-cut, injected shutdown-failure, gated recovery action or production activation acceptance is claimed. Existing captured Claude sessions and fixtures retain their earlier limited evidence scope.
- No extra source tooling, crash hooks, qualification override, clean worktree, provider capture or performance benchmark was built just to expand validation.

## Ordinary-acceptance preparation (2026-10-24, after O24)

- External coordinator independence verified: current shell → Pi PID 37549 → shell → tmux PID 4432; no CE ancestor. PID 8017 was revalidated before the subsequently approved ordinary quit below.
- Scratch candidate rechecked: `codesign --verify --deep --strict` passed; executable, MCP helper and provenance hashes exactly match the three values below. Bundled helper reports `rpce-cli-debug (repoprompt-mcp) 1.0.29`. Current HEAD is `d971983b8d30044d05723f2595709d6747d4c4a3`; the committed delta from candidate `e7ac41e4` contains documentation and source-layout guardrails, not production Swift.
- Exact focused reproduction: `make dev-test FILTER=RepoPromptTests.MCPCodeStructureWorktreeTests/testRetainedProjectionPreloadStopsAfterIndexAdvanceAndForegroundRecoversOnce`, ticket `4bf27f5b-0a10-4fb9-aa02-0919bede1312`, failed (1 test, same line 1805).
- One diagnostic-only repeat, ticket `6881583b-4119-4fd6-9d55-7737ebd2cccf`, added failure-message observations, not changed assertions. It showed `didStage=false`, no stage error, one preload started and completed, 20/20 candidates processed, and zero repository-authority changes. The test never staged its intended Git-index mutation in that run. Source inspection confirms its catalog-build hook is bypassed when an already-published catalog shard is reused (`WorkspaceFileContextStore.swift`, `ensureCodemapProjectionCatalogShard`). This identifies a failed test stimulus, not a passing recovery assertion or historical regression attribution. The temporary diagnostic edit was removed; the owner's dirty helper was untouched. Full-root gate remains failed; no test repair or exclusions are claimed.
- Existing control inspection found prompt-free `agent_manage` `create_session`, but no verified composer draft setter/readback or queue-only insertion in the inspected MCP/debug surfaces. Draft/attachment acceptance needs normal composer UI. No dedicated computer-use tool is exposed here; native accessibility was subsequently verified below. Queue acceptance needs a separately bounded actual queued-send scenario; do not substitute a schedule, transcript fixture, or direct store edit.
- `conductor app stop` and the stop phase of launch/relaunch use process termination; they do not establish an ordinary app quit. Have the owner use normal Quit, stop on cancellation/failure, verify exit, then use coordinated build/launch. Do not invoke a signal-based stop to get past a pending quit.
- Documentation checks passed: `Scripts/check-agent-context` (existing route-count warning), `Scripts/test-check-agent-context` (23/23), `make guardrails`, and `git diff --check`. The subsequently completed composer/image UI cycle is below; queued-send live acceptance has not run.

### Approved bootstrap quit and packaging (2026-10-24)

The owner explicitly approved the agent quitting CE and reported no ongoing work. After revalidating UID, PID, birth time, bundle ID and executable path, the external driver called `NSRunningApplication.terminate` for PID 8017 through JXA. The normal quit request was accepted and the original process exited within the bounded observation. No signal, `forceTerminate`, conductor stop, or escalation was used. A subsequent process inventory found no RepoPrompt app process. This is an old-build bootstrap quit, not candidate preservation acceptance.

With the app stopped, coordinated packaging to `/Applications/RepoPrompt CE Dev.app` passed. Initial ticket `d1f5c362-d9e9-44d9-9de5-684155c41410` selected auto-signing's `alternate-in-memory` storage; that package was never launched. Ticket `b60a6057-7f2b-4385-8bb4-742516b9d729` repackaged with `DEBUG_SECURE_STORAGE_BACKEND=keychain`, preserving the earlier verified candidate's storage choice and the same Apple Development identity. The final package passed deep-strict signature verification, bundle ID and Keychain-marker checks; source is `d971983b8d30044d05723f2595709d6747d4c4a3`, dirty, lane `debug`. No credential values were read or changed.

Final installed SHA-256 values:
- executable: `eb69781eb008c725a062c4d8c3f43239cfdccb72f686915f8018d156074eb611`;
- MCP helper: `e27da6610cb6ecc2495726b7446c55bd2cbbc32f6c8c7cdc3d04b0fe1b779bd2`;
- provenance: `4f9f1c3050e91fe7899c47fe56508239dd4c989c1812093c617cefe4f3fac60c`.

Restart-resilient local evidence: `.agent-artifacts/lossless-restart-ordinary-acceptance/lifecycle.json`.

### Current-candidate launch and synthetic draft preparation

The owner then approved launching and continuing verification. `REPOPROMPT_DEBUG_APP_BUNDLE='/Applications/RepoPrompt CE Dev.app' make dev-launch-existing`, ticket `6becd705-fb1c-4f9c-8c46-4481d689aae9`, passed with the old app already stopped. New PID 40413 started 2026-10-24 19:58:24; its executable path, hashes/stat, source provenance timestamps and compiled `debug` ping were bound successfully. The existing workspace is window 1; no workspace switch was made.

Created a prompt-free synthetic session, `Restart acceptance synthetic 2026-10-24`, through `agent_manage.create_session`; its exact ID is in the local evidence. Selected only that new tab. Native System Events accessibility was available. After explicit composer focus (the first click did not acquire focus and produced no text), typed this single-line draft without Return/Send:

`RPCE_RESTART_ACCEPTANCE_20261024_A: unsent synthetic draft; preserve exactly; do not dispatch.`

The AX text value and a window-scoped screenshot confirmed the exact text. Read-only inspection of that synthetic session's recovery file independently matched its composer text, with empty intents, attempts and runAttempts. No provider prompt was sent. At this preparation step only pre-restart persistence was established; restoration was verified in the completed cycle below. A synthetic PNG fixture was created outside CE but was not attached; the actual managed image present in the synthetic session became the recorded restoration baseline. Queued-input live acceptance has not run.

**Resolved access interruption:** the desktop subsequently became locked (`CGSSessionScreenIsLocked=true`), and CE's accessibility windows became unavailable. After the owner approved the Settings popup, access briefly returned and the image picker/Go-to-folder sheet was opened, but the intended fixture path was not confirmed entered. On the later Continue request, the desktop was locked again; no input was delivered or lock bypass attempted. Read-only reinspection still matches the exact synthetic draft with no intents or run attempts. One managed image titled `assets-oracle-icon.png` is now in that synthetic record and its managed bytes exist; it is not the generated `synthetic-attachment.png` fixture. The coordinator did not establish its source or attachment action; current ID/metadata/hash are recorded locally only as a possible pre-restart baseline, not claimed UI acceptance.

While UI access was blocked, focused source validation passed: `make dev-test FILTER=AgentRecoveryComposerPersistenceControllerTests` (21/21, ticket `028e116d-19e8-42b1-8491-81e6a6bf090e`), `make dev-test FILTER=AgentRecoveryQueuedInputTests` (10/10, `d49b1fa7-2950-4111-b4a8-feb17e44bf51`) and `make dev-test FILTER=AgentSessionLifecyclePersistenceTests` (15/15, `dfdf6279-025d-4fdd-8dee-27c505ee39a9`). These use temporary fixture stores, not the daily recovery records. Initial combined-filter attempts failed at shell parsing (127) and conductor preflight (64); exact suite filters were then run individually without overrides or ledger changes. The 46 passing tests are focused evidence, not a repaired full-root gate or live restoration evidence.

### Completed normal preservation cycle (2026-10-25)

After unlock, verified the first synthetic session's exact draft and `assets-oracle-icon.png` title in its actual composer UI. Created a second prompt-free session, `Restart acceptance synthetic B 2026-10-24`, and entered a distinct unsent draft through the focused composer. Selecting A again confirmed tab-switch preservation. Before quit, recorded both complete composer payloads (including empty tagged-file/workflow-related fields), session/incarnation/reset identities and the managed image's metadata and SHA-256 in the local journal. Both synthetic records had no intents, attempts or runAttempts.

The owner then explicitly approved this normal quit/relaunch cycle. With PID/start identity and package hashes revalidated, requested `NSRunningApplication.terminate` for PID 40413. The owner answered the normal quit dialog; the app exited with no signal escalation or force termination. Coordinated `make dev-launch-existing`, ticket `d4f6103b-4aa4-4a3b-a55c-aa8941bb8b3e`, confirmed the app was already stopped and launched PID 1657 from the unchanged package. Postlaunch process/start/stat/provenance/hash binding and compiled `debug` ping passed.

Results:
- Both recovery records retained exact composer content, session/incarnation/reset identities and no synthetic send attempts.
- The managed image bytes matched their pre-quit SHA-256.
- Draft A text restored exactly in the UI. Its attachment title was absent in the initial immediate lookup, then present after selecting B and A again; the recorded result is eventual restored UI, not proof of immediate first-frame attachment presentation.
- Draft B restored exactly in its separately selected session. Post-hydration records still matched the baseline and still contained no send attempts.
- Normal quit plus same-candidate relaunch is **PASS for these two drafts and one image only**. No provider prompt was sent and no production gate changed. Synthetic sessions remain intact; nothing was silently deleted as cleanup.

The quit request-to-observed-exit interval was 14.09 seconds including JXA startup, polling and, as the owner clarified, time away from the screen before approving the quit dialog. **Exclude it from quit-latency qualification.** It neither proves nor disproves the coordinator's 8-second work deadline; no rerun solely to replace this invalid sample is required.

Additional deterministic shutdown validation: `make dev-test FILTER=AgentLifecycleShutdownCoordinatorTests`, ticket `ac4b2b1c-fb57-4823-b2d5-5f309621950a`, passed 48/48 tests using temporary stores, fake participants and a manual deadline clock, with no real lifecycle actions. Together with the prior three suites, focused persistence/shutdown validation is 94/94. This does not repair the failed full-root gate or establish live injected-failure behavior.

Remaining work is **not** an account setup or UI-access blocker: live queued-input/running-turn preservation needs a bounded real admission scenario; advanced recovery actions remain unavailable under default-off qualification; exact crash/fault cases still need a reviewed control method. Historical questions, edit reviews, child links, busy scheduled sends, every-supported-provider qualification and performance workloads were not exercised. Do not mark the whole lossless-restart spec accepted from this ordinary cycle.

### Queued-input and running-turn cycles (2026-10-25, same candidate)

Owner approved every normal quit/relaunch cycle. All sends used synthetic prompts through the real composer or MCP `agent_run`; no production gate changed.

- **Composer Send stuck (not isolated):** before a relaunch, Return and the Send button did nothing in MCP-created and UI-created sessions after earlier MCP `agent_run start` calls. AX showed Send `enabled=false`, the composer showed an orange "MCP" chip and a locked model, and no intent or attempt was persisted. After a normal quit and relaunch, Send worked in a UI session. Treat as a possible stale in-memory MCP-control or submit-target flag; cause not isolated, and no diagnostics reader exists (`enableAgentModePerfDiagnostics` was already on).
- **Coordinator mistakes (not app faults):** a click on the bottom-right composer button while a turn ran was Stop and cancelled one run. Twice, RepoPrompt lost focus and the script's keystrokes or Return went to the Ghostty terminal; nothing was executed and the repo was unchanged. Focus is now verified before every input.
- **Concurrent composer send (steer):** with a foreground tool running, UI Return delivered the new message as a new user turn; the running tool call was interrupted. Intents moved `dispatching` to `deliveryUnknown` or `providerAccepted`, origin `composer`. There is no separate durable queue for this Claude path. Queued-behind-running admission is **not** shown by this.
- **Two-draft cycle with older intents:** a normal quit with an idle app preserved 8/8 recovery records exactly (drafts, `deliveryUnknown` and `providerAccepted` intents, attempt counts); no resend.
- **Quit during a live turn: PASS, bounded.** Normal Quit with the dialog "Quitting will end 1 active agent session" while a foreground loop ran. The app, its Claude child and the loop exited within about 2 s, no signal. After relaunch the in-flight intent was `deliveryUnknown` with the same identity, incarnation and counts (no resend, no duplicate run), and the UI showed "The previous run may still be running ... sending is paused until you confirm" and "Message may have been delivered ... could deliver it twice". Recovery buttons were not exercised.

- **Codex command in progress at quit: PASS, bounded (persisted-record evidence only).** A `codexExec` (gpt-6-luna low) run with a foreground shell loop was active when Quit was answered. The app and every Codex child exited within about 2 s with no signal and no survivors. After relaunch the intent stayed `providerAccepted` with identical identity and incarnation and one attempt/run attempt (no resend, no duplicate command); the run attempt carries `shutdown{reason:appQuit}` and `terminal{cause:appQuit,state:cancelled}`. The transcript's command row still reads `success` (summary-only) though the run was cancelled, and the UI banner for this session and Codex thread resume were not exercised.

- **Claude background child at quit: PASS, bounded.** A `sleep 240` started with `run_in_background` under a completed Claude turn was alive when the app was quit normally. The app, Claude child, wrapper bash and `sleep` were all gone afterwards with no coordinator signal. No survivor was left to watch or stop. The plain "Are you sure?" dialog (no active-session warning) appeared because the turn itself had completed.
- **Scheduled send across a quit: PASS, bounded (persisted-record evidence).** A new-session schedule (15 minutes) was persisted as `scheduled`; the app was quit normally before it was due and relaunched about 15 minutes after the due time. The record became `needsConfirmation` with `confirmationReason: missedWhileClosed`, kept its schedule ID and text, and nothing dispatched (no items, no provider process). Banner presentation and Send-now were not exercised because the desktop locked again.

- **Four active sessions at quit: PASS, bounded (persisted-record evidence).** Claude, Codex exec, OpenCode (ACP) and Cursor (ACP, parked on an approval prompt) each ran a foreground shell loop. Normal Quit (dialog "end 4 active agent sessions"), answered by the coordinator, took **1.12 s** click-to-exit, a single advisory sample on this shared debug host. After relaunch every intent kept its identity and incarnation, with 1 attempt / 1 run attempt each and `terminal{cause:appQuit}`; Claude, OpenCode and Cursor intents were `deliveryUnknown`, Codex stayed `providerAccepted`. No resend and no new provider process. One survivor: the Claude shim and its child outlived the quit by roughly a minute and exited without signalling; cause not established.
- **Send now on an overdue scheduled send did not dispatch:** from `needsConfirmation/missedWhileClosed`, both Send-now menu items left the record in place (the run-alongside item only flipped the flag). No intent, attempt or provider process appeared over a minute. The scheduler admits only after recovery startup reports ready and not for restricted workspaces; I did not isolate which gate held. Treat the scheduled-send "Send now after restart" path as **not verified**, and possibly a finding.

### Recovery buttons, Codex resume and Codex steer (2026-10-25, Claude and Codex focus)

All on synthetic sessions; rows for the owner's other sessions in the Needs Attention list were not touched.

- **Recovery buttons: PASS, bounded.** "It stopped" wrote a durable `crashHoldAcknowledgement` (same incarnation, the intent ID) and left the intent `deliveryUnknown`. "Dismiss" on a "Message may have been delivered" row wrote a `cardAcknowledgements` entry (`savedInput`, `deliveryUnknown|held:false|stale:false`). "View" opens a read-only popover with the exact saved text and changes nothing. "Remove" moved the intent to `withdrawn` with `withdrawnAt`. None of them sent anything or started a provider process. The row actions (Continue, Send saved and the rest) are not offered, as designed while qualification is off. A View popover left open swallows a later press on the same row, so the first Remove attempt did nothing.
- **Codex resume: PASS via MCP steer.** A Codex run cancelled by quit was steered after two relaunches. A new intent in the same incarnation completed (`ordinary/completed`) and replied `RESUMED`. A follow-up question returned `100`, the bound from the first message, so the thread's context survived. The cancelled command was not re-executed. Resume started from the composer UI was not exercised.
- **Codex steer and quit: PASS, bounded.** A message steered into a live Codex turn ("Delivered to the active Codex run") left both intents `providerAccepted`, with no fallback queue entry and no interruption. A normal quit then ended the run (`appQuit/cancelled`), and after relaunch both intents were unchanged with no resend.
- **Queued-behind-running on Codex: not reached.** Codex accepted the steer in place, so the `queuedFallback` path (taken only when the provider rejects a steer) never triggered. I did not find a safe way to force that rejection.

### Crash cuts by SIGKILL (2026-10-25, owner-approved, Claude and Codex)

Timing-based `kill -KILL` of the daily app, not exact hook cuts. All sessions synthetic.

- **Mid-turn, Claude and Codex:** records stayed frozen (Claude intent `dispatching`, Codex `providerAccepted`, run attempts without a terminal). Codex children died with the app. The Claude shim, its child and the loop survived as orphans (ppid 1) and finished on their own; nothing signalled them. After relaunch: no resend, same incarnation and counts, no new provider process. Banners say "RepoPrompt quit unexpectedly while this session was working. Sending to it is paused until you confirm the previous run has stopped", "Turn interrupted · RepoPrompt quit unexpectedly during this turn" and "Message may have been delivered" (wording distinct from the normal-quit "RepoPrompt was quit during this turn").
- **Kill right after Return (~0 ms):** draft preserved exactly, no intent, nothing sent.
- **Kill 0.25 s and 0.7 s after Return:** a committed `queued` intent with the composer cleared and no attempt. After relaunch nothing auto-sent; the banner reads "Saved message, not sent · It was saved before RepoPrompt closed and was never handed to the agent" with View / Edit / Remove / Dismiss. Edit restored the exact text to the composer and withdrew the intent; still nothing sent.
- **Kill 2 s after Return (dispatching cut):** one attempt and one run attempt recorded without a terminal, alongside an older queued intent. After relaunch: no resend, plus "Run interrupted before it was saved · A run started but its turn was not saved before RepoPrompt stopped. Its output may be missing."
- **Not claimed:** exact intent/ack/drain boundaries (timing only), process-registry adoption or stop of the orphaned Claude child (gated), crash during Stage A/B quit.

### Injected shutdown failure (2026-10-25, owner-approved)

Fault: `chmod 555` of only `AgentRecovery/v1/sessions` for about 40 s (restored to 755 by a shell trap), with unsaved composer text, then a normal Quit.

- **Quit blocked, app usable: PASS.** The app showed "RepoPrompt couldn't save everything before quitting" with the T7 session, the message-box save failure (raw `AgentRecoveryStoreError.storageFailure` text including the `mktemp` / `Permission denied` detail) and "Nothing was stopped or closed. You can keep working, or try again." with Cancel and Retry. The app stayed running and the composer text stayed in the UI; the persisted record kept its older text during the fault.
- **Retry: PASS.** After permissions were restored, Retry flushed the pending text (all of it, including what was typed during the fault) to the record and the app quit; relaunch worked.
- **Finding (cosmetic):** the user-facing dialog exposes the raw Swift error description.
- **Not claimed:** which shutdown stage (A or B) failed, a failure after providers were stopped, or a storage fault during an active run.

### Exact crash cuts by debugger (2026-10-25, owner-approved, Claude)

The debug bundle has no hardened runtime, so `lldb` attaches to the installed app without a prompt and file:line breakpoints resolve. A breakpoint command sent `SIGKILL` to the app the moment it was hit; nothing else was changed. Session T10 is synthetic.

| Cut | Breakpoint | Disk at kill | After relaunch |
|---|---|---|---|
| Queued written, before receipt | `AgentRecoveryStore.swift:747` (`commitQueuedIntent`) | intent `queued`, composer consumed, no attempt | unchanged; "Saved message, not sent"; no resend |
| Run attempt recorded, before dispatch | `AgentRecoveryQueuedInput.swift:252` | intent `queued`, open run attempt, no delivery attempt | unchanged; crash hold plus "Run interrupted before it was saved"; no resend |
| Dispatching written, before handoff | `AgentRecoveryStore.swift:870` (`beginDispatch`, after `rewrite`) | intent `dispatching`, one attempt | unchanged; "Message may have been delivered" (conservative: the provider never saw it); no resend |
| Stage A, after the unclean mark | `AgentLifecycleShutdownCoordinator.swift:584` | `launch-state` `shutdownInProgress`, draft on disk | treated as unclean; draft restored exactly |
| Stage B, before the clean mark | `AgentLifecycleShutdownCoordinator.swift:776` | `launch-state` still `shutdownInProgress` | treated as unclean; draft restored exactly |

No provider process was started after any relaunch. Line 868 resolves to `attempts.append`, before the durable `rewrite`, so it reproduces the second cut rather than the third.

### Scheduled follow-up, same app session (2026-10-25)

- A follow-up scheduled in an idle composer-created Claude session fired on time without a restart, then failed in about 130 ms. The scheduled intent was withdrawn; the schedule went to `failed` with "The agent runtime changed before the scheduled message could be sent."; the banner showed "Delivery unconfirmed · …". The previous, completed turn was rewritten to `failed` with an appended "This message was not sent because its delivery could not be recorded. It stays saved." The new turn stayed `running`.
- **Finding (product bug, unfixed):** the text is the nil-outcome fallback of `scheduledNotAcceptedMessage` (`AgentModeViewModel+ScheduledSend.swift`), not an identity check. `finishMandatoryScheduledDispatch` treats Claude's normal nil send outcome plus no dispatch evidence as non-delivery. It withdraws the intent even though a run was started. No test covers a nil outcome with a failed Claude run.
- MCP-created sessions cannot schedule (`canScheduleSend` requires no MCP control); this is by design.
- The earlier "Send now does not dispatch after a restart" finding is still unisolated. The most likely cause is the new-session recovery gate, which ignores Run alongside while any unresolved recovery exists in the workspace.

### Queued behind a running command, Codex (2026-10-25, partial)

- In a composer-created Codex session, an MCP `agent_run` steer sent while a `/compact` command was in progress returned "Queued to start". It persisted as a `queued` intent and drained exactly once afterwards (`providerAccepted`; reply `QUEUED`).
- That command's run ended `userCancel` within milliseconds, and the next `/compact` answered "Start a Codex conversation before using /compact." although the thread existed (finding, not isolated). So this proves run-admission queueing, not Codex `queuedFallback` / `nonSteerableTurn(.compact)`.
- A composer message typed during compaction did not submit.

### Codex resume from the composer after a restart (2026-10-25)

- **PASS.** After a normal quit and relaunch, a composer message in the Codex session was accepted once. It answered "QUEUED; lighthouses.", which needs both earlier turns, so the thread context survived. Nothing was re-executed.
- A later attempt to quit during a running Codex turn did not finish within 30 s; `dev-launch-existing` then stopped the app mid-shutdown. Recovery classified it as `appCrash`, with no resend. The Codex app-server and its command died with the app. That makes `resumedThreadActive` (the only reliable live trigger for Codex `queuedFallback`) unreachable here, because no Codex thread outlives the app.

### Full-root gate failure attribution (2026-10-25)

`MCPCodeStructureWorktreeTests.testRetainedProjectionPreloadStopsAfterIndexAdvanceAndForegroundRecoversOnce` fails at line 1805 (`XCTUnwrap`) in a clean detached worktree both at `d971983b` and at `5507c3fa`. `5507c3fa` is the commit that last changed that test, and it predates every restart-series commit. The failure is therefore not caused by the restart work or by the local uncommitted codemap helper.

Still unverified: Codex `queuedFallback` live (covered only by `CodexFallbackFIFOTests` and `AgentModeRunServiceLifecycleTests`), quit during an active Codex turn via the sheet (its buttons were not inspected), process-registry adoption or stop of orphans (gated), and recovery actions (gated off). Local journal: `.agent-artifacts/lossless-restart-ordinary-acceptance/lifecycle.json`.

## Candidate identity (packaging evidence, not live acceptance)

Scratch bundle, still unlaunched:
`/var/folders/05/h5dklt3s7nnbc4kf4r_153_40000gn/T/rpce-prelive-pkg.nX1Ney/RepoPrompt.app`.

It is temporary and may be removed by system cleanup. Rediscover and verify it before reuse; do not copy over the running app. A later acceptance candidate must be explicitly selected again.

- Source HEAD: `e7ac41e44ca8ce0d07034fd93b339a0d960ef300`; provenance `dirty: true`, debug/`Onone`, build epoch `1792838152.229955`.
- Before evidence edits, SHA-256 of `git status --porcelain=v1`: `327eab669760262d43e0ca8c95a587bed84690d85f98e52109ba573c3abeef3c`; SHA-256 of `git diff --binary HEAD`: `5474609406db94b40ec9893fab9379b06ac34c3238c823356b22fa7c77251089`. These identify the recorded dirty tracked inputs/status, not contents of every untracked file.
- Dirty paths are listed in the validation report. No production Swift was dirty; the root test artifact includes the modified codemap helper. This is not clean-HEAD full-suite acceptance.
- `Contents/MacOS/RepoPrompt` SHA-256: `081609c4d84c84e7299da9c05e45e055c9e4dda84f45c2eb6e14f0dd3f0ba98c`.
- `Contents/MacOS/repoprompt-mcp` SHA-256: `6f9fd118e052d8645b295d9fea7c6a7915fed69fd3efa189cef81f7fe6fa7329`.
- `Contents/Resources/RepoPromptDebugProvenance.json` SHA-256: `55fd48b20ef05436d6b99a735f8fa177b54e9f8a7cafd9880fae533b9116877b`.
- Apple Development signature, authorized team `AM9B9Y6HBV`, debug bundle ID `com.pvncher.repoprompt.ce.debug`; no identity or release metadata change. Package cache reuse was unavailable; normal signing and full checks passed.
- The packaging compatibility link was restored to its previous target. Main checked that link and PID 8017 afterward. The live bundle was not the package destination.

## Minimal owner work and external driver

1. Use the existing daily account and the already-running Pi coordinator in Terminal **outside CE**. No new account, login migration or credential copying is needed.
2. Diagnose the remaining test failure without modifying unrelated owner work. Select and verify the exact current candidate before any bootstrap launch; do not package over a running bundle.
3. Prepare distinctly named synthetic sessions, drafts, attachments and queued messages through supported app paths. Record exact payloads and identities outside CE before the acceptance quit. Do not inject records into live stores or send unrelated provider work.
4. Obtain explicit approval immediately before the identified normal quit/relaunch. Exercise the app's ordinary quit pipeline, not a force-stop. If quit fails, is cancelled or remains pending, report and stop rather than escalating to a kill. Use coordinated launch after confirmed exit.
5. Verify exact restoration and no automatic resend. Use available computer use for actual UI checks; if unavailable, ask only for the UI actions that the CLI cannot exercise. Crash cuts, storage faults, survivor signalling and gated recovery actions are separate work.

Claude.app and ChatGPT.app were present in the daily account; Codex.app was absent at the checked Applications location. No dedicated computer-use tool is available in this main session. During acceptance, native System Events accessibility and window-scoped screencapture were verified usable; temporary screen-lock interruptions were resolved before the completed ordinary cycle. App installation alone does not establish automation access. Do not promise zero manual UI work or use a CE-hosted child as the sole coordinator across CE termination.

**Protect existing daily state while testing the daily app.** Only the freshly approved lifecycle operation may stop/relaunch it. Confine acceptance mutations to synthetic data; do not overwrite existing drafts, inspect credentials, or replace a running bundle. No CLI-link installation is needed. If destructive tests later use a separate account, keep all mutable paths account-local: conductor's so-called machine locks are per UID and cannot serialize cross-account writes to shared destinations.

The CE CLI is `rpce-cli-debug`, not production `rp-cli-debug`. Resolve the actual account-local executable rather than guessing a bundle filename: the debug install script points that command at `Contents/MacOS/repoprompt-mcp`. Verify its identity/version before use. Do not run the installer against the global link.

### Copyable brief for the external driver

> Do not call ask_oracle or ask_user, do not use context_builder with response_type review or plan, and do not start other agents. If you have a question or want a second opinion or a review, stop and report back to the main agent.
>
> Read this handoff and the linked validation evidence. Coordinate from Terminal outside RepoPrompt CE in the existing daily account; a disposable account is not a prerequisite for normal quit/relaunch checks. Verify the exact candidate and CLI paths and process identity. Use only synthetic acceptance sessions/payloads, not unrelated owner conversations or credentials. Do not edit persisted stores, enable production gates, install shared links or push. Obtain fresh action-boundary approval before each visible lifecycle operation. Use normal quit, never force-stop or a kill fallback. A bootstrap into the current candidate is not that candidate's preservation test: prepare its synthetic state before the subsequent acceptance quit/relaunch. Persist the next action before an approved lifecycle operation and results afterward. Reobserve after interruption; never blindly retry a send or restart. Gated recovery, deliberate crashes and injected failures remain separate and unverified. Return compact evidence and unresolved items.

## Isolation and testability prerequisites

Verified source anchors:
- UID-namespaced MCP socket and user-domain Application Support: `MCPFilesystemIdentity.swift:133–147`; socket ownership checks: `BootstrapSocketOwnership.swift:77–98`.
- Registry process UID/birth identity and marker/lineage inspection: `ProcessInspection.swift:4–18,168–169`, `AgentProcessRegistry.swift:383–445`. Cross-account unreadability is unknown, not stopped. Do not import another account's runtime records.
- Relaunch target is the current bundle and its bundled helper: `AppRelaunchCoordinator.swift:193–206`; helper validates parent containment: `ProcessRelaunchHelper.swift:560–580`.
- Per-UID conductor locks: `Scripts/conductor.py:1913–1915`; global/user CLI link chain: `Scripts/install_debug_cli.sh:5–10`.

A disposable account is an **optional isolation choice for destructive fault tests**, not a prerequisite for ordinary quit/relaunch preservation. A second app copy with only a temporary workspace still shares per-user stores and is not isolation. Before any separately approved destructive case, choose a proportionate isolation method and verify actual store, history, socket, helper and bundle paths.

Two prerequisites remain unmet for their respective advanced scenarios, not for ordinary preservation checks:
1. **Whole-app qualification composition.** Component injection exists, but the app composition does not inject action qualification; VM677 and launch authority85 independently use production registry/qualification, and the window manager uses the default relaunch coordinator. No executable whole-app acceptance entrypoint was found. A later narrowly scoped candidate must cover these real paths consistently; changing a test flag is not proof.
2. **Exact crash/failure boundary control.** Store FileOperations and lifecycle Environment failure injection are XCTest seams. No installed-app control for every intent/ack/drain/reservation cut or Stage A/B failure was found. Sleeps or unverified debugger recipes cannot establish exact crash cuts. Review only the smallest control needed by the selected scenario; do not build a new framework now.

Normal-build production qualification remains empty/off. An isolated candidate may test an explicitly labeled hypothesis, but `supportsCompleteDiscovery=true` is then an experimental input, not observed evidence. No fixture or subset capture qualifies production.

The armed-helper policy is already resolved by Step 4c, commit `cb15d40f`: the narrowly admitted Stage B safe-restart choice is **Exit — may reopen**, with a matching request/attempt pre-arm witness. Main read coordinator888–905. Do not reopen O14; verify this policy live later.

## Ordered live checklist (bounded ordinary cycle passed; advanced rows pending)

| Order | Scope | Expected evidence / stop point |
|---|---|---|
| Bootstrap | **PASS:** approved old-build normal quit, current packaging and launch with gates off | Bound current candidate, not counted as pre-quit preservation acceptance. |
| Ordinary preservation | **PASS, bounded:** two distinct drafts and one managed image across normal quit/relaunch, with persisted and UI comparison | Exact identities/content/image bytes; no synthetic sends. Queued input, tagged-file/non-default workflow variants and running turns remain untested. |
| Discovery prerequisites | Real shims, actual app permissions/MCP/hooks, foreground/background tools, markers and complete discovery | Requires a reviewed real-path candidate and evidence for each supported pair. Missing access or one failed pair leaves coupled activation off. |
| Claude | Foreground tool then new tool; background child; unanswered stdio permission; in-flight CE MCP; startup hooks; dangling tool-use resume; fresh session-ID compatibility | Exact new-session identities, owned descendants and native history; no transfer of another profile's qualification. |
| Codex | Command in progress, then thread resume | Correct thread/turn association and no duplicate command; require actual interrupted app path. |
| Intent/delivery crash cuts | Before commit; commit-before-ack; ack-before-drain; direct Send; scheduled transfer | Respectively no success ack; one recoverable intent; full payload; held/unknown delivery; no duplicate. Exact cuts need verified boundary controls. |
| Other crash cuts | Mid-stream; quit Stage A; quit Stage B; reserved-before-identity | Honest interruption/staleness and unresolved ownership. Distinguish a failed/cancelled Stage A (app remains usable) from a killed process, which cannot remain usable until relaunched. |
| Shutdown failures | Stage A failure → Cancel → interact → quit; Stage B failure → Retry flush | Preservation and truthful failure UI. Existing unit seams do not prove live fault control. |
| Survivor/helper | Let finish/watch; explicit stop; uncertain armed helper | Signal only approved owned PID/birth identity, never by name; verify the already-decided uncertain-exit policy. |
| Recovery UI | Continue; Edit first; Send saved; answer as new input; reconciliation; fresh conversation | No automatic resend; same saved-message ID/chronology; failed send remains unsent at current end. CLI success does not prove button/accessibility behavior. |
| Preservation UI | Draft/attachments/queued input, historical question/edit review and child links, busy scheduled sends | Exact restored payload and honest historical/uncertain state; no replay of expired continuations or review application. |
| Final lifecycle/performance | Restart safely; Cmd-Q with several sessions; five-active-session quit, typing and commit latency | Approved actual app lifecycle, click counts and measured method. Targets remain advisory on this shared host, not fabricated from fixtures. |

Supported-pair source inventory (13, **not credentials or live coverage**): native standard Claude; compatible GLM/Kimi/custom; headless standard/GLM/Kimi/custom; Codex app-server and exec; ACP OpenCode/Cursor/Oh My Pi. Authority: `AgentProcessRegistrySupport.supportedPairs`, `ClaudeCodeRuntimeVariant`, `ACPProviderID`. Do not narrow this set or activate only a subset without a separate owner-approved design change.

## Restart-resilient evidence without new tooling

Use ordinary account-local files outside CE Application Support, not a new service. For each scenario record: candidate revision/dirty inputs, executable+helper hashes, UID, PID/start/path, approval scope, synthetic inputs/expected IDs, last completed operation, next permitted operation, observations and pass/fail/blocked result. Write intended action first and outcome afterward. A missing outcome is unknown, never an invitation to repeat an action. Rebind after every launch and reobserve after coordinator disconnect.

Keep raw process/history/protocol captures private, minimal and bounded; publish only sanitized evidence. Never record auth values, full environments, existing conversations or unrelated window titles. After all required live rows pass, production activation is a separate reviewed source decision and validation—not an automatic effect of this checklist.

## Guidance and scope decisions

[OracleA](pre-live-guidance-oraclea.md) and [OracleB](pre-live-guidance-oracleb.md) independently accepted the earlier non-lifecycle stopping boundary after source-audit corrections. Their historical guidance is retained, but the owner's 2026-10-24 correction supersedes making disposable-account setup mandatory. Proceed with ordinary daily-app preservation acceptance and an external Terminal coordinator; reserve isolation decisions for destructive tests. No blanket crash permission, clean worktree solely for ceremony, new tooling, or assumed external-app computer-use capability.

Maintainer-guidance check: protect daily user state; source/tests establish current behavior, while actual runtime ownership and fresh native history remain the authorities. Build mismatch is directly observed; full-suite failure attribution is unresolved. Keep operations observable via conductor tickets and the external driver's plain evidence file. This handoff records bounded ordinary live acceptance, not completion of advanced qualification or the full lossless-restart spec.
