#!/usr/bin/env python3
"""Lab MCP proxy in front of the CE debug MCP helper (repoprompt_ce_cli_debug), spawned by the host CLI.

Exposes only read_file, file_search, get_code_structure, get_file_tree (+ an optional `code_mode`) and binds the
upstream connection to CMLAB_REPO. Paths come from lab_config (CMLAB_REPO, CMLAB_CLI, CMLAB_QJS_HOST, CMLAB_SCRATCH);
runner.py passes them explicitly because host CLIs do not always forward the parent environment.
Env:
  PROXY_MODE      text | structured   (structured adds outputSchema + structuredContent from _rawJSON, keeps full text)
  PROXY_CODEMODE  0 | 1               (1 adds `code_mode`, run by the QuickJS-ng host built from qjs/cm_host_v2.c:
                                      one _rawJSON upstream call per child, data-first {data|text,isError}, failures reject
                                      unless {allowError:true}, one retry per failed child, failure footer, partial output on
                                      stop, plan §6 limits)
  PROXY_LOG       path to JSONL call log (sizes/timings only)
  PROXY_FAULT_ERR  <rate>             (default off) return isError "RepoPrompt: transient error, please retry" instead of calling upstream
  PROXY_FAULT_SLOW <rate>:<seconds>   (default off) sleep <seconds> before answering
  PROXY_FAULT_SEED <str>              seed; decisions are deterministic per (seed, call index). Applied identically to direct and nested calls.
  PROXY_FORWARD_INSTRUCTIONS 0|1      (default 0) forward the upstream server instructions; disables the cached tool list
  PROXY_STARTUP_TIMEOUT <s>           (default 60) per upstream request during startup
  PROXY_CM_WALL_S <s>                 (default 60) code_mode wall limit; nested calls never outlive it (+5 s backstop)
  PROXY_CM_SETTLE_S <s>               (default 5) after a script stops, how long in-flight nested calls may still resolve;
                                      calls unresolved after that are logged as upstream errors (row not usable)
"""
import itertools, json, os, random, subprocess, sys, threading, time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import lab_config
from upstream import Upstream, UpstreamError, connect_and_bind, text_of

ROOT = str(lab_config.REPO) if lab_config.REPO else None
MODE = os.environ.get("PROXY_MODE", "text")
CODEMODE = os.environ.get("PROXY_CODEMODE", "0") == "1"
LOG = os.environ.get("PROXY_LOG") or str(lab_config.SCRATCH / "proxy.log")
ALLOW = ["read_file", "file_search", "get_code_structure", "get_file_tree"]
SCHEMAS = json.load(open(lab_config.LAB_DIR / "schemas.json"))
CACHE = lab_config.SCRATCH / "tools_cache.json"
FWD_INSTR = os.environ.get("PROXY_FORWARD_INSTRUCTIONS", "0") == "1"
out_lock = threading.Lock()
FAULT_ERR = float(os.environ.get("PROXY_FAULT_ERR") or 0)
_fs = (os.environ.get("PROXY_FAULT_SLOW") or "").split(":")
FAULT_SLOW_RATE, FAULT_SLOW_S = (float(_fs[0]), float(_fs[1])) if len(_fs) == 2 else (0.0, 0.0)
FAULT_SEED = os.environ.get("PROXY_FAULT_SEED", "0")
FAULTS = FAULT_ERR > 0 or FAULT_SLOW_RATE > 0
_fault_idx = itertools.count(); _fault_lock = threading.Lock()
FAULT_ERR_TEXT = "RepoPrompt: transient error, please retry"


def fault_for_next_call():
    """(err, slow) for the next RepoPrompt call; deterministic per (seed, call index), independent draws per fault kind."""
    with _fault_lock: i = next(_fault_idx)
    r = random.Random(f"{FAULT_SEED}:{i}")
    return r.random() < FAULT_ERR, r.random() < FAULT_SLOW_RATE


