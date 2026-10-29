# Agent Mode crash recovery and lossless restart

Scope: read when the task touches composer draft or queued-input persistence, durable send acknowledgement, quit or window-close preservation, the surviving-process registry, interrupted-turn state, delivery wording, the Needs Attention list, or Resume, Check, Reconcile and Continue after an app restart.
Authority: Authoritative
Last-verified: 2026-10-29

This feature is implemented and in production. Its completed plan, the per-step record and all review evidence are in [the lossless-restart spec](plans/completed/2026-10-18-lossless-app-restart-spec.md). Read it only when you need history; this page holds the durable facts.

## Activation
- `AgentRecoveryActivation.production` is `.claudeAndCodex`. It covers Claude Code (standard; native and headless) and Codex (app-server and exec). Every consumer reads that one value, and tests inject their own.
- Changing activation is a reviewed source change backed by live evidence. It is not a setting.
- **Allowed actions:** same-conversation resume and history reconciliation (Continue with text, Send saved message, a question answer as input, Reconcile only).
- **Off by owner decision:** Continue in a new conversation, fresh Claude conversations, fresh session IDs, and Restart safely.
- ACP and Oh My Pi keep their input and interruption data, but recovery for them stays context-only.

## Storage
- All recovery files live under Application Support `…/AgentRecovery/v1/`. Never edit them by hand.
  - `sessions/<sessionID>.json`: one record per session holding the composer, intents (every sent or queued message), run attempts, question snapshots and recovery decisions.
  - `runtimes/`: provider-process ownership.
  - `tombstones/` and `attachments/`.
  - `launch-state.json`: the launch instance and its clean-exit mark.
  - `ordinary-exit-settlement.json`: the one-time Step 11 marker.
- `AgentRecoveryStore` is the only writer. Writes are atomic, revision-checked, and keep members they don't know.
- Unknown schema versions and corrupt files are kept and shown as unknown; they are never overwritten.
- `Scripts/quarantine_fixture_workspaces.py` allowlists the `v1` entries. Update it whenever a new file is added there.

## Delivery states and quiet-by-default rules
- **Intents** move through `queued`, `dispatching`, `providerAccepted`, `deliveryUnknown`, `failed` and `withdrawn`.
  - An intent is committed before any handoff.
  - "Queued" needs a store receipt, and "accepted" needs affirmative provider evidence.
- **RepoPrompt's own interrupts count as acceptance (O49).**
  - A written message whose turn started, and which RepoPrompt itself then interrupted by steer, Stop, window close or quit, settles `providerAccepted`. It creates no row and no Needs Attention item.
  - **Claude:** a start (`startedTurnID`) is credited only by the first non-empty text block or tool call in a complete `assistant` envelope of that turn. It is never credited by the final `result` message or by a queued turn.
    - The CLI is launched without `--include-partial-messages`, so no `stream_event` payloads arrive.
    - Reasoning extraction is off (`ClaudeReasoningExtractionFeature.isEnabled == false`), so thinking-only output credits nothing.
    - The uncredited window is therefore everything before Claude's first visible output. On a reasoning-heavy turn that can be tens of seconds.
    - A steer's mark stays provisional until the interrupt is acknowledged. The interrupt is bounded by a 1.5-second control timeout.
    - Stop, window close and quit set a final teardown mark before the run detaches.
    - **Before first output (Step 12, gated acceptance).** A turn interrupted by RepoPrompt before it was credited as started settles `providerAccepted` only when all of these hold:
      - the interrupt was acknowledged;
      - a CLI-authored result, not one the controller synthesized, arrives for that turn;
      - the result reports the interruption itself;
      - it names that turn's outbound UUID (`user_message_uuid(s)`);
      - that turn was the only unresolved written turn, both when the interrupt was issued and when the result arrived.

      Anything else stays `deliveryUnknown`.
    - After such an acknowledged interrupt, the steer holds its own write for up to 1.5 s so that result can arrive first.
    - A turn with an acknowledged pre-output interrupt never gets an O49 mark later.
  - **ACP:** receipt evidence is kept per prompt. A prompt that overlaps another can never prove receipt.
  - **Codex** has no equivalent path.
- **Crash wording only after an unclean exit (O50).** "RepoPrompt quit unexpectedly" and "closed while sending" wording appears only when no run end was recorded. Otherwise the message reads "Not confirmed", and the not-sent text is neutral.
- **One-time settlement of old warnings (O51).**
  - At startup, before discovery, one pass settles older `deliveryUnknown` intents whose runs all ended with cause `ordinary` and no shutdown evidence.
  - It writes its cutoff before touching any record, carries that cutoff in every launch mark, and caps it at 2026-11-06. Anything dispatched later is never settled.
  - It marks the pass complete only when nothing failed.
  - Intents left from a user Stop recorded by an earlier build, or from runs with no recorded end, are deliberately left alone.

