import Foundation
import JSONSchema
import MCP
import Ontology
import RepoPromptAgentCore

@MainActor
final class MCPOracleToolProvider: MCPWindowToolProviding {
    let group: MCPWindowToolGroup = .oracle

    private let runtime: MCPWindowToolRuntime
    private let dependencies: MCPWindowToolDependencies

    init(runtime: MCPWindowToolRuntime, dependencies: MCPWindowToolDependencies) {
        self.runtime = runtime
        self.dependencies = dependencies
    }

    func buildTools() -> [Tool] {
        [
            oracleUtilsTool(),
            askOracleTool(),
            oracleSendTool(),
            oracleChatLogTool()
        ]
    }

    private func oracleUtilsTool() -> Tool {
        runtime.tool(
            name: MCPWindowToolName.oracleUtils,
            freshnessPolicy: .none,
            description: """
            Oracle helper utilities.

            Use this for read-only oracle-specific helpers:
            - `op="models"`   → list model choices relevant to oracle sends
            - `op="sessions"` → list oracle/chat sessions for the current workspace. Pass context_id to filter to a specific context's sessions.

            Model discovery lists only selectable models under Available models. If configured presets are disabled or temporarily hidden, it reports them separately as NOT selectable with exact remediation. Do not pass those presets to ask_oracle until they are enabled.

            Use `ask_oracle` for all send/continue turns.
            """,
            inputSchema: .object(
                properties: [
                    "op": .string(description: "Helper operation", enum: ["models", "sessions"]),
                    "limit": .integer(description: "Maximum sessions to return for the sessions operation"),
                    "scope": .string(description: "Filter scope: 'workspace' (default) or 'tab'. Auto-inferred when context_id is provided."),
                    "context_id": .string(description: "Context UUID to filter to a specific context's sessions. Use bind_context op=list to discover values.")
                ],
                required: ["op"]
            )
        ) { [dependencies] _, args in
            try await dependencies.executeOracleUtils(args)
        }
    }