def log(e):
    with open(LOG, "a") as f: f.write(json.dumps({"t": time.time(), "mode": MODE, "cm": CODEMODE, **e}) + "\n")


up = None
READY = threading.Event(); _state = {}
STARTUP_TIMEOUT = float(os.environ.get("PROXY_STARTUP_TIMEOUT") or 60)   # per upstream request during startup
CALL_TIMEOUT = 300                                                     # direct upstream tool call


def _connect():
    """Connect, bind and list tools. Any failure is published in _state["fatal"]; READY is always set."""
    global up
    try:
        up = Upstream(lab_config.CLI, stderr_path=os.path.join(os.path.dirname(LOG) or ".", "upstream.stderr"))
        _state["instr"] = connect_and_bind(up, ROOT, timeout=STARTUP_TIMEOUT).get("instructions")
        tl = [t for t in up.req("tools/list", {}, STARTUP_TIMEOUT).get("tools", []) if t.get("name") in ALLOW]
        if sorted(t["name"] for t in tl) != sorted(ALLOW):
            raise UpstreamError(f"upstream lacks lab tools: has {sorted(t['name'] for t in tl)}")
        _state["tools"] = tl
        if not CACHE.exists():  # atomic: concurrent proxies may race to write it
            CACHE.parent.mkdir(parents=True, exist_ok=True)
            tmp = CACHE.with_name(f"{CACHE.name}.{os.getpid()}.tmp"); tmp.write_text(json.dumps(tl)); os.replace(tmp, CACHE)
    except Exception as e:  # noqa: BLE001 - every startup failure must reach callers
        _state["fatal"] = f"{type(e).__name__}: {e}" if not isinstance(e, UpstreamError) else str(e)
        log({"tool": "_startup", "upstream_error": True, "text_chars": 0, "error": True, "detail": _state["fatal"][:300]})
    finally:
        READY.set()


def upstream_ready():
    """None when the upstream is usable, else the reason. Waits at most for the startup deadline."""
    if not READY.wait(4 * STARTUP_TIMEOUT + 5): return "upstream startup did not finish"
    return _state.get("fatal")


def proxy_error(msg):
    return {"content": [{"type": "text", "text": f"lab proxy: RepoPrompt upstream unavailable: {msg}"}], "isError": True}


def call_rp(name, args, structured, fault_box=None):
    """Returns CallToolResult dict. structured=True adds structuredContent parsed from _rawJSON (text kept intact)."""
    args = {k: v for k, v in (args or {}).items() if not k.startswith("_")}
    if FAULTS:
        err, slow = fault_for_next_call()
        if fault_box is not None: fault_box.update(err=err, slow=slow)
        if slow: time.sleep(FAULT_SLOW_S)
        if err: return {"content": [{"type": "text", "text": FAULT_ERR_TEXT}], "isError": True}
    if not structured:
        return up.req("tools/call", {"name": name, "arguments": args}, CALL_TIMEOUT)
    res_box = {}
    def raw():
        try: res_box["raw"] = up.req("tools/call", {"name": name, "arguments": {**args, "_rawJSON": True}}, CALL_TIMEOUT)
        except UpstreamError as e: res_box["err"] = e
    th = threading.Thread(target=raw); th.start()
    res = up.req("tools/call", {"name": name, "arguments": args}, CALL_TIMEOUT)
    th.join()
    if "err" in res_box: raise res_box["err"]
    r = res_box.get("raw") or {}
    if not res.get("isError") and not r.get("isError"):
        try:
            sc = json.loads(text_of(r))
            if isinstance(sc, dict): res = {**res, "structuredContent": sc}
        except Exception: pass
    return res


