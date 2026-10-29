# Lossless restart Phase 4d — isolated Claude CLI capture

Scope: read when the task touches Claude CLI stream-json caller UUID persistence, stdout-to-native-JSONL identity correlation, or native Claude history record roles for the lossless app restart plan.
Authority: Reference
Last-verified: 2026-10-23

Owner O16 approved the initial bounded experiment; O19 approved the controlled default-configuration retry. This is not live RepoPrompt acceptance. **Outcome: capture authentication resolved; one real single-text-block completion observed.** The first two attempts inherited the Claude worker's configuration override and produced synthetic authentication errors only. Removing only `CLAUDE_CONFIG_DIR` in the third attempt produced a real reply with matching caller and assistant identities in native history. This qualifies only that exact invocation and one-turn shape, not thinking, multi-block output, tools or resume.

## First attempt — provenance and bounds
- Binary: the `claude` entry in `~/.local/bin` is a symlink to `…/claude/versions/2.1.302`, a Mach-O arm64 executable. Its SHA-256 is `5262ce9de86243fed0d21edc39b271555d56780d0112e2b194439fe1c6662d37`. `--version` reports `2.1.302 (Claude Code)`, and the init event also reports `claude_code_version` 2.1.302.
- Docs consulted: `claude --help` (local) and the official CLI reference at `code.claude.com/docs/en/cli-reference`, fetched 2026-10-23.
- Workspace: a fresh `mkdtemp` directory under `/tmp` (`p4d-ws-<redacted>`, mode 0700, outside the repo, not a git repo). Raw captures are in a separate `p4d-raw-<redacted>` directory (0700 dir, 0600 files) and are temp-only. Nothing raw was copied into the repo.
- Budget used: 1 process, 2 user prompts (of 3 allowed), 1 fresh session UUID, and 1 fresh caller UUID per prompt. The driver gated the optional resume on `exit==0`. The child exited 1, so the resume never ran, and nothing was retried. Reported cost was `0` in the `total_cost_usd` and native `cost-state` fields, and `duration_api_ms` was `0`.
- Limits: a 120 s deadline covered the whole invocation, stdout was capped at 2 MB (9,285 B observed), and `--max-budget-usd 0.50` was set.
- Process cleanup: the child ran with `start_new_session=True`. The driver signals only that child's own process group, and only if it is still alive. That was not needed: the child exited by itself. Afterward `ps -p <pid>` and `pgrep -g <pid>` were both empty. The child's own messaging socket no longer existed after exit. No `pkill` or global signals were used. The visible app and its provider sessions were not touched. No RepoPrompt, `rpce-cli`, or MCP executable was invoked.

## Redacted command
```
cd <ws> && env <parent env minus strip-list> /Users/<user>/.local/bin/claude -p \
  --input-format stream-json --output-format stream-json --verbose --replay-user-messages \
  --safe-mode --setting-sources user --strict-mcp-config --mcp-config '{"mcpServers":{}}' \
  --tools "" --disable-slash-commands --no-chrome --permission-prompts none \
  --system-prompt "You are a terse test responder. Never use tools. Reply with exactly the requested text and nothing else." \
  --model sonnet --effort high --max-budget-usd 0.50 --session-id <S>
```
- The strip-list removed the parent agent's Claude/MCP/RepoPrompt variables: `CLAUDECODE`, `CLAUDE_CODE_{CHILD_SESSION,SESSION_ID,MESSAGING_SOCKET,MESSAGING_TOKEN,ENTRYPOINT,SESSION_ATTENDED,EXECPATH,MAX_OUTPUT_TOKENS,ENABLE_TELEMETRY,AUTO_COMPACT_WINDOW}`, `CLAUDE_PID`, `CLAUDE_EFFORT`, `CLAUDE_AUTOCOMPACT_PCT_OVERRIDE`, `CLAUDE_BASH_MAINTAIN_PROJECT_WORKING_DIR`, `ENABLE_CLAUDEAI_MCP_SERVERS`, `MCP_TIMEOUT`, `MCP_TOOL_TIMEOUT`, `MAX_MCP_OUTPUT_TOKENS`, `RP_SHELL_LOOKUP`, and `REPOPROMPT_*`. `CLAUDE_CONFIG_DIR` was kept, so history was written under the configured directory. No permission bypass was used.
- Stdin frames had the shape `{"type":"user","message":{"role":"user","content":<text>},"parent_tool_use_id":null,"session_id":<S>,"uuid":<C1|C2>}`. Prompt C1 was `Reply with exactly: ALPHA-7`. Prompt C2 was `What is 17 multiplied by 23? Reason it through first, then reply with only the number.`

