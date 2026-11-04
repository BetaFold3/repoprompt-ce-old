# Code-mode readiness, RepoPrompt-owned code-mode executor, and Git surface narrowing plan

Scope: read when the task touches MCP `outputSchema`/`structuredContent` delivery, structured results for `read_file`/`file_search`/`get_code_structure`/`get_file_tree`, a RepoPrompt-owned code-mode script executor (`code_mode`), nested tool dispatch from a script, the `git_review_snapshot` tool, or shell-aware narrowing of the `git` tool in Agent Mode runs.
Authority: Reference
Last-verified: 2026-10-12

Status: Steps 0–5 and updated-base integration are implemented, independently reviewed, and committed through 9b832ea8; the reviewed live collector is committed as 342c8334. The original 280-attempt comparison remains unchanged: Claude fails task-level correctness and the strict attempted-tool violation rule, with two unusable attempts; Codex passes implemented checks but targeted multi-step/heavy savings are not established. The 2026-11-04 follow-up audited the original Claude traces, completed eight separate Sonnet/Opus diagnostic attempts without replacement, and completed a genuine provider-native Bash-disabled Git/snapshot-to-Oracle flow after one explicit recovery. All eleven original flagged sessions made rejected unavailable-tool calls, not successful native file/shell access; the original gate result is not rewritten. Native defaults and D1 structured results off remain unchanged. Step 6 remains blocked for promotion/closure: model patch-context errors and MCP startup/first-call reliability remain distinct concerns, with startup cause unproven. The subsequent identity-correlated startup investigation recovered pre-session launch logs and completed one additional native Opus 5.5 read probe with verified app/launcher/provider/helper ancestry and routing. Exact-session Claude per-server logs identify all three startup failures as early Connection closed errors after client-reported 221–237 ms with a configured 30-second timeout, excluding expiry of that full timer. The initiating component remains unproven, and the checked app/helper terminal retention window postdates the failures; successful-path capture does not qualify pre-admission failure capture or establish reliability. An app-only, opt-in DEBUG startup capture is implemented in ca73d78c and independently reviewed by OracleA/OracleB, with 75 focused tests passing; owner-approved optimized-incremental installation and one identity-correlated native Opus 5.5 Git-snapshot/read probe passed on 2026-11-04. Capture recorded early peer, bootstrap and approval acceptance and drained cleanly; no startup failure reproduced, so historical attribution remains unresolved. It adds typed early-peer, refusal-site, approval and terminal evidence without changing admission, retries, timeouts or defaults. Structured-enabled provider presentation remains unverified. Startup investigation evidence is local under docs/context/plans/evidence/2026-10-03-code-mode-readiness-and-git-narrowing/mcp-startup-investigation-2026-11-04/. Full results and limitations are local under docs/context/plans/evidence/2026-10-03-code-mode-readiness-and-git-narrowing/live-gate-2026-11-03/ and claude-followup-2026-11-04/. The new capture is instrumentation, not a reliability fix or default promotion; no blanket executor-savings claim follows.

Step 0 — done | rounds 2/2 | open: none | downgraded: none | assumed: single-turn Claude Code/Codex harness only; multi-turn sessions and other historical experiments remain local (reversible scope cut; see evidence) | deferred: live/paid gate and source-built QuickJS validation; non-blocking findings and recovery cautions recorded in the step-0 evidence
Step 1 — done | rounds 1/2 | open: none for default-off implementation (5748d6c6) | downgraded: none | assumed: raw MCP off/on schemas, structured objects, unchanged text and connection snapshot behavior passed on the relaunched app; evidence in live-gate-2026-11-03 | deferred: structured-enabled provider presentation and D1 per-host §7 gate before enablement; non-blocking review notes and D3 reserved-notice sink semantics in local step-1 evidence

Step 2 — done | rounds 1/2 | open: none for implementation or bounded Git-to-Oracle acceptance | downgraded: wildcard-filter concern is P3 after literal-Git audit | assumed: shell-enabled and unknown-shell checks passed; genuine ordinary Claude Bash-disabled Git/snapshot flow passed after one explicit recovery, with exact artifacts consumed by OracleA/OracleB; temporary project denial removed and fixture restored | deferred: first Git status Connection closed remains a separate reliability observation; non-blocking coverage, empty multi-repo publication and folder-selection caveats in step-2 evidence; current live proof in claude-followup-2026-11-04

Step 3 — done | rounds 0/2 | open: none | downgraded: none | assumed: existing 2026-10-11 prototype approval in §3.8 and §8 remains authoritative; no new implementation | deferred: no new paid prototype run; in-app confirmation belongs to Step 6
Step 4 — done | rounds 1/2 | open: none for inert code scope; full-suite exception remains documented | downgraded: working_dirs routing concern closed by normalizer/allowlist audit | assumed: inert seam only; unanswered baseline-failure question follows recommended documented exception confirmed at 11398839 (local step-4 evidence), not a green full suite | deferred: codemap preload baseline failure; production eligibility and companion coexistence/activation move atomically to Step 5; live acceptance pending lifecycle approval

Step 5 — done | rounds 1/2 | open: none for reviewed implementation | downgraded: none | assumed: app_settings-only opt-in; actual Claude alias and Codex direct-companion execution, warm continuation, cancellation/native recovery and bounded-failure checks passed on the unchanged optimized app; live-gate-2026-11-03 evidence | deferred: native defaults unchanged; explicit dynamic Claude model ID eligibility remains limited to the qualified alias workaround; non-blocking notes in step-5 and step-5-codex evidence

Step 6 — blocked | rounds 2/2 | open: promotion/closure not approved; original Claude task-level gate failure remains; initiating cause of early MCP startup connection closures and separate first-call failure unknown; new DEBUG startup capture installed and successful-path live wiring verified, but live failure attribution remains pending; helper death before app receipt remains unobservable; Codex targeted multi/heavy savings remain unestablished | downgraded: none | assumed: native defaults retained; eight separate diagnostic attempts preserved (seven completed, one Opus MCP-init failure), no replacements or original-gate pooling; all completed Opus patches apply strictly, Sonnet context/count errors persist, neither model invoked code_mode on E1; original rejected tool-name attempts remain violations under unchanged collector rules; no-shell Git-to-Oracle replay passed after recovery; one separate identity-captured native Opus 5.5 startup/read passed on the unchanged app, ruling out an unconditional launcher/provider PID-equality requirement but not transient races; owner-authorized opt-in DEBUG capture implemented, A/B reviewed with no P0/P1, 75 focused tests passed, non-blocking follow-ups resolved or deferred; ca73d78c installed with owner approval, one additional native Opus 5.5/medium Git-snapshot/read probe passed with correlated launch/helper/connection acceptance and drained capture, no failure reproduced; local controller schema mistake and pre-start advertised model-ID rejection preserved separately; a further owner-requested real Claude source investigation completed nine successful MCP reads/searches with drained capture and no startup failure, independently locating the invalid advertised Claude selector in ToolOutputFormatter effort shorthand (unfixed), as recorded in mcp-startup-diagnostics-2026-11-04/real-work-capture-03-findings.txt | deferred: owner acceptance; structured-enabled provider presentation/D1 gate; explicit dynamic Claude ID eligibility fix; broader live workloads and any promotion campaign; no default change or additional unapproved lifecycle action

