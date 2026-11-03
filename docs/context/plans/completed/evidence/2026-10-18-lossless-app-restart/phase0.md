# Lossless app restart — Phase 0 evidence (measure and prepare)

Scope: read when the task touches lossless-restart Phase 0 evidence: the `save.session.written` diagnostic, transcript save starvation or large-session save cost, the session-incarnation authority, the send/acknowledgement route inventory, or eager provider spawn at hydration.
Authority: Reference
Last-verified: 2026-10-20

Evidence for Phase 0 of [the lossless app restart spec](../../2026-10-18-lossless-app-restart-spec.md). It does not change the spec. Status, owner decisions, and any spec amendment belong to the plan owner.

**What this is, and isn't:**
- It is bounded, advisory fixture evidence. It comes from XCTest runs against temporary storage in a debug build on one development machine.
- It is not live acceptance. Live sampling of the new field is **pending**: the instrumented build was not installed or run as the app.
- Real-app crash tests are **deferred** (O3, 2026-10-20). Nothing here substitutes for them.
- No app was launched, stopped, or restarted. No live Application Support data was read or written.
- No product behavior changed. The new code is DEBUG-only diagnostics plus tests.

## 1. `save.session.written` instrumentation

**Where:** `AgentSessionDataService.saveAgentSessionLocked` (`Sources/RepoPromptAgentCore/AgentMode/Runtime/AgentSessionDataService.swift`).
- Clock marks are at `:1978`, `:1990`, and `:1997`.
- The commit-point call is at `:2003`, immediately after `try await diskWriter.enqueueAndWait` at `:1999`.
- The recorder is `recordFullSessionWrittenDiagnostics` at `:2043`.

**What it records:** one counter `save.session.written` (global, plus `.tab.<composeTabID>`) and one event with these fields:

| Field | Boundary |
|---|---|
| `prepare` | Around `Self.sessionPreparedForStorage`, on the data-service actor |
| `encode` | Around `AgentSessionDataCodec.encodeSession`, on the data-service actor |
| `writerAwait` | Around `await diskWriter.enqueueAndWait`: **awaited writer latency**, including queueing and coalescing; not disk-only time |
| `duration` | Event-scoped: from the `prepare` start until the writer returns, i.e. the sum of the three measured phases. It is not `save.session.complete`'s `duration`, which runs from VM save entry. A rename was suggested (B P3-4) and deferred |
| `bytes`, `itemCount`, `turnCount`, `transcriptReset` | Encoded byte count, persisted counts, and whether the save committed a transcript reset |
| `sessionID`, `tabID` | Short IDs only. No content, paths, prompts, or attachments. `tabID` and the per-tab counter come from the persisted `composeTabID`. When it is nil, only the global counter increments; when it differs from the VM tab, the per-tab counters do not join by VM tab identity. Use `sessionID` as the join key where available (B P3-5) |

**How it is gated and when it fires:**
- Everything sits inside `#if DEBUG`, including the clock reads.
- Timing capture starts only when `AgentModePerfDiagnostics` is enabled. Later marks follow that captured start, so emitted events have a complete timing split.
- It is recorded at the commit point: after the atomic writer returns, and before schedule/reset authority updates and the metadata-index upsert.
- Thrown errors propagate unchanged. Save order, signatures, actor isolation, and formats are unchanged.
- Timestamps use the recorder's existing convention, `CFAbsoluteTimeGetCurrent` (wall clock, not monotonic), and existing formatting.

**What the measured window excludes (B P2-1):** the event measures only `prepare`, `encode`, and `writerAwait`. Other data-service work for the same save falls outside it:
- waiting in `acquireSessionPersistence`;
- the folder and stamp checks;
- `cachedOrLoadedScheduleAuthority`, which can parse the whole session JSON on a cold save;
- applying the schedule authority;
- `rememberScheduleAuthority`;
- the metadata-index upsert.

The measured phases are therefore **not** the actor's full occupancy for a save.

