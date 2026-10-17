#!/usr/bin/env python3
"""Code-mode lab runner: single-turn runs of lab tasks per arm, one JSONL row per run.

Usage: runner.py --arms cc_text,cc_cm2 --tasks T1_caps,T7_top_lines --reps 5 --out results.jsonl [--workers 4] [--dry-run]
       runner.py --out results.jsonl --prune-unusable      (move rows that are not usable aside before re-running them)
Rows carry raw usage, price-weighted tokens (wtok), correctness, violations, Codex direct-call evidence and proxy stats.
An existing --out file is resumed: (arm, task, rep) rows already present are skipped, and it must have been written with
the same models, effort and truth commit. See README.md for prerequisites and recovery.
"""
import argparse, glob, json, os, random, subprocess, sys, threading, time
from concurrent.futures import ThreadPoolExecutor

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import lab_config as C
from tasks import TASKS, prompt, grade

# Baselines: cc_text (Claude Code, today's tools) and cx_text_rp (Codex native code mode, RepoPrompt's real launch flags).
ARMS = {
 "cc_text":       {"host": "claude", "mode": "text"},
 "cc_struct":     {"host": "claude", "mode": "structured"},
 "cc_cm2":        {"host": "claude", "mode": "text", "cm": True},
 "cx_text_rp":    {"host": "codex",  "mode": "text", "rpcfg": True},
 # RepoPrompt tools direct through features.code_mode.direct_only_tool_namespaces, plus optional code_mode (plan §6).
 "cx_dons_rpcm2": {"host": "codex",  "mode": "text", "rpcfg": True, "dons": "mcp__rp", "cm": True},
}
# Fault profiles (proxy PROXY_FAULT_*; same seed per task/rep across arms). F1: 15% transient errors; F2: 20% calls +10 s.
FAULT_PROFILES = {"f1": {"fault_err": 0.15}, "f2": {"fault_slow": "0.2:10"}}
for _base in ("cc_text", "cc_cm2", "cx_text_rp", "cx_dons_rpcm2"):
    for _fp, _fv in FAULT_PROFILES.items():
        ARMS[f"{_base}_{_fp}"] = {**ARMS[_base], **_fv}
# Model choices are time-sensitive; the 2026-10 runs used these. Override per run with --claude-model / --codex-model / --codex-effort.
MODELS = {"claude": "sonnet", "codex": "gpt-6-sol"}
EFFORT = {"claude": "cli-default", "codex": "low"}
HOST_LIMIT = {"claude": threading.Semaphore(2), "codex": threading.Semaphore(2)}
LAB_TOOLS = ("read_file", "file_search", "get_code_structure", "get_file_tree", "code_mode")
CLAUDE_DISALLOWED = "Bash,Edit,Write,Read,Glob,Grep,Task,Agent,WebFetch,WebSearch,NotebookEdit,TodoWrite"
RP_NAMESPACE = "mcp__rp"   # MCP server "rp" as Codex names it in rollouts and as Claude prefixes its tools
wlock = threading.Lock()


def proxy_env(arm, log, seed):
    """Environment for rp_proxy.py. Lab paths are passed explicitly: host CLIs may not forward the parent environment."""
    env = {"PROXY_MODE": arm["mode"], "PROXY_CODEMODE": "1" if arm.get("cm") else "0", "PROXY_LOG": log,
           "CMLAB_REPO": str(C.REPO), "CMLAB_CLI": str(C.CLI), "CMLAB_QJS_HOST": str(C.QJS_HOST), "CMLAB_SCRATCH": str(C.SCRATCH)}
    if arm.get("fault_err"): env["PROXY_FAULT_ERR"] = str(arm["fault_err"])
    if arm.get("fault_slow"): env["PROXY_FAULT_SLOW"] = arm["fault_slow"]
    if arm.get("fault_err") or arm.get("fault_slow"): env["PROXY_FAULT_SEED"] = seed
    return env


def proxy_argv(env):
    return [f"{k}={v}" for k, v in env.items()] + [C.PYTHON, str(C.LAB_DIR / "rp_proxy.py")]


def run_claude(arm, rd, p, log, seed):
    cfg = {"mcpServers": {"rp": {"command": "/usr/bin/env", "args": proxy_argv(proxy_env(arm, log, seed))}}}
    with open(f"{rd}/mcp.json", "w") as f: json.dump(cfg, f)
    cmd = [C.CLAUDE, "-p", p, "--mcp-config", f"{rd}/mcp.json", "--strict-mcp-config", "--allowedTools", RP_NAMESPACE,
           "--disallowedTools", CLAUDE_DISALLOWED, "--model", MODELS["claude"], "--output-format", "stream-json", "--verbose"]
    return cmd, {k: v for k, v in os.environ.items() if k not in C.CLAUDE_STRIP_ENV}


