#!/usr/bin/env python3
"""Measurement-only adapter for live in-app A/B runs of the lab tasks (real RepoPrompt tools, real in-app code_mode).

The main agent starts every Agent Mode session itself; this module never starts, steers or configures agents, never
calls providers and never reads credentials. It only:
  prepare  check the pinned fixture checkout and print one worker prompt per task (same prompt for both arms)
  collect  read one finished session (exact AgentSession JSON plus its exact raw provider trace) into one row that
           analyze.py accepts, after checking identity, terminal status, usage coverage and tool violations
  weigh    add `wtok` to collected rows from explicitly declared weights (no built-in prices)

Usage:
  live_ab.py prepare --tasks T1_caps,T7_top_lines            (needs CMLAB_REPO = clean checkout of the truth commit)
  live_ab.py collect --sessions-dir <Workspace-*/AgentSessions> --session-id <UUID> --arm app_cx_cm --task T1_caps \
                     --rep 0 --wall-s 41.2 --status completed --out rows.jsonl   (fresh rows need the same CMLAB_REPO)
  live_ab.py weigh rows.jsonl --weights unc=1,cw5m=1.25,cw1h=2,cr=0.1,out=5 --label <name> --out weighted.jsonl
See README.md ("Live in-app A/B").
"""
from __future__ import annotations

import argparse, glob, hashlib, json, os, subprocess, sys, time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import lab_config as C
from tasks import TASKS, grade, prompt as lab_prompt

PROHIBITION = ("Do not call ask_oracle or ask_user, do not use context_builder with response_type review or plan, and do not "
               "start other agents. If you have a question or want a second opinion or a review, stop and report back to the "
               "main agent.")
READ_TOOLS = ("read_file", "file_search", "get_code_structure", "get_file_tree")
ALLOWED_TOOLS = READ_TOOLS + ("code_mode",)
# Host startup contract: Agent Mode base instructions require one set_status call. Allowed once per turn (top-level, or Codex
# exec-nested on a RepoPrompt server), counted separately as admin_calls; repeats are violations. Not a read or script tool.
ADMIN_TOOL = "set_status"
# Arm names only tag rows; both arms of a host get the same prompt. Pass --pairs app_cc_cm:app_cc_base,app_cx_cm:app_cx_base to analyze.py.
ARMS = {"app_cc_base": "claude", "app_cc_cm": "claude", "app_cx_base": "codex", "app_cx_cm": "codex"}
CLAUDE_RAW_DIR = "/tmp/repoprompt-ce-claude-raw-events"
CLAUDE_RP_PREFIX = "mcp__RepoPromptCE__"
CODEX_RP_NAMESPACES = {"mcp__RepoPromptCE", "mcp__RepoPromptCE_Direct"}
CODEX_RP_SERVERS = {"RepoPromptCE", "RepoPromptCE-Direct"}
CODEX_EXEC_TOOL = "exec"   # Codex native code-mode container (custom_tool_call); allowed only for nested RepoPrompt read tools
CODEX_OK_ITEMS = {"UserMessage", "AgentMessage", "Reasoning", "McpToolCall"}
NOT_TERMINAL = {None, "idle", "running", "waitingForUser", "waitingForQuestion", "waitingForApproval"}
TOKEN_KEYS = ("unc", "cw5m", "cw1h", "cw", "cr", "out")   # cw = cache write without a TTL breakdown (Codex)
STATUSES = ("completed", "failed", "cancelled", "interrupted", "timeout", "error")   # main's observed agent_run outcome
RECORDED_RCS = (0, 1)   # attempt outcomes; rc 2 (identity/treatment/shape) and 3 (wait expired) are measurement problems


# ---------------------------------------------------------------- prepare

def check_fixture(repo) -> list[str]:
    """Problems with the pinned checkout the app answers for. Untracked files count: file_search would see them."""
    if not repo: return ["CMLAB_REPO is unset (clean detached checkout of the truth commit, bound by main)."]
    if not os.path.isdir(repo): return [f"CMLAB_REPO={repo} does not exist."]
    head = subprocess.run(["git", "-C", str(repo), "rev-parse", "HEAD"], capture_output=True, text=True)
    if head.returncode != 0 or head.stdout.strip() != C.TRUTH_COMMIT:
        return [f"CMLAB_REPO HEAD is {head.stdout.strip() or 'unknown'}, not {C.TRUTH_COMMIT}."]
    dirty = subprocess.run(["git", "-C", str(repo), "status", "--porcelain"], capture_output=True, text=True)
    if dirty.returncode != 0 or dirty.stdout.strip():
        return [f"CMLAB_REPO is not clean ({len(dirty.stdout.splitlines())} changed or untracked paths)."]
    return []


