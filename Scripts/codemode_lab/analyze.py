#!/usr/bin/env python3
"""Summarize single-turn lab results (runner.py rows) and print the plan §7 gate view.

Usage: analyze.py results.jsonl [...] [--pairs cc_cm2:cc_text,cx_dons_rpcm2:cx_text_rp] [--boot 2000]
Correctness counts every attempted row (a run with a nonzero exit is an incorrect answer). Costs use usable rows only (exit 0, usage
reported, no RepoPrompt upstream error). The verdict is PASS only when every task and every kind has usable rows in both
arms and no attempted row is unusable; otherwise FAIL (a gate criterion is broken) or INCOMPLETE (evidence is missing).
Metric: wtok = uncached x1 + cache write x1.25 + cache read x0.1 + output x5. Ratio = geometric mean over tasks of
per-task medians (arm / baseline); the interval resamples repetitions within each task (seed 7).
Multi-turn session rows are not supported by this harness and are refused, as are inputs that mix recorded models, effort
or truth commits within an arm (or truth commits across arms).
"""
import argparse, collections, json, math, os, random, statistics as st, sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import lab_config as C
from tasks import TASKS

KINDS = ("single", "multi", "heavy")
COST_BOUND = 1.10   # §7.2: at most 10% above baseline in each kind
MIN_REPS = 5        # §7.4
REQUIRED = ("arm", "host", "task", "kind", "rep", "rc", "wtok", "correct")
FAULT_SUFFIXES = ("_f1", "_f2")


class BadInput(ValueError):
    pass


def gm(x): return math.exp(sum(map(math.log, x)) / len(x))
def med(x): return st.median(x) if x else float("nan")
SETTINGS = ("model", "effort", "truth_commit")


def correct(r): return bool(r["correct"]) and r["rc"] == 0
def majority(rows): return sum(map(correct, rows)) * 2 > len(rows)


def check_rows(rows, where="input"):
    """Refuse rows this analyzer cannot judge: missing fields, unknown kinds, or multi-turn session rows."""
    for i, r in enumerate(rows, 1):
        missing = [k for k in REQUIRED if k not in r]
        if missing: raise BadInput(f"{where} row {i}: missing {', '.join(missing)}")
        if r.get("seq", r["task"]) != r["task"] or r.get("turn", 0) != 0:
            raise BadInput(f"{where} row {i}: multi-turn session row (seq={r.get('seq')!r}, turn={r.get('turn')!r}); "
                           "session runs are not supported by this harness")
        if r["kind"] not in KINDS: raise BadInput(f"{where} row {i}: unknown kind {r['kind']!r}")
        if r.get("qualification_only"):
            raise BadInput(f"{where} row {i}: qualification-only row (live_ab.py collect --turn-index); not a fresh gate sample")
        if r.get("graded") is False and r["rc"] == 0:
            raise BadInput(f"{where} row {i}: completed run was never graded (live_ab.py collect --no-grade is inspection-only)")
        if r["task"] in TASKS and TASKS[r["task"]]["kind"] != r["kind"]:
            raise BadInput(f"{where} row {i}: task {r['task']} has kind {r['kind']!r}, expected {TASKS[r['task']]['kind']!r}")


def check_settings(rows):
    """Refuse pooled conditions: one recorded (model, effort, truth_commit) per arm and one truth commit overall.
    Returns the arms whose rows record none of them (historical rows), for a warning."""
    per_arm = collections.defaultdict(set)
    for r in rows: per_arm[r["arm"]].add(tuple(r.get(k) for k in SETTINGS))
    for arm, s in sorted(per_arm.items()):
        if len(s) > 1: raise BadInput(f"arm {arm} mixes recorded settings (model, effort, truth_commit): {sorted(s, key=str)}")
    truths = {r.get("truth_commit") for r in rows}
    if len(truths) > 1: raise BadInput(f"inputs mix truth commits: {sorted(truths, key=str)}")
    return sorted(a for a, s in per_arm.items() if s == {(None, None, None)})


def group(rows, usable_only):
    by = collections.defaultdict(list)
    for r in rows:
        if not usable_only or C.row_is_usable(r): by[(r["arm"], r["task"])].append(r)
    return by