def run_codex(arm, rd, p, log, seed):
    args = json.dumps(proxy_argv(proxy_env(arm, log, seed)))
    cmd = [C.CODEX, "exec", "--json", "--skip-git-repo-check", "-s", "read-only", "-C", rd, "-m", MODELS["codex"],
           "-c", f'model_reasoning_effort="{EFFORT["codex"]}"']
    for s in C.CODEX_DISABLE_SERVERS: cmd += ["-c", f"mcp_servers.{s}.enabled=false"]
    cmd += ["-c", 'mcp_servers.rp.command="/usr/bin/env"', "-c", f"mcp_servers.rp.args={args}",
            "-c", "mcp_servers.rp.tool_timeout_sec=600", "-c", "mcp_servers.rp.startup_timeout_sec=300"]
    for t in LAB_TOOLS: cmd += ["-c", f'mcp_servers.rp.tools.{t}.approval_mode="approve"']
    if arm.get("dons"): cmd += ["-c", "features.code_mode.direct_only_tool_namespaces=[\"%s\"]" % arm["dons"]]
    # RepoPrompt's real Codex launch flags (plan §3.6).
    if arm.get("rpcfg"): cmd += ["-c", "features.tool_search=false", "-c", "features.apps=false", "-c", "features.plugins=false", "-c", "features.tool_suggest=false"]
    return cmd + [p], dict(os.environ)


BUILDERS = {"claude": run_claude, "codex": run_codex}


def comps(host, out):
    """Usage components (uncached, cache write, cache read, output) from host stdout."""
    c = dict(unc=0, cw=0, cr=0, out=0)
    for l in out.splitlines():
        try: d = json.loads(l)
        except Exception: continue
        if host == "claude" and d.get("type") == "result":
            u = d.get("usage") or {}
            c = dict(unc=u.get("input_tokens", 0), cw=u.get("cache_creation_input_tokens", 0), cr=u.get("cache_read_input_tokens", 0), out=u.get("output_tokens", 0))
        elif host == "codex" and d.get("type") == "turn.completed":
            u = d.get("usage") or {}
            c["cr"] += u.get("cached_input_tokens", 0); c["unc"] += u.get("input_tokens", 0) - u.get("cached_input_tokens", 0)
            c["cw"] += u.get("cache_write_input_tokens", 0); c["out"] += u.get("output_tokens", 0)
    return c


def wtok(c): return round(sum(C.WEIGHTS[k] * v for k, v in c.items()))


def parse(host, out):
    """`shell_calls` counts violations: Codex shell commands; Claude tool uses outside the lab server (native tools).
    `violation_tools` names them so a FAIL can be judged."""
    m = {"in_tokens": 0, "out_tokens": 0, "cost": None, "turns": 0, "tool_calls": 0, "shell_calls": 0, "violation_tools": [], "final": ""}
    lines = []
    for l in out.splitlines():
        try: lines.append(json.loads(l))
        except Exception: pass
    if host == "claude":
        for d in lines:
            if d.get("type") == "assistant":
                uses = [c for c in d["message"].get("content", []) if c.get("type") == "tool_use"]
                m["tool_calls"] += len(uses)
                native = [str(c.get("name", "")) for c in uses if not str(c.get("name", "")).startswith(RP_NAMESPACE + "__")]
                m["shell_calls"] += len(native); m["violation_tools"] = sorted(set(m["violation_tools"]) | set(native))
            if d.get("type") == "result":
                u = d.get("usage") or {}
                m["in_tokens"] = u.get("input_tokens", 0) + u.get("cache_creation_input_tokens", 0) + u.get("cache_read_input_tokens", 0)
                m["out_tokens"] = u.get("output_tokens", 0); m["cost"] = d.get("total_cost_usd"); m["turns"] = d.get("num_turns", 0)
                m["final"] = d.get("result") or ""
    elif host == "codex":
        tid = None; m["rp_direct_calls"] = 0; m["exec_calls"] = 0; m["rollout_found"] = False
        for d in lines:
            if d.get("type") == "thread.started": tid = d.get("thread_id")
            if d.get("type") == "turn.completed":
                u = d.get("usage") or {}; m["in_tokens"] += u.get("input_tokens", 0); m["out_tokens"] += u.get("output_tokens", 0)
            it = d.get("item") or {}
            if d.get("type") == "item.completed":
                if it.get("type") == "agent_message": m["final"] = it.get("text", "")
                if it.get("type") == "command_execution": m["shell_calls"] += 1; m["violation_tools"] = ["command_execution"]
        # Tool calls are only in Codex's rollout file. Direct RepoPrompt calls are function_call items in namespace
        # mcp__rp (verified on 2026-10 lab rollouts); code-mode scripts are custom_tool_call items named exec.
        # Turns are approximated as tool calls + 1 (reported, never gated).
        fs = glob.glob(f"{C.CODEX_HOME}/sessions/**/*{tid}*.jsonl", recursive=True) if tid else []
        if fs:
            m["rollout_found"] = True
            with open(fs[0]) as fh:
                for l in fh:
                    try: p = json.loads(l).get("payload") or {}
                    except Exception: continue
                    if p.get("type") in ("function_call", "custom_tool_call"): m["tool_calls"] += 1
                    if p.get("type") == "function_call" and p.get("namespace") == RP_NAMESPACE: m["rp_direct_calls"] += 1
                    if p.get("type") == "custom_tool_call" and p.get("name") == "exec": m["exec_calls"] += 1
            m["turns"] = m["tool_calls"] + 1
    return m


