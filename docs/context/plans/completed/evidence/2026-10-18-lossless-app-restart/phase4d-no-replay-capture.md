# Lossless restart Phase 4d: bounded no-replay Claude Read and resume capture (O21)

Scope: read when the task touches Claude CLI stream-json output without `--replay-user-messages`: how a caller message's identity reaches native history, how Read tool-call envelopes are shaped, same-session `--resume` continuity, or the offline comparison with the Step 4d5 live classifier for the lossless app restart plan.
Authority: Reference
Last-verified: 2026-10-24

Owner decision O21 approved this bounded capture. It is **not** live RepoPrompt acceptance, app-profile qualification or recovery activation.

**Outcome:** the run used two real completions across two processes, without replay, and each made one built-in `Read` call.
- Stdout carried no user record for the caller message. The caller UUID appeared only in attribution fields.
- Native history persisted the caller UUID and its content exactly.
- Every stdout assistant and tool-result record joined its native entry.
- Process 2 resumed the same session, and its native file kept process 1's file as a byte-identical prefix.
- The envelope shapes were identical to the O20 capture with replay ([phase4d-tool-resume-capture.md](phase4d-tool-resume-capture.md)).

This report uses synthetic labels only: S for the session, C1 and C2 for callers, U, M and T for entry, message and tool-use IDs, and P for promptIds. No real IDs, paths, file or attachment contents, API-request data, or auth or config values are kept here.

## Provenance and bounds (chronological)
1. **Preflight, using no prompts.**
   - `/Users/<user>/.local/bin/claude` is a symlink to `…/claude/versions/2.1.302`, whose SHA-256 is `5262ce9de86243fed0d21edc39b271555d56780d0112e2b194439fe1c6662d37`, unchanged since O20.
   - `--version` reported `2.1.302 (Claude Code)`.
   - The targeted `--help` still lists every flag used.
   - `CLAUDE_CONFIG_DIR` was removed for the child only. No auth status, config or credential inspection was done.
2. **Driver.** It is a fresh private temp copy of the O20 driver with single-line edits.
   - **`--replay-user-messages` is removed.**
   - The two synthetic fixture files are 0400 and each holds one literal token.
   - Process 1 sends one prompt; process 2 resumes with one prompt.
   - Main inspected the driver and asked for scope-tightening corrections, which were applied before execution:
     - Any alternate-session history copy was removed. An unexpected session ID means stop and report.
     - A pre-existing project directory for the fresh workspace aborts the run before the provider starts.
     - Process 2 runs only if all of the following hold for process 1. Otherwise the run stops with no second prompt.
       - Status ok, exit 0 and a `success`/`completed` result.
       - No truncation, no signal, no remaining process group and no live PID.
       - The native file exists.
       - Every init lists tools exactly `["Read"]` and an empty MCP list.
       - Exactly one Read call with the fixture path, and one linked result that is not an error.
       - One final text and one result, both equal to the token.
       - Only session S appears.
3. **Redacted command (both processes).**
   ```
   cd <fresh 0700 ws> && env <parent env minus approved strip-list, minus CLAUDE_CONFIG_DIR> /Users/<user>/.local/bin/claude -p \
     --input-format stream-json --output-format stream-json --verbose \
     --safe-mode --restricted --strict-mcp-config --mcp-config '{"mcpServers":{}}' \
     --tools Read --disable-slash-commands --no-chrome --permission-prompts none \
     --system-prompt "<terse responder; use only Read when asked; reply with exactly the token>" \
     --model sonnet --effort high --max-budget-usd 0.25 \
     (process 1: --session-id <S> | process 2: --resume <S>)
   ```
   - Not passed: `--replay-user-messages`, `--setting-sources`, `--permission-mode`, `--allowedTools`, `--add-dir`, any bypass flag, and `--fork-session`.
   - Stdin frames were `{"type":"user","message":{"role":"user","content":<string>},"parent_tool_use_id":null,"session_id":S,"uuid":Cn}`. Each 151-character prompt asks the model to Read one fixture by absolute path and reply with exactly its token.
   - Stdin stayed open until that prompt's `result`, then closed.
4. **Budget consumed: 2 of 2 processes and 2 of 2 prompts.** There were no failures and no retry.
   - Process 1 exited 0 by itself after 4.1 s wall time. Stdout was 6,926 B and stderr 0 B.
   - Process 2 exited 0 by itself after 4.6 s wall time. Stdout was 6,940 B and stderr 0 B.
   - Nothing was truncated or signalled.
   - Afterwards `ps -p` and `pgrep -g` were empty for both PIDs.
   - `total_cost_usd` was 0.0086298 for process 1 and 0.0109402 for process 2, and native `cost-state` matched each.
   - Whether these figures accumulate across the resumed session is not established. The upper bound is USD 0.0196 total, against a USD 0.25 cap per process.
   - No visible app, RepoPrompt CLI, MCP executable, global setting or login was touched.