def worker_prompt(tid: str, root: str) -> str:
    """The lab prompt with the `rp` proxy namespace replaced by the real RepoPrompt read-only tools. Same text for both
    arms: code_mode is mentioned as possibly available, never required. Begins with the exact delegation prohibition."""
    body = lab_prompt(tid, root).split("\n\n", 1)[1]   # "Question: ..." / "Change: ..." plus the answer-format paragraph
    rules = ("Use only RepoPrompt's read-only tools read_file, file_search, get_code_structure and get_file_tree (a code_mode "
             "tool may also be available). If your host instructions require it, you may call set_status once at startup; do not "
             "call it again. Do not run shell commands, do not use native file tools, do not modify files, and do not call any "
             "other tool. Paths are relative to the repository root.")
    if TASKS[tid].get("family") == "edit":
        head = f"Prepare a code change for the repository at {root}. {rules} You cannot modify files: output the change as a patch instead."
    else:
        head = f"Answer a question about the repository at {root}. {rules}"
    return f"{PROHIBITION}\n\n{head}\n\n{body}"


def prepare(tasks: list[str], repo) -> list[dict]:
    problems = check_fixture(repo)
    if problems: raise SystemExit("Fixture not ready:\n- " + "\n- ".join(problems))
    out = []
    for t in tasks:
        p = worker_prompt(t, str(repo))
        out.append({"task": t, "kind": TASKS[t]["kind"], "family": TASKS[t].get("family", "lookup"), "prompt": p,
                    "prompt_sha256": hashlib.sha256(p.encode()).hexdigest(), "fixture": str(repo), "truth_commit": C.TRUTH_COMMIT})
    return out


# ---------------------------------------------------------------- collect helpers

def _jsonl(path):
    with open(path) as fh:
        for line in fh:
            if line.strip():
                try: yield json.loads(line)
                except json.JSONDecodeError: yield {"_bad_line": True}


def _tool_leaf(name: str) -> str:
    return str(name or "").split("__")[-1]


class Ev:
    """Collected evidence. errors = identity/shape failures (row incorrect, rc 2); pending = data not persisted yet
    (retried until the wait expires, then rc 3); usage_problems = usage not honestly measurable (row unusable)."""
    def __init__(self):
        self.errors, self.pending, self.usage_problems, self.warnings, self.violations = [], [], [], [], []
        self.f = {}


def _session_part(d, session_id, turn_index, ev):
    if str(d.get("id", "")).upper() != session_id.upper():
        ev.errors.append(f"session id {d.get('id')!r} != {session_id}")
    state = d.get("lastRunState"); ev.f["session_state"] = state
    turns = (d.get("transcript") or {}).get("turns") or []
    if turn_index is None:
        if state in NOT_TERMINAL: ev.pending.append(f"session lastRunState={state!r}"); return None
        if len(turns) != 1:
            ev.errors.append(f"session has {len(turns)} transcript turns; a fresh single-turn session is required "
                             "(--turn-index is for offline qualification only)"); return None
        t = turns[0]
    else:
        if turn_index >= len(turns): ev.errors.append(f"turn index {turn_index} out of range ({len(turns)} turns)"); return None
        t = turns[turn_index]
    spans = t.get("responseSpans") or []
    term = t.get("terminalState")
    if term is None and turn_index is not None and spans and all(s.get("lifecycle") == "completed" for s in spans):
        term = "completed"; ev.warnings.append("turn terminalState absent; qualification used span lifecycles")
    ev.f["turn_terminal"] = term
    if term is None: ev.pending.append("transcript turn has no terminalState")
    acts = [a for s in spans for a in s.get("activities") or []]
    concl = next((a for a in acts if a.get("id") == t.get("conclusionActivityID")), None) or \
        next((a for a in reversed(acts) if a.get("role") == "assistant"), None)
    ev.f["transcript_final"] = (concl or {}).get("text") or ""
    ev.f["request_text"] = (t.get("request") or {}).get("text") or ""
    cards = [a["toolExecution"] for a in acts if a.get("toolExecution")]
    names = [_tool_leaf(c.get("toolName")) for c in cards]
    ev.f.update(transcript_turn_id=t.get("id"), transcript_tool_cards=len(cards),
                cm_child_cards=sum(1 for c in cards if c.get("codeModeParentInvocationID")),
                tool_errors=sum(1 for c in cards if c.get("toolIsError") or c.get("status") not in (None, "success")),
                card_violation_tools=sorted({n for n in names if n not in ALLOWED_TOOLS + (CODEX_EXEC_TOOL, ADMIN_TOOL)} |
                                            _admin_card_violations(cards, names)))
    ev.f["has_unmeasured_history"] = (d.get("providerUsage") or {}).get("hasUnmeasuredHistory")
    return t