    private func askOracleTool() -> Tool {
        runtime.tool(
            name: MCPWindowToolName.askOracle,
            freshnessPolicy: .providerManaged,
            description: """
            Agent-mode oracle send/continue tool.

            Use this to start or continue an oracle conversation in `chat`, `plan`, or `review` mode for the current agent tab.

            `op` defaults to `send`. Single sends, `consultations` batches, and `op:"wait"` are bounded observations: routinely omit `timeout_seconds` to use the parent-family automatic wait, or pass `0` to poll. A timeout or steering wake returns pending operation handles while the same Oracle queries keep running. Pending may include advisory sampled `progress`: response character count and observed stream-activity age for bound work, or a zero-based FIFO queue position for queued batch lanes. It contains no response text and never proves completion, failure, provider liveness, cache state, or TTL. Pending is normal: never resend the question. Resume with `op:"wait"` and the returned handles; after compaction, omit `operation_ids` to collect every owned undelivered operation in the current tab, including more than 16. After a steering wake, respond to the user first, then resume waiting. A wait or transport heartbeat does not issue a provider-model request and does not warm a prompt cache.

            `op:"wait"` accepts only `operation_ids` and `timeout_seconds`; `op:"cancel"` accepts only required operation IDs and does not wait. Both controls reject all send arguments. Cancel only when the user asks or the question is known to be wrong. An unkeyed repeated send is a new consultation; a caller-supplied UUID `request_id` protects an identical live send from duplicate spend but is not persisted across app relaunch.

            Every Oracle send re-packages the full chat history. `selection_mode` controls this send's packaging on any single send with an explicit conversation target (`chat_id` or `new_chat:true`): `current` (default) re-packages the current workspace selection exactly as before; `none` sends no workspace selection and suppresses review-mode frozen/automatic diffs for this send; `explicit_slices` packages only the supplied `slices` for this send. Explicit slices never mutate the shared workspace selection. In `review` mode, `none` and `explicit_slices` omit the automatic diff, so put diff text in `message` or slice the changed files. `consultations` lanes always package `current`. Prune selection, use `selection_mode:none`, or continue a long lane in a fresh chat with a concise summary.

            Before a `review` of Git changes, publish the diff with `git_review_snapshot` (for example `{"scope":"selected"}`); it auto-selects the review artifacts that `current` packaging sends. It stays available in Agent Mode runs that hide `git` because the run has a native shell.

            Before a provider starts, the exact immutable packaged request is checked against a known model context window with output reserve and tokenizer margin. `max_output_tokens` customizes only that reserve. Unknown context windows skip the overflow check. Result usage echoes `context_window` and `pct` only for exact windows, never provider fallbacks, and reports the applied `output_reserve_tokens`.

            `response_mode` controls how much reply text returns inline: `full` (default) returns the complete response; `tail` returns the last ~2000 characters as `excerpt` plus stats; `none` returns stats only. Whenever the reply is trimmed (`tail` or `none`), the full response is auto-exported and the result includes `export_path`, shareable `oracle_export_path` / `oracle_export_instruction`, `line_count`, and `char_count` so the full text remains retrievable. Ask Oracle replies to end with a final `## Recommendations` section so `tail` remains semantically useful.

            `consultations` accepts 1...16 independent new-chat lanes and atomically returns one operation receipt per lane in stable input order. The app queues excess lanes in a per-tab FIFO behind the authoritative 2-stream Oracle cap; existing single sends and legacy `oracle_send` streams occupy that cap and are never queued. Batch responses use the same `results` + `wait` + `wait_policy` envelope as `op:"wait"`; each lane keeps its `index`, and pending lanes may report `queued`, `starting`, `streaming`, or `cancelling`. Resume or cancel lanes by operation ID. A batch root accepts only `consultations`, `require_distinct`, `op`, and `timeout_seconds`; each lane accepts only `message`, `model`, `mode`, `chat_name`, and `response_mode`. Batch `request_id` is unsupported: recover accepted work with `op:"wait"` rather than resending. At most 32 nonterminal Oracle operations may exist per tab across all callers and singles/batches. Optional `require_distinct:true` rejects the whole batch before admission when two items resolve to the same preset. Continue completed lanes with their returned `chat_id`. Under parallel use, always pass an explicit `chat_id` to `oracle_chat_log`.

            A `chat_id` continuation stays on the model preset that chat last used, so `model` can be omitted and the lane will not drift. Passing a different `model` with `chat_id` deliberately switches that lane from then on. If the chat's preset was deleted, disabled, or no longer supports the requested `mode`, the call fails instead of silently substituting another model. A manual send into the chat from the app resets its preset binding. Each result reports how the model was chosen through `model_selection` (`explicit`, `inherited`, or `automatic`).

            When the user names one or more Oracles, treat those names as model-preset selectors. Resolve them with `oracle_utils op=models` unless their exact preset UUIDs are already known (for example from an `oracle_model_required` rejection), prefer exact preset UUIDs, and pass an explicit `model` on every new-chat lane. Issue independent lanes together in the same tool-call batch or via `consultations`. `chat_name` is display-only and never selects a model. Before synthesizing, verify each result's returned preset ID/name matches the requested preset; if identity is missing or mismatched, do not synthesize. Refer to lanes by preset alias only, and never relay one lane's metadata to another.

            On a single send, pass `export_response: true` to write the response to a shareable file and get back shareable `oracle_export_path` / `oracle_export_instruction` values. `export_response` is single-send only and is rejected with `consultations`; to export a batch lane, set that lane's `response_mode` to `tail` or `none`, which auto-exports it and returns that lane's own `oracle_export_path` / `oracle_export_instruction`. To hand the export to a child agent, include `oracle_export_path` inside the `message` (or `messages`) you send on your next delegation call; your system prompt names the specific delegation tool available to you.

            After compaction, first call `op:"wait"` without `operation_ids` to recover owned undelivered results. Use `oracle_chat_log` with a known `chat_id` only to recover conversation text when no operation can be collected; never reconstruct a lost operation by resending.

            Recipes: wait = `{"op":"wait","operation_ids":["<operation_id from the send>"]}`; cancel = `{"op":"cancel","operation_ids":["<operation_id>"]}`; slice = `{"path":"Sources/App.swift","ranges":[{"start_line":10,"end_line":40}]}`. Omit `op` when sending; set it only to wait or cancel. When a result includes `resume`, send exactly that object as the next call; do not merge it into the original send arguments.
            """,
            annotations: .repoPromptLocalEphemeralState,
            inputSchema: .object(
                properties: [
                    "op": .string(
                        description: "Operation: send (default), wait, or cancel. wait observes existing operations without resending; cancel never waits.",
                        default: "send",
                        enum: ["send", "wait", "cancel"]
                    ),
                    "timeout_seconds": .number(
                        description: "Single send, consultations batch, or wait observation bound in seconds, 0...14400. Omit for the parent-family automatic wait; zero polls. A timeout returns pending and never stops the Oracle. Rejected with cancel."
                    ),
                    "request_id": .string(
                        description: "Optional caller-generated UUID for duplicate-spend protection on a single send. Identical live retries observe the same operation; conflicting intent is rejected. Not persisted across app relaunch. Rejected with consultations, wait, and cancel."
                    ),
                    "operation_ids": .array(
                        description: "Operation UUIDs for wait or cancel (1...16, distinct). Optional for wait: omission collects all owned undelivered operations in the current tab, including after compaction. Required for cancel. Rejected on send.",
                        items: .string(description: "Oracle operation UUID")
                    ),
                    "message": .string(
                        description: "Your message to send (single-send mode). Mutually exclusive with `consultations`.",
                        minLength: 1
                    ),
                    "mode": .string(
                        description: "Operation mode",
                        default: "chat",
                        enum: ["chat", "plan", "review"]
                    ),
                    "chat_id": .string(
                        description: "Continue a specific chat in the current agent tab. The chat keeps the model preset it last used, so `model` can be omitted."
                    ),
                    "new_chat": .boolean(
                        description: "Start a new chat session (default: false). Keep false for continuity; use true for an independent review or each independent parallel lane. A fresh chat needs an explicit `model` when more than one preset supports the mode; the rejection lists the exact preset UUIDs to retry with."
                    ),
                    "model": .string(
                        description: "Exact model preset UUID (preferred) or exact preset name from oracle_utils op=models. Required when the user requests a named Oracle, and on a fresh chat when more than one preset supports the mode; that rejection lists the exact preset UUIDs to retry with. Omit it with `chat_id` to keep that chat's current preset; passing a different preset switches the chat to it."
                    ),
                    "chat_name": .string(
                        description: "Optional display-only session name; valid only with new_chat:true. This never selects the model."
                    ),
                    "selection_mode": .string(
                        description: "Single-send context mode. none and explicit_slices require an explicit conversation target (`chat_id` or `new_chat:true`) and are rejected in `consultations`. current (default) packages the current shared selection; none packages no selection and no review diff; explicit_slices packages only `slices` for this send without mutating shared selection.",
                        default: "current",
                        enum: ["current", "none", "explicit_slices"]
                    ),
                    "slices": .array(
                        description: "Send-local file/range specs used only with selection_mode:explicit_slices. Uses manage_selection slice vocabulary and never mutates shared selection. Each slice needs `ranges` or `lines`; a path alone is rejected.",
                        items: .object(
                            properties: [
                                "path": .string(description: "Relative or absolute file path"),
                                "ranges": .array(
                                    description: "Inclusive line ranges",
                                    items: .object(
                                        properties: [
                                            "start_line": .integer(description: "1-based start line"),
                                            "end_line": .integer(description: "1-based end line"),
                                            "description": .string(description: "Optional slice description")
                                        ],
                                        required: ["start_line"]
                                    )
                                ),
                                "lines": .string(description: "Comma-separated shorthand such as '10-20,40'")
                            ],
                            required: ["path"]
                        )
                    ),
                    "max_output_tokens": .integer(
                        description: "Positive output-token reserve for the pre-send context-budget check. Defaults to known model output metadata, otherwise 8192."
                    ),
                    "response_mode": .string(
                        description: "How much reply text to return inline: full (default) returns the complete response; tail returns the last ~2000 characters as excerpt plus export_path/stats; none returns export_path/stats only. Trimmed modes always auto-export the full response and return shareable oracle_export_path/oracle_export_instruction.",
                        default: "full",
                        enum: ["full", "tail", "none"]
                    ),
                    "export_response": .boolean(
                        description: "Single send only; rejected with `consultations` (set a lane's `response_mode` to tail or none to export it instead). When true, export the response to a file and return `oracle_export_path` plus `oracle_export_instruction`. Include `oracle_export_path` inside the `message` you send on your next delegation call; the specific delegation tool is named by your system prompt."
                    ),
                    "consultations": .array(
                        description: "Bounded resumable batch of 1...16 independent new-chat Oracle consultations. Valid only for send (op omitted or send); mutually exclusive with the single-send parameter set (including export_response), operation_ids, and request_id. Returns stable indexed lane receipts in the shared results/wait envelope, queues excess lanes behind actual per-tab Oracle stream capacity, and supports later wait/cancel by operation ID.",
                        items: .object(
                            properties: [
                                "message": .string(
                                    description: "Message for this consultation",
                                    minLength: 1
                                ),
                                "model": .string(
                                    description: "Exact model preset UUID or name for this lane"
                                ),
                                "mode": .string(
                                    description: "Operation mode for this lane",
                                    default: "chat",
                                    enum: ["chat", "plan", "review"]
                                ),
                                "chat_name": .string(
                                    description: "Optional display-only session name for this lane"
                                ),
                                "response_mode": .string(
                                    description: "Per-item response_mode override (full|tail|none). tail and none auto-export this lane and return its shareable oracle_export_path/oracle_export_instruction; this is the batch export path.",
                                    default: "full",
                                    enum: ["full", "tail", "none"]
                                )
                            ],
                            required: ["message", "model"]
                        )
                    ),
                    "require_distinct": .boolean(
                        description: "When true with consultations, reject the whole batch before any lane starts if two items resolve to the same preset/model."
                    )
                ],
                required: []
            )
        ) { [dependencies] _, args in
            try await dependencies.executeAskOracle(args)
        }
    }

