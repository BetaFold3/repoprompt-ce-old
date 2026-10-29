# Lossless restart Phase 4d — bounded Claude Read-tool and resume capture (O20)

Scope: read when the task touches Claude CLI stream-json tool_use/tool_result identity, stdout-to-native-JSONL correspondence for tool turns, native Claude parent-graph/non-rendering record types around tool calls, or same-session `--resume` continuity for the lossless app restart plan.
Authority: Reference
Last-verified: 2026-10-24

Owner O20 approved this bounded capture. It is **not** live RepoPrompt acceptance and does not qualify app recovery. **Outcome: real completions with one built-in `Read` tool call per prompt observed in all three prompts. Every stdout user/assistant record joined its native entry exactly, and a second process resumed the same session with a byte-identical native prefix.** Synthetic labels are used throughout: S = session, C1–C3 = caller UUIDs, U/M/T/P = other UUIDs, message ids, tool_use ids and promptIds. No real ids, paths, file contents, attachment contents, API request data or auth/config values are retained here.

## Provenance and bounds (chronological)
1. **Preflight (no prompts used).** `/Users/<user>/.local/bin/claude` is a symlink to `…/claude/versions/2.1.302`; the target's SHA-256 is `5262ce9de86243fed0d21edc39b271555d56780d0112e2b194439fe1c6662d37`, the same as earlier Phase 4d attempts. `--version` reported `2.1.302 (Claude Code)`. The targeted `--help` text confirmed support for `--safe-mode`, `--restricted`, `--tools <list>`, `--strict-mcp-config`, `--permission-prompts none`, `--max-budget-usd`, `--session-id` and `-r/--resume`. Both preflight calls ran with `CLAUDE_CONFIG_DIR` unset in the child. No auth status, config or credential inspection was done. Official web docs were not needed.
2. **Driver.** This was a new private temp driver modeled on the prior O19 `driver3.py`, which main inspected read-only. It used the same strip-list plus `env.pop('CLAUDE_CONFIG_DIR')` in the child environment only.
   - Workspace: a fresh `mkdtemp` directory under `/tmp`, mode 0700, not a git repo.
   - Fixtures: three synthetic files, mode 0400, each containing one literal token (`BRAVO-42`, `CHARLIE-19`, `DELTA-63`).
   - Raw captures: stored in a separate 0700 temp directory with 0600 files.
   - Per process: 120 s whole-process deadline, 2 MB caps on both stdout and stderr, and one stdin frame at a time.
   - Gating: stdin stayed open until that prompt's `result`. A prompt that returned an error or synthetic result stopped all further prompts. Process 2 ran only if process 1 produced two real results.
3. **Redacted command (both processes).**
   ```
   cd <ws> && env <parent env minus strip-list, minus CLAUDE_CONFIG_DIR> /Users/<user>/.local/bin/claude -p \
     --input-format stream-json --output-format stream-json --verbose --replay-user-messages \
     --safe-mode --restricted --strict-mcp-config --mcp-config '{"mcpServers":{}}' \
     --tools Read --disable-slash-commands --no-chrome --permission-prompts none \
     --system-prompt "<terse responder; use only Read when asked; reply with exactly the token>" \
     --model sonnet --effort high --max-budget-usd 0.25 \
     (process 1: --session-id <S> | process 2: --resume <S>)
   ```
   - There was no `--setting-sources`, because `--restricted` ignores user/project/local settings files. There was also no `--permission-mode`, `--allowedTools`, `--add-dir` or bypass flag.
   - `--replay-user-messages` is a capture-only choice. Earlier app launch evidence shows the app does not pass it, so app qualification must not be inferred from this capture.
   - Stdin frames had the shape `{"type":"user","message":{"role":"user","content":<string>},"parent_tool_use_id":null,"session_id":S,"uuid":Cn}`. Each prompt was `Use the Read tool to read the file <ws>/fixtureN.txt and then reply with exactly the single token it contains and nothing else.` That string is 151 characters long.
4. **Budget consumed.** The run used 2 of 2 processes and 3 of 3 prompts; nothing failed or was retried.
   - Process 1 sent C1 and C2. It exited 0 by itself after 6.6 s wall time. Stdout was 14,228 B and stderr 0 B, neither truncated.
   - Process 2 sent C3. It exited 0 by itself after 3.7 s wall time. Stdout was 7,321 B and stderr 0 B.
   - Neither process was signalled. Afterwards `ps -p <pid>` and `pgrep -g <pid>` were empty for both.
   - Reported `total_cost_usd` per result was 0.0086842 (C1), 0.0110447 (C2) and 0.0134111 (C3). Native `cost-state` matched the last value of each process.
   - Whether these figures are cumulative per process or per turn was not established. Their sum is USD 0.03314 (less than USD 0.034 total), well under each process's USD 0.25 cap.
   - No visible app, RepoPrompt CLI or MCP executable was touched. No global environment, settings or login was changed.