def _claude_part(d, t, turn_index, raw_dir, ev):
    sid = d.get("providerSessionID")
    if not sid: ev.pending.append("no providerSessionID"); return
    pu = d.get("providerUsage") or {}; uturns = pu.get("turns") or []
    if turn_index is None:
        if len(uturns) != 1:
            (ev.pending if not uturns else ev.errors).append(f"providerUsage has {len(uturns)} Claude turns, expected 1"); return
        u = uturns[0]
    else:   # qualification only: assumes providerUsage.turns follow transcript order
        if turn_index >= len(uturns): ev.pending.append("no providerUsage turn for the selected turn"); return
        u = uturns[turn_index]
    segs = pu.get("claudeSegments") or []
    if not (0 <= u.get("segmentIndex", -1) < len(segs)) or segs[u["segmentIndex"]].get("executionID") != u.get("executionID"):
        ev.errors.append("providerUsage turn executionID does not match its segment")
    ev.f.update(usage_turn_id=u.get("turnID"), execution_id=u.get("executionID"),
                usage_contract=(segs[u["segmentIndex"]].get("contractID") if 0 <= u.get("segmentIndex", -1) < len(segs) else None))
    files = sorted(glob.glob(os.path.join(raw_dir, f"claude-session-{glob.escape(sid)}-*.jsonl")))
    if not files: ev.pending.append(f"no raw event file for provider session {sid}"); return
    scoped, found = [], 0
    for f in files:
        inside = False
        for e in _jsonl(f):
            if e.get("_bad_line"): continue
            p = e.get("payload") or {}
            if e.get("kind") == "usage.dispatch.registered" and p.get("turnID") == u.get("turnID"):
                found += 1; inside = True
                if p.get("launchToken") != u.get("executionID"): ev.errors.append("raw dispatch launchToken != usage executionID")
            if inside:
                if e.get("sessionID") != sid: ev.errors.append("raw event from another provider session")
                scoped.append(e)
                if e.get("kind") == "usage.result.attributed" and p.get("turnID") == u.get("turnID"): inside = False
    if found != 1:
        (ev.pending if not found else ev.errors).append(f"{found} raw dispatch records for usage turn {u.get('turnID')}"); return
    attributed = next((e["payload"] for e in scoped if e.get("kind") == "usage.result.attributed"), None)
    if not attributed: ev.pending.append("raw usage.result.attributed missing"); return
    span_runs = {s.get("runID") for s in t.get("responseSpans") or [] if s.get("runID")}
    raw_runs = {e.get("runID") for e in scoped if e.get("runID")}
    if span_runs and not raw_runs <= span_runs: ev.errors.append(f"raw runIDs {sorted(raw_runs)} not in transcript spans {sorted(span_runs)}")
    stream = [e["payload"] for e in scoped if e.get("kind") == "protocol.inbound.streamPayload" and isinstance(e.get("payload"), dict)]
    init = next((p for p in stream if p.get("type") == "system" and p.get("subtype") == "init"), {})
    results = [p for p in stream if p.get("type") == "result" and p.get("result_index") == attributed.get("resultIndex")]
    if len(results) != 1: ev.errors.append(f"{len(results)} raw results for resultIndex {attributed.get('resultIndex')}"); return
    res = results[0]
    model = init.get("model"); ev.f["model"] = model; ev.f["cli_version"] = init.get("claude_code_version")
    tools = init.get("tools")   # what this turn's Claude process was actually offered
    ev.f["cm_advertised"] = (CLAUDE_RP_PREFIX + "code_mode") in tools if isinstance(tools, list) else None
    ev.f["treatment_evidence"] = "claude init.tools" if isinstance(tools, list) else "none (init.tools absent)"
    msg_models = {(p.get("message") or {}).get("model") for p in stream if p.get("type") == "assistant"} - {None}
    if model is None or msg_models - {model}: ev.warnings.append(f"assistant models {sorted(msg_models)} vs init model {model!r}")
    ev.f["aux_models_excluded"] = sorted(set(res.get("modelUsage") or {}) - {model})
    am = str(d.get("agentModel") or "")
    ev.f["effort"], ev.f["effort_source"] = (am.split(":", 1)[1], "session.agentModel (raw trace has no effort)") if ":" in am else ("unrecorded", "none")
    ok = attributed.get("status") == "completed" and res.get("subtype") == "success" and not res.get("is_error")
    ev.f["provider_terminal"] = "completed" if ok else f"{attributed.get('status')}/{res.get('subtype')}/is_error={res.get('is_error')}"
    ev.f["provider_final"] = res.get("result") or ""
    ev.f["turns"] = res.get("num_turns", 0)
    # Tool uses: every assistant tool_use in this turn's scope; subagent (parent_tool_use_id) traffic is a violation.
    direct = cm = total = admin = 0
    for p in stream:
        if p.get("type") != "assistant": continue
        for c in (p.get("message") or {}).get("content") or []:
            if not isinstance(c, dict) or c.get("type") != "tool_use": continue
            total += 1; name = str(c.get("name", ""))
            if p.get("parent_tool_use_id"): ev.violations.append(f"subagent:{name}"); continue
            if name == CLAUDE_RP_PREFIX + ADMIN_TOOL: admin += 1; continue
            if not name.startswith(CLAUDE_RP_PREFIX) or _tool_leaf(name) not in ALLOWED_TOOLS: ev.violations.append(name); continue
            direct += 1; cm += _tool_leaf(name) == "code_mode"
    _admin(admin, ev)
    ev.f.update(tool_calls=total, rp_direct_calls=direct, cm_calls=cm, cm_direct_calls=cm, exec_calls=0, exec_nested_calls=0)
    # Usage: the app's persisted turn must equal the raw primary terminal usage; cache writes need the TTL breakdown.
    ru = res.get("usage") or {}; cc = ru.get("cache_creation") or {}
    pairs = (("inputTokens", "input_tokens"), ("cacheCreationInputTokens", "cache_creation_input_tokens"),
             ("cacheReadInputTokens", "cache_read_input_tokens"), ("outputTokens", "output_tokens"))
    if u.get("coverage") != "complete" or u.get("outcome") != "completed":
        ev.usage_problems.append(f"usage turn coverage={u.get('coverage')} outcome={u.get('outcome')}")
    for a, b in pairs:
        if u.get(a) is None or ru.get(b) is None: ev.usage_problems.append(f"missing {a}/{b}")
        elif u[a] != ru[b]: ev.usage_problems.append(f"{a}={u[a]} != raw {b}={ru[b]}")
    w5, w1 = cc.get("ephemeral_5m_input_tokens"), cc.get("ephemeral_1h_input_tokens")
    if w5 is None or w1 is None or w5 + w1 != ru.get("cache_creation_input_tokens"):
        ev.usage_problems.append("cache write TTL breakdown missing or does not sum to cache_creation_input_tokens")
    if not ev.usage_problems:   # Claude input_tokens already excludes cache reads and writes: nothing is subtracted.
        ev.f["tokens"] = {"unc": ru["input_tokens"], "cw5m": w5, "cw1h": w1, "cw": 0, "cr": ru["cache_read_input_tokens"],
                          "out": ru["output_tokens"]}