## Isolation observations (init event, counts only)
- Tools: 0. MCP servers: 0. Skills: 0. Slash commands: 0. Output style: `default`. Permission mode: `default`. `cwd` and `original_cwd` both equal the temp workspace. Model: `claude-sonnet-5-5`.
- Agents: 4 reported definitions. Plugins: 3 metadata entries even under `--safe-mode`; names are omitted from retained evidence. Their origin was not verified. Metadata presence alone is not evidence of installed-plugin execution; see the documented safe-mode boundary below.
- `messaging_socket_path` was non-null. It differed from the parent's socket and was removed on exit.
- No managed policy files were present: `managed-settings.json`, `managed-mcp.json`, and `managed-settings.d` are all absent under `/Library/Application Support/ClaudeCode/`.
- User settings were still loaded (`--setting-sources user`) so that configured auth could work; their contents were not read.
- Native history shows that the CLI injected `environment`, `session_context`, `date`, and `prompt_snapshot` attachments even though `--system-prompt` was replaced. Their content was not exported.

## Authentication failure and follow-up
Both stdout assistant messages had `error: "authentication_failed"`, `is_api_error_message: true`, and `message.model: "<synthetic>"`, with the text `Not logged in · Please run /login`. Both results had `subtype: "success"` but `is_error: true` and `terminal_reason: "api_error"`. Init reported `apiKeySource: "none"`. The cause was not investigated. It could be the stripped parent environment, `--safe-mode`, `--setting-sources user`, or how the configured auth is provided to the main session. A non-printing `claude auth status` method-only check was denied by the sandbox classifier as credential exploration and was not retried or worked around. A qualifying rerun needs a normal authenticated invocation, not credential discovery. The owner subsequently selected “Use my normal CLI (Recommended)” (O17), without a custom command or explicit completed-login confirmation. Main requested read-only command resolution; main subsequently authorized the final single-prompt attempt recorded below.