5. **Native history.** Only the new project directory `~/.claude/projects/<encoded-ws>/` was read. It did not exist before the run and held exactly one entry, `S.jsonl`, after each process. No sidecar directory or extra session file appeared.
   - `S.jsonl` was copied by exact path after process 1 and again after process 2.
   - Process 2 stdout reported no other session id, so no other file was read.
   - The test session file remains in the default history location. Deciding whether to clean it up is left to main and the owner.

## Isolation observations (init, all three turns identical)
- Tools: exactly `["Read"]`. MCP servers 0, skills 0, slash commands 0, output style `default`, and `cwd` equal to the temp workspace. Model `claude-sonnet-5-5`, with real completions (never `<synthetic>`).
- **Permission mode `default`.** The earlier O19 default-context run, which loaded user settings, showed `auto`. Native user entries also record `permissionMode: default`.
- **Plugins: 3 metadata entries**, compared with 7 in O19 and 3 in attempts 1 and 2. Agents: 4. Names are omitted, and metadata presence alone does not prove plugin execution.
- No hook-typed stdout records appeared. This is absence evidence only; per O20, managed-policy hooks are not independently ruled out.
- Native tool-result entries carry `permissionDecision {decision: accept, source: config}`, plus a `reasonType` key whose value was not retained. The result's `permission_denials` count was 0.

## Stdout shape per prompt (same for C1, C2 and C3)
```
command_lifecycle queued/started (command_uuid=Cn)
system/init                    uuid fresh, not in native
user  isReplay  uuid=Cn        string content (151 chars)
assistant uuid=Ua msg.id=Ma    blocks=[tool_use T(Read){file_path=<ws>/fixtureN}]  user_message_uuid(s)=Cn  request_id, wire_tool_inputs present  stop_reason=null on stdout
[rate_limit_event]             C1 and C3 only; fresh uuid, not in native
user  uuid=Ub                  blocks=[tool_result tool_use_id=T, string content containing the token, no is_error field]
                               tool_use_result{type,file}, tool_result_meta (list); parent_tool_use_id=null
assistant uuid=Uc msg.id=Mb    blocks=[text == token]  (no user_message_uuid fields)
result/success                 is_error=false terminal_reason=completed num_turns=2 result==token umu=Cn permission_denials=0
command_lifecycle completed
```
- Every stdout `session_id` was S, in both processes.
- **Grouping:** each API message (tool_use turn, final text turn) is its own stdout `assistant` record with one content block. There were no thinking blocks and no multi-block messages.
- The tool-result `user` record has its own fresh UUID. It is not a caller UUID, and the `parent_tool_use_id` envelope field remains null for main-thread tools.

## Native parent graph and record types
Process 1 wrote native ordinals 0–43. Process 2 appended 44–61.
```
0-1   queue-operation enqueue/dequeue
2     user null→C1  promptId=P1  promptSource/turnOrigin=sdk  turnPosition{promptIndex:0,turnIndex:1}
3-11  attachment chain C1→…→N (environment, model, total_tokens_reminder, budget_usd, [atis-latch, no uuid], session_context, date, credential_org, prompt_snapshot)
12-15 api-request-shape, api-request-blob ×2, api-request              (no uuid)
16    assistant N→U1  msg.id=M1  [tool_use T1]  stop=tool_use  requestId, wireToolInputs
17    user U1→U2  promptId=P1  [tool_result T1]  sourceToolAssistantUUID=U1  toolUseResult{type=text,file{content,filePath,numLines,startLine,totalLines}}  permissionDecision
18-20 attachment chain U2→… (prompt_snapshot, total_tokens_reminder, budget_usd)
21-23 api-request-blob ×2, api-request
24    assistant …→U3  msg.id=M2  [text BRAVO-42]  stop=end_turn
25-26 queue-operation enqueue/dequeue
27    user U3→C2  promptId=P2  turnIndex:2
28-29 attachment (total_tokens_reminder, budget_usd)
30-31 api-request-blob, api-request
32    assistant …→U4  [tool_use T2]          33 user U4→U5 [tool_result T2] sourceToolAssistantUUID=U4
34-38 attachment ×2, api-request-blob ×2, api-request
39    last-prompt leaf=<attachment before final assistant>     40 atis-latch
41    assistant …→U6  [text CHARLIE-19]      42 last-prompt leaf=U6     43 cost-state
--- process 2 (--resume S) appends ---
44-45 queue-operation enqueue/dequeue
46    user U6→C3  promptId=P3  turnIndex:3   (parent = last assistant from process 1)
47-48 attachment (total_tokens_reminder, budget_usd); no environment/session_context/date/prompt_snapshot re-injected
49-50 api-request-blob, api-request
51    assistant …→U7 [tool_use T3]           52 user U7→U8 [tool_result T3] sourceToolAssistantUUID=U7
53-57 attachment ×2, api-request-blob ×2, api-request
58    assistant …→U9 [text DELTA-63]         59 last-prompt leaf=U9     60 mode (value "normal", no uuid)     61 cost-state
```
- Every native `sessionId` was S, and `isSidechain` was false on every UUID-bearing entry.
- Only `user`, `assistant` and `attachment` entries carry `uuid`/`parentUuid`. A new non-rendering type, `mode`, appeared after the resumed turn.
- **Tool linkage:**
  - The `tool_use.id` in the assistant entry equals the `tool_result.tool_use_id` in the next user entry, on both stdout and native.
  - The native tool-result `user` entry's `parentUuid` is the tool_use assistant directly, with no attachment between. It also carries `sourceToolAssistantUUID` equal to that assistant and shares the prompt's `promptId`.
  - The follow-up assistant is parented on the last attachment after the tool result.