Owner decisions (2026-10-03, unchanged):
1. Scope is code mode plus Git narrowing. Pi provider work is out of scope (`docs/context/plans/pi-provider-integration.md`).
2. Context Builder is deprecated: no investment, current behavior kept, no constraint on Git design.
3. Git: hide plain inspection only in runs that have a native shell; keep a review snapshot everywhere.
4. The executor is RepoPrompt-owned, phased, and gated by measurement.
5. Knowledge sessions are unchanged: no `git`, no snapshot, no executor.
6. The executor engine is vendored QuickJS-ng.
7. The executor is Agent Mode–only until its gate passes.

## 1. Summary

| Deliverable | What | Measured basis (§3) | Plan |
|---|---|---|---|
| D1 Structured results | Keep today's text; add `structuredContent` and `outputSchema` for the four exploration tools | Clients disagree on what they show the model. Codex about 9% cheaper (not yet significant); Claude cost-neutral and more correct; Pi dearer | Ship the capability default-off; turn it on per host after a confirming gate run (Codex first) |
| D2 Git narrowing | `git_review_snapshot` everywhere; hide `git` in runs with a shell | Shell already carries more Git inspection than the tool | Ship |
| D3 `code_mode` executor | Bounded script over the four read-only tools, for runs where RepoPrompt's tools are called directly (never inside a client's code mode) | Optional `code_mode` is about 11% cheaper on Claude, about 20% cheaper on Codex with RepoPrompt tools taken out of Codex's code mode, and about 44% cheaper than Pi's own code mode, all at equal correctness; nested inside Codex's code mode it is about 12% dearer; heavy fan-out turns produce 61% of real exploration output | Experimental and optional, per provider; confirm with the prototype at 5 repetitions and a fixed result shape, then build the QuickJS engine |
| D4 Measurement | Usage analyzer plus a controlled lab harness | Both exist locally | The harness and one gate decide every default |

Non-goals: Pi provider integration; Context Builder changes; Knowledge policy; a `code_mode` tool nested inside a client's code mode; rewriting a provider's model catalog; persistent script state; edits, selection, Git, Oracle or delegation inside scripts.

## 2. Verified repository facts

| Fact | Evidence |
|---|---|
| Successful window-tool calls return Markdown text only. | `Sources/RepoPrompt/Infrastructure/MCP/MCPConnectionManager.swift:13102-13103` |
| No server code produces `structuredContent` or `outputSchema`; the pinned SDK supports both. | `.build/checkouts/swift-sdk/Sources/MCP/Server/Tools.swift:23,100-108` |
| Typed DTOs already exist and are encoded to `Value` before formatting; hidden `_rawJSON` returns them as compact JSON text. | `ToolResultDTOs.swift` (`SearchResultDTO`, `FileTreeDTO`, `CodeStructureReplyDTO`, `ReadFileReply`); `MCPToolArgsNormalizer.swift:161-163,203-205`; `ToolOutputFormatter.swift:977-1021` |
| The handshake client name is stored per connection (`ctx.clientName = clientInfo.name`). Client names are client-asserted and must never authorize anything. | `MCPConnectionManager.swift:5583`, `:186-192` |
| Admission: small reads 2 per connection and 2 per window; searches 4; Git 2 per connection + 1 per repository; exclusive 1; control 8. Lanes are independent limiters. | `Policies/MCPToolAdmissionPolicy.swift:32-38`; `MCPConnectionManager.swift:1535-1545,1821-1836` |
| Every advertised tool needs an execution contract and an admission class; only `.bounded` contracts get the server watchdog. | `Policies/MCPToolExecutionContract.swift:59-105`; `MCPConnectionManager.swift:12743-12747` |
| Agent Mode `read_file` and eligible searches enqueue automatic selection. | `ViewModels/MCPReadFileAutoSelectionCoordinator.swift:3-8` |
| `git` is one tool with `op` + `artifacts`; artifacts auto-select review files and Oracle review needs them. | `WindowTools/MCPGitToolProvider.swift:331-372,436-447,695-747` |
| Shell availability is a per-run fact (Claude keeps Bash unless the preference is off or the profile is `.mcpSafeDefaults`; Knowledge and discovery runs disallow it). Run restrictions are enforced at both `tools/list` and `tools/call`. | `ClaudeControllerLaunchPolicy.swift:5-25`; `ClaudeCodeIntegrationConfiguration.swift:47-67`; `AgentModeRunLease.swift:14-24`; `MCPConnectionManager.swift:11395-11420` |
| RepoPrompt's OpenCode overlay registers the RepoPrompt server without a `codemode` key and allows `bash` in managed interactive mode. | `Sources/RepoPromptAgentCore/AI/Providers/OpenCode/OpenCodeIntegrationConfiguration.swift:32-41,117-128,293-295` |

## 3. Evidence

All numbers are local aggregates; no private session content is quoted. Token figures from client logs are provider-reported, not billing. The full per-arm, per-task and per-turn figures, the method details, and the non-token measurements are recorded in [code-mode lab measurements](../code-mode-measurements.md); this section keeps the decision-relevant summaries.

### 3.1 Usage baseline (2026-04-03 to 2026-10-04)

From `Scripts/analyze_tool_usage.py` over 3,488 Codex and 978 Claude Code session files (pass every Claude log root with repeated `--claude-root`).

- `read_file` (21,379 calls, 27.3% of all tool output) and `file_search` (7,970, 10.7%) dominate; the four exploration tools are 88.7% of RepoPrompt's output. RepoPrompt's burden is tool **results**, not tool definitions.
- Claude Code is a heavy RepoPrompt user (988 RepoPrompt turns, median 11 / p90 48 calls per turn) and already batches calls natively (5,655 multi-call batches).
- Codex already uses its native code mode on RepoPrompt: 1,452 of 1,958 `exec` scripts call RepoPrompt tools; 513 use `Promise.all`.
- 42–50% of reads re-read a path already read in the session (58M characters); search→read joins are low (5–9%).
- Git: RepoPrompt `git` 1,673 (Codex) / 286 (Claude) calls versus 2,269 / 2,202 shell Git inspection commands. Artifact publication is 4% of Codex `git` calls but 23% of Claude's.

### 3.2 Prior art

| Source | What it says or does | Takeaway for this plan |
|---|---|---|
| Armin Ronacher, "Codemode" (2026-10-06), and Pi 1.1 docs (`codemode.md`, `mcp.md`) | Pi runs scripts on the harness in QuickJS/WASM with no network, filesystem or timers; MCP tools default to code-mode exposure (`codemode`, `deferred`, `direct`, `hidden`); scripts get the full `CallToolResult`; tool calls are capped at 4 concurrent; `store`/`load` keep values across scripts; probe 5–10 items, then process the rest. The post asks MCP servers for `structuredContent` + `outputSchema`, results that are consistent regardless of size, and composable tool search. It warns that server-side code mode inside a client's code mode is "pretty bad", that durability is hard, and that smaller models do worse. It publishes no measurements. | Supports D1's "same result, plus structure" shape. Supports restricting D3 to runs where RepoPrompt's tools are called directly, never nested in a client's code mode. Gives no evidence of size of wins, so §3.4 measures it. |
| OpenCode v2 Code Mode (source on `dev`, release 1.18.34; v2 docs) | Default for every MCP server: tools sit behind one `execute` tool. Scripts receive `structuredContent` when present, otherwise text, and never parse text. Its headline saving (177k → 13k tokens) measured tool-definition overhead with a 97-tool server. Open issue #51849: stdio servers fail with `Unknown tool` in v2 code mode. | OpenCode v2 puts RepoPrompt behind its code mode by default. The headline saving (tool definitions) does not transfer, but the lab found v2's default cheaper for RepoPrompt for other reasons (§3.4, §8). |
| Codex 0.159 | Its model catalog marks every current model `tool_mode: "code_mode_only"` (only the older gpt-5.5 is not), so all MCP calls run inside `exec`; scripts get typed declarations and the full result. Rewriting the catalog breaks tool discovery (§3.6). The documented key `features.code_mode.direct_only_tool_namespaces` exposes named MCP namespaces as direct tools and removes them from the `exec` surface, while code mode stays on for everything else. | Codex can join D3 through the namespace key; never through the catalog. |