def _codex_part(d, turn_index, ev):
    thread, path = d.get("codexConversationID"), d.get("codexRolloutPath")
    if not thread or not path: ev.pending.append("codexConversationID/codexRolloutPath not persisted"); return
    if not os.path.exists(path): ev.pending.append("rollout file missing"); return
    order, turn, meta = [], None, None
    per = {}   # turn_id -> scoped evidence
    def T(tid): return per.setdefault(tid, {"calls": [], "items": [], "records": [], "ctx": None, "end": None, "final": None})
    for e in _jsonl(path):
        p = e.get("payload") if isinstance(e.get("payload"), dict) else {}
        typ, pt = e.get("type"), p.get("type")
        if typ == "session_meta": meta = p
        elif typ == "turn_context": T(p.get("turn_id"))["ctx"] = p
        elif typ == "token_usage_record":
            if p.get("thread_id") != thread: ev.errors.append("token_usage_record from another thread")
            T(p.get("turn_id"))["records"].append(p)
        elif pt == "task_started":
            turn = p.get("turn_id"); order.append(turn); T(turn)
        elif pt in ("task_complete", "turn_aborted"):
            x = T(p.get("turn_id") or turn); x["end"] = pt; x["final"] = p.get("last_agent_message")
        elif pt == "item_completed": T(p.get("turn_id"))["items"].append(p.get("item") or {})
        elif typ == "response_item" and pt in ("function_call", "custom_tool_call") and turn: T(turn)["calls"].append(p)
    if not meta or meta.get("id") != thread: ev.errors.append("rollout session_meta id != codexConversationID"); return
    ev.f["cli_version"] = meta.get("cli_version")
    if turn_index is None:
        if len(order) != 1: (ev.pending if not order else ev.errors).append(f"rollout has {len(order)} turns, expected 1"); return
        tid = order[0]
    else:
        if turn_index >= len(order): ev.errors.append("turn index out of rollout range"); return
        tid = order[turn_index]
    x = per[tid]; ev.f["usage_turn_id"] = tid
    if x["end"] is None: ev.pending.append("rollout turn has no task_complete/turn_aborted"); return
    ev.f["provider_terminal"] = "completed" if x["end"] == "task_complete" else x["end"]
    ev.f["provider_final"] = x["final"] or ""
    ctx = x["ctx"] or {}
    ev.f["model"], ev.f["effort"], ev.f["effort_source"] = ctx.get("model"), ctx.get("effort"), "rollout turn_context"
    ev.f["turns"] = len(x["records"])   # model requests in the turn
    # Tool calls: top-level calls of this turn; exec is a container whose nested dispatches arrive as McpToolCall items "exec-*".
    direct = cm = execs = admin = 0
    for c in x["calls"]:
        name, ns = c.get("name"), c.get("namespace")
        if c.get("type") == "function_call" and ns in CODEX_RP_NAMESPACES and name == ADMIN_TOOL: admin += 1
        elif c.get("type") == "function_call" and ns in CODEX_RP_NAMESPACES and name in ALLOWED_TOOLS:
            direct += 1; cm += name == "code_mode"
        elif c.get("type") == "custom_tool_call" and name == CODEX_EXEC_TOOL: execs += 1
        else: ev.violations.append(f"{ns + '.' if ns else ''}{name}")
    nested = 0
    for it in x["items"]:
        ty = it.get("type")
        if ty not in CODEX_OK_ITEMS: ev.violations.append(f"item:{ty}"); continue
        if ty != "McpToolCall": continue
        exec_child = str(it.get("id", "")).startswith("exec-")
        nested += exec_child
        if it.get("server") in CODEX_RP_SERVERS and it.get("tool") == ADMIN_TOOL:
            admin += exec_child; continue   # a direct call's completion item was already counted from the call itself
        if it.get("server") not in CODEX_RP_SERVERS or it.get("tool") not in ALLOWED_TOOLS:
            ev.violations.append(f"{'exec>' if exec_child else ''}{it.get('server')}.{it.get('tool')}")
        elif exec_child and it.get("tool") == "code_mode":
            # Real code_mode use, but through Codex's exec container: the plan requires the directly exposed executor, never nesting.
            cm += 1; ev.violations.append(f"exec>{it.get('server')}.code_mode (nested code_mode route)")
    if nested and not execs: ev.errors.append("exec-dispatched McpToolCall items without an exec call in the turn")
    _admin(admin, ev)
    # Codex traces list no advertised tools. Direct-namespace use shows the Direct companion was in use, not that code_mode was
    # advertised, so only an observed code_mode call proves the treatment; its absence proves nothing.
    ev.f["cm_advertised"] = True if cm else None
    ev.f["treatment_evidence"] = "codex code_mode call observed" if cm else "none (Codex traces do not list advertised tools)"
    ev.f["rp_servers_used"] = sorted({it.get("server") for it in x["items"] if it.get("type") == "McpToolCall"} - {None})
    # The Direct companion exists only under the direct code_mode setting, so its use contradicts a baseline arm.
    ev.f["direct_companion_used"] = ("RepoPromptCE-Direct" in ev.f["rp_servers_used"] or
                                     any(c.get("namespace") == "mcp__RepoPromptCE_Direct" for c in x["calls"]))
    ev.f.update(tool_calls=len(x["calls"]), rp_direct_calls=direct, cm_calls=cm, exec_calls=execs, exec_nested_calls=nested,
                cm_direct_calls=sum(1 for c in x["calls"] if c.get("namespace") in CODEX_RP_NAMESPACES and c.get("name") == "code_mode"))
    # Usage: exactly one measured interval for this thread/turn, equal to the rollout's last per-turn total. Intervals are
    # selected by turn first, so one for this turn without this session's thread (e.g. threadID null) is never dropped.
    pu = d.get("providerUsage") or {}
    ivs = pu.get("codexIntervals") or []
    if turn_index is None and any(i.get("turnID") != tid for i in ivs): ev.errors.append("providerUsage has intervals for other turns")
    foreign = [i for i in ivs if i.get("turnID") == tid and i.get("threadID") != thread]
    if foreign: ev.usage_problems.append(f"{len(foreign)} interval(s) for this turn without this thread "
                                        f"(threadID {sorted({str(i.get('threadID')) for i in foreign})}); coverage unprovable")
    mine = [i for i in ivs if i.get("turnID") == tid and i.get("threadID") == thread]
    measured = [i for i in mine if i.get("inputTokens") is not None]
    if not measured:
        # An aborted turn never gets a measured interval: that is a recorded, unusable attempt, not something to wait for.
        (ev.usage_problems if x["end"] == "turn_aborted" else ev.pending).append("no measured usage interval for the turn")
        return
    if len(measured) > 1 or (turn_index is None and len(mine) != 1):
        ev.usage_problems.append(f"{len(mine)} usage intervals ({len(measured)} measured) for the turn"); return
    if len(mine) > 1: ev.warnings.append(f"{len(mine) - 1} unmeasured interval(s) for the same turn ignored (qualification)")
    i = measured[0]; ev.f["execution_id"] = i.get("executionID")
    if i.get("coverage") != "complete": ev.usage_problems.append(f"interval coverage={i.get('coverage')}")
    if i.get("resolvedModelID") and i.get("resolvedModelID") != ev.f["model"]: ev.warnings.append("interval model != turn_context model")
    rec = (x["records"][-1].get("turn_token_usage") if x["records"] else None) or {}
    for a, b in (("inputTokens", "input_tokens"), ("cachedInputTokens", "cached_input_tokens"),
                 ("cacheWriteInputTokens", "cache_write_input_tokens"), ("outputTokens", "output_tokens")):
        if i.get(a) is None or rec.get(b) is None: ev.usage_problems.append(f"missing {a}/{b}")
        elif i[a] != rec[b]: ev.usage_problems.append(f"{a}={i[a]} != rollout {b}={rec[b]}")
    if i.get("cacheWriteInputTokens"):
        ev.usage_problems.append("nonzero Codex cache writes: whether input_tokens includes them is unverified")
    if not ev.usage_problems:   # Codex input_tokens INCLUDES cached tokens: subtract them once.
        ev.f["tokens"] = {"unc": i["inputTokens"] - i["cachedInputTokens"], "cw5m": 0, "cw1h": 0, "cw": 0,
                          "cr": i["cachedInputTokens"], "out": i["outputTokens"]}
        ev.f["tok_reasoning"] = i.get("reasoningOutputTokens")