**Writer contract, as read:**
- `AgentSessionDiskWriter` coalesces per URL: a newer payload replaces an unwritten older one.
- Every waiter resumes after the drain, with the result of the last write.
- A successful return therefore means the URL's latest queued payload was atomically replaced (`Data.write(.atomic)`). That payload can be newer than the caller's, and the write is not fsync-durable.
- Full saves and scheduled-send mutations both take `acquireSessionPersistence` (`:2584`), so coalescing between full saves for one session is not expected.
- **Shared-writer audit, deferred to Phase 1a planning (B recommendation 4):** load rewrites (`commitLoadedSessionStorage`, `:1742`) and the metadata-recovery migration rewrite (`:2756`) use the same `diskWriter` URL. Whether they hold the per-session gate was not audited.
  - If they don't, a full save could return success after a rewrite replaced its payload.
  - `save.session.written` would still count that save, and the VM would mark the session clean.
  - Flush-before-teardown would rely on that success.

**Deliberately not counted:**
- the `.resetAlreadyCommitted` early return (`:1916`), which writes nothing;
- stale-generation and stamp throws before encoding;
- encode or writer failures;
- scheduled-send mutation writes (`performScheduledSendMutation`, write at `:2193`);
- accepted-send finalization (`finalizeScheduledSend`, write at `:2558`);
- hydration storage rewrites (`commitLoadedSessionStorage`, `:1742`);
- metadata-recovery migration rewrites (`:2756`).

**VM-side events already present** (`Sources/RepoPrompt/Features/AgentMode/ViewModels/AgentModeViewModel.swift`): `save.schedule` and `save.schedule.replaced` (`scheduleSave`, `:14074–14098`); `save.session.invoked` (`:14194`); skipped, error, and stale events; and `save.session.complete` (`:14667–14678`), whose `duration` is elapsed time from save entry.

**`save.schedule.replaced` caveat (B P3-1):** it is computed as `saveDebounceTask != nil` (VM `:14085`).
- In normal flow nothing clears the handle after the debounced save runs, and flushing cancels the handle without clearing it.
- It is cleared only in the removal final-save path (VM `:13937`) and the stale-reset recovery paths (`AgentModeViewModel+StaleResetRecovery.swift:147`, `:822`).
- So after a tab's first schedule, the counter counts every schedule. It is **not** evidence that a pending save was replaced.
- Starvation conclusions rest only on `save.session.invoked` and `save.session.written`. Live-sampling readers should treat this counter the same way.

## 2. Fixture evidence

### Tests

All four are in `Tests/RepoPromptTests/AgentMode/AgentStaleResetOwnershipTests.swift`. They reuse that suite's `makeHarness`, whose storage is a fresh `FileManager.default.temporaryDirectory` subfolder that is deleted at teardown.

| Test | Kind |
|---|---|
| `testFullSessionWrittenDiagnosticCountsOnlyCommittedWrites` (`:2003`) | Always runs (contract) |
| `testFullSessionWrittenDiagnosticSkipsStaleResetRejection` (`:2055`) | Always runs (contract) |
| `testRestartPhase0LongTextOnlyStreamSaveTimelineReport` (`:2090`) | Opt-in report, about 13 s |
| `testRestartPhase0LargeSessionSaveCostReport` (`:2165`) | Opt-in report, one reference-size session (1,500 source items), about 9 s |

**Opt-in mechanism:** the reports reuse the existing conductor-forwarded gate `RPCE_RUN_SCALE_TESTS=1`. No new environment key, marker file, or tooling was added. They print `[RestartPhase0]` lines to the conductor job log and have no thresholds. All four appear in `make dev-test-list`.

**Retained scope:** the large-session report keeps only the 1,500-item reference size. An earlier 6,000-item case was **removed from the retained test**: it took about 100 s, close to conductor's 180 s per-method deadline. Its one observed run is kept below as historical evidence only.

### Counter contract (always runs)

The counter counted each successful full save exactly once, including the peer's reset save (`transcriptReset=true`). It counted nothing for:
- a clean save skipped before the data service;
- a writer failure: the sessions folder was made read-only and atomic `mktemp` failed with EACCES, Cocoa error 513. A retry after restoring permissions counted once;
- the owner's save rejected by the stale reset-generation fence.

### Long text-only stream (opt-in report)