### 3.3 Live client probe (2026-10-10)

A stdio fixture returned different sentinels in text (`TXT-…`, a one-line summary) and in `structuredContent` (`STRUCT-…` plus an items array) for the same call.

| Client (handshake `clientInfo.name`, version) | Direct call: model sees | Native script sees |
|---|---|---|
| Claude Code (`claude-code` 2.1.281) | **Only `structuredContent` as JSON; the text is dropped** | No native code mode |
| Codex (`codex-mcp-client` 0.159.0) | Both | Full result (`content`, `structuredContent`, `isError`) |
| OpenCode (`opencode` 1.18.34) | Text only | `execute` (experimental flag): `structuredContent` only; text dropped |
| OpenCode v2 (`opencode` 2.0.26, package `@opencode/cli`) | Text only (`codemode: false`) | `execute` (the default): `structuredContent` only; text dropped. Issue #51849 (`Unknown tool` on stdio servers) did not reproduce |
| Pi (`pi` 1.1.0) | Text only | Full result; scripts often pass it through with `text(JSON.stringify(r))`, so the model then sees both |

Consequences: a compact summary text (the earlier `structuredCompact` idea) would starve OpenCode and Pi direct callers, and Claude would see JSON regardless. The only safe shape is **text unchanged + `structuredContent`**. For Claude Code that shape still replaces Markdown with JSON on the wire.

JSON versus today's Markdown on a 24-call corpus from this repository: `read_file` +3%, `get_file_tree` +2%, `get_code_structure` +6%, `file_search` +72% (JSON keeps full match lines where Markdown truncates to about 160 characters), `git` +82%. Any client that shows the model the JSON pays these deltas.

### 3.4 Controlled lab experiment (2026-10-10)

Harness: `docs/investigations/2026-10-10-codemode-lab/` (local). An MCP proxy in front of `repoprompt_ce_cli_debug` exposes only the four exploration tools and can add `structuredContent` (from `_rawJSON`) and a prototype `code_mode` tool (Node `vm` sandbox; nested results `{text, data, isError}`; 60 s, 32 calls, 32 KiB output). Eight tasks with machine-checked ground truth: three single-lookup, three multi-step, two heavy fan-out (rank or count across 20–30 files). Three repetitions per arm and task. Native file and shell tools are disabled where the host allows it, and violations are counted.

| Host and model | Arms |
|---|---|
| Claude Code, Sonnet | `cc_text` (today), `cc_struct` (+`structuredContent`), `cc_cm` (+optional `code_mode`), `cc_cm_only` (only `code_mode`) |
| Pi 1.1, `gpt-6-sol` (low) | `pi_direct`, `pi_cm` (Pi code mode), `pi_cm_struct` |
| Codex 0.159, `gpt-6-sol` (low) | `cx_text`, `cx_struct` (code mode is always on) |
| OpenCode 1.18.34, `big-pickle` | `oc_direct`, `oc_cm` (experimental `execute`), `oc_cm_struct` |
| OpenCode 2.0.26, `big-pickle` (isolated install) | `oc2_direct` (`codemode: false`), `oc2_cm` (default code mode), `oc2_cm_struct` |