def _admin_card_violations(cards, names):
    """set_status as a code_mode script child is never the startup route; more than one status card is a repeat."""
    admin = [c for c, n in zip(cards, names) if n == ADMIN_TOOL]
    bad = {f"{ADMIN_TOOL} (code_mode child)" for c in admin if c.get("codeModeParentInvocationID")}
    return bad | ({f"{ADMIN_TOOL} (repeated)"} if len(admin) > 1 else set())


def _admin(n, ev):
    """One startup set_status is the host contract; every further call is a violation. Raw tool_calls still count all of them."""
    ev.f["admin_calls"] = n
    ev.violations += [f"{ADMIN_TOOL} repeated (only one startup call allowed)"] * max(0, n - 1)


def collect_once(path, session_id, turn_index, raw_dir):
    ev = Ev()
    if not os.path.exists(path): ev.pending.append("session file missing"); return ev
    try:
        with open(path) as fh: d = json.load(fh)
    except (OSError, json.JSONDecodeError) as e: ev.pending.append(f"session file unreadable: {e}"); return ev
    kind = d.get("agentKind"); host = {"claudeCode": "claude", "codexExec": "codex"}.get(kind)
    ev.f["host"] = host
    if not host: ev.errors.append(f"unsupported agentKind {kind!r}"); return ev
    t = _session_part(d, session_id, turn_index, ev)
    if t is None or ev.errors: return ev
    if host == "claude": _claude_part(d, t, turn_index, raw_dir, ev)
    else: _codex_part(d, turn_index, ev)
    return ev