5. **Native history.**
   - The fresh project directory `~/.claude/projects/<encoded-ws>/` did not exist beforehand and held exactly one entry after each process.
   - `S.jsonl` was copied by exact path only, after each process.
   - No other history was read or listed.
   - The test session file remains in the default history location. Whether to clean it up is left to the owner or main.

## Isolation (init, both turns)
- **Init inventory:**
  - Tools: exactly `["Read"]`.
  - MCP servers, skills and slash commands: 0 each.
  - Output style and permission mode: both `default`.
  - `cwd`: the temp workspace.
  - Model: `claude-sonnet-5-5`, with real completions only.
- **Plugins and agents:** 3 plugin metadata entries and 4 agent entries, both unchanged from O20. Names are omitted, and these counts are not evidence that any plugin executed.
- **Permission decisions:** native tool-result entries carry `permissionDecision {decision: accept, source: config, reasonType: mode}`, and `permission_denials` was empty.
- **Hooks:** no hook records appeared on stdout. This is only an absence of observed hook records, not proof that no hook executed; managed-policy hooks are not independently ruled out (O21).

## Stdout without replay
```
command_lifecycle queued/started (command_uuid=Cn)
system/init                    user_message_uuids=[Cn]
assistant  [tool_use T Read{file_path}]   user_message_uuid=Cn, user_message_uuids=[Cn], wire_tool_inputs{T: input}
[rate_limit_event status=allowed]          (P1: between call and result; P2: between result and final; it varies)
user       [tool_result T, string]        own fresh uuid; tool_use_result{type:text,file{…}}, tool_result_meta[{id:T,permission_decision}]
assistant  [text == token]                no attribution keys
result/success terminal_reason=completed stop_reason=end_turn num_turns=2 safety_stops=0 user_message_uuid=Cn user_message_uuids=[Cn]
command_lifecycle completed
```
- **No stdout record has `uuid` equal to Cn, and there are no `isReplay` records.**
- The only stdout `user` records are the two tool results.
- The caller UUID appears only as:
  - `command_uuid` (3 lifecycle records)
  - `user_message_uuids` (init, call and result)
  - `user_message_uuid` (call and result)
- Every stdout `session_id` is S.
- **Shapes are identical to O20.** I compared the full nested key/type shapes of the call assistant, tool-result user, final text assistant, result, rate-limit and lifecycle records, and the init key set, against the O20 capture with replay. They were equal, and within each run they matched each other too.
  - Removing replay only removed the replay `user` record.

## Native history and caller identity
- **The caller survives without replay.** For C1 and for C2, the stdin `uuid` equals the native `user.uuid`. `message.content` is equal under canonical JSON, the role is `user` and `sessionId` is S.
- **Stdout↔native joins.** All 6 stdout assistant and tool-result records join their native entry by `uuid` with the same type, equal `message.content`, equal `message.id` and the same session. Init, rate-limit, result and lifecycle UUIDs are stdout-only.
- **Graph.** The run produced 46 native lines; the per-turn sequence below follows the O20 observation.
  - The caller user's `parentUuid` is null in process 1. For C2 it is the final assistant from process 1.
  - The caller user carries `promptId` P and `turnPosition {promptIndex:0, turnIndex:n}`, with `promptSource`/`turnOrigin` = `sdk`.
  - An attachment chain follows. Process 1 has the full set: environment, model, total_tokens_reminder, budget_usd, session_context, date, credential_org and prompt_snapshot. The resumed turn has only total_tokens_reminder and budget_usd.
  - The tool_use assistant has `stop_reason` `tool_use`.
  - The tool-result user's `parentUuid` is the call assistant, with `sourceToolAssistantUUID` equal to the call assistant and the same `promptId`.
  - Then come attachments, the final assistant (`end_turn`), `last-prompt` with leaf = final assistant, and `cost-state`.
  - Process 2 appended `mode` (value `normal`) and `atis-latch` before its `cost-state`.
  - `isSidechain` is false on every UUID-bearing entry, and every `sessionId` is S.
- **Resume.**
  - Process 2 reported session S throughout. No new session file appeared.
  - The native file after process 1 (27 lines) is a **byte-exact prefix** of the file after process 2 (46 lines), and the line-level canonical comparison also matched.
  - `turnIndex` continued at 2, and C2 has its own fresh `promptId`.

## Offline comparison with the Step 4d5 classifier
These checks evaluated the predicates in `ClaudeLiveTranscriptQualification.swift` offline as booleans over the private stdout. No Swift was run.