    private func oracleSendTool() -> Tool {
        runtime.tool(
            name: MCPWindowToolName.oracleSend,
            freshnessPolicy: .providerManaged,
            description: """
            Consult a second AI for planning, review, or questions.

            Use this to start or continue an oracle conversation in `chat`, `plan`, or `review` mode.
            Use `oracle_utils` for passive helpers like models and sessions. Pass either `chat_id` to continue or `new_chat:true` to start fresh; the two arguments cannot be combined.

            A `chat_id` continuation stays on the model preset that chat last used, so `model` can be omitted. Passing a different `model` with `chat_id` deliberately switches that chat from then on.

            Pass `export_response: true` to write the response to a shareable file and get back shareable `oracle_export_path` / `oracle_export_instruction` values. To hand the export to a child agent, include `oracle_export_path` inside the `message` (or `messages`) you send on your next delegation call; your system prompt names the specific delegation tool available to you.

            Build context first with file reads, `manage_selection`, or `workspace_context`. Before a `review` of Git changes, publish the diff with `git_review_snapshot`; it auto-selects the review artifacts.
            """,
            annotations: .repoPromptLocalEphemeralState,
            inputSchema: .object(
                properties: [
                    "message": .string(
                        description: "Your message to send",
                        minLength: 1
                    ),
                    "mode": .string(
                        description: "Operation mode",
                        default: "chat",
                        enum: ["chat", "plan", "review"]
                    ),
                    "chat_id": .string(
                        description: "Continue a specific chat in the current tab or current context. The chat keeps the model preset it last used, so `model` can be omitted."
                    ),
                    "new_chat": .boolean(
                        description: "Start a new chat session (default: false). Keep false for continuity; use true for an independent review. Cannot be combined with chat_id."
                    ),
                    "model": .string(
                        description: "Model preset ID or name override. With `chat_id`, omitting it keeps the chat's current preset and passing a different one switches the chat to it."
                    ),
                    "export_response": .boolean(
                        description: "When true, export the response to a file and return `oracle_export_path` plus `oracle_export_instruction`. Include `oracle_export_path` inside the `message` you send on your next delegation call; the specific delegation tool is named by your system prompt."
                    )
                ],
                required: ["message"]
            )
        ) { [dependencies] _, args in
            try await dependencies.executeOracleSend(args)
        }
    }