**Metric.** Raw token totals are dominated by cheap cache reads (47–90% of all tokens depending on host), so the comparison uses **price-weighted tokens**: uncached input ×1, cache write ×1.25, cache read ×0.1, output ×5 (Sonnet's relative prices). On Claude this tracks the billed cost closely ($2.36–3.02 per million weighted tokens across all 96 runs). Ratios are the geometric mean over tasks of per-task medians against the host's baseline arm; brackets are 95% bootstrap intervals (resampling repetitions within tasks); below 1 is cheaper.

| Host | Change vs host baseline | Single lookup | Multi-step | Heavy fan-out | All tasks | Correct (change / baseline) |
|---|---|---:|---:|---:|---:|---:|
| Claude Code | optional `code_mode` (`cc_cm`) | ×1.00 [0.93–1.08] | ×0.95 [0.91–1.11] | ×0.67 [0.27–0.90] | ×0.89 [0.72–1.00] | 96% / 96% |
| Claude Code | only `code_mode` (`cc_cm_only`) | ×1.29 [1.03–1.32] | ×1.05 [0.87–1.39] | ×0.46 [0.24–0.57] | ×0.93 [0.74–1.01] | 92% / 96% |
| Claude Code | +`structuredContent` (`cc_struct`) | ×1.02 [0.95–1.09] | ×1.03 [1.02–1.05] | ×1.10 [0.50–1.62] | ×1.04 [0.85–1.15] | 100% / 96% |
| Codex | +`structuredContent` (`cx_struct`) | ×0.87 [0.64–1.34] | ×0.97 [0.74–1.54] | ×0.89 [0.76–1.39] | ×0.91 [0.81–1.22] | 100% / 100% |
| Pi 1.1 | Pi code mode (`pi_cm`) | ×2.46 [1.67–3.12] | ×1.50 [1.36–1.84] | ×1.30 [0.77–1.44] | ×1.74 [1.41–1.98] | 100% / 100% |
| Pi 1.1 | Pi code mode +`structuredContent` | ×3.26 [2.04–3.94] | ×1.73 [1.58–2.23] | ×1.03 [0.61–1.36] | ×1.93 [1.54–2.15] | 100% / 100% |
| OpenCode 1.18 | experimental code mode (`oc_cm`) | ×1.31 [0.92–1.54] | ×1.24 [0.88–1.49] | ×0.75 [0.57–0.88] | ×1.12 [0.90–1.21] | 92% / 100% |
| OpenCode 1.18 | code mode +`structuredContent` | ×1.21 [1.03–1.35] | ×1.03 [0.77–1.34] | ×0.71 [0.54–0.84] | ×1.00 [0.86–1.11] | 100% / 100% |
| OpenCode 2.0.26 | default code mode (`oc2_cm`) | ×0.37 [0.32–0.59] | ×0.39 [0.31–0.55] | ×0.74 [0.46–1.08] | ×0.45 [0.39–0.58] | 100% / 100% |
| OpenCode 2.0.26 | code mode +`structuredContent` | ×0.58 [0.49–0.98] | ×0.49 [0.42–0.67] | ×0.58 [0.41–0.86] | ×0.54 [0.49–0.72] | 100% / 100% |

Correctness: every arm answered at least 92% of runs correctly. Native-tool or shell violations: one run in 360 (OpenCode v2 with structured content). The only task that broke was T7 (rank the five longest of about 28 files). Claude scripts counted lines in the Markdown `text` (header lines included) instead of using the structured value; `cc_cm_only` was wrong in 2 of 3 runs and `cc_cm` in 1 of 3, while `cc_struct` was right in 3 of 3 and `cc_text` in 2 of 3. Two OpenCode v1 code-mode runs timed out.

Findings:
- **The executor's win is real on Claude, and it comes from heavy fan-out.** Optional `code_mode` costs the same on single lookups, slightly less on multi-step tasks, and about a third less on heavy tasks, where a script replaces about 30 direct reads (T7: 3 turns instead of 31). Forcing scripts for every call (`cc_cm_only`) saves more on heavy tasks but costs 29% more on single lookups and loses correctness. Claude chose the optional tool in 42% of runs, always on heavy tasks and never on single lookups.
- **Client-side code mode depends on the harness.** Pi 1.1 costs 1.5–2.5× more on single and multi-step tasks, and OpenCode v1's experimental mode costs more on small tasks and saves 25–30% only on heavy ones; their overheads come from tool discovery calls, script writing, and scripts that pass raw results through. OpenCode v2 is the opposite: its default code mode is about 55% cheaper than the same harness with `codemode: false` on every task kind, at 100% correctness. Two effects explain it: with code mode off, the v2 model still searches `execute` for the tools first and wastes turns, and scripts return only what is needed. The v2 harness is also lighter overall (first-step context about 10k tokens versus about 17k for v1).
- **Structured results are client-specific.** Codex is cheaper with them (×0.91 overall, interval includes 1). Claude is cost-neutral and gets T7 right every time. Pi gets dearer (×1.11 over Pi code mode), because scripts dump the whole result, which then carries both text and structure. OpenCode v2 code mode gets 20% dearer (×1.20 [1.09–1.45] over its own code mode), because scripts then receive the larger JSON instead of Markdown.
- **Raw-token view, for contrast:** optional `code_mode` looks ×1.09 more expensive on raw totals while it is ×0.89 on price-weighted tokens. Gating on raw totals would have rejected the one real win.

Limits: eight tasks are a small, exploration-only sample; one model per host; cross-host numbers are not comparable (different models and harness prompts), only ratios within a host; wall time is inflated by shared-window admission because runs share one RepoPrompt window (tokens and turns are unaffected); OpenCode ran unrestricted on a free model; Pi used an OpenAI model because its Anthropic login had expired; the executor was a Node prototype in a proxy, not the in-app QuickJS design.

### 3.5 Real-usage checks

Codex, July 2026 (natural comparison): of turns with at least three exploration calls, 161 turns that used `exec` with RepoPrompt calls versus 128 that used direct calls only. Median input tokens were similar (224k versus 231k), model calls 8 versus 9, and duration 40 s versus 58 s, while tool output was larger (56k versus 21k characters, because scripts often return raw results). This is observational and confounded by task choice: script turns looked faster, not cheaper.

How often real work looks like the heavy lab tasks (Claude Code, 2026-04-03 to 2026-10-10, 1,152 user turns with at least one direct exploration call):

| Exploration calls in the turn | Share of turns | Share of exploration output |
|---|---:|---:|
| 1 | 14.1% | 1.1% |
| 2–4 | 26.0% | 5.1% |
| 5–9 | 20.8% | 11.0% |
| 10–19 | 18.1% | 21.6% |
| 20+ | 20.9% | 61.2% |

Fan-out-sized turns are common: a fifth of exploring turns make 20 or more calls and produce 61% of the exploration output. (Counting only adjacent call chains, as the earlier draft did, understated this, because any other tool call breaks a chain.) Most real 20+ turns read code for understanding rather than counting, so the model must still see much of the content; the lab's heavy-task saving is an upper bound for them.

### 3.6 Provider code mode off, RepoPrompt `code_mode` on (2026-10-10 follow-up)

The owner's proposal: use RepoPrompt's `code_mode` and turn off a provider's own code mode where it has one. Same harness and metric as §3.4; the proxy now answers `initialize` and `tools/list` at once (a slow start had hidden the tools from some Codex runs), and the re-run baselines matched the earlier ones within 3%. Codex arms use RepoPrompt's real Codex launch settings (`features.tool_search=false`, apps, plugins and tool suggestions off) on `gpt-6-sol` at low effort.

| Host | Change vs baseline (same model) | Reps | Single | Multi | Heavy | All | Correct | `code_mode` used |
|---|---|---:|---:|---:|---:|---:|---:|---:|
| Codex | RepoPrompt tools direct (namespace key) + optional `code_mode`, vs native code mode | 5 | ×0.76 | ×0.77 | ×0.93 | ×0.80 [0.62–1.03] | 40/40 | 19/40 (multi and heavy only) |
| Codex | RepoPrompt tools direct, no `code_mode`, vs native code mode | 5 | ×0.74 | ×1.40 | ×1.81 | ×1.18 [0.83–1.35] | 40/40 | — |
| Codex | Native code mode + nested `code_mode`, vs native code mode | 3 | ×1.20 | ×1.06 | ×1.08 | ×1.12 [0.92–1.38] | 24/24 | 12/24 |
| Codex | Catalog rewrite (`tool_mode` removed) | 2 | — | — | — | — | 4/16 | 12 of 16 runs never reached the tools |
| Codex gpt-5.5 (no `code_mode_only`) | direct + optional `code_mode`, vs direct | 3 | ×1.00 | ×0.78 | ×0.46 | ×0.75 [0.61–1.13] | 24/24 | 8/24 |
| Pi 1.1 | RepoPrompt server `exposure: direct` + optional `code_mode`, vs Pi direct | 3 | ×0.71 | ×1.19 | ×0.80 | ×0.89 [0.68–1.10] | 24/24 | 12/24 |
| Pi 1.1 | the same, vs Pi's own code mode | 3 | ×0.40 | ×0.76 | ×0.61 | ×0.56 [0.45–0.67] | 24/24 | — |

Findings:
- **Codex can turn its code mode off for RepoPrompt alone,** through `features.code_mode.direct_only_tool_namespaces` (documented in the 0.159 config schema). Verified with the lab server (`mcp__rp`) and with the real `RepoPromptCE` server (`mcp__RepoPromptCE`): calls arrive as direct function calls while `exec` stays available for other tools. The catalog rewrite is not usable: the model often emits a `tool_search_tool` call that Codex rejects, then gives up.
- **On Codex, direct RepoPrompt tools need `code_mode`.** Without it, multi-step and heavy tasks cost 40–81% more than Codex's own code mode; with it, every kind is cheaper and the run passes the §7 gate. The saving is not yet proven (the interval reaches 1.03).
- **Nesting stays bad,** as Ronacher warned: `code_mode` inside Codex's code mode is dearer in every kind.
- **On Pi, RepoPrompt's `code_mode` beats Pi's own code mode clearly** and is close to Pi direct (multi-step ×1.19 breaches the +10% bound at 3 repetitions). Pi ran an OpenAI model only.
- Models used `code_mode` only on multi-step and heavy tasks (Codex 19 of 40 runs, Pi 12 of 24), never on single lookups, as on Claude.

Oracle consultation (OracleD and OracleE, independent): both reject the catalog rewrite and nesting, keep OpenCode v2 native, and ask for per-run eligibility rather than per-provider; OracleE pointed to the namespace key, which the lab then verified. Blind spots both raised: understanding-heavy and edit-interleaved turns, Opus and higher reasoning effort, long sessions and caching, failure and timeout cost, admission contention, the Node→QuickJS-ng behavior gap, and engine containment.

### 3.7 Blind-spot follow-up (2026-10-10)

The reviewers' blind spots, measured the same day by three lab workers and the session runner (about 900 more runs; same metric; Codex arms use RepoPrompt's real launch config). Repo HEAD `d4cbd9d1`.

