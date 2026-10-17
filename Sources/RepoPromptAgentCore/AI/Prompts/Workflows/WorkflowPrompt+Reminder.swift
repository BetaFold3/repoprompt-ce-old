import Foundation

extension RepoPromptWorkflowPrompts {
	static let rpReminder = rpReminder(variant: .mcp)

	/// Generate rp-mcp (reminder) for a specific variant.
	static func rpReminder(variant: WorkflowPromptVariant) -> String {
		let suffix = variant == .cli ? " (CLI)" : ""
		let toolDesc = variant == .cli ? "rpce-cli" : "RepoPrompt MCP tools"
		let oracleRecoveryDescription = if variant == .cli {
			"Recover recent Oracle messages after compaction. When multiple Oracle lanes exist, always pass the exact `chat_id`."
		} else {
			"Recover recent Oracle messages after `ask_oracle op:\"wait\"` without IDs has collected any owned undelivered operations. When multiple Oracle lanes exist, always pass the exact `chat_id`. Never recover by resending."
		}

		return """
\(frontmatter(name: "rp-reminder", description: "Reminder to use \(toolDesc)", variant: variant))

# RepoPrompt Tools Reminder\(suffix)

Continue your current workflow using \(toolDesc) instead of built-in alternatives.

## File & Code

| Task | Use | Not |
|------|-----|-----|
| Search paths/content | \(variant == .cli ? "`search`" : "`file_search`") | grep, find, Glob |
| Read file (whole or sliced) | \(variant == .cli ? "`read`" : "`read_file`") | cat, head, Read |
| Directory tree | \(variant == .cli ? "`tree`" : "`get_file_tree`") | ls, find |
| Signatures / overview | \(variant == .cli ? "`structure`" : "`get_code_structure`") | reading whole files |
| Edit file | \(variant == .cli ? "`edit`" : "`apply_edits`") | sed, Edit |
| Create / delete / move | \(variant == .cli ? "`file`" : "`file_actions`") | touch, rm, mv, Write |
\(variant == .cli ? "| Git status / diff / log / blame | `git` | shelling out for analysis |" : "| Git status / diff / log / blame | `git` | shelling out while `git` is in your tool list |\n| Publish a diff for Oracle review | `git_review_snapshot` | hand-built `git` diff artifacts |\n\n\(nativeShellGitInspectionNote) `git_review_snapshot` stays available there.")

## Context & Planning

| Tool | Use for |
|------|---------|
| `manage_selection` | Curate the file set used by chat, builder, and exports. Refresh before each planning call. Modes: `full`, `slices`, `codemap_only`. |
| `workspace_context` | Snapshot current prompt + selection + token budget; also exports. |
| `prompt` | Read/set the shared prompt; list or select copy presets. |
| `context_builder` | Heavy discovery sub-agent — describe the task, it curates files + rewrites the prompt. `response_type`: `clarify` / `plan` / `question` / `review`. Pass `export_response:true` to hand the result to a child agent. |
| \(variant == .cli ? "`chat` (`ask_oracle`)" : "`ask_oracle`") | Chat-mode reasoning over the current selection. Continue one lane by its exact `chat_id`. For independent parallel opinions, start up to two calls with `new_chat:true` and exact model-preset IDs or names from `oracle_utils op=models`. Modes: `chat` / `plan` / `review`. |
| `oracle_chat_log` | \(oracleRecoveryDescription) |
| `ask_user` | Ask the user when ambiguity is load-bearing — don't guess at requirements. |

### Named Oracle requests

When the user asks for one or more named Oracles, treat each name as a model-preset selector:

1. Call `oracle_utils op=models` and resolve every requested name against the authoritative list. Prefer the returned exact preset UUID; do not guess when a name is missing or ambiguous.
2. For independent opinions, issue all `ask_oracle` calls together in the same tool-call batch. Give every lane `new_chat:true` and an explicit `model`. `chat_name` is display-only and never selects a model. Refer to lanes by preset alias only, and never relay one lane's metadata to another.
3. Before comparing or synthesizing, verify every result's returned `model_preset_id` and `model_preset_name` match the requested preset. If identity is missing, mismatched, or a lane fails, report the failure and do not synthesize.

\(sharedOracleResumableWaitGuidance(variant: variant, includeMCPVariant: true))

Every Oracle send re-packages the current workspace selection and the full chat history. Prune the selection before another turn, or continue a long lane in a fresh chat with a concise summary.

## Agent Delegation — `agent_run` / `agent_manage`

Dispatch a sub-agent when a side investigation or delegated chunk of work would otherwise flood this session's context.

**Role labels** (pass as `model_id` on `agent_run op=start`):

| Role | Use for |
|------|---------|
| `explore` | Fast **read-only** probes — git archaeology, "where is X wired?", narrow lookups, web/doc search. One question per probe. |
| `engineer` | Balanced implementation work delegated to a child agent. |
| `pair` | Multi-step reasoning with back-and-forth — lead investigator or main implementer of a decomposed item. |
| `design` | Architecture / review / extended analysis — primary deliverable is a markdown report under `docs/reviews/`, `docs/designs/`, or `docs/analysis/`. Expect the report path in the summary. |

**Key `agent_run` ops:** `start` (creates a new session/tab — never pass `session_id` here), `wait` / `poll` (accept `session_id` **or** `session_ids` array), `steer` (continue an existing session), `respond` (answer a pending `interaction_id`), `cancel`.

**Key `agent_manage` ops:** `list_agents` (discover roles + compound model_ids), `list_sessions`, `get_log`, `cleanup_sessions` (delete finished MCP-started sessions).

**Fan-out pattern:** call `agent_run op=start` with `detach:true` for each probe, then `agent_run op=wait session_ids=[…]` to block on the batch. Always follow a `detach` with a `wait` — don't leave probes unattended. For routine supervision, omit `timeout` / `timeout_seconds`; omission selects the automatic wait from the effective parent provider: \(lifecycleAutomaticWaitProviderSummary). Actionable state wakes the wait early, so automatic and explicit values are upper bounds rather than mandatory sleeps. A timeout returns the current state while the worker remains active.

A wait or transport heartbeat does not itself send a provider-model request and therefore does not warm a prompt cache. The next parent-model continuation may refresh a cache depending on the actual provider product and account path. Longer explicit waits trade fewer supervisory model calls against a greater chance of cache expiry on short-retention paths. Use an explicit override only for deliberate responsiveness/control or a known caller constraint, not merely because a worker may run for a long time. The accepted explicit range is `\(lifecycleExplicitWaitRange)` seconds; zero means poll.

**Export handoff:** when `context_builder` or `ask_oracle` returns `oracle_export_path`, include that path inside the child agent's next `message` so it reads the export with `read_file`.

## Quick Reference

\(example(variant,
	mcp: """
```json
// Search · Read · Edit · File ops
{"tool":"file_search","args":{"pattern":"keyword","mode":"auto"}}
{"tool":"read_file","args":{"path":"Root/file.swift","start_line":50,"limit":30}}
{"tool":"apply_edits","args":{"path":"Root/file.swift","search":"old","replace":"new"}}
{"tool":"file_actions","args":{"action":"create","path":"Root/new.swift","content":"..."}}

// Selection · Builder · Oracle
{"tool":"manage_selection","args":{"op":"add","paths":["Root/path/file.swift"]}}
{"tool":"context_builder","args":{"instructions":"<task>","response_type":"plan"}}
{"tool":"ask_oracle","args":{"message":"...","mode":"plan","chat_id":"<existing-chat-id>"}}
// Independent parallel opinions: issue both calls together, each with new_chat:true.
{"tool":"ask_oracle","args":{"message":"Review independently.","mode":"review","model":"<exact-preset-uuid-a>","chat_name":"Oracle A","new_chat":true,"timeout_seconds":0}}
{"tool":"ask_oracle","args":{"message":"Review independently.","mode":"review","model":"<exact-preset-uuid-b>","chat_name":"Oracle B","new_chat":true,"timeout_seconds":0}}
{"tool":"ask_oracle","args":{"op":"wait","operation_ids":["<operation-id-a>","<operation-id-b>"]}}

// Delegate · Fan-out · Steer · Cleanup
{"tool":"agent_run","args":{"op":"start","model_id":"explore","session_name":"Probe: X","message":"<question>","detach":true}}
{"tool":"agent_run","args":{"op":"wait","session_ids":["<uuid1>","<uuid2>"]}}
{"tool":"agent_run","args":{"op":"steer","session_id":"<uuid>","message":"now do Y","wait":true}}
{"tool":"agent_manage","args":{"op":"cleanup_sessions","session_ids":["<uuid>"]}}
```
""",
	cli: """
```bash
# Search · Read · Edit · File ops
rpce-cli -w <window_id> -e 'search "keyword"'
rpce-cli -w <window_id> -e 'read Root/file.swift --start-line 50 --limit 30'
rpce-cli -w <window_id> -e 'call apply_edits {"path":"Root/file.swift","search":"old","replace":"new"}'
rpce-cli -w <window_id> -e 'file create Root/new.swift "content..."'

# Selection · Builder · Oracle
rpce-cli -w <window_id> -e 'select add Root/path/file.swift'
rpce-cli -w <window_id> -e 'builder "<task>" --response-type plan'
rpce-cli -w <window_id> -e 'chat "..." --mode plan'

# Delegate · Fan-out · Steer · Cleanup
rpce-cli -w <window_id> -e 'agent_run op=start model_id=explore session_name="Probe: X" message="<question>" detach=true'
rpce-cli -w <window_id> -e 'agent_run op=wait session_ids=["<uuid1>","<uuid2>"]'
rpce-cli -w <window_id> -e 'agent_run op=steer session_id="<uuid>" message="now do Y" wait=true'
rpce-cli -w <window_id> -e 'agent_manage op=cleanup_sessions session_ids=["<uuid>"]'
```
"""))

Continue with your task using these tools.
"""
	}

	/// CLI variant of rp-mcp (reminder) - uses rpce-cli commands.
	static var rpReminderCLI: String { rpReminder(variant: .cli) }

}