    private func oracleChatLogTool() -> Tool {
        runtime.tool(
            name: MCPWindowToolName.oracleChatLog,
            freshnessPolicy: .none,
            description: """
            Read recent Oracle conversation messages to recover context during agent mode.

            Returns recent Oracle chat messages as lightweight `{ role, text }` objects. Available only during agent mode runs.

            **Parameters**:
            - `chat_id` (optional): Target a specific Oracle chat (short ID or UUID). Omit to read the most recent one.
            - `limit` (optional): Number of messages to return (default: 8, range: 1–50)
            - `include_user` (optional): Include your own messages in output (default: false)
            - `max_chars` (optional): Per-message character budget (default: 8000)
            - `part` (optional): Which portion to keep when trimming a message: `head`, `tail` (default), or `both`
            - `max_total_chars` (optional): Ceiling across all returned message texts; later messages are trimmed first when exceeded

            Truncation is self-describing: `[truncated: N of M chars omitted; …]`. When no export path exists, the marker tells you to export via ask_oracle `export_response` or retry with a larger `max_chars`.
            """,
            annotations: .repoPromptLocalReadOnly,
            inputSchema: .object(
                properties: [
                    "chat_id": .string(description: "Chat ID (short ID or UUID) to read"),
                    "limit": .integer(description: "Max number of messages to return (default: 8, min: 1, max: 50)"),
                    "include_user": .boolean(description: "Include user messages in output (default: false)"),
                    "max_chars": .integer(description: "Per-message character budget (default: 8000)"),
                    "part": .string(
                        description: "Portion to keep when a message exceeds max_chars: head, tail (default), or both",
                        default: "tail",
                        enum: ["head", "tail", "both"]
                    ),
                    "max_total_chars": .integer(
                        description: "Optional ceiling across all returned message texts. When omitted, no total ceiling is applied."
                    )
                ],
                required: []
            )
        ) { [dependencies] _, args in
            try await dependencies.executeOracleChatLog(args)
        }
    }
}