| Blind spot | Setup | Result (cost ratio, code-mode arm vs its baseline) | Correctness (code mode / baseline) |
|---|---|---|---|
| Understanding and edit tasks (3 trace-the-behaviour tasks, 3 return-a-diff tasks; 5 reps) | Claude Sonnet | understand ×1.04 [0.90–1.20], edit ×0.94 [0.88–1.09] | 28/30 / 28/30 |
| | Codex low | understand ×0.81 [0.71–0.87], edit ×0.75 [0.62–0.81] | 22/30 / 24/30; majority lost on E3 |
| Opus and high effort (3 reps) | Claude Opus, T1–T8 | ×0.96 [0.72–0.99]; heavy ×0.71 | 24/24 / 24/24 |
| | Claude Opus, understand/edit | ×1.00 [0.93–1.10] | 18/18 / 18/18 |
| | Codex high, T1–T8 | ×0.75 [0.62–1.11] | 24/24 / 24/24 |
| | Codex high, understand/edit | ×0.73 [0.66–0.85] | 16/18 / 17/18 |
| Long sessions (6 turns, resumed CLI session, 3 orders × 2 reps) | Claude Sonnet | session total ×0.70 [0.62–0.79] | 32/36 / 36/36 |
| | Codex low | session total ×0.84 [0.70–1.00] (corrected 2026-10-12, §3.9) | 36/36 / 36/36 |
| Failures: 15% transient errors (F1) / 20% calls slowed 10 s (F2), same faults on direct and nested calls (3 reps) | Claude | F1 ×0.80, F2 ×0.69 | loses T8 (F1) and T7 (F2) |
| | Codex | F1 ×0.73, F2 ×0.68 | no task lost |

Findings:
- **The savings hold or grow.** Codex is cheaper with `direct + code_mode` on every new dimension. Claude saves most in long sessions (fewer raw results stay in context, so later turns are cheaper); on understanding and edit tasks it is cost-neutral, which is acceptable because the tool is optional.
- **Every correctness loss traces to two fixable executor behaviours.** (1) Scripts count lines in the Markdown `text` instead of `data.total_lines`; in sessions the model then reuses the wrong method on later turns (all 4 Claude session failures). (2) Failed nested calls are silently treated as empty: 11 of 13 Claude and 7 of 10 Codex scripts that hit a failed call still reported success, and timeouts threw away all finished work. Codex re-issued every failed script and stayed correct.
- **Codex E3 loss is a search-output problem, not a script problem.** The model built its diff from `file_search` context snippets, whose tree prefix and `▶` match marker shift indentation, so the diff did not apply; the baseline failed the same way in 2 of 5 runs. Code-mode runs lean on search snippets more.
- **Read-slot contention:** the 2-per-window small-read cap is the ceiling. 32 reads took 1.80 s serial, 1.40 s with 2 in flight, 1.33 s with 4, 1.56 s with 8. Admission is FIFO with no starvation, but a foreground `read_file` p50 rose from 52 ms to 177/310/664 ms with 1/2/4 background scripts on the same connection (113/169/399 ms on separate connections).
- **QuickJS-ng 0.17 (built without libc, C host on the planned protocol):** 167 harvested real scripts gave identical results to Node (no engine-caused difference; nested call counts equal for all 167). Differences in a 74-expression probe: no `Intl` (locale formatting, `localeCompare`) and different error wording. 286 adversarial runs: CPU spins, async spins and catastrophic regex stop at 2 s guest CPU (the interrupt fires inside the regex engine and cannot be caught), never-settling promises are detected in about 5 ms, heap stays at the 64 MiB limit, recursion stops at 1,022 frames, at most 4 calls reach the bridge, no calls after the deadline, and patching `tools`, `JSON` or `Promise` cannot affect the bridge. The Node prototype failed most of these (no CPU or memory limit, host `process` reachable, forged protocol frames); it also lost results over about 64 KiB (a handful of lab scripts), so earlier lab numbers are slightly pessimistic for code mode.

Reports and data: `docs/investigations/2026-10-10-codemode-lab/` (local): `reports/new_tasks.md`, `reports/contention_faults.md`, `reports/qjs.md`.

### 3.8 Phase 3 gate run (2026-10-11)

The lab executor was swapped for the QuickJS-ng host (built without libc) with the §6 rules: data-first child results from one tool call, failed calls reject (opt-out `{allowError: true}`) with a failure footer, one executor retry, partial output on timeout, 2 calls in flight, 32 calls, 32 KiB output, and the §6 description. Baselines re-ran in the same window. Claude long sessions ran as one stream-json process per session, as Agent Mode drives Claude. About 570 runs.

| Host | Set | Reps | Single | Multi | Heavy | All | Correct (code mode / baseline) |
|---|---|---:|---:|---:|---:|---:|---:|
| Claude Sonnet | T1–T8 | 5 | ×1.01 [1.00–1.09] | ×0.74 [0.72–0.90] | ×0.58 [0.25–0.74] | ×0.78 [0.64–0.87] | 68/70 / 66/70 over all 14 tasks |
| | understand / edit | 5 | | | | ×0.94 / ×1.05; ×1.00 [0.89–1.13] | |
| | 6-turn sessions | 2 × 3 orders | | | | ×0.66 [0.56–0.79] | 36/36 / 34/36 |
| | 15% injected errors | 3 | ×1.22 | ×0.78 | ×0.73 | ×0.82 [0.71–0.87] | 18/18 / 18/18 |
| Codex gpt-6-sol | T1–T8 | 5 | ×0.45 [0.41–0.78] | ×0.66 [0.54–0.98] | ×0.55 [0.39–0.86] | ×0.55 [0.49–0.71] | 67/70 / 68/70 over all 14 tasks |
| | understand / edit | 5 | | | | ×0.79 / ×0.73; ×0.76 [0.66–0.87] | |
| | 6-turn sessions | 2 × 3 orders | | | | ×0.79 [0.62–0.93] (corrected 2026-10-12, §3.9) | 36/36 / 36/36 |
| | 15% injected errors | 3 | ×0.47 | ×0.62 | ×0.51 | ×0.55 [0.48–0.68] | 18/18 / 17/18 |

Gate (§7) over all 14 tasks: Claude single ×1.01, multi ×0.90, heavy ×0.68; Codex ×0.45, ×0.70, ×0.65; no task lost its majority on either host, with or without injected errors. **Both hosts pass**, and the savings are now shown (intervals below 1) for Claude on T1–T8 and sessions and for Codex everywhere. The fixes removed every earlier correctness loss: under injected errors the executor retried 36 failed calls and surfaced the 6 that still failed; no script timed out. Models used `code_mode` in 20% (Claude) and 69% (Codex) of single-task runs.

Codex on the app-server path (owner's shim, RepoPrompt's real override set, computer use on and off): the namespace key in the thread-level config makes the RepoPrompt tools direct calls in every run; without it they run inside `exec`; no tool-search failures. Lab details: `reports/qjs.md` (v2 executor) and `reports/appserver.md`.

### 3.9 Long sessions and Claude resume (2026-10-12)

