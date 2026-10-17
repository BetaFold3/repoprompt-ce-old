# Code-mode lab harness

This harness re-runs the single-turn controlled experiment behind the [code-mode plan](../../docs/context/plans/2026-10-03-code-mode-readiness-and-git-narrowing-plan.md) (§3.4, §3.8 single-turn gate) and prints the §7 gate view. Claude Code or Codex answers fixed tasks through an MCP proxy in front of the RepoPrompt CE debug app. The proxy exposes only the four exploration tools. It can add `structuredContent` (D1) and an optional `code_mode` tool that runs in a QuickJS-ng host (D3). The harness grades each answer against machine-checked ground truth and records usage, price-weighted tokens (`wtok`), correctness, violations, and Codex direct-call evidence.

Live runs spend real model usage and write private transcripts. None of the offline tests below proves live behavior.

## Files

| File | Role |
|---|---|
| `lab_config.py` | Environment-driven paths, the truth-commit pin, price weights, preflight checks, the upstream probe, and the usable-row rule |
| `tasks.py`, `edit_grade.py` | 14 tasks (T1–T8 lookup/multi/heavy, U1–U3 understand, E1–E3 edit) and their graders; `mechanical_truths()` recomputes T3–T8 from git |
| `upstream.py` | Checked JSON-RPC client for the CE debug MCP helper (deadlines, error responses, helper exit, bind result) |
| `rp_proxy.py`, `schemas.json` | MCP proxy spawned by the host CLI (text or structured mode, `code_mode`, fault injection) |
| `qjs/cm_host_v2.c`, `build_qjs_host.sh` | The QuickJS-ng `code_mode` host from the §3.8 gate, and its build |
| `runner.py` | Single-turn runs, one JSONL row per run (resumable, with prune for unusable rows) |
| `analyze.py` | Arm table, per-kind ratios with 95% bootstrap intervals, and the §7 verdict |
| `test_codemode_lab.py` | Offline tests: graders, truth pin, parsing, commands, preflight and probe, proxy against a fake upstream (including outages), the real QuickJS bridge, gate math |

## Prerequisites