def collect(sessions_dir, session_id, *, arm, task, rep, wall_s, status, turn_index=None, raw_dir=CLAUDE_RAW_DIR,
            wait_s=20.0, poll_s=1.0, do_grade=True) -> dict:
    """One analyze.py row for a session main started. Bounded wait on this exact session file only: missing data and
    usage that does not yet match the terminal trace are re-read until `wait_s` expires; identity errors stop at once."""
    if arm not in ARMS: raise ValueError(f"unknown arm {arm!r}")
    if task not in TASKS: raise ValueError(f"unknown task {task!r}")
    path = os.path.join(os.path.expanduser(sessions_dir), f"AgentSession-{session_id.upper()}.json")
    deadline = time.monotonic() + wait_s; reads = 0
    while True:
        ev = collect_once(path, session_id, turn_index, raw_dir); reads += 1
        if ev.errors or not (ev.pending or ev.usage_problems) or time.monotonic() >= deadline: break
        time.sleep(poll_s)
    f = ev.f; tok = f.get("tokens")
    if status not in STATUSES: raise ValueError(f"unknown status {status!r} (choices: {', '.join(STATUSES)})")
    if f.get("host") and f["host"] != ARMS[arm]: ev.errors.append(f"arm {arm} is a {ARMS[arm]} arm but the session is {f['host']}")
    # Treatment: trace evidence must not contradict the arm; missing evidence leaves it unverified (weigh withholds wtok).
    adv, want = f.get("cm_advertised"), arm.endswith("_cm")
    if adv is not None and adv != want:
        ev.errors.append(f"treatment mismatch: arm {arm} but code_mode {'offered' if adv else 'not offered'} ({f.get('treatment_evidence')})")
    if f.get("direct_companion_used") and not want:
        ev.errors.append(f"treatment mismatch: arm {arm} but the RepoPromptCE-Direct companion (direct code_mode setting) was used")
    treatment = "verified" if adv is not None and adv == want else "unverified"
    # Task label and fixture: a fresh row must carry the prepared prompt (provenance text may surround it) for a clean fixture.
    if f.get("transcript_turn_id") and turn_index is None:
        if not C.REPO: ev.errors.append("CMLAB_REPO unset: the task prompt and fixture cannot be verified")
        elif worker_prompt(task, str(C.REPO)) not in f.get("request_text", ""):
            ev.errors.append(f"session request does not contain the prepared {task} prompt for {C.REPO}")
    if C.REPO: ev.errors += [f"fixture: {p}" for p in check_fixture(C.REPO)]
    terminal_ok = (status == "completed" and f.get("turn_terminal") == "completed" and f.get("provider_terminal") == "completed"
                   and (turn_index is not None or f.get("session_state") == "completed"))
    rc = 2 if ev.errors else 3 if ev.pending else 0 if terminal_ok else 1
    final = f.get("provider_final", "")
    if final and f.get("transcript_final") is not None and final.strip() != f["transcript_final"].strip():
        ev.warnings.append("provider final answer differs from the transcript conclusion (graded the provider answer)")
    g = {"correct": False, "score": 0.0, "parse": None}
    graded = rc == 0 and do_grade
    if graded: g = grade(task, final)
    violations = ev.violations + [f"card:{n}" for n in f.get("card_violation_tools", [])]
    row = {"arm": arm, "host": ARMS[arm], "task": task, "kind": TASKS[task]["kind"], "rep": rep, "rc": rc, "wall_s": wall_s,
           "main_status": status, "session_state": f.get("session_state"), "turn_terminal": f.get("turn_terminal"),
           "provider_terminal": f.get("provider_terminal"), **{k: v for k, v in g.items()},
           "answer_correct": g["correct"] if graded else None, "graded": graded, "correct": bool(g["correct"]) and rc == 0,
           "final_chars": len(final), "usage_complete": tok is not None,
           **{f"tok_{k}": (tok or {}).get(k) for k in TOKEN_KEYS}, "tok_reasoning": f.get("tok_reasoning"),
           "tok_input_total": sum(tok[k] for k in ("unc", "cw5m", "cw1h", "cw", "cr")) if tok else None,
           # wtok 0 is analyze.py's "unusable" marker until `weigh` applies declared weights; raw token fields stay None when unmeasured.
           "wtok": 0, "wtok_label": None,
           "turns": f.get("turns", 0), "tool_calls": f.get("tool_calls", 0), "rp_direct_calls": f.get("rp_direct_calls", 0),
           "cm_calls": f.get("cm_calls", 0), "cm_direct_calls": f.get("cm_direct_calls", 0), "exec_calls": f.get("exec_calls", 0), "exec_nested_calls": f.get("exec_nested_calls", 0),
           "admin_calls": f.get("admin_calls", 0),
           "transcript_tool_cards": f.get("transcript_tool_cards", 0), "cm_child_cards": f.get("cm_child_cards", 0),
           "tool_errors": f.get("tool_errors", 0), "shell_calls": len(violations), "violation_tools": sorted(set(violations)),
           # Not measured in-app (no proxy): None, never a claimed 0. App-side tool failures appear only in tool_errors.
           "upstream_errors": None, "treatment": treatment, "treatment_evidence": f.get("treatment_evidence"),
           "cm_advertised": adv, "rp_servers_used": f.get("rp_servers_used"), "model": f.get("model"), "effort": f.get("effort"), "effort_source": f.get("effort_source"),
           "cli_version": f.get("cli_version"), "aux_models_excluded": f.get("aux_models_excluded"),
           "usage_contract": f.get("usage_contract"), "truth_commit": C.TRUTH_COMMIT[:8], "session_id": session_id.upper(),
           "transcript_turn_id": f.get("transcript_turn_id"), "usage_turn_id": f.get("usage_turn_id"), "execution_id": f.get("execution_id"),
           "has_unmeasured_history": f.get("has_unmeasured_history"), "qualification_only": turn_index is not None,
           "collect_errors": ev.errors + [f"timed out waiting: {p}" for p in ev.pending], "usage_problems": ev.usage_problems,
           "warnings": ev.warnings, "collect_reads": reads}
    return row