# ---------------- code_mode executor (QuickJS-ng host, plan §6 rules as run in the §3.8 gate) ----------------
CM_WALL_S = float(os.environ.get("PROXY_CM_WALL_S") or 60)
CM_BACKSTOP_S = CM_WALL_S + 5
CM_SETTLE_S = float(os.environ.get("PROXY_CM_SETTLE_S") or 5)
CM_ENV = {"CM_WALL_MS": str(int(CM_WALL_S * 1000)), "CM_CPU_MS": "2000", "CM_HEAP_MB": "64", "CM_STACK_KB": "1024", "CM_MAX_CALLS": "32",
          "CM_MAX_INFLIGHT": "2", "CM_CHILD_MAX": "2097152", "CM_OUT_MAX": "32768", "CM_OUT_MODE": "fail", "CM_CALL_MODE": "fail"}
CM_CHILD_MAX = 2 * 1024 * 1024
CM_DESC = ("Run a JavaScript async function body (top-level await/return allowed) that calls RepoPrompt read-only tools: "
 "`await tools.read_file(args)`, `tools.file_search(args)`, `tools.get_code_structure(args)`, `tools.get_file_tree(args)` "
 "(same arguments as the direct tools). Each call resolves to `{data}`, the structured result: "
 "read_file -> data.content (file text), data.total_lines, data.first_line, data.last_line; "
 "file_search -> data.total_matches, data.matched_files, data.per_file_totals [{path,count}] (all matches per file), "
 "data.per_file_counts [{path,count}] (returned matches), data.content_match_groups [{path, lines:[{line_number,line_text}]}], "
 "data.path_match_lines, data.limit_hit (true = results capped; raise max_results); "
 "get_code_structure -> data.files [{path, content, tokens}], data.status; get_file_tree -> data.tree (text), data.was_truncated. "
 "If structured data is unavailable you get `{text}` instead. A failed call REJECTS (message names the tool, path/pattern and error) "
 "unless you pass a second argument `{allowError: true}`, which resolves `{isError: true, error}` instead; check failures and retry "
 "only the failed items. At most 2 calls run at once: use Promise.all for independent calls. Count lines with data.total_lines, "
 "never by splitting text. No Intl (toLocale*/localeCompare are not locale-aware): sort with explicit comparators. "
 "`return` only the aggregate you need (strings as-is, other values as JSON); text(v)/console.log also add output. "
 "No filesystem, network, timers or modules. Limits: 60 s, 32 tool calls, 32 KiB output (over the limit is an error, not a truncation). "
 "Use it for several reads/searches or large results you only need part of, not for single lookups.")


STOPPED_TEXT = "code_mode stopped before this call was sent"


def call_rp_raw(name, args, fault_box=None, timeout=CALL_TIMEOUT, stop=None):
    """At most one upstream call with _rawJSON, waiting at most `timeout` s. Faults (PROXY_FAULT_*) are drawn per attempt,
    as in call_rp; an injected delay ends early when `stop` is set, and nothing is sent once it is set.
    Returns (child_result, error_text_or_None, raw_chars)."""
    args = {k: v for k, v in (args or {}).items() if not k.startswith("_")}
    if FAULTS:
        err, slow = fault_for_next_call()
        if fault_box is not None: fault_box.update(err=err, slow=slow)
        if slow: stop.wait(FAULT_SLOW_S) if stop else time.sleep(FAULT_SLOW_S)
        if err: return {"text": FAULT_ERR_TEXT, "isError": True, "error": FAULT_ERR_TEXT}, FAULT_ERR_TEXT, len(FAULT_ERR_TEXT)
    if (stop is not None and stop.is_set()) or timeout <= 0:
        return {"isError": True, "error": STOPPED_TEXT}, STOPPED_TEXT, 0
    try:
        r = up.req("tools/call", {"name": name, "arguments": {**args, "_rawJSON": True}}, timeout=timeout)
    except Exception as e:  # noqa: BLE001
        msg = f"bridge error: {e if isinstance(e, UpstreamError) else type(e).__name__}"
        if fault_box is not None: fault_box["upstream_error"] = True
        return {"isError": True, "error": msg}, msg, 0
    txt = text_of(r); n = len(txt.encode("utf-8", "replace"))
    if n > CM_CHILD_MAX:
        msg = f"result is {n} bytes, over the 2 MiB per-call limit; narrow the request"
        return {"isError": True, "error": msg}, msg, n
    data = None
    try:
        d = json.loads(txt)
        if isinstance(d, dict): data = d
    except Exception: pass
    is_err = bool(r.get("isError")) or bool(data and data.get("is_error"))
    if is_err:
        msg = (data or {}).get("error") if isinstance((data or {}).get("error"), str) else (txt or "tool error")
        out = {("data" if data is not None else "text"): (data if data is not None else txt), "isError": True, "error": msg}
        return out, msg, n
    return ({"data": data, "isError": False} if data is not None else {"text": txt, "isError": False}), None, n