**Consistent with the predicates:**
- Lifecycle keys ⊆ `lifecycleKeys`, with states `queued`, `started` and `completed`.
- Init keys ⊆ `initKeys`.
- Rate-limit keys and info keys fit the allowlist, with status `allowed`.
- **Read call:**
  - The envelope keys equal `readCallKeys`.
  - The block keys are `{type, caller:{type:direct}, id, name:Read, input:{file_path}}`.
  - Both attribution fields name exactly the outbound UUID.
  - `wire_tool_inputs` is the singleton map from the call's id to its input.
- **Read result:**
  - The keys equal `readResultKeys`, `timestamp` is a string, and `message` is `{role, content}`.
  - The block is `{type, tool_use_id, content}`, with no `is_error`.
  - `tool_use_result {type:text, file}` uses `readResultFileKeys`.
  - `tool_result_meta` holds one entry, `{id, permission_decision{decision:accept, source:config, reason_type:mode}}`.
  - The tool-use ID, metadata ID and path all link, and the block content contains `file.content`.
  - The entry UUID differs from both the outbound UUID and the call's UUID.
- **Final assistant:** keys ⊆ `assistantKeys`, with one `{type, text}` block and non-empty text. It carries no attribution, which is allowed only in the `readReturned` state.
- **Result:**
  - Keys ⊆ `resultKeys`, with `success`, `is_error` false, `api_error_status` null and empty denials.
  - `terminal_reason` is `completed`, `stop_reason` is `end_turn` and `safety_stops` is 0.
  - The text equals the final answer, and both attribution fields name exactly the outbound UUID.
- **No-replay path:** without a replay record, the turn stays `dispatched(replayed:false)`. The call is still attributed by both fields as required, and nothing on stdout would route to `classifyReplay`.
- **Ordering:** the position of the rate-limit event varies between the two runs, but neither position changes the classifier's turn state.

**Not evaluated:**
- The `semanticMarker` predicate.
- Translator equivalence, meaning the translated `content`, `tool_call` and `tool_result` events and their invocation-ID pairing.
- History-reader row projections and digests.
- Eligibility and the controller's outbound recording.

## Main verification and disposition

Main inspected the complete prepared driver before execution and requested the scope-tightening corrections above. After the worker completed, main read the complete correction diff and this report, independently checked both PIDs and process groups were absent, and ran an assert-only Python parser over the exact new private capture files. It passed: exact installed binary SHA-256, two successful single-Read prompts, both stdin/native caller identities, all six stdout/native type/content/message-ID/session joins, no replay, exact 27-to-46-line byte prefix, resumed caller ancestry, tool-use/result/native-parent links, terminal attribution/text agreement, Read-only/empty-MCP init inventories, and private capture permissions. Reported costs summed to USD 0.01957; these are CLI-reported figures, not independently verified billing. No payload or credential values were emitted.

The worker's offline classifier comparison is partial evidence, not execution of the Swift classifier. The unevaluated predicates listed above remain limits. The isolated no-replay gap is closed for this captured shape only; broader app/profile and activation qualification remain open. Documentation-only evidence and owner-decision changes require no additional Oracle review under the review policy. No production behavior changed.

Maintainer-guidance check: the user impact is reliable attribution of saved input without a replay echo; the observed CLI identity behavior is confirmed directly, while app integration remains unproven. Native history and the existing ledger remain the authorities. No new retention policy or recovery authority was added. The test was bounded to two synthetic prompts; shared-host timing is advisory.

## Explicit limits
This evidence covers one CLI version and one invocation profile: safe and restricted modes, `--tools Read`, **no replay**, a child running with the default config, and sonnet at high effort. It covers main-thread `Read` only, string prompts, one call per prompt and successful results.

These shapes match the classifier's allowlist offline, which is consistent with Step 4d5's no-replay fixture assumption for this profile. **That match is not production, installed-profile or app qualification**, because the app's actual launch composition and translator path were not exercised.

Still unqualified:
- thinking or multi-block messages
- parallel or other tools
- tool errors or denials
- permission prompts
- sidechains or subagents
- interrupts, retraction, abnormal exit and compaction
- fork resume, and resume of a session that is still running
- universal isolation

The O21 budget is now exhausted. The capture worker made no product edits, builds, git staging or commits, and did not activate recovery. Main stages only this sanitized evidence and the plan's owner decision/status for a local checkpoint.

Documentation validation: the first context check rejected the draft's noncanonical Scope header; main corrected it. `Scripts/check-agent-context`, all 23 `Scripts/test-check-agent-context` checks, `make guardrails` and `git diff --check` then passed. The pre-existing 24-route warning remains. No source changed, so no Swift build, test suite, lint or app acceptance was rerun for this evidence-only step. After checkpoint `4cc4909a`, the next guardrail run saw this newly tracked report and rejected its missing durable-doc allowlist entry (the pre-stage check had not scanned it). Main added this exact evidence path to `Scripts/source_layout_guardrails.sh` with the Step 4d6 evidence paths; guardrails then passed. This follow-up corrects the document-registration omission, not the capture results.