QuickJS-ng executor as in §3.8; Codex 0.162.0-alpha through the owner's shim; 204 more turns. Full per-turn tables, cumulative cost and context per turn: [code-mode lab measurements](../code-mode-measurements.md) §4–§5.

| Host | Session | Paired sessions | Session total | Context at end (code mode / baseline) | Correct turns (code mode / baseline) |
|---|---|---:|---|---|---:|
| Claude Sonnet, `--resume` per turn | 6-turn T-only (S1–S3) | 6 | ×0.71 [0.54–0.93] | 67k / 78k | 36/36 / 35/36 |
| Claude Sonnet, stream-json | 11-turn mixed (T1–T8 + U1–U3) | 3 | ×1.01 [0.97–1.08] | 144k / 143k | 33/33 / 33/33 |
| Codex | 11-turn mixed | 3 | ×0.85 [0.77–0.90] | 54k / 65k | 31/33 / 32/33 |

Findings:
- **Codex session figures were overstated by the harness, not by Codex.** `codex exec resume` reports each turn's usage as the cumulative thread total (checked against the per-request usage in Codex's rollout files on 0.159 and 0.162); earlier session totals summed those running totals. Per-turn usage gives §3.7 ×0.84 [0.70–1.00] and §3.8 ×0.79 [0.62–0.93]; the conclusions stand.
- **Codex keeps its saving at 11 turns** and carries 17% less context forward. Single-turn ratios scatter but do not drift upward with session length.
- **Claude resume through the owner's shim works** (stream-json output; 72/72 turns) and agrees with the stream-json process: ×0.71 versus ×0.66 on the same sequences.
- **Claude's long-session saving depends on the mix.** On the 11-turn mixed session it is cost-neutral (within the +10% bound): understanding turns are half of the session's cost and run ×1.07; fan-out turns save less in a session (×0.83) because earlier turns already loaded the files for the baseline too; and Claude chose `code_mode` in only 4 of 33 turns. The 6-turn T-only saving (×0.66–0.71) is the fan-out-heavy end, not the typical session.
- Codex missed U3 (the 27-check trace task) twice with code mode and once without, each time on a single check; no other turn failed.

## 4. D1 — Structured results

- **Shape (one, no modes):** today's text content unchanged, plus `structuredContent` (the existing DTO encoded as JSON) and an `outputSchema` in `tools/list`. Errors keep `isError: true` and their text. Delegated-question notices stay text-only. `_rawJSON` keeps its exact text and also carries `structuredContent` when schemas are advertised.
- **Tools:** `read_file`, `file_search`, `get_code_structure`, `get_file_tree`; later `git_review_snapshot` and `code_mode`. Legacy `git` gets no schema.
- **Enablement:** one app setting `mcp.structured_results` = `off` (default) | `on`, read when a connection is set up. A change applies to the next connection, because once `outputSchema` is advertised the connection must keep returning `structuredContent`. No client table ships. If a host later passes the §7 gate, a small table keyed by handshake client name may be added; the name would select presentation only, never permissions.
- **Why ship it while it is off by default:** the executor (D3) needs the structured value for nested results regardless of this setting (the setting governs wire output only); Codex was about 9% cheaper with it, and Claude answered the heavy ranking task correctly every time with it (§3.4). Pi and OpenCode v2 scripts got dearer with it (they consume `structuredContent`, which is larger than the Markdown), so it is not a universal default.
- **First candidates:** Codex (`codex-mcp-client`), then Claude Code, each after a confirming §7 run at 5 repetitions. Enabling for one host but not another needs the client-name table above; until then the setting is global.
- **Schemas:** hand-written in a new `MCPToolOutputSchemas.swift`, permissive about additional properties, with a parity test that encodes fixture DTOs and checks keys and primitive types. No generator.
- **Projection:** one `makeToolResult(toolName:args:value:structured:)` used by the success exit (`MCPConnectionManager.swift:13102`) and the error helpers.
- **Dropped from earlier drafts:** `structuredCompact` summary text, the per-provider lease override, version-pinned probe tables, an `auto` client table, a per-call `_structured` argument, and a custom initialize capability.

## 5. D2 — Git narrowing

- **New tool `git_review_snapshot`:** fixed `op = diff`, `artifacts = true`, `detail = summary`; accepts `compare`, `scope`, `mode`, `repo_root(s)`, `repo_key`, `path(s)`, `context_lines`, `detect_renames`; rejects everything else. It reuses the existing publication, auto-selection and cleanup path through a shared invocation kind (`full` / `reviewSnapshot`) that passes the real tool name to artifact authorization. Admission `.gitRead`, contract `.workspaceLifecycleCancellable`, not read-only (it writes snapshot files and selection).
- **Shell signal:** one boolean `runHasNativeShell`, computed from the final launch configuration. When true, the Agent Mode lease adds `git` to `restrictedTools`. The MCP layer never learns about shells. RepoPrompt cannot see a user's own Claude Code permission rules, so a user who denies Bash there must turn off RepoPrompt's Bash preference to get `git` back; the Agent Mode docs must say so.

| Launch | Shell | Result |
|---|---|---|
| Claude with Bash | yes | `git` hidden; snapshot available |
| Claude with Bash off or `.mcpSafeDefaults` | no | full `git` |
| Codex Agent Mode | yes | `git` hidden |
| OpenCode managed interactive (`bash: allow`) | yes | `git` hidden |
| OpenCode headless / no-tools, OMP (`--no-tools`), Cursor (until verified), external clients | no or unknown | full `git` + snapshot |
| Context Builder discovery | no | unchanged: must not gain the snapshot; Phase 2 confirms how its tool set is bounded |
| Knowledge | n/a | unchanged: its closed allowlist (`AgentSessionProfile.swift:16-27`) already excludes both new tools |

- **Prompts:** Oracle review guidance names `git_review_snapshot` first; shell-enabled prompts send inspection to the shell.
- **Rollback:** drop the restriction; the snapshot tool stays.

## 6. D3 — `code_mode` executor (experimental)

- **Who gets it:** Agent Mode runs in which RepoPrompt's tools are called **directly**, never from inside a client's code mode. Eligibility is a per-run fact computed from provider, resolved model and final launch configuration (next to `runHasNativeShell`); the handshake client name plays no part, and an unknown capability means no `code_mode`. Knowledge and Context Builder discovery never get it. It is always **offered alongside** the direct tools: `cc_cm_only` shows that forcing scripts for every call costs 29% more on single lookups and loses correctness, while optional exposure let models use scripts where they pay (multi-step and heavy runs only, on every host).
- **Per-provider setting** ("RepoPrompt tools": `native` | `direct + code_mode`), default `native` until that provider passes §7 at 5 repetitions; it applies from the next run:

  | Provider | `native` (default) | `direct + code_mode` |
  |---|---|---|
  | Claude Code | Direct tools (no native code mode) | Adds optional `code_mode` |
  | Codex | RepoPrompt tools inside Codex's `exec` | Registers a second, read-only RepoPrompt server entry (the four exploration tools plus `code_mode`), lists its namespace in `features.code_mode.direct_only_tool_namespaces` in the thread-level config, and leaves the main RepoPrompt server inside `exec`. Exposing the whole RepoPrompt catalog directly adds about 15k prompt tokens per model request (31.7k vs 16.8k on the first request; the 5-tool lab server adds about 1.5k), which would erase the saving. The namespace is `mcp__` plus the server name with `-` turned into `_`, case-sensitive; a wrong name silently falls back to `exec`, so verify the direct tools on the first turn. Verified on the app-server path through the owner's shim, with computer use on and off (2026-10-10). Never rewrite the model catalog or `tool_mode`. Without `code_mode`, direct RepoPrompt tools are dearer than native (§3.6), so the two always switch together |
  | Pi (future provider) | Pi's code mode | Writes `exposure: direct` for the RepoPrompt server and adds `code_mode`; confirm the model cannot also reach RepoPrompt tools from Pi's own scripts |
  | OpenCode v2 | OpenCode's code mode | Not offered (native is about 55% cheaper than direct; replacement is research only) |