The [official CLI reference](https://code.claude.com/docs/en/cli-reference), checked again by main on 2026-10-23, describes safe mode as disabling installed customizations while retaining normal authentication and built-in behavior; managed-policy hooks can still apply. Already captured local help explicitly permits built-in plugins. Thus the metadata counts alone prove neither installed-plugin execution nor full isolation. Their origin remains unverified, and the normal invocation must preserve the existing tools/MCP-disabled and temporary-history bounds.

## Observations (synthetic labels; S = session, C1/C2 = caller UUIDs)
Stdout run (ordinal: record):
```
0 command_lifecycle queued    command_uuid=C1
1 command_lifecycle started   command_uuid=C1
2 system/init                 uuid=I1 (not in native)
3 user  isReplay=true         uuid=C1  content="Reply with exactly: ALPHA-7"
4 assistant (1 text block)    uuid=A1  message.id=M1  user_message_uuid=C1 user_message_uuids=[C1]
5 result                      uuid=R1 (not in native) user_message_uuid=C1
6 command_lifecycle cancelled command_uuid=C1
7-13 same pattern for C2: queued, started, init I2, replay C2, assistant A2/M2, result R2, cancelled
```
All stdout `session_id` values = S. The `command_lifecycle` records carry their own fresh `uuid`, which does not appear in native history.

Native JSONL, `<config>/projects/<encoded-ws>/S.jsonl`, read by exact path only. The new project directory contained exactly one entry.
```
ord type                parent → uuid          notes
0   queue-operation     (no uuid)              enqueue, content = C1 text
1   queue-operation     (no uuid)              dequeue
2   user                null → C1              promptId P1, promptSource/turnOrigin=sdk, turnPosition{promptIndex:0,turnIndex:1}
3-6 attachment          C1 → N1 → N2 → N3 → N4 environment, model, total_tokens_reminder, budget_usd
7   atis-latch          (no uuid)
8-10 attachment         N4 → N5 → N6 → N7      session_context, date, prompt_snapshot
11  api-request-shape   (no uuid)
12  api-request-blob    (no uuid)              role=system text (request content persisted)
13  api-request         (no uuid)              own UUID id ≠ M1, querySource=sdk
14  assistant           N7 → A1                message.id=M1, error=authentication_failed, model <synthetic>
15-16 queue-operation   enqueue C2 / dequeue
17  user                A1 → C2                promptId P2 ≠ P1, turnIndex:2
18-19 attachment        C2 → N8 → N9           total_tokens_reminder, budget_usd
20  api-request-blob    role=user, 2 text blocks: C1 text + C2 text (synthetic error turn excluded from request history)
21  api-request-blob    role=system
22  api-request         own UUID id
23  assistant           N9 → A2                message.id=M2
24  last-prompt         leafUuid=A2            lastPrompt = C2 text
25  cost-state          totalCostUSD 0, totalAPIDuration 0
```
All native `sessionId` values = S. `isSidechain=false` on every UUID-bearing entry.

## Answers and limits
- **Caller UUID → native user UUID: yes, observed.** For both turns, the stdin `uuid` was persisted verbatim as the native `user` entry `uuid`. The same value appeared in the stdout replay `uuid`, in `command_lifecycle.command_uuid`, and in the assistant/result `user_message_uuid(s)`. This holds for string-content prompts in one process.
- **Assistant stdout UUID / message.id ↔ native: matched for synthetic error messages only.** Stdout A1/A2 had the same `uuid` and `message.id` as native ordinals 14 and 23, each with one text block. Multi-block grouping and thinking were not observed and are **unqualified**.
- **Native metadata roles:** only `user`, `attachment`, and `assistant` entries carry `uuid`/`parentUuid`. Attachments form a linear chain between a user entry and its assistant reply, so the assistant's `parentUuid` is the last attachment, not the user entry. A turn-2 user entry's parent is the previous assistant entry. `queue-operation`, `atis-latch`, `api-request-shape`, `api-request-blob`, `api-request`, `last-prompt`, and `cost-state` have no `uuid`. `last-prompt.leafUuid` points at the final assistant entry. Stdout `system/init`, `result`, and `command_lifecycle` UUIDs are stdout-only.
- **Session continuity:** two turns in one stream-json process kept S exactly, on stdout and in native history. Resume was **not executed** and is unqualified.
- **Explicitly unqualified:** tool calls and results, retractions, abnormal exit, real API completions, thinking blocks, multi-block assistant messages, resume or fork, compaction, and any other unobserved variant. This is a single fixture on CLI 2.1.302. The pinned SDK docs give identity hints, but this capture does not establish universal normalization.

## Second attempt (final authorized prompt)
Main authorized this attempt under O16/O17 after confirming how the owner's normal CLI resolves. In the login shell `/opt/homebrew/bin/bash`, both `-lic` and `-lc` give `type -t claude` = `file` and `type -P claude` = `~/.local/bin/claude`, with no alias or function. That is the same symlink to the 2.1.302 binary used in attempt 1.

**Bounds**
- Same executable, flags, strip-list and inherited auth/config environment as attempt 1. `CLAUDE_CONFIG_DIR` was inherited unchanged.
- No auth-variable inspection, no auth status, and no config or credential reads.
- The driver was the attempt 1 temp driver with a two-line edit: one prompt only, and the resume branch removed.
- Fresh 0700 temp workspace, fresh session UUID S′, and fresh caller UUID C1′.
- One input: `Reply with exactly: ALPHA-7`. This was prompt 3 of the 3 allowed. There was no retry, no resume and no second prompt.
- 120 s deadline, 2 MB stdout cap, `--max-budget-usd 0.50`.

**Outcome**
- **The process** exited 1 by itself; the CLI result reported `duration_ms: 27` (not measured whole-process wall time). Stderr was 0 B, stdout 4,612 B (not truncated), and the driver status was `ok`.
  - The child's PID and process group were empty afterward. No signal was sent. Its own messaging socket was distinct from the parent's and absent after exit.
- **No real model completion was observed:** reported API cost 0 and API time 0 (stdout `total_cost_usd` 0 and `duration_api_ms` 0; native `cost-state` totalCostUSD 0 and totalAPIDuration 0).
  - The model was **synthetic**: the assistant had `message.model` `<synthetic>`, `error` `authentication_failed`, `is_api_error_message` true, and the same 33-character not-logged-in text as before.
  - The result had `subtype` `success`, `is_error` true and `terminal_reason` `api_error`. Init again reported `apiKeySource` `none`.
  - **The normal executable remained unauthenticated under these unchanged bounds; the owner had not confirmed a completed login.**
- **Hooks:** no hook events appeared on stdout. This is absence evidence only. It does not prove that nothing installed ran.
- **Init counts:** tools 0, MCP servers 0, skills 0, slash commands 0, agents 4, plugins 3 metadata entries (names omitted, same count as attempt 1). Permission mode and output style were `default`, and `cwd` was the temp workspace.

**Stdout scope (S′)**
- Ordinals: 0–1 `command_lifecycle` queued/started (command_uuid=C1′) → 2 `system/init` → 3 `user` replay → 4 `assistant` → 5 `result` → 6 `command_lifecycle` cancelled.
- The replay at ordinal 3 had `uuid=C1′`, `isReplay` true, and content equal to the input text.
- The assistant at ordinal 4 had a fresh `uuid` A′ and `user_message_uuid=C1′`. It had one text block, not equal to `ALPHA-7`.
- The result at ordinal 5 had `user_message_uuid=C1′`, `result` not equal to `ALPHA-7`, and `num_turns` 1.
- Every `session_id` was S′. The init, result and lifecycle UUIDs are fresh and do not appear in native history.

**Native scope** (`<config>/projects/<encoded-ws′>/S′.jsonl`, read by exact path; the new project directory had 1 entry)
- Ordinals: 0–1 queue enqueue/dequeue → 2 `user` uuid=C1′, parent null, promptId present → 3–6 attachments chained C1′→N1→N2→N3→N4 (environment, model, total_tokens_reminder, budget_usd) → 7 `atis-latch` → 8–10 attachments N4→N5→N6→N7 (session_context, date, prompt_snapshot) → 11 `api-request-shape` → 12 `api-request-blob` → 13 `api-request`, whose own id did not match any `message.id` → 14 `assistant` N7→A′ → 15 `last-prompt`, leafUuid=A′ → 16 `cost-state`.
- No thinking blocks. Every `sessionId` was S′, and `isSidechain` was false on every UUID-bearing entry.

**Equality results (synthetic-error path only)**
- Input C1′ equals both the stdout replay `uuid` and the native user `uuid`.
- Stdout A′ equals native ordinal 14 in `uuid` and `message.id`.
- The record types, ordering and parent chain repeat attempt 1 exactly.

**Limits**
- Attempt 2 adds reproducibility for the synthetic-error path only.
- Still unqualified: real completions, thinking, multi-block grouping, resume, tool calls, retraction, abnormal exit, and universal isolation.
- The original prompt budget is now exhausted. A further run needs renewed bounded authorization. The owner subsequently confirmed that the exact executable works manually; lack of an owner login must not be inferred from these worker-context failures.

## Dedicated launch-context diagnosis
The owner explicitly requested a dedicated worker after confirming manual success with `/Users/tnguyen/.local/bin/claude`. Read-only Codex worker `AE7B3068-3BE8-44E2-91D7-371B3EA8A662` inspected both generated drivers and repository launch composition. Main independently read `driver2.py`: line2 pins the exact executable; lines8–10 copy the worker environment minus linkage keys; line21 passes that environment directly to the child; lines56–59 locate only the new native history. Neither driver removes `CLAUDE_CONFIG_DIR`.

The Codex diagnostic worker measured `CLAUDE_CONFIG_DIR` absent in its current context. A separate presence/equality-only probe in the original Claude worker measured it present and nonempty, unequal to `$HOME/.claude`; HOME was present and XDG_CONFIG_HOME absent. No paths, variable values or hashes, configuration contents or credentials were printed. This later probe is not proof of the exact earlier environment, and the owner's independent terminal environment remains unmeasured. Launching a login shell from a worker inherits its context and does not establish equivalence to the owner's terminal.

The strongest hypothesis is inherited non-default configuration, not a wrong binary. The owner-reported manual success and later worker-context difference do not prove which credential source is involved. The smaller next experiment is one prompt with only `CLAUDE_CONFIG_DIR` removed from the capture child's environment, retaining every isolation flag and bound. Main requested explicit approval for this default-context attempt; no additional prompt is inferred from the diagnosis request. No product source fix is indicated by this harness discrepancy.

Repository composition differs from this temporary driver: `ProcessEnvironmentBuilder.swift:76–109,122–160` selects inherited versus captured shell context and merges overrides; `ClaudeNativeProcessSessionController.swift:4026–4069` applies its configured/resolver overrides. Main spot-checked both ranges. The diagnosis does not prove an app launch bug or qualify app recovery.

## Third attempt (O19: default config context, final authorized prompt)
**Setup**
- Ran in the same Claude worker context. `driver3.py` is `driver2.py` plus one line, `env.pop('CLAUDE_CONFIG_DIR', None)`, placed right after the environment is built. Nothing else changed: same binary (2.1.302), flags, strip-list, 120 s deadline, 2 MB stdout cap and `--max-budget-usd 0.50`.
- Fresh 0700 temp workspace, fresh session UUID S″ and fresh caller UUID C1″. One input, `Reply with exactly: ALPHA-7`. No resume and no retry.
- No auth status and no config or credential inspection. Native history was read only at the driver's existing fallback path, `~/.claude/projects/<encoded-ws″>/S″.jsonl`. The existing driver also counted entries in that newly created project directory: there was 1. Raw files are temp-only at `/private/tmp/p4d-raw-qhxwi3ld` (0700 directory, 0600 files) for main's allowlist-only verification.
- One sanitizing analysis pass was blocked by the sandbox classifier. A narrower pass that read neither the init `apiKeySource` field nor any environment value produced the counts below.

**Outcome: a real completion.**
- **Exit:** the child exited 0 by itself. Stderr was 0 B and stdout 6,258 B (not truncated). Its PID and process group were empty afterward, and no signal was needed.
- **Cost and time:** stdout result `total_cost_usd` 0.002542, `duration_api_ms` 1,264 and `duration_ms` 1,696. The native `cost-state` record shows the same cost and API duration.
- **Model:** `claude-sonnet-5-5`, not `<synthetic>`. The result had `is_error` false, `terminal_reason` `completed` and `num_turns` 1, and its result text equals `ALPHA-7`.
- **Hooks:** no hook-typed records appeared on stdout. That is absence evidence only, not proof that nothing installed ran.

**Init inventory (counts only)**
- Tools 0, MCP servers 0, skills 0, slash commands 0, agents 4, output style `default`. `cwd` was the temp workspace.
- **Plugins: 7 metadata entries (names omitted), compared with 3 in the earlier non-default context. Permission mode: `auto`, compared with `default` earlier.**
- These differences show that the effective contexts differ, but counts and permission mode alone do not prove installed customization execution or weaker isolation. The run used the same documented safe-mode contract, reported no available tools/MCP and showed no tool-use blocks; universal isolation is not established.

**Stdout scope (S″)**
- Ordinals: 0–1 `command_lifecycle` queued/started (command_uuid=C1″) → 2 `system/init` → 3 `user` replay → 4 `assistant` → 5 `rate_limit_event` → 6 `result` → 7 `command_lifecycle` **completed** (attempts 1 and 2 ended with `cancelled`).
- The replay at ordinal 3 had `uuid=C1″`, `isReplay` true, and content equal to the input.
- The assistant at ordinal 4 had uuid A″ and `user_message_uuid=C1″`. It had one `text` block equal to `ALPHA-7`, no thinking block, and `stop_reason` null on stdout.
- Every `session_id` was S″. The init, rate-limit, result and lifecycle UUIDs are fresh and do not appear in native history.

**Native scope**
- Ordinals: 0–1 queue enqueue/dequeue → 2 `user` uuid=C1″, parent null.
- 3–6 attachments chained C1″→N1→N2→N3→N4: environment, model, total_tokens_reminder, budget_usd.
- 7 `atis-latch`.
- 8–11 attachments N4→N5→N6→N7→N8: session_context, date, `credential_org` (only the type discriminator inspected; context content not inspected), prompt_snapshot.
- 12 `api-request-shape`, 13–14 `api-request-blob` ×2, 15 `api-request`.
- 16 `assistant` N8→A″, real model, `requestId` present, one text block equal to `ALPHA-7`.
- **17 `attachment` A″→N11, prompt_snapshot after the assistant.** 18 `last-prompt` with **leafUuid=N11 (the trailing attachment, not the assistant)**. 19 `cost-state`.
- Every `sessionId` was S″, and `isSidechain` was false on every UUID-bearing entry.

**Equality results**
- Input C1″ equals both the stdout replay `uuid` and the native user `uuid`.
- Stdout A″ equals native ordinal 16 in `uuid` and `message.id`, and the `message.content` arrays are equal.
- For this one-block real reply, the stdout assistant record and the native entry are the same block grouping.

**Limits**
- This evidence covers only this default-config CLI invocation, a single-text-block real reply, and one turn.
- It does not qualify RepoPrompt app resume, multi-block or thinking grouping, tool calls and results, retraction, abnormal exit, multi-turn continuity on the real path, or universal isolation.
- Default-context plugin metadata and permission mode differ from attempts1/2; this is a provenance difference, not proof of plugin execution.
- Four prompts have now been used, and no further prompt is authorized.

Main independently verified the exact one-line driver diff, parsed the new stdin/stdout/native copies using allowlisted structural/result fields, confirmed the real expected reply and both identity/content matches, and checked that the child PID no longer exists. The result supports inherited configuration as the cause of this capture failure and a child-local default-context correction; it does not establish a product bug or identify/read any credential source. No global environment, login, settings or source file was changed.