def _cm_key(args):
    for k in ("path", "pattern", "paths"):
        if isinstance(args, dict) and k in args: return f"{k}={json.dumps(args[k])[:120]}"
    return json.dumps(args)[:120] if args else "{}"


def run_codemode(script):
    """Nested calls share the script's deadline. When the script stops, no further attempt or retry is sent; calls still
    in flight get CM_SETTLE_S to resolve, then accounting is final and any unresolved call counts as an upstream error."""
    t0 = time.time(); deadline = t0 + CM_BACKSTOP_S
    n = {"calls": 0, "failed": 0, "child_chars": 0, "attempts": 0, "retried": 0}
    failures = []; flock = threading.Lock(); settled = threading.Condition(flock); sem = threading.Semaphore(2)
    stop = threading.Event(); pending_rpcs = [0]   # shared with child threads: never rebind, only mutate under flock
    p = subprocess.Popen([str(lab_config.QJS_HOST)], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True,
                         bufsize=1, encoding="utf-8", errors="replace", env={**os.environ, **CM_ENV})
    p.stdin.write(json.dumps({"type": "start", "script": script}) + "\n"); p.stdin.flush()
    wlock = threading.Lock(); final = {}; done_children = [0]

    def handle(m):
        with flock: n["calls"] += 1; k = n["calls"]
        name, args = m.get("name"), m.get("args")
        if k > 32: res, err = {"isError": True, "error": "call limit exceeded (32)"}, "call limit exceeded (32)"
        elif name not in ALLOW: res, err = {"isError": True, "error": f"tool not allowed: {name}"}, f"tool not allowed: {name}"
        elif not isinstance(args, dict): res, err = {"isError": True, "error": "arguments must be a JSON object"}, "arguments must be a JSON object"
        else:
            res, err = {"isError": True, "error": STOPPED_TEXT}, STOPPED_TEXT
            with sem:
                for attempt in (0, 1):
                    # Stop check, registration and retry count are one step under flock; the finalizer sets `stop`
                    # under flock, so every attempt it does not see as pending is never sent.
                    with flock:
                        if stop.is_set(): break
                        pending_rpcs[0] += 1
                        if attempt: n["retried"] += 1
                    fb = {}; nchars = 0
                    try: res, err, nchars = call_rp_raw(name, args, fb, timeout=deadline - time.time(), stop=stop)
                    except Exception as e:  # noqa: BLE001 - still account for the attempt and answer the script
                        err = f"bridge error: {type(e).__name__}"; res = {"isError": True, "error": err}; fb["upstream_error"] = True
                    finally:
                        # One atomic publish: the finalizer never sees the call as settled before its counters.
                        with flock:
                            n["attempts"] += 1; n["child_chars"] += nchars
                            if fb.get("upstream_error"): n["upstream_errors"] = n.get("upstream_errors", 0) + 1
                            if fb.get("err"): n["fault_err"] = n.get("fault_err", 0) + 1
                            if fb.get("slow"): n["fault_slow"] = n.get("fault_slow", 0) + 1
                            pending_rpcs[0] -= 1; settled.notify_all()
                    if not err or "2 MiB" in err or err == STOPPED_TEXT or attempt == 1: break
        if err:
            msg = f"tools.{name}({_cm_key(args)}) failed: {err[:300]}"
            res = {**res, "error": msg}
            with flock: n["failed"] += 1; failures.append(f"{name} {_cm_key(args)} — {err[:200]}")
        with flock: done_children[0] += 1
        with wlock:
            try: p.stdin.write(json.dumps({"type": "reply", "id": m["id"], "result": res}) + "\n"); p.stdin.flush()
            except Exception: pass

    timer = threading.Timer(CM_BACKSTOP_S, p.kill); timer.start()   # backstop; the host enforces the wall and 2 s CPU limits itself
    for line in p.stdout:
        try: m = json.loads(line)
        except Exception: continue
        if m.get("type") == "call": threading.Thread(target=handle, args=(m,), daemon=True).start()
        elif m.get("type") == "done": final = m; break
    timer.cancel()
    try: p.kill(); p.wait(timeout=5)
    except Exception: pass
    with flock: stop.set()
    with wlock: p.stdin.close()
    p.stdout.close()
    settle_until = min(deadline, time.time() + CM_SETTLE_S)
    with settled:
        while pending_rpcs[0] and time.time() < settle_until: settled.wait(settle_until - time.time())
        unresolved = pending_rpcs[0]
        n["unresolved_at_stop"] = unresolved
        if unresolved: n["upstream_errors"] = n.get("upstream_errors", 0) + unresolved
        # final: later child updates do not change what is reported or logged
        stats = json.loads(json.dumps(n)); nf, fl, ncalls, ndone = n["failed"], list(failures), n["calls"], done_children[0]
    secs = time.time() - t0; st = final.get("stats") or {}; lim = st.get("limit") or ""
    out = final.get("output", "") if final else ""
    completed = st.get("completed", ndone) if final else ndone
    host_inflight = (st.get("inflight_at_stop", 0) + st.get("queued_at_stop", 0)) if final else max(0, ncalls - ndone)
    infl_txt = f"{host_inflight} in flight" + (f" ({st.get('inflight_at_stop', 0)} running, {st['queued_at_stop']} queued)" if final and st.get("queued_at_stop") else "")
    timeout = (not final) or lim in ("wall time limit exceeded", "CPU time limit exceeded", "cancelled")
    lines = []
    if timeout:
        why = lim or "host did not finish"
        lines.append(f"⏱ code_mode stopped after {secs:.0f} s ({why}): {completed} completed, {infl_txt}, {nf} failed")
    elif lim:
        extra = f" — returned the first {st.get('out_bytes', len(out))} bytes; aggregate more in code and return less" if lim == "output limit exceeded" else ""
        lines.append(f"⛔ code_mode {lim} (limits: 32 calls, 32 KiB output, 64 MiB heap, 2 MiB per call): {completed} completed, {infl_txt}, {nf} failed{extra}")
    elif final.get("error"):
        lines.append("Script error: " + final["error"])
    if stats["unresolved_at_stop"]:
        lines.append(f"⚠ {stats['unresolved_at_stop']} nested calls had no answer from RepoPrompt when code_mode stopped")
    if fl:
        lines.append(f"⚠ {nf} of {ncalls} nested calls failed:")  # counts as of the final snapshot
        lines += [f"  {x}" for x in fl[:10]] + ([f"  … and {len(fl) - 10} more"] if len(fl) > 10 else [])
    if lines: out = (out + "\n" if out else "") + "\n".join(lines)
    err_flag = bool(timeout or lim or final.get("error"))
    log({"tool": "code_mode", "v2": True, "script_chars": len(script), "out_chars": len(out), "nested": stats, "ms": int(secs * 1000), "error": err_flag,
         "upstream_error": bool(stats.get("upstream_errors")),
         "failed": nf, "retried": stats["retried"], "timeout": bool(timeout), "limit": lim, "cpu_ms": st.get("cpu_ms"), "heap_peak": st.get("heap_peak")})
    return {"content": [{"type": "text", "text": out}], "isError": err_flag}