**Method:**
- The harness session is current and idle; no runner or provider is involved.
- The test calls `enqueueAssistantDelta` every 100 ms for 12 s, sampling the tab counters after each sleep (about 100 ms resolution) and once more after the loop.
- Each 250 ms buffer flush mutates a source item, and `onSourceItemsChanged` calls `scheduleSave` (`AgentModeViewModel.swift:4039–4047`). That cancels and re-arms the 1 s debounce.
- **After the review fix (A P2-01, B P3-3):** the report waits until the atomically replaced session file contains the final chunk, polling the file every 10 ms. The condition is satisfied immediately if a write already landed. No save is forced, so the experiment is unchanged. A write between the last in-loop sample and the end of the stream is reported separately (`writtenAfterLastSample`) and is not given a stream offset.
- Runs 1–2 used the earlier wait, which required one more write after the last loop sample.

| Metric | Run 1 | Run 2 | Run 3 | Run 4 |
|---|---|---|---|---|
| Wait condition | next write | next write | final text on disk | final text on disk |
| Stream length / chunks | 12.00 s / 114 | 12.00 s / 114 | 12.00 s / 115 | 12.00 s / 114 |
| `save.schedule` during the stream | 38 | 38 | 38 | 38 |
| `save.schedule.replaced` during the stream (see the caveat in §1) | 38 | 38 | 38 | 38 |
| `save.session.invoked` during the stream | 0 | 0 | 0 | 0 |
| `save.session.written` during the stream (in-loop samples) | 0 | 0 | 0 | 0 |
| Write after the last sample, before the stream ended | not sampled | not sampled | 0 | 0 |
| Longest unsaved window (in-loop samples) | 12.01 s | 12.05 s | 12.08 s | 12.02 s |
| Observed after the stream ended | next write at 0.97 s | next write at 0.96 s | final text on disk at 1.16 s; 1 write | final text on disk at 0.97 s; 1 write |
| Final file contains the last chunk | yes (2,935 bytes) | yes (2,935 bytes) | yes (2,945 bytes) | yes (2,935 bytes) |

**Reading:**
- In this fixture, a session whose text keeps arriving faster than the debounce is never invoked or written while the stream lasts. The final text reaches disk only after the stream stops. This supports R3's maximum wait.
- The conclusion rests on `invoked = 0` and `written = 0`, not on the `replaced` counter.

**Limits:**
- These are synthetic deltas, not a provider stream.
- `scheduleSave` callers only re-arm the same timer. Direct `saveSession`/`saveSessionDetailed`/`flushSave` callers during a real run (for example dispatch-attempt saves) were **not inventoried**, so real runs may write during a stream (B P3-2).
- The stream length was capped at 12 s. Behavior beyond that is inferred from the code.
- "Observed after the stream ended" is a polling observation, not an exact quiet-write latency. It stacks the last 250 ms buffer flush, the 1 s debounce, the save itself, main-actor scheduling, and the poll interval. The stream end is itself the end of a sleep that can resume late.
- Offsets come from wall-clock `Date()` differences at the sampling resolutions above.

### Large-session save cost (opt-in report)

**Method:**
- The fixture is deterministic and synthetic, with four items per turn: a user item (about 0.2 KB), a bash tool call, a bash tool result (about 1.5 KB of output), and an assistant item (about 0.7 KB).
- 1,500 source items (375 turns) are installed with one `replaceItems`.
- Then there is one cold save, followed by 5 repetitions of "append one assistant row, then `flushSave`".
- All saves go through the real VM save, preparation, codec, and writer.