- **Codex structured results interplay:** in direct mode Codex showed the model only `structuredContent` (§3.3, probed through the catalog rewrite; re-probe with the namespace key), so D1 on Codex changes what direct calls look like; gate D1 and `direct + code_mode` on Codex together.
- **Tool:** `code_mode(script)`; the script is an async function body of at most 32 KiB.
- **Nested result shape (decide in Phase 3):** the lab's heavy-task correctness loss came from scripts counting lines in the Markdown `text` (seven header lines too many) while `data.total_lines` was available; the prototype description offered `data` but did not tell models to prefer it. Candidates: (a) `{text, data, isError}` with a description that says to read fields from `data`; (b) data-first, OpenCode's choice: `{data, isError}` when a structured value exists and `text` only as a fallback. Pick the candidate that passes §7 on the prototype; §3.7 makes (b) the leading candidate (the same text-counting error recurred in sessions and propagated to later turns). Either way, each child result comes from one tool call (the prototype's second `_rawJSON` call halved read capacity), and the description tells models to probe a few items before looping over many, to use `Promise.all` for independent calls, to count lines with `data.total_lines`, to check failures and retry only failed items, that there is no `Intl` (sort with explicit comparators), and to return only the aggregate.
- **Engine:** vendored QuickJS-ng without `quickjs-libc` (no filesystem, network or timers); one runtime per call on a dedicated thread; interrupt handler for deadline, cancel and guest CPU (thread CPU time, counted only inside JS); `JS_NewContextRaw` with only the needed intrinsics; frozen, non-configurable `tools`; host-side argument serialization through C APIs (never through guest `JSON`); a never-settling script (no jobs, nothing in flight) ends at once. Validated in the lab (§3.7): parity with Node on 167 real scripts and containment on 286 adversarial runs.
- **Allowlist:** `read_file`, `file_search`, `get_code_structure`, `get_file_tree`, admitted only if classified `.smallRead` or `.fileSearch` (fails closed otherwise).
- **Limits:** 60 s wall, 2 s guest CPU, 64 MiB heap, 1 MiB stack, 32 nested calls, **2 in flight** (the small-read window cap; 4 or 8 bought at most 5% and multiplied foreground queueing, §3.7), 2 MiB per child result, 32 KiB final output, argument object at most 64 KiB. Exceeding the output cap, the heap or any other limit returns `isError: true` with call counts; nothing is truncated silently. About 5% of real scripts produced more than 32 KiB and about a fifth made 28–29 nested calls, so keep the limits visible in the description.
- **Dispatch:** children re-enter the connection's registered `tools/call` handler with a non-wire task-local origin, so each child runs the full policy, restriction, admission, contract, observer and cancellation path. Children may not override routing (`context_id`, `_tabID`, `_windowID`). Automatic selection is suppressed for children; the description tells callers to select shortlisted files afterwards.
- **Admission:** parent classified `.control` with a script cap of 1 per connection and 1 per window; the parent never holds a read slot while awaiting children; contract `.bounded(62 s)`. Optional: admit direct calls ahead of queued script children.
- **Failure:** a nested call that fails rejects by default (scripts may opt into `{allowError: true}`), and the result always ends with a failure footer listing failed calls (also in `structuredContent`). Retry transient read errors once inside the executor. On timeout or cancel, stop new children and return the partial output plus completed, in-flight and failed call counts, marked as a timeout; never discard finished work. In the lab, silent success with failed children caused every code-mode correctness loss under injected faults.
- **Visibility:** child calls appear as flat transcript cards marked "via code_mode".
- **Notices:** children release delegated-question notices; the parent attaches them once after its children finish.

## 7. D4 — Measurement and the gate

- **Usage analyzer:** `Scripts/analyze_tool_usage.py` with 17 fixture tests. Re-run it after each phase to watch real usage.
- **Lab harness:** §3.4. Re-run it for every default change and for new client versions. It reports tokens, turns, tool calls, correctness, violations and wall time per arm, paired per-task ratios, and a per-kind gate view.
- **Reproducibility:** the lab harness is local and uncommitted today. Before a gate decision depends on it, commit it under `Scripts/` (without logs or credentials) with a short README, so someone else can re-run a gate.
- **One gate for every default change** (D1 per host, D3 promotion), always against that host's baseline arm (today's tools, no executor, no structured content):
  1. **Correctness:** for each task, the change is correct in a majority of repetitions wherever the baseline is. Zero violations: no native shell or file use where disabled, no honored routing override, no selection change caused by a nested call.
  2. **Cost, per task kind:** in each kind (single lookup, multi-step, heavy fan-out), the geometric mean of per-task median **price-weighted tokens** (§3.4) is at most 10% above the baseline. Raw token totals, turns and wall time are reported, not gated: raw totals are dominated by cheap cache reads and would have rejected the one real saving, and wall time is noisy while runs share a window.
  3. **Claimed savings must show:** a change justified by savings must lower price-weighted tokens on the kind it targets, with the 95% bootstrap interval below 1.
  4. **Repetitions:** at least 5 per arm and task for a gate decision (the 2026-10-10 run used 3 and is exploratory).
- **Missing data blocks the claim, not the work:** if a host cannot be measured, its default stays off.

## 8. Phases

| Phase | Changes | Validation | Exit |
|---|---|---|---|
| 0 Evidence | Analyzer, lab harness, this plan | Analyzer tests (17 pass); `Scripts/check-agent-context` | Done; commit the lab harness before a gate decision relies on it |
| 1 D1 | `Tool.outputSchema`, schemas, `makeToolResult`, `mcp.structured_results` (default off) | `make dev-lint`; focused `MCPStructuredOutputTests` (text byte-identical, errors, truncation, `_rawJSON`, notices); `make dev-swift-build`; lab re-run against the real app | Output byte-identical with the setting off |
| 2 D2 | Snapshot tool, then shell restriction and prompts | `MCPGitSurfaceTests` (including `tools/list` for Knowledge and discovery runs); existing artifact and Oracle suites; live Oracle review from a shell run and a no-shell run | Oracle review works in both; Knowledge and discovery unchanged |
| 3 D3 prototype decision | **Done 2026-10-11: passed on Claude Code and Codex (§3.8); continue to Phase 4.** No app code. Done 2026-10-10 (§3.6–3.7): understanding and edit tasks, Opus and high effort, long sessions, injected faults, contention, QuickJS-ng parity and containment. Remaining: swap the lab bridge to the QuickJS-ng host with the §6 fixes (data-first results, failure rejection and footer, partial output on timeout, 2 in flight, one call per child), then re-run T1–T8 + U/E at 5 repetitions, the long sessions, and fault profile F1 for Claude Sonnet and Codex; run Codex once through RepoPrompt's app-server launch and the owner's shim | §7 gate per host, plus zero correctness loss under F1 | Continue for the hosts that pass; stop D3 if none passes and record the result here |
| 4 D3 seam | Re-entry callable, origin task-local, typed result sink; lease carries the per-run eligibility; Codex overrides add the namespace key only in `direct + code_mode` (tests for CLI and app-server override parity) | All MCP suites; `make dev-test-parallel` | Transport behavior unchanged |
| 5 D3 executor | QuickJS-ng target, bridge, limits, selection suppression, cards | Runtime tests (no globals, loops interrupted, memory, output caps, cancel); bridge tests (denials, routing overrides rejected, selection unchanged, notice once, absent from Knowledge and discovery); `make guardrails` | No bypass, leak or deadlock |
| 6 Decide | Lab re-run with the in-app executor | §7 gate | Owner sign-off on the default |