## Holds, processes and ownership
- Recovered intents become held input that needs one click; they never rejoin live queues.
  - The `previousInstance` hold is derived from the app-instance ID, never written.
- `AgentProcessRegistry` reserves a runtime record before spawn and marks it live before the first message. Process identity is boot session, PID, start time and UID; the launcher sets `RPCE_RUNTIME_ID`.
  - The registry records `writerPID`. Survivor rows show the process count, the launcher PID and the agent PID.
  - Denied inspection means unknown, never exited.
- **Two-writer rule:** no second managed writer while a recorded writer or launcher is alive, reserved or unverifiable.
  - A crash hold is released by Check (confirmed exit) or Let it finish. Nothing is signalled automatically.
- **Quit** runs in two stages within one 8-second deadline:
  - Stage A is reversible: freeze admission, commit records, flush sessions.
  - Stage B tears down.
  - A window close never marks the launch clean.

## Resume limits
- **Claude Resume and Reconcile** work only for sends whose outbound message identity matched exactly (O48). Identity is eligible only for the `automaticResolved` and `configuredOverride` command provenances on the default Claude backend.
- **Claude output import** is best-effort.
  - The history reader skips thinking blocks and known metadata attachments.
  - It refuses attachment types it doesn't know, such as `deferred_tools_record` and `silent_turn_reminder`.
  - If live output can't be safely matched to Claude's history, nothing is imported (`canonicalOutputImportWithheld`) and the card says so. Live tool rows other than Read carry random IDs and so can't be matched.
  - The durable fix would be persisting native `toolu_` IDs on live rows.
- **Codex** reads the newest turn with `itemsView: "full"`, retrying once without it if the field is rejected, and resumes on the same thread.
- **Continue and Check provider history** appear only while the session is open (U1, by design).

## Known gaps
- **Interrupt before first output, unproven live.** Gated acceptance needs the CLI to name the interrupted message's UUID on its interrupted result, and nobody has observed that yet.
  - If the CLI doesn't, a steer or Stop before first output still ends `deliveryUnknown`. That shows as a "Message may have been delivered" row with a "Not confirmed" bubble. The same applies to launches that send no outbound UUID.
  - Each such steer then also pays the full 1.5 s hold.
  - A live capture should record whether that result arrives, its shape, whether it is attributed, and how its timing compares with the 1.5 s steer hold and the 200 ms Stop window.
  - Only if rows still appear in practice, evaluate `--include-partial-messages`, with its own tests.
- **Quit or kill before first output.** If the process is gone before the CLI writes its result, the message stays uncertain.
- **FIFO attribution.** Claude output is credited to turns by queue position, not by user-message UUID. If the CLI silently skips a message (for example a duplicate UUID replayed through the shim), that message never gets a result, and every later turn's output is credited one turn early. No in-app path reuses a UUID, so this needs external replay.
- No route-level ACP Stop or quit test; ACP is covered at controller level.
- Claude teardown routes other than Stop, quit and window close (agent or model switch, MCP-health restart, session reset) record `deliveryUnknown` first, then refine it to accepted on an interrupt acknowledgement.
- After a second kill, an orphan tool result can show as a duplicate row.
- If the app is force-killed after Stage A of a quit, the crash wording is lost.
- Older builds may not decode the `notConfirmedByAgent` delivery value persisted in transcripts.

## Validation
- **Recovery suites:**
  - `AgentRecoveryCoordinatorTests`
  - `AgentRecoveryActionTests`
  - `AgentRecoveryStartupCompositionTests`
  - `AgentRecoveryStartupReconciliationTests`
  - `AgentRecoveryReconciliationTests`
  - `AgentRecoveryResetBoundaryTests`
  - `AgentRecoveryStoreTests`
  - `AgentProcessRegistryTests`
  - `AgentDeliveryQuietByDefaultTests`
  - `AgentProviderHandoffTests`
  - `ClaudeSessionHistoryReaderTests`
- **Elsewhere:**
  - The Claude coordinator tests run as extensions of `AgentModeRunServiceLifecycleTests`, so filter by that suite name.
  - `ACPAgentSessionControllerModeConfigTests` and `ClaudeNativeTurnTeardownTests` cover the controller seams.
- **Live checks** need the owner. Quitting or relaunching the app ends an agent session running inside it, so ask at the action boundary.