def proxy_stats(log):
    """proxy_tool_calls counts lab-tool calls the proxy received from the host, whether made directly or from inside a
    Codex exec script, so it is not evidence of direct calls (use rp_direct_calls). upstream_errors counts failures
    talking to the RepoPrompt app (startup, bind, RPC errors, exit, timeouts); such rows are not usable."""
    s = {"proxy_tool_calls": 0, "proxy_tool_chars": 0, "cm_calls": 0, "cm_nested": 0, "cm_out_chars": 0, "cm_child_chars": 0, "cm_errors": 0,
         "upstream_errors": 0}
    if not os.path.exists(log): return s
    with open(log) as fh: entries = [json.loads(l) for l in fh if l.strip()]
    for e in entries:
        if e.get("upstream_error"): s["upstream_errors"] += 1
        if e["tool"] == "code_mode" and "nested" in e:
            s["cm_calls"] += 1; s["cm_nested"] += e["nested"]["calls"]; s["cm_out_chars"] += e["out_chars"]; s["cm_child_chars"] += e["nested"]["child_chars"]; s["cm_errors"] += int(e["error"])
        elif not e.get("upstream_error"):
            s["proxy_tool_calls"] += 1; s["proxy_tool_chars"] += e["text_chars"] + e.get("sc_chars", 0)
    return s


def run_dir(name):
    rd = C.SCRATCH / "runs" / f"{name}-{int(time.time() * 1000)}"; rd.mkdir(parents=True); return str(rd)


def settings(host):
    return {"model": MODELS[host], "effort": EFFORT[host], "truth_commit": C.TRUTH_COMMIT[:8]}


def one(job, out_path, dry=False):
    arm_name, tid, rep = job; arm = ARMS[arm_name]; host = arm["host"]
    rd = run_dir(f"{arm_name}-{tid}-{rep}") if not dry else str(C.SCRATCH / "runs" / "dry-run")
    log = f"{rd}/proxy.log"; p = prompt(tid)
    if dry:
        os.makedirs(rd, exist_ok=True)
        cmd, _ = BUILDERS[host](arm, rd, p, log, f"{tid}:{rep}")
        print(json.dumps({"arm": arm_name, "task": tid, "rep": rep, "cmd": cmd})); return
    cmd, env = BUILDERS[host](arm, rd, p, log, f"{tid}:{rep}")
    with HOST_LIMIT[host]:
        t0 = time.time()
        try:
            r = subprocess.run(cmd, cwd=rd, env=env, stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=900)
            out, err, rc = r.stdout, r.stderr, r.returncode
        except subprocess.TimeoutExpired as e:
            out, err, rc = (e.stdout or b"").decode() if isinstance(e.stdout, bytes) else (e.stdout or ""), "TIMEOUT", -9
        wall = time.time() - t0
    with open(f"{rd}/stdout.jsonl", "w") as f: f.write(out)
    with open(f"{rd}/stderr.txt", "w") as f: f.write(err[-20000:])
    m = parse(host, out); g = grade(tid, m["final"]); c = comps(host, out)
    # A run that crashed or timed out is incorrect even if its last answer graded correct; keep the answer-only grade.
    g = {**g, "answer_correct": g["correct"], "correct": bool(g["correct"]) and rc == 0}
    rec = {"arm": arm_name, "host": host, "task": tid, "kind": TASKS[tid]["kind"], "rep": rep, "rc": rc, "wall_s": round(wall, 1),
           **{k: v for k, v in m.items() if k != "final"}, **{f"tok_{k}": v for k, v in c.items()}, "wtok": wtok(c),
           **g, **proxy_stats(log), **settings(host), "run_dir": rd}
    rec["usable"] = C.row_is_usable(rec)
    with wlock:
        with open(out_path, "a") as f: f.write(json.dumps(rec) + "\n")
    print(f"{arm_name:16} {tid:18} r{rep} ok={g['correct']} wtok={rec['wtok']} usable={rec['usable']} calls={m['tool_calls']} "
          f"cm={rec['cm_calls']}/{rec['cm_nested']} upstream_errors={rec['upstream_errors']} wall={wall:.0f}s rc={rc}", flush=True)