**Steady state, retained 1,500-item test** (5 repetitions per run; persisted rows 1,119–1,123; 906,119–907,430 bytes). "Measured phases" means `prepare + encode + writerAwait` (the event's `duration`); the test now prints it as `measuredPhases`.

| Run | `prepare` | `encode` | `writerAwait` | Measured phases | `vmTotal` |
|---|---|---|---|---|---|
| 1 | 20.6–22.4 ms | 9.1–9.8 ms | 1.0–1.1 ms | 30.9–33.3 ms | 34.3–36.8 ms |
| 2 | 25.4–28.0 ms | 9.7–10.4 ms | 0.9–1.3 ms | 36.2–39.3 ms | 40.8–44.4 ms |
| 3 | 20.8–22.0 ms | 9.7–10.1 ms | 0.9–1.5 ms | 31.9–33.2 ms | 35.4–37.2 ms |
| 4 | 20.8–21.9 ms | 9.1–9.4 ms | 1.3–1.6 ms | 31.3–32.8 ms | 34.6–36.7 ms |

**Cold first save, 1,500 items:**

| Run | Install (`replaceItems`) | First save wall time | First save measured phases |
|---|---|---|---|
| 1 | 5.347 s | 0.217 s | 34.9 ms |
| 2 | 6.887 s | 0.324 s | 41.5 ms |
| 3 | 5.160 s | 0.221 s | 34.6 ms |
| 4 | 5.163 s | 0.224 s | 34.9 ms |

**Historical only: the 6,000-item case, removed from the retained test** (one run before the scope cut; 1,500 turns; persisted rows 4,494–4,498; 3,580,276–3,581,447 bytes):
- Steady state: `prepare` 76.8–77.9 ms, `encode` 34.8–35.2 ms, `writerAwait` 1.7–5.3 ms, measured phases 114.1–117.6 ms, `vmTotal` 124.0–127.0 ms.
- Install 81.590 s; first save wall time 2.629 s; first save measured phases 122.2 ms.
- This case can't be reproduced from the current test without editing it.

**How to read these numbers:**
- `prepare` and `encode` run on the `AgentSessionDataService` actor. They are **not** main-actor serialization time.
- `vmTotal` (`save.session.complete`) is elapsed time from VM save entry. It includes suspension across the data-service await and the index update, so it is **not** isolated main-actor cost.
- In the steady state, `vmTotal − measured phases` (about 3–6 ms at 1,500 items) bounds everything outside the measured phases, combined. That includes unmeasured data-service work (gate wait, schedule-authority load, metadata-index upsert), VM work, and actor hops.
- The cold first save spends about 0.18–0.28 s outside the measured phases at 1,500 items. That time includes unmeasured data-service work, possibly a cold `cachedOrLoadedScheduleAuthority` parse of the whole session JSON plus the index upsert, as well as VM snapshot and transcript building and suspension. None of it was attributed further.
- Run-to-run variation on the same machine was about 15–20%: measured phases were 31–33 ms in runs 1, 3, and 4 versus 36–39 ms in run 2. The numbers come from one debug build on one machine, with timings from wall-clock `CFAbsoluteTimeGetCurrent` deltas. Five repetitions per run are too few for a percentile; do not use them as a p95 or a threshold.
- `writerAwait` is temporary-folder latency on this machine, not fsync-durable time.
- Fixture install time is fixture cost, not save cost. It was not investigated.
- The fixture has no images, reasoning, or compaction history.

**For R3 tuning:** at the spec's reference size of about 1,500 items in this fixture:
- a periodic steady-state full save took about 31–39 ms in the measured phases (`prepare + encode + writerAwait`, on the data-service actor);
- `vmTotal`, from VM save entry, was about 35–44 ms.

Neither figure is the actor's full occupancy or isolated main-actor cost. Live sampling on the owner's Mac is pending.

## 3. Session-incarnation authority (spec R1): mismatch

R1 assumes there is an existing **durable** incarnation (reset/delete generation) to store in each recovery record. The code doesn't have one:
- `AgentSessionPersistenceStamp` is documented as "Immutable, process-local ownership" (`AgentSessionDataService.swift:21–35`). It carries `deletionGeneration` and a `serviceID` that is a per-instance `UUID()` (`:231`).
- Deletion and reset generations live in actor dictionaries: `deletionGenerationsByFileKey` and `transcriptResetAuthorityByFileURL` (`:269–276`). They default to `0` (`currentTranscriptResetGeneration` and `persistenceState`, `:1269–1290`).
- Stamp validation compares `serviceID` with the current service instance (`validatePersistenceStamp`, `:1291–1309`). A stamp can never survive a relaunch.
- A successful reset save advances only the in-memory authority (`:2017–2025`).
- Neither `AgentSession.swift` nor `AgentSessionMetadataIndex.swift` serializes any generation, incarnation, or tombstone field. `AgentSessionTranscriptResetReceipt` is an in-memory `UUID` wrapper.

**Consequence:** Phase 1b needs an explicit design decision for a durable incarnation. Phase 0 introduces no counter, serialized identity, migration, or tombstone. Amending R1 is the plan owner's call.

## 4. Send and acknowledgement route inventory

Each route is listed as: entry → queue/admission → provider handoff → acknowledgement. Paths are under `Sources/`. "VM" means `RepoPrompt/Features/AgentMode/ViewModels/AgentModeViewModel.swift`, "Codex coordinator" means `RepoPromptAgentCore/AgentMode/Runtime/Codex/CodexAgentModeCoordinator.swift`, and "RunService" means `RepoPromptAgentCore/AgentMode/Runtime/AgentModeRunService.swift`. Line numbers were spot-checked on 2026-10-20.

| Route | Path | Acknowledgement | Persisted before acknowledgement? |
|---|---|---|---|
| Shared submission (composer, MCP, remote) | VM `:9593–9686` decides the delivery: waiting continuation, follow-up queue, Claude/ACP interrupt queue, or Codex turn | `MCPInstructionDispatch` (`AgentModeViewModel+Types.swift:344–348`) and user-facing text (`:726–737`) | No |
| Waiting continuation | VM `:16469–16496` resumes `instructionContinuation` | `.deliveredIntoWaitingContinuation` | No (memory only) |
| Delivered signal after optimistic submit | VM `:16267–16268` → `signalMCPInstructionDeliveredFireAndForget` (`:6296–6342`) | MCP "delivered" | No |
| Follow-up queue | VM `:16522` appends to `session.pendingInstructions: [String]`; drained at `:19609–19620` | `.queuedFollowUp` | No (memory only) |
| Claude native send | `ClaudeIntegratedAgentModeRunner.swift:135` → `ClaudeAgentModeCoordinator.swift:1834` (`controller.sendUserMessage`) | Turn ID from the controller | No |
| Claude with images | VM `:16451–16460` cancels the run, then restarts with the attachments | Restart path | No |
| Claude steering | RunService `:1359–1382` dequeues `pendingClaudeSteeringInstructions` | `.queuedClaudeInterrupt` at enqueue | No (memory only) |
| ACP prompt | `ACPIntegratedAgentModeRunner.swift:648` (steering) and `:1629–1632` (`controller.prompt(…, onSubmitted:)`); the callback at `:1679–1700` fires at the real `session/prompt` write | `onSubmitted` stage | No |
| ACP steering | RunService `:936–972` batches `pendingACPSteeringInstructions` | `.queuedACPInterrupt` at enqueue | No (memory only) |
| Codex start, steer, retry | Codex coordinator `:4983–5026` (`controller.startUserTurn` and friends) | `.startAccepted` / `.steerAccepted` (`:5080–5082`, `:5106–5108`); a dropped fallback resolves `.startAccepted` (`:2232`). That drop is deduplication, not discard. `dropDeliveredClaimedCodexFallbackIfNeeded` (`:2216–2238`) fires only when the queued entry's MCP attempt ID is already in `codexDeliveredMCPFallbackAttemptIDs`. That set is filled only by `removeQueuedCodexFallbackForDeliveredAttempt` (`:2189–2193`) after provider acceptance of the same attempt (`:5074`, only when the accepted thread is still the persisted session thread; `:5103`). It is not a second false acknowledgement (B P2-3) | No local durable-intent prerequisite; acknowledgement is provider acceptance only |
| **Codex fallback (known bug)** | Codex coordinator `:2284–2302` appends to `codexFallbackQueue` | Resolves `.durablyQueued` (`:2286–2289`), then only schedules a save (`:2296–2298`) that doesn't contain the queue. The VM is a second producer: `.queuedFallback` → `.durablyQueued` (`:16422–16423`) | **No.** Reported durable while in memory only |
| Codex acknowledgement consumer | `CodexSteerAckTracker.swift:34–51` counts `.durablyQueued` as confirmed; VM consumer at `:9384–9390` | MCP dispatch | n/a |
| Scheduled send | `startAgentRun` outcome `.sent` / `.queuedFallback` stamps provenance (`AgentModeViewModel+ScheduledSend.swift:20`); `NativeSendOutcome.didSend` is true for both (Codex coordinator `:203`); the runner keeps ownership on fallback (`CodexIntegratedAgentModeRunner.swift:88`); failure text at `+ScheduledSend.swift:2177` | Schedule cleared on acceptance | Yes for the schedule and dispatch attempt; **no** for a fallback-queued payload |
| MCP outward metadata | `RepoPrompt/Infrastructure/MCP/Agent/AgentRunMCPToolService.swift:3873–3878` copies the `delivery` raw value | MCP result | Inherits the route above |
| Remote host | VM `:16333–16348` (remote start window picker / error) | Remote result | Local process ownership does not apply; R2's local intent-before-handoff requirement still applies |
| Headless runner | `HeadlessAgentModeRunner.swift:21–36` (initial message), `:74–80` (provider) | Run result | No |
| Other Codex starts | Codex coordinator `:2504` (fallback drain), `:3970` (replay); control `compactThread` at `:1604` | Accepted or failed | No |

**Follow-up entrypoint joins (read-only, after review):**

| Entrypoint | Join and acknowledgement |
|---|---|
| Remote Resend | VM `resendUndeliveredRemoteUserTurn` (`:15750–15818`) bypasses shared submission. It calls `remoteCoordinator.startRemoteSession` or `.steer` (`:15795–15807`), then independently clears `isUndeliveredRemoteSend` and the retained resend payload. The already-adopted matching start branch (`:15763–15777`) reconciles delivery without another send. Phase 1b must cover both outcomes. |
| Codex managed-auth replay | Codex coordinator `:3940–3984` calls `controller.startUserTurn` at `:3970–3976`, then records usage acceptance and successful-send handling. This is the existing “Other Codex starts” row. |
| Edit-and-resend | No Agent Mode edit-and-resend entrypoint was found in the scoped trace. `AgentMessageBubble.swift:357–395` renders the remote Resend button and read-only user content. The concrete `editAndResend` found is in the separate Oracle chat subsystem (`RepoPrompt/Features/Chat/ViewModels/Oracle/OracleViewModel.swift:3320–3363`), not an additional Agent Mode acknowledgement producer. |
| Claude `/compact` | VM `:15486,15513` routes through the command resolver at `:16969–16978`; the Codex resolver returns nil for non-Codex sessions (`CodexAgentModeCoordinator.swift:1495–1497`). Claude input therefore uses the existing native-send or steering route. There is no separately identified Claude compaction acknowledgement producer. |
| Child `agent_run` initial send | `RepoPrompt/Infrastructure/MCP/Agent/AgentRunMCPToolService.swift:1563–1594` passes parent identity into `startRun`; production wiring at `MCP/ViewModels/MCPServerViewModel.swift:852–874` reaches `MCP/Agent/AgentExternalMCPRunStarter.swift:242–261`, which uses `mcpDispatchInstruction` and returns the shared delivery classification. Child lineage adds no separate message acknowledgement here; durable parent/child linkage remains Phase 5. |

**Method and limits (A evidence assessment, B missing evidence):** this is a static inventory assembled by following queued/delivered acknowledgement producers, provider send/start/steer/prompt calls, shared entrypoints, and the four follow-up routes above. The main agent spot-checked the remote resend, external starter, non-Codex command guard, message-bubble, and fallback deduplication joins. It is not an executable proof that every possible route is covered. Direct `saveSession`/`saveSessionDetailed`/`flushSave` callers were not inventoried as a separate persistence census. Phase 1b must verify these joins against the then-current code before claiming every route has durable intents.

**For R2:** every message handoff, including directly accepted Codex sends and remote sends, needs a committed local intent before dispatch; rows marked "No" identify current gaps. Provider acceptance does not waive that prerequisite. The two Codex fallback producers must change together.

## 5. Hydration and eager provider spawn (`claude --resume`)

The trace, with VM line numbers:
1. Cold restore normalizes active run states to idle. `AgentSessionDataService+Restore` normalizes at `:712`, and `AgentSessionRestoreSupport.swift:61–68` maps active to `.idle`.
2. The restored state is installed at VM `:5700` (`session.runState = payload.normalizedRunState`).
3. `ensureSessionReady` (VM `:5838–5881`) defaults to `reconnectActiveProviders: false`. Its Codex and Claude reconnects are both gated on `reconnectActiveProviders && …isActive`.
4. Workspace-switch ensures are gated on `runState.isActive` for both Codex and Claude-native providers (VM `:3957–3962`).
5. If an ensure does run, `ClaudeAgentModeCoordinator.swift:642` and `:1210–1215` call `controller.startOrResume`. That reaches `startProcessIfNeeded` (`ClaudeNativeProcessSessionController.swift:789`), which appends `--resume <id>` (`:3233–3236`).

6. The unconditional workspace-switch call `scheduleProvisionalClaudeContextWindowResolutionForActiveSession` (VM `:3957`; `AgentModeViewModel+RuntimeMetricsUI.swift:61–86`) is not a writer.
   - It builds a process-environment snapshot and calls `ClaudeProvisionalContextWindowResolver.resolveUncachedConfiguredContextWindow` (`ClaudeProvisionalContextWindowResolver.swift:63–81`).
   - That reads Claude `settings.json` files through `ClaudeEffectiveContextWindowResolver`.
   - No Claude process launch and no `--resume` occur on this path (narrow read only).

**Static conclusion:** no unconditional cold spawn of `claude --resume` was found at hydration. Spawn needs an active run state, and cold restore normalizes that away. Phase 1's crash hold should **preserve the active-state gating**, because any future path that hydrates with an active state and `reconnectActiveProviders: true` would spawn. This was not verified at runtime.

## 6. Deferred and pending

- **Live sampling** of `save.session.written` and the existing save events on the owner's app: pending; the build was not installed.
- **Real-app crash and kill tests:** deferred (O3).
- **Main-actor serialization cost:** not isolated; it would need separate VM-side marks.
- **Spec inference "the terminal state written at quit is probably lost" (spec Evidence, Quit row): NOT VALIDATED (B P2-2).**
  - Static half only: there is no `flushSave`, `flushSaveDetailed`, or `saveSession` call in `AppDelegate.swift`, in `WindowStateManager.swift`, or in `prepareForWindowClose`/`prepareSessionForWindowClose` (VM `:3756–3837`).
  - Whether a pending 1 s debounce task completes before process exit was not observed.
  - That needs a quit test, which stays deferred with O3. Phase 1a's flush-before-teardown must not cite this inference as validated.
- **Shared-writer gate audit** for load/migration rewrites: deferred to Phase 1a planning (see §1).
- **Untested by-construction claims (B P3-7):** that `.resetAlreadyCommitted` is not counted, and that clocks aren't read while diagnostics are off. Both hold by construction. Tests are deferred.
- **Test placement (B P3-8):** the Phase 0 reports live in `AgentStaleResetOwnershipTests` to reuse its harness. Revisit when `Recovery/` suites exist.
- **Event-field naming (B P3-4):** the `duration` rename is deferred; the semantics are documented in §1.

## 7. Validation run (2026-10-20)

**After the review fixes** (the stream wait condition, the post-loop sample, `measuredPhases` labels, and test comments). The main agent independently checked completed conductor job `7c482463-c620-4083-b520-b4f6bf718579` for run 4: exit 0, 39 tests, no failures. Later route-inventory edits are documentation only:

| Command | Result |
|---|---|
| `RPCE_RUN_SCALE_TESTS=1 make dev-test FILTER='AgentStaleResetOwnershipTests'` (run 3) | Passed: 39 tests, 0 failures, both opt-in reports included |
| `RPCE_RUN_SCALE_TESTS=1 make dev-test FILTER='AgentStaleResetOwnershipTests'` (run 4, after the label rename) | Passed: 39 tests, 0 failures in 22.5 s (stream 13.0 s, large session 6.5 s). Conductor exec time 37.1 s |
| `make dev-lint` | Exit 0 (0/2084 files need formatting; SwiftLint strict clean) |
| `Scripts/check-agent-context` | Exit 0 after the two review files' Scope lines were given the required `read when the task touches` form. One pre-existing warning: `AGENTS.md` has 24 routes |
| `Scripts/test-check-agent-context` | Exit 0 (23 passed) |
| `make guardrails` | Exit 0 (the same warning only) |

**After the scope cut, before review (run 2):**

| Command | Result |
|---|---|
| `RPCE_RUN_SCALE_TESTS=1 make dev-test FILTER='AgentStaleResetOwnershipTests/testRestartPhase0'` | Passed: 2 tests in 21.9 s |
| `make dev-test FILTER='AgentStaleResetOwnershipTests'` | Passed: 39 tests, 2 opt-in reports skipped |
| `make dev-test-list` | Exit 0; lists all four new tests |
| `make dev-lint`, `Scripts/check-agent-context`, `Scripts/test-check-agent-context` (23 passed), `make guardrails` | All exit 0 |

**Earlier runs, before the scope cut:**

| Command | Result |
|---|---|
| `make dev-test FILTER='AgentStaleResetOwnershipTests/testFullSessionWritten'` | Passed: 2 tests |
| `RPCE_RUN_SCALE_TESTS=1 make dev-test FILTER='AgentStaleResetOwnershipTests/testRestartPhase0'` | Passed: 2 tests, 117 s, with the 6,000-item case |
| `make dev-test FILTER='AgentScheduledSendPersistenceTests'` | Passed: 34 tests |

A still earlier opt-in run, which built the fixture with per-item `appendItem`, hit the 180 s per-method deadline (exit 70) before printing anything. The fixture now installs with one `replaceItems`.

A release build to verify the `#if DEBUG` exclusion was not run. Every addition is inside `#if DEBUG` and calls only DEBUG-only `AgentModePerfDiagnostics` symbols, so a release build would fail to compile if one leaked.

## 8. Independent reviews and dispositions

The verbatim initial reviews are [OracleA](phase0-oraclea-review.md) and [OracleB](phase0-oracleb-review.md). Neither found a P0 or P1. Under the review policy, the P2/P3-only fixes were not re-reviewed.

| Finding | Disposition |
|---|---|
| A P2-01: the stream report waited for an extra write, not final-text persistence | **Fixed** in the test: it waits for the final chunk in the saved file, with no forced save (§2) |
| B P2-1: "data-service total" and "outside the data service" misattributed work | **Fixed** in the docs: "measured phases", with the exclusions listed (§1, §2); the test's printed labels were renamed |
| B P2-2: the quit-time lost-terminal-state inference was unaddressed | **Documented as NOT VALIDATED**, with only the static half recorded (§6) |
| B P2-3: the `:2232` dropped fallback might be a false acknowledgement | **Checked:** it is deduplication after provider acceptance of the same attempt, not a gap (§4) |
| B P3-1: `save.schedule.replaced` semantics | **Confirmed and documented:** the handle is never cleared in normal flow, so conclusions rest on invoked/written (§1, §2) |
| B P3-2: overclaim about other mutations | **Fixed:** direct save callers are marked as not inventoried (§2, §4) |
| B P3-3: race between the last sample and the stream end | **Fixed:** post-loop sample plus the final-text wait (§2) |
| B P3-4: `duration` key collision | **Deferred:** semantics documented (§1, §6) |
| B P3-5: `composeTabID` versus VM tab | **Documented:** use `sessionID` as the join key (§1) |
| B P3-6: status-line `assumed:` | Already handled by the plan owner's status edit |
| B P3-7: untested by-construction claims | **Deferred** (§6) |
| B P3-8: test placement | **Deferred** (§6) |
| B missing evidence: route completeness, provisional Claude resolution | **Follow-up traced** retry/resend, edit-and-resend, Claude `/compact`, and child starts (§4); retained static-evidence limits. Provisional resolution is not a writer (§5) |
| B recommendation 4: shared-writer gate audit | **Deferred** to Phase 1a planning (§1, §6) |