def ratio_ci(by, a, b, tasks, n=2000, seed=7):
    ts = [t for t in tasks if by.get((a, t)) and by.get((b, t))]
    if not ts: return None
    va = {t: [r["wtok"] for r in by[(a, t)]] for t in ts}; vb = {t: [r["wtok"] for r in by[(b, t)]] for t in ts}
    pt = gm([med(va[t]) / med(vb[t]) for t in ts])
    rnd = random.Random(seed)
    bs = sorted(gm([med(rnd.choices(va[t], k=len(va[t]))) / med(rnd.choices(vb[t], k=len(vb[t]))) for t in ts]) for _ in range(n))
    return pt, bs[int(0.025 * n)], bs[int(0.975 * n) - 1], len(ts)


def fmt(res): return f"×{res[0]:.2f} [{res[1]:.2f}–{res[2]:.2f}]" if res else "—"


def gate(rows, a, b, n=2000):
    """Plan §7 for arm `a` against baseline `b`. Verdict PASS / FAIL / INCOMPLETE, marked exploratory below MIN_REPS.
    Not measurable here (app executor properties): honored routing overrides and selection changes by nested calls."""
    check_rows(rows); check_settings(rows)
    rows = [r for r in rows if r["arm"] in (a, b)]
    attempted, usable = group(rows, False), group(rows, True)
    kind = {r["task"]: r["kind"] for r in rows}
    all_tasks = sorted(kind)
    tasks = [t for t in all_tasks if usable.get((a, t)) and usable.get((b, t))]
    per_kind = {k: ratio_ci(usable, a, b, [t for t in tasks if kind[t] == k], n) for k in KINDS}
    lost = [t for t in all_tasks if attempted.get((a, t)) and attempted.get((b, t))
            and majority(attempted[(b, t)]) and not majority(attempted[(a, t)])]
    # A violation in either arm fails the comparison: a contaminated baseline is not a valid reference.
    violations = sum(1 for r in rows if r.get("shell_calls", 0) > 0)
    baseline_violations = sum(1 for r in rows if r["arm"] == b and r.get("shell_calls", 0) > 0)
    violation_tools = sorted({t for r in rows for t in r.get("violation_tools") or []})
    unusable = sum(1 for r in rows if not C.row_is_usable(r))
    reps = min((len(usable[(x, t)]) for t in all_tasks for x in (a, b)), default=0)
    worst = max((v[0] for v in per_kind.values() if v), default=float("nan"))
    fail, missing = [], []
    if worst > COST_BOUND: fail.append(f"cost above ×{COST_BOUND:.2f}")
    if lost: fail.append("lost majority-correct task")
    if violations: fail.append("violations")
    for x in (a, b):
        if not any(r["arm"] == x for r in rows): missing.append(f"no rows for {x}")
    no_usable = [f"{x}/{t}" for t in all_tasks for x in (a, b) if not usable.get((x, t))]
    if no_usable: missing.append("no usable rows for " + ", ".join(no_usable))
    no_kind = [k for k in KINDS if not per_kind[k]]
    if no_kind: missing.append("no comparable tasks of kind " + ", ".join(no_kind))
    if unusable: missing.append(f"{unusable} unusable rows (prune and re-run, README Recovery)")
    verdict = "FAIL" if fail else "INCOMPLETE" if missing else "PASS"
    return {"pair": (a, b), "per_kind": per_kind, "all": ratio_ci(usable, a, b, tasks, n), "lost_majority": lost,
            "violations": violations, "baseline_violations": baseline_violations, "violation_tools": violation_tools, "unusable_rows": unusable, "min_reps": reps, "tasks": len(tasks), "reasons": fail + missing,
            "verdict": verdict + ("" if reps >= MIN_REPS else f" (exploratory: {reps} reps < {MIN_REPS})")}


def direct_calls(R):
    v = [r["rp_direct_calls"] for r in R if "rp_direct_calls" in r]
    return f"{med(v):.0f}" if v else "—"