# ---------------------------------------------------------------- weigh

def parse_weights(spec: str) -> dict:
    w = {}
    for part in filter(None, spec.split(",")):
        k, _, v = part.partition("=")
        if k not in TOKEN_KEYS: raise ValueError(f"unknown weight {k!r} (keys: {', '.join(TOKEN_KEYS)})")
        w[k] = float(v)
    missing = [k for k in ("unc", "cr", "out") if k not in w]
    if missing: raise ValueError(f"weights must declare {', '.join(missing)}")
    return w


def weigh(rows: list[dict], weights: dict, label: str, allow_unverified_treatment: bool = False) -> list[dict]:
    """Price-weighted tokens from declared weights only. A nonzero token class without a declared weight is refused, and so
    is model, effort or CLI-version drift within a host. Rows without complete usage keep wtok 0 (unusable for analyze.py),
    never a computed zero; so do rows whose treatment is unverified unless main explicitly allows them (recorded per row)."""
    seen = {}
    for r in rows:
        if r.get("model"): seen.setdefault(r.get("host"), set()).add((r.get("model"), r.get("effort"), r.get("cli_version")))
    drift = {h: sorted(s, key=str) for h, s in seen.items() if len(s) > 1}
    if drift: raise ValueError(f"model/effort/CLI version drift within a host: {drift}")
    out = []
    for r in rows:
        r = dict(r)
        # Main's settings attestation covers Codex only; Claude treatment is always provable from init.tools.
        allowed = allow_unverified_treatment and r.get("host") == "codex" and r.get("treatment") != "verified"
        withheld = r.get("usage_complete") and r.get("treatment") != "verified" and not allowed
        if withheld: r["wtok_withheld"] = "treatment unverified"
        elif r.get("usage_complete"):
            used = {k: r.get(f"tok_{k}") or 0 for k in TOKEN_KEYS}
            undeclared = [k for k, v in used.items() if v and k not in weights]
            if undeclared: raise ValueError(f"{r['arm']} {r['task']} r{r['rep']}: tokens in {undeclared} but no weight declared")
            r["wtok"] = round(sum(weights.get(k, 0.0) * v for k, v in used.items()))
        r["wtok_label"], r["wtok_weights"] = label, weights
        r["wtok_unverified_treatment_allowed"] = allowed
        out.append(r)
    return out


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0]); sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("prepare"); p.add_argument("--tasks", default=",".join(TASKS)); p.add_argument("--out")
    c = sub.add_parser("collect")
    c.add_argument("--sessions-dir", required=True); c.add_argument("--session-id", required=True)
    c.add_argument("--arm", required=True, choices=sorted(ARMS)); c.add_argument("--task", required=True, choices=sorted(TASKS))
    c.add_argument("--rep", type=int, required=True); c.add_argument("--wall-s", type=float, required=True)
    c.add_argument("--status", required=True, choices=STATUSES, help="terminal status main observed for the agent run")
    c.add_argument("--turn-index", type=int, help="qualification only: select one turn of a multi-turn session")
    c.add_argument("--claude-raw-dir", default=CLAUDE_RAW_DIR); c.add_argument("--wait-s", type=float, default=20.0)
    c.add_argument("--no-grade", action="store_true", help="inspection only: skip grading (cannot be combined with --out)")
    c.add_argument("--out", help="append rc 0/1 rows to this JSONL file; rc 2/3 rows go to <out>.inspect.jsonl")
    w = sub.add_parser("weigh"); w.add_argument("rows"); w.add_argument("--weights", required=True)
    w.add_argument("--label", required=True); w.add_argument("--out", required=True)
    w.add_argument("--allow-unverified-treatment", action="store_true",
                   help="weight rows whose arm treatment the trace cannot prove (recorded in every row)")
    a = ap.parse_args(argv)
    if a.cmd == "prepare":
        rows = prepare(a.tasks.split(","), C.REPO)
        text = "".join(json.dumps(r) + "\n" for r in rows)
        if a.out:
            with open(a.out, "w") as fh: fh.write(text)
        else: sys.stdout.write(text)
    elif a.cmd == "collect":
        # Exit code = row rc (0 recorded, 1 recorded attempt failure, 2/3 inspection only); 4 = refused duplicate.
        if a.no_grade and a.out: ap.error("--no-grade is inspection-only and cannot be combined with --out")
        if a.out and os.path.exists(a.out):
            with open(a.out) as fh: seen = [json.loads(l) for l in fh if l.strip()]
            if any(r.get("session_id") == a.session_id.upper() or (r.get("arm"), r.get("task"), r.get("rep")) == (a.arm, a.task, a.rep)
                   for r in seen):
                print(f"{a.out} already has a row for session {a.session_id} or ({a.arm}, {a.task}, {a.rep}); nothing written",
                      file=sys.stderr)
                sys.exit(4)
        row = collect(a.sessions_dir, a.session_id, arm=a.arm, task=a.task, rep=a.rep, wall_s=a.wall_s, status=a.status,
                      turn_index=a.turn_index, raw_dir=a.claude_raw_dir, wait_s=a.wait_s, do_grade=not a.no_grade)
        print(json.dumps(row))
        if a.out:
            target = a.out if row["rc"] in RECORDED_RCS else a.out + ".inspect.jsonl"
            with open(target, "a") as fh: fh.write(json.dumps(row) + "\n")
        sys.exit(row["rc"])
    else:
        with open(a.rows) as fh: rows = [json.loads(l) for l in fh if l.strip()]
        if os.path.exists(a.out): raise SystemExit(f"{a.out} exists; choose a new file (inputs are never overwritten)")
        out = weigh(rows, parse_weights(a.weights), a.label, a.allow_unverified_treatment)
        with open(a.out, "w") as fh: fh.writelines(json.dumps(r) + "\n" for r in out)


if __name__ == "__main__":
    main()