def load_rows(path):
    if not os.path.exists(path): return []
    with open(path) as fh: return [json.loads(l) for l in fh if l.strip()]


def incompatible(rows, arms):
    """Rows in the output file for these arms that were written with other models, effort or truth commit."""
    bad = []
    for r in rows:
        if r["arm"] not in arms: continue
        want = settings(ARMS[r["arm"]]["host"])
        got = {k: r.get(k) for k in want}
        if got != want: bad.append(f"{r['arm']} {r['task']} r{r['rep']}: {got} != {want}")
    return bad


def prune_unusable(path):
    rows = load_rows(path); keep = [r for r in rows if C.row_is_usable(r)]; drop = [r for r in rows if not C.row_is_usable(r)]
    if not drop:
        print(f"{path}: all {len(rows)} rows usable; nothing to prune"); return
    aside = f"{path}.unusable.jsonl"
    with open(aside, "a") as f: f.writelines(json.dumps(r) + "\n" for r in drop)
    tmp = f"{path}.tmp"
    with open(tmp, "w") as f: f.writelines(json.dumps(r) + "\n" for r in keep)
    os.replace(tmp, path)
    print(f"{path}: kept {len(keep)} rows; moved {len(drop)} unusable rows to {aside}. Re-run the same command to repeat them.")


def check_ready(arms, tasks, dry):
    hosts = {ARMS[x]["host"] for x in arms}
    problems = C.preflight(hosts, any(ARMS[x].get("cm") for x in arms), any(TASKS[t].get("family") == "edit" for t in tasks))
    if not problems and not dry:
        bad = C.probe_upstream()
        if bad: problems.append(bad)
    if problems and not dry:
        sys.exit("Not ready (no run started):\n- " + "\n- ".join(problems))
    for x in problems: print(f"# preflight (dry run, not enforced): {x}", file=sys.stderr)


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--reps", type=int, default=1); ap.add_argument("--rep-offset", type=int, default=0)
    ap.add_argument("--tasks", default=",".join(TASKS)); ap.add_argument("--arms")
    ap.add_argument("--out", required=True); ap.add_argument("--workers", type=int, default=4); ap.add_argument("--seed", type=int, default=7)
    ap.add_argument("--claude-model"); ap.add_argument("--codex-model"); ap.add_argument("--codex-effort")
    ap.add_argument("--dry-run", action="store_true", help="print the host commands instead of running them")
    ap.add_argument("--prune-unusable", action="store_true", help="move unusable rows to <out>.unusable.jsonl and exit")
    a = ap.parse_args()
    if a.prune_unusable: return prune_unusable(a.out)
    if not a.arms: ap.error("--arms is required")
    if a.claude_model: MODELS["claude"] = a.claude_model
    if a.codex_model: MODELS["codex"] = a.codex_model
    if a.codex_effort: EFFORT["codex"] = a.codex_effort
    arms, tasks = a.arms.split(","), a.tasks.split(",")
    unknown = [x for x in arms if x not in ARMS] + [t for t in tasks if t not in TASKS]
    if unknown: sys.exit(f"unknown arm or task: {', '.join(unknown)}")
    rows = load_rows(a.out)
    bad = incompatible(rows, arms)
    if bad: sys.exit(f"{a.out} holds rows from other settings; use a new --out file.\n- " + "\n- ".join(bad[:5]))
    check_ready(arms, tasks, a.dry_run)
    jobs = [(arm, t, r + a.rep_offset) for r in range(a.reps) for t in tasks for arm in arms]
    rnd = random.Random(a.seed); rnd.shuffle(jobs); jobs.sort(key=lambda j: j[2])  # rep-major, shuffled within rep
    done = {(r["arm"], r["task"], r["rep"]) for r in rows}
    jobs = [j for j in jobs if j not in done]
    unusable = sum(1 for r in rows if r["arm"] in arms and not C.row_is_usable(r))
    if unusable:
        print(f"WARNING: {a.out} has {unusable} unusable rows for these arms (non-zero exit, no usage or upstream errors); "
              f"they are kept and skipped. If they came from an outage, run: runner.py --out {a.out} --prune-unusable", file=sys.stderr)
    if a.dry_run:
        for j in jobs: one(j, a.out, dry=True)
        return
    print(f"{len(jobs)} jobs", flush=True)
    with ThreadPoolExecutor(a.workers) as ex:
        list(ex.map(lambda j: one(j, a.out), jobs))


if __name__ == "__main__":
    main()