def print_arm_table(rows):
    print("| Arm | Runs | Usable | Correct | Median wtok (usable) | Median model turns | Median tool calls | Median direct `mcp__rp` calls | "
          "Median wall s | Runs using `code_mode` | Violations |")
    print("|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|")
    warn = []
    for a in sorted({r["arm"] for r in rows}):
        R = [r for r in rows if r["arm"] == a]; U = [r for r in R if C.row_is_usable(r)]
        print(f"| `{a}` | {len(R)} | {len(U)} | {sum(map(correct, R))}/{len(R)} | {med([r['wtok'] for r in U]):,.0f} | "
              f"{med([r.get('turns', 0) for r in R]):.0f} | {med([r.get('tool_calls', 0) for r in R]):.0f} | {direct_calls(R)} | "
              f"{med([r.get('wall_s', 0) for r in R]):.1f} | {sum(1 for r in R if r.get('cm_calls'))}/{len(R)} | "
              f"{sum(1 for r in R if r.get('shell_calls', 0) > 0)} |")
        if a.startswith("cx_dons"):
            none = sum(1 for r in R if not r.get("rp_direct_calls"))
            if none: warn.append(f"`{a}`: {none}/{len(R)} runs have no recorded direct `mcp__rp` call in the Codex rollout "
                                 "(field absent or 0); direct-namespace routing is unproven for them.")
    print()
    for w in warn: print(f"WARNING: {w}\n")


def print_gate(g):
    a, b = g["pair"]
    print(f"**`{a}` vs `{b}` — {g['verdict']}** ({g['tasks']} comparable tasks, min {g['min_reps']} usable reps per arm and task)\n")
    print("| Kind | Ratio [95% CI] | Bound |\n|---|---|---|")
    for k in KINDS: print(f"| {k} | {fmt(g['per_kind'][k])} | ≤ ×{COST_BOUND:.2f} |")
    print(f"| all | {fmt(g['all'])} | reported |\n")
    tools = f" ({', '.join(g['violation_tools'])})" if g["violation_tools"] else ""
    print(f"Majority-correct lost (all attempts): {', '.join(g['lost_majority']) or 'none'}. Violations (both arms): {g['violations']}, baseline {g['baseline_violations']}{tools}. "
          f"Unusable rows: {g['unusable_rows']}. A claimed saving shows only where the interval is below 1 (§7.3).\n")
    if g["reasons"]: print("Reasons: " + "; ".join(g["reasons"]) + ".\n")


def baseline_for(arm, host):
    base = {"claude": "cc_text", "codex": "cx_text_rp"}.get(host)
    if not base: return None
    suffix = next((s for s in FAULT_SUFFIXES if arm.endswith(s)), "")
    return base + suffix


def default_pairs(rows):
    """Each arm against its host's baseline under the same fault profile (cc_cm2_f1 -> cc_text_f1)."""
    host = {r["arm"]: r["host"] for r in rows}
    pairs = []
    for a, h in sorted(host.items()):
        b = baseline_for(a, h)
        if b and a != b and b in host: pairs.append((a, b))
    return pairs


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("files", nargs="+"); ap.add_argument("--pairs", default="")
    ap.add_argument("--boot", type=int, default=2000, help="bootstrap resamples for task ratios (default matches the 2026-10 ledger)")
    a = ap.parse_args()
    rows = []
    for f in a.files:
        with open(f) as fh: part = [json.loads(l) for l in fh if l.strip()]
        try: check_rows(part, f)
        except BadInput as e: sys.exit(f"analyze.py: {e}")
        rows += part
    try: unrecorded = check_settings(rows)
    except BadInput as e: sys.exit(f"analyze.py: {e}")
    if unrecorded:
        print(f"WARNING: no recorded model, effort or truth commit for {', '.join(unrecorded)} (rows predate these fields); "
              "make sure each file comes from one configuration.\n")
    pairs = [tuple(p.split(":")) for p in a.pairs.split(",") if p] or default_pairs(rows)
    print(f"## Single-turn runs ({len(rows)} rows)\n"); print_arm_table(rows)
    for p in pairs:
        if any(r["arm"] == p[0] for r in rows): print_gate(gate(rows, *p, n=a.boot))


if __name__ == "__main__":
    main()