Throughout: never weaken assertions; leave the frozen XCTest ledger alone.

**OpenCode v2 note (provider work, outside D1–D4):** when RepoPrompt launches OpenCode v2, keep OpenCode's default code mode for the RepoPrompt server (do not write `codemode: false`): the lab shows the default about 55% cheaper at equal correctness, and the stdio `Unknown tool` defect did not reproduce on 2.0.26. Keep D1 off for OpenCode v2 (structured content made its scripts dearer). v2 is a separate package (`@opencode/cli`) with its own config shape (`mcp.servers.<name>`); the overlay must target it explicitly. Two harness facts from the lab: v2 waits on stdin unless it is closed, and it resolves its workspace from `PWD`, not the process working directory.

## 9. Decisions log

- 2026-10-03: The owner decisions above. The Git design uses a separate snapshot tool rather than op-level gating. Nested dispatch re-enters the registered handler rather than extracting it. Executor admission uses `.control` plus a script cap. Child notices release, and the parent attaches them once.
- 2026-10-10: The promotion-gate dispute (≥15% token saving versus no-increase) is replaced by the single §7 gate, measured per task kind in price-weighted tokens. D1 drops the compact mode and the lease and probe precedence for one default-off setting. D2's tri-state capability becomes a boolean. D3 is limited to clients without native code mode, is always optional, and gets a prototype decision step before the engine is built. Independent review (OracleD) shaped the per-kind gate, the default-off D1, the lease-based D3 exposure and the phase order. The OpenCode v2 recommendation flipped from "pin `codemode: false`" to "keep the default" after the 2.0.26 lab run.
- 2026-10-10 (follow-up, owner question "why Claude only, what about Codex?"): D3 eligibility changes from "provider without native code mode" to "RepoPrompt tools called directly", with a per-provider `native` | `direct + code_mode` setting. Codex qualifies through `features.code_mode.direct_only_tool_namespaces` (§3.6: ×0.80 at 5 repetitions, 40/40 correct); Pi through `exposure: direct`; OpenCode v2 stays native. Rejected: rewriting Codex's model catalog (4/16 correct) and nesting `code_mode` inside a client's code mode (×1.12). OracleD and OracleE consulted independently; OracleE found the namespace key.
- 2026-10-10 (blind-spot follow-up, §3.7): the Oracles' blind spots were measured. Savings hold for Codex on every dimension and grow for Claude in long sessions; all correctness losses come from text-based counting and silently swallowed nested failures. Executor changes: data-first results become the leading shape, nested failures reject by default with a failure footer, timeouts return partial output, children run 2 in flight with 1 script per window, and each child is one tool call. QuickJS-ng is confirmed as the engine (parity and containment in the lab).
- 2026-10-12 (long sessions, §3.9): the full numbers move to `docs/context/code-mode-measurements.md`, regenerated from the surviving raw rows (the original §3.4 rows were lost with `/tmp`). Codex session figures are corrected for cumulative usage reporting. No decision changes: Codex saves in long sessions; Claude is cost-neutral on mixed long sessions and saves on fan-out-heavy ones, which keeps `code_mode` optional rather than a default push for Claude.
- 2026-10-11 (Phase 3 gate, §3.8): with the QuickJS-ng host and the §6 rules, `direct + code_mode` passes §7 on Claude Code and Codex at 5 repetitions, in sessions and under injected errors, with no correctness loss. D3 proceeds to Phases 4–5. For Codex the direct set is a second, read-only RepoPrompt server entry (the full catalog direct costs about 15k prompt tokens per request); verified on the app-server path through the owner's shim.
- 2026-10-17 (owner): when structured results are enabled, delegated-question notices appear in both the unchanged text and a reserved structured field (`delegated_question_notices`), amending D1's text-only notice rule.

- 2026-10-17 (owner): commit now; if signing fails on a later commit in this work, an unsigned commit is authorized.
- 2026-10-18 (owner): keep defaults native and defer the live gate.
- 2026-10-18 (owner): implement the Codex companion.
- 2026-10-18 (owner): defer Codex direct-only compatibility verification to the live gate; add no new capability probe. Keep the companion opt-in and explicitly unverified live, with native defaults.
- 2026-11-03 (owner): merge the updated base into this worktree and validate the combined code before any live testing.
- 2026-11-03 (owner): after manually quitting and relaunching the requested optimized-incremental build, proceed with full live verification.
- 2026-11-04 (owner): investigate the existing Claude traces, try Opus 5.5 in the bounded diagnostic, and complete a genuine no-shell replay using existing controls.
- 2026-11-04 (owner): the app's Claude Bash toggle was already off; leave it off.

## 10. Risks and open questions

- **Client behavior drifts.** The probe matrix is per version; re-run the probe and lab when Claude Code, Codex, OpenCode or Pi change major behavior.
- **Claude JSON substitution.** Claude Code shows `structuredContent` instead of the text. If it later forwards both, re-measure `cc_struct`.
- **Lab tasks are mechanical.** Heavy lab tasks count and rank; real 20+ call turns mostly read code for understanding, so expect smaller real savings than the lab's heavy-task figure.
- **Read re-use** (42–50% re-reads) may be a larger lever than D3. A separate investigation is optional.
- **Codex launch drift.** `direct_only_tool_namespaces`, the `code_mode_only` catalog and tool-search behavior are version-specific; re-probe on each Codex upgrade and fall back to `native` when the key is unknown. The namespace is derived from the configured server name; RepoPrompt's own launch and the owner's shim must use the same name.
- **Remaining unmeasured shapes.** §3.7 covered understanding and edit tasks, Opus, high effort, 6-turn sessions, faults and contention. §3.9 added 11-turn mixed sessions and Claude resume. Still unmeasured: real edits applied between reads (the lab's edit tasks return a diff) and sessions long enough to compact (the longest reached about 144k context on Claude). The lab tasks remain small (14 tasks, one repository).
- **Search snippets are not edit-safe.** `file_search` context lines carry a tree prefix and a `▶` marker that shift indentation; diffs built from them fail to apply (Codex E3 in §3.7, with and without code mode). Independent of D3; the description should tell models to read the target lines with `read_file` before editing, and a search format fix is a separate question.
- **Engine containment.** QuickJS-ng runs model-written code in-process; a dedicated thread is not isolation. The lab host passed 286 adversarial runs (§3.7); the in-app executor needs the same cases as tests. `Object.prototype.toJSON` can rewrite arguments inside the guest, so the app's path policy stays the boundary.
- **Open:** the tool names `code_mode` and `git_review_snapshot`; whether Cursor has a shell; whether OMP should join a later D3 experiment.