def send(m):
    with out_lock: sys.stdout.write(json.dumps(m) + "\n"); sys.stdout.flush()


def handle(msg, tools, instructions):
    """Every request with an id gets exactly one reply, even when handling raises."""
    try:
        _handle(msg, tools, instructions)
    except Exception as e:  # noqa: BLE001
        if msg.get("id") is None: return
        log({"tool": str((msg.get("params") or {}).get("name") or msg.get("method")), "upstream_error": True, "text_chars": 0, "error": True,
             "detail": f"{type(e).__name__}: {e}"[:300]})
        if msg.get("method") == "tools/call":
            send({"jsonrpc": "2.0", "id": msg["id"], "result": proxy_error(f"{type(e).__name__}: {e}")})
        else:
            send({"jsonrpc": "2.0", "id": msg["id"], "error": {"code": -32603, "message": f"lab proxy: {type(e).__name__}: {e}"[:300]}})


def _handle(msg, tools, instructions):
    method, mid, p = msg.get("method"), msg.get("id"), msg.get("params") or {}
    if method == "initialize":
        send({"jsonrpc": "2.0", "id": mid, "result": {"protocolVersion": p.get("protocolVersion", "2025-06-18"),
              "capabilities": {"tools": {"listChanged": False}}, "serverInfo": {"name": "rp", "version": "exp"},
              **({"instructions": instructions} if FWD_INSTR and instructions else {})}})
    elif method == "tools/list":
        out = []
        for t in tools:
            t = dict(t)
            if MODE == "structured": t["outputSchema"] = SCHEMAS[t["name"]]
            out.append(t)
        if CODEMODE:
            out.append({"name": "code_mode", "description": CM_DESC,
                        "inputSchema": {"type": "object", "properties": {"script": {"type": "string", "description": "JavaScript async function body"}}, "required": ["script"]}})
        send({"jsonrpc": "2.0", "id": mid, "result": {"tools": out}})
    elif method == "tools/call":
        name, args = p.get("name"), p.get("arguments") or {}
        t0 = time.time()
        bad = upstream_ready()
        if bad:
            log({"tool": str(name), "upstream_error": True, "text_chars": 0, "error": True, "detail": bad[:300]})
            res = proxy_error(bad)
        elif name == "code_mode" and CODEMODE:
            res = run_codemode(args.get("script", ""))
        elif name in ALLOW:
            fb = {}; res = call_rp(name, args, MODE == "structured", fb)
            log({**({"fault": fb} if FAULTS else {}), "tool": name, "text_chars": len(text_of(res)), "sc_chars": len(json.dumps(res.get("structuredContent"))) if "structuredContent" in res else 0,
                 "ms": int((time.time() - t0) * 1000), "error": bool(res.get("isError"))})
        else:
            res = {"content": [{"type": "text", "text": f"Unknown tool {name}"}], "isError": True}
        send({"jsonrpc": "2.0", "id": mid, "result": res})
    elif mid is not None:
        send({"jsonrpc": "2.0", "id": mid, "result": {}})


def main():
    if not ROOT:
        sys.exit("rp_proxy: CMLAB_REPO is unset (see Scripts/codemode_lab/README.md)")
    # Answer initialize/tools/list at once from a cached tool list; connect upstream in the background.
    threading.Thread(target=_connect, daemon=True).start()
    if CACHE.exists() and not FWD_INSTR:
        tools, instructions = json.loads(CACHE.read_text()), None
    else:
        bad = upstream_ready()
        if bad: sys.exit(f"rp_proxy: {bad}")
        tools, instructions = _state["tools"], _state.get("instr")
    for line in sys.stdin:
        line = line.strip()
        if not line: continue
        try: msg = json.loads(line)
        except Exception: continue
        threading.Thread(target=handle, args=(msg, tools, instructions), daemon=True).start()


if __name__ == "__main__":
    main()