1. **Pinned repository.** The task truths hold only at commit `d4cbd9d1` (`lab_config.TRUTH_COMMIT`); several task files have moved or changed since. Create a detached checkout with `git worktree add --detach <dir> d4cbd9d1`, open `<dir>` as a workspace in the running CE debug app, and set `CMLAB_REPO=<dir>`. The runner refuses to start if HEAD differs or tracked files are modified. Relative paths in `CMLAB_*` variables resolve against the current directory.
2. **Running CE debug app** and its MCP helper (`CMLAB_CLI`, default `~/Library/Application Support/RepoPrompt CE/repoprompt_ce_cli_debug`). The harness never launches the app. Before any paid run, `runner.py` connects to the helper and binds `CMLAB_REPO` exactly as the proxy will, and stops with the reason if that fails. See [Use the CE debug CLI](../../docs/context/workflows/development.md#use-the-ce-debug-cli).
3. **QuickJS-ng host** for `code_mode` arms. Build it with `QJS_SRC=<quickjs-ng v0.17.0 checkout> ./build_qjs_host.sh`, which compiles four engine files and never quickjs-libc. `./build_qjs_host.sh --homebrew` links Homebrew's dylib, which also bundles quickjs-libc. It writes `cm_host_v2-homebrew`, never the gate path, and the runner refuses a host that links `libqjs`. Use it only for offline tests.
4. **Host CLIs**, logged in by you: `claude` and/or `codex` (override with `CMLAB_CLAUDE` / `CMLAB_CODEX`). Codex rollouts are read from `CODEX_HOME` (default `~/.codex`) to count tool calls. The harness reads no credential files.
5. **Isolation for Codex.** Set `CMLAB_CODEX_DISABLE_SERVERS` to the MCP servers in your own Codex config, such as `RepoPromptCE,node_repl`, so the model cannot reach RepoPrompt around the proxy. The harness does not check this. If it is unset or incomplete, Codex can call your real RepoPrompt server, including `git`, without counting a violation, and both arms' costs change. Check it before a gate run. Wrapper-specific variables can be removed before Claude starts with `CMLAB_CLAUDE_STRIP_ENV`.
6. Python 3, plus `swiftc` (`CMLAB_SWIFTC`, default `/usr/bin/swiftc`) when E1–E3 are selected; preflight checks it.

**Security.** Edit grading (E1–E3) applies the model's diff to extracts of product files, then compiles and runs the result with `swiftc` on your machine, without a sandbox. Run edit tasks only on a machine where that is acceptable.

Scratch output goes to `CMLAB_SCRATCH` (default `<repo>/.build/codemode-lab`, git-ignored). It holds `runs/<arm>-<task>-<rep>-<ms>/` with host stdout, stderr, proxy call logs (sizes and timings only) and `upstream.stderr`, plus the cached tool list. Treat it as private: don't commit transcripts or result files.

## Run

```bash
cd Scripts/codemode_lab
python3 -m unittest discover -s . -p 'test_*.py'          # offline, about 15 s; builds the Homebrew test host if available
python3 runner.py --arms cc_text,cc_cm2 --tasks T1_caps --out r.jsonl --dry-run   # print host commands only
# §7 gate decision: at least 5 repetitions per arm and task, both arms in the same window
python3 runner.py --arms cc_text,cc_cm2,cx_text_rp,cx_dons_rpcm2 --reps 5 --out gate.jsonl
python3 runner.py --arms cc_text_f1,cc_cm2_f1,cx_text_rp_f1,cx_dons_rpcm2_f1 --reps 3 --out faults.jsonl
python3 analyze.py gate.jsonl        # each arm vs its host baseline
python3 analyze.py faults.jsonl      # fault arms vs the baseline under the same profile (cc_cm2_f1 vs cc_text_f1)
```

Arms: `cc_text` (baseline), `cc_struct`, and `cc_cm2` on Claude Code; `cx_text_rp` (baseline: native code mode with RepoPrompt's launch flags) and `cx_dons_rpcm2` (RepoPrompt tools direct through `features.code_mode.direct_only_tool_namespaces`, plus `code_mode`) on Codex. Suffix `_f1` injects 15% transient errors and `_f2` slows 20% of calls by 10 s. Faults are seeded per task and repetition, so every arm gets the same seeded sequence by call order. That is not the same fault on the same logical call, because arms make different numbers of calls. Models default to Sonnet and `gpt-6-sol` at low effort. Model names are time-sensitive; pass `--claude-model`, `--codex-model` or `--codex-effort` to change them. Each row records `model`, `effort` and `truth_commit`; Claude effort is recorded as `cli-default` because the runner does not set it.

**Verdict.** Correctness counts every attempted row: a run with a nonzero exit (crash or timeout) is an incorrect answer, even if its last answer graded correct (`answer_correct` keeps that grade). Costs use usable rows only: exit 0, usage reported, and no RepoPrompt upstream error. The result is FAIL when a kind's ratio is above ×1.10, a task loses its majority-correct answer, or there is a violation. Otherwise it is INCOMPLETE when any task or kind lacks usable rows in either arm, or when any row is unusable. Only a run with none of these is PASS. Below 5 usable repetitions the verdict is marked exploratory. A violation is a Codex shell command, or a Claude tool use outside `mcp__rp__*` (any tool, even a harmless or denied one). Rows record `violation_tools`, and the gate prints the names so you can judge a FAIL. `analyze.py` refuses inputs whose rows record more than one model, effort or truth commit for an arm, or more than one truth commit overall. Inputs consisting only of historical rows without these fields (2026-10 results) get a warning instead; mixing them with newly recorded rows is refused. A claimed saving needs an interval below 1. For fault profiles, the Phase 3 condition is correctness only; read the "Majority-correct lost" line.

## Recovery

- **Interrupted runs:** re-run the same command with the same `--out`. Finished (arm, task, rep) rows are skipped. The runner refuses an `--out` file written with other models, effort or truth commit; start a new file instead.
- **RepoPrompt outage mid-run** (app quit, window closed, workspace unbound, helper crash): the proxy answers each tool call with `lab proxy: RepoPrompt upstream unavailable: …` instead of hanging. New nested attempts and retries stop when the script stops; already-sent calls may remain pending until their RPC wait expires. The intended budget is 60 s plus a 5 s backstop, but an injected F2 delay currently extends that wait by the delay duration (a known non-blocking follow-up). Calls that are still unanswered 5 s after the stop are counted as upstream errors. The row records `upstream_errors` and is not usable, so the verdict stays INCOMPLETE. Fix the app (prerequisite 2), then run `runner.py --out gate.jsonl --prune-unusable`. This moves the unusable rows to `gate.jsonl.unusable.jsonl`. Re-run the original command to repeat only those runs. The runner warns when an `--out` file still holds unusable rows.
- **Before pruning:** `--prune-unusable` removes all unusable rows from the analyzed file, including timeouts and crashes, not just confirmed outages. Those attempts then stop contributing to correctness; inspecting `rc`, the stop reason, `unresolved_at_stop`, and `upstream.stderr` is necessary to avoid redrawing model failures until they pass. An unresolved call after a script timeout can mean a slow app rather than an outage. Retain the original results and do not treat a pruned result as evidence that every original attempt passed.
- **A task that stays INCOMPLETE after prune and re-run:** any JSON-RPC error response from the app also counts as an upstream error, not only transport failures. If the app answers a particular call with a JSON-RPC error every time, for example a malformed argument from a `code_mode` script, re-running reproduces it. Before re-running again, check that run's error: `detail` in `proxy.log` for direct calls, the failure footer of the `code_mode` result in `stdout.jsonl` for nested calls, and `upstream.stderr`.
- **"Not ready" from preflight:** each line gives the fix (pin, helper path, upstream bind, host build, `swiftc`, CLI on PATH). No run starts.
- **App upgraded or tool descriptions changed:** delete `$CMLAB_SCRATCH/tools_cache.json`. The proxy answers `tools/list` from it so slow upstream starts don't hide tools.
- **Codex arms that never call the tools directly:** a wrong namespace silently falls back to `exec`. Each Codex row records `rp_direct_calls` (rollout `function_call` items in namespace `mcp__rp`) and `exec_calls` (`custom_tool_call` items named `exec`). `analyze.py` warns when a `cx_dons_*` run has no direct call. `proxy_tool_calls` counts every lab-tool call the proxy received, including calls from inside `exec` scripts, so it is not direct-call evidence.
- **QuickJS-ng other than 0.17.0:** the build warns. The parity and containment suites from 2026-10-10 are not part of this harness, so re-validate the engine before trusting results.

## Coverage and limitations

- **Single-turn gate only.** The 6-turn (S1–S3) and 11-turn (SL) session runs and their analysis (§3.8 and §3.9 session totals) are not in this harness, so they cannot be reproduced from it. `analyze.py` refuses rows shaped like sessions. That is an assumed, reversible scope cut. The local originals remain the record.
- **Hosts:** Claude Code and Codex only, the gate hosts for D1 and D3. Also not carried over: Pi and OpenCode arms; the Node `vm` prototype executor; the rejected Codex catalog rewrite and nested `code_mode`; the Codex app-server client run through the owner's wrapper; the read-slot contention bench; the QuickJS parity (167 scripts) and containment (286 runs) suites; context-size enrichment; and one-off usage analyses. Those results stay in the plan and in [code-mode lab measurements](../../docs/context/code-mode-measurements.md). They cannot be re-run from this directory.
- **Violations:** for Codex, a violation is a shell command in the run. For Claude, it is any tool use outside the lab's `mcp__rp__*` tools; native tools are also blocked by `--disallowedTools`. The §7 checks for routing overrides and selection changes by nested calls are properties of the in-app executor and are not measured here.
- **Truth:** the U1–U3 truths were confirmed on 2026-10-10 by compiling stubs against the truth commit; those scripts are not included. Only T3–T8 are recomputed (`mechanical_truths`).
- **Method notes:** Codex `turns` is approximated as tool calls + 1 and is not gated. Wall time is inflated when runs share one app window. Bootstrap intervals can differ by ±0.01 from plan figures that came from the older scripts.
- **Raw results:** results from the 2026-10 runs are not committed. `analyze.py` reproduces the §3.8 single-turn gate ratios from the surviving local rows. Those rows predate `rp_direct_calls`, and their run directories are gone, so their direct-call evidence can't be recomputed per run.