- **`last-prompt` placement:**
  - In process 1, the second turn wrote a `last-prompt` whose leaf was an attachment before the final assistant. A second `last-prompt` whose leaf was the final assistant followed it.
  - In the first turn, no `last-prompt` was written between the turns.
  - In O19, the leaf was a trailing `prompt_snapshot` attachment.
  - Leaf targets therefore vary, and consumers must not assume the leaf is an assistant.
- **Field names:** native assistant entries carry `wireToolInputs`, `requestId`, `apiBlockIndex`, `effort`/`perTurnEffort` and `requestedModel`. On stdout the corresponding fields are `wire_tool_inputs` and `request_id`. Native `stop_reason` was `tool_use`/`end_turn` while stdout `stop_reason` was null, yet the `message.content` arrays are equal.

## Equality joins (allowlisted parser over the newly generated private files only)
- **Caller UUIDs.** For each of C1, C2 and C3, the stdin `uuid` equals the stdout replay `uuid`, the `command_lifecycle.command_uuid`, the first-assistant and result `user_message_uuid(s)`, and the native `user.uuid`.
- **Stdout to native.** All 12 stdout user/assistant records join a native entry by `uuid`: 3 caller replays, 3 tool_use assistants, 3 tool-result users and 3 final text assistants. In each join, the native entry has the same type, `message.content` is equal under canonical JSON, `message.id` is equal, and `session_id` equals `sessionId`.
- **Stdout-only records.** Stdout `system/init`, `rate_limit_event`, `result` and `command_lifecycle` UUIDs never appear in native history.
- **Resume continuity.**
  - Process 2 stdout reported `session_id` S throughout. No new session file was created, and no fork occurred because `--fork-session` was absent.
  - The native file after process 1 (44 lines) is a **byte-exact prefix** of the file after process 2 (62 lines), and the line-level canonical comparison is equal.
  - C3's parent is the final process 1 assistant.
  - `turnIndex` continued at 3 and `promptId` was fresh.
  - The tool_use and result shapes after resume match those before it.

## Reader follow-up

[Step 4d4 worker evidence](phase4d4-worker.md) records the exact-mode reader change and sanitized Read/resume fixtures. It does not expand the live classifier or establish app qualification. Main verified the two-file diff and the focused test/build/style tickets before independent review.

## Explicit limits
- This covers one CLI version (2.1.302), one invocation profile (safe-mode plus restricted, `--tools Read`, replay on, default-config child, sonnet/high effort), main-thread `Read` only, string-content prompts, one tool call per prompt and successful results.
- Still **unqualified:**
  - thinking or redacted-thinking blocks
  - multi-block or parallel tool_use in one message
  - tool errors or denials
  - permission prompts and `--permission-prompts host`
  - sidechain or subagent (`parent_tool_use_id` non-null) records
  - retraction or interrupt
  - abnormal exit mid-tool
  - compaction
  - resume with `--fork-session`, resume of a still-running session, and the no-replay app flag shape
  - other tools
  - universal isolation, including managed-policy hooks
- Cost-field semantics (cumulative versus per-turn) were not established.
- These facts describe the CLI's observed persistence, not RepoPrompt's import or recovery behavior. No product source, build, git staging or recovery activation was performed. The O20 prompt and process budget is now exhausted.

## Main verification

Main read the complete driver after native read_file rejected the outside-workspace temporary path, then independently parsed only the new capture files. Verified: private directory 0700 and files 0600; two processes and three prompts; all exits zero with no signal or truncation; new project with one session file; all session IDs match; all 12 live user/assistant records match native type, content and message ID; caller inputs match native entries; native history grows from 44 to 62 lines with an exact byte prefix. A first linkage verifier stopped with KeyError because it did not filter native record types before indexing UUID-bearing tool messages. The corrected verifier restricted linkage to user/assistant records: three Read calls and three results, every tool-result ID/source/direct-parent link matches, every Read path is one of the three approved synthetic fixtures, all expected replies succeeded, init advertises only Read and no MCP, and the mode record has no uuid/parentUuid. No opaque record contents or credential values were printed. Both recorded process IDs and groups were absent on the final check.

These are direct observations of the bounded CLI invocation, not product-source validation or broader profile qualification. No extra prompts were sent by verification; the test session and private evidence remain intact.

For a narrowly scoped reader follow-up, main inspected only the new mode record's key names/types and its non-sensitive discriminator: exact keys are `type` (string), `mode` (string), `sessionId` (string); `mode == "normal"`. The earlier session-equality check covers its sessionId. There are no graph identity keys. This does not authorize treating other mode values or unknown additional fields as harmless.
