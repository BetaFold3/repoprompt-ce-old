#!/usr/bin/env python3
"""Offline tests for the code-mode lab harness. No host CLI, model, credentials or running app is used.

Fixture rows and fake upstream replies stand in for live data; nothing here is a measurement.
The proxy tests run rp_proxy.py as a real subprocess against a fake MCP upstream; the code_mode tests also need a
QuickJS-ng host (CMLAB_TEST_QJS_HOST, else a Homebrew test build) and skip with the reason when none is available.
Run: python3 -m unittest discover -s Scripts/codemode_lab -p 'test_*.py'
"""
from __future__ import annotations

import json
import os
import queue
import shutil
import subprocess
import sys
import tempfile
import textwrap
import threading
import time
import unittest
from functools import lru_cache
from pathlib import Path
from unittest import mock

LAB = Path(__file__).resolve().parent
sys.path.insert(0, str(LAB))

import analyze  # noqa: E402
import lab_config as C  # noqa: E402
import runner  # noqa: E402
import edit_grade  # noqa: E402
import tasks  # noqa: E402
from edit_grade import grade_edit  # noqa: E402


def has_truth_commit() -> bool:
    return subprocess.run(["git", "-C", str(C.git_dir()), "cat-file", "-e", f"{C.TRUTH_COMMIT}^{{commit}}"],
                          capture_output=True).returncode == 0


def answer(obj) -> str:
    return "Done.\n```json\n" + json.dumps(obj) + "\n```"


# Applies strictly to E3's humanizer at the truth commit (a comment line; not a semantic answer).
E3_APPLYING_DIFF = ("--- a/Sources/RepoPrompt/Infrastructure/VCS/GitWorktreeDisplayLabelHumanizer.swift\n"
                    "+++ b/Sources/RepoPrompt/Infrastructure/VCS/GitWorktreeDisplayLabelHumanizer.swift\n"
                    "@@ -1,3 +1,4 @@\n import Foundation\n+// lab\n \n enum GitWorktreeDisplayLabelHumanizer {\n")


class GradingTests(unittest.TestCase):
    def test_lookup_grader_accepts_truth_and_rejects_one_wrong_value(self):
        truth = {"exclusive": 1, "control": 8, "smallRead": 2, "smallReadPerWindow": 2, "gitRead": 2, "gitReadPerRepository": 1, "fileSearch": 4}
        self.assertTrue(tasks.grade("T1_caps", answer(truth))["correct"])
        g = tasks.grade("T1_caps", answer({**truth, "control": 4}))
        self.assertFalse(g["correct"]); self.assertAlmostEqual(g["score"], 6 / 7, places=3)

    def test_missing_or_invalid_json_block_is_a_parse_failure(self):
        self.assertEqual(tasks.grade("T1_caps", "no block"), {"correct": False, "score": 0.0, "parse": False})
        self.assertFalse(tasks.grade("T1_caps", "```json\n{oops\n```")["parse"])

    def test_line_count_tasks_allow_off_by_one_but_require_exactly_five_entries(self):
        truth = dict(tasks.TASKS["T7_top_lines"]["truth"])
        self.assertTrue(tasks.grade("T7_top_lines", answer({k: v + 1 for k, v in truth.items()}))["correct"])
        self.assertFalse(tasks.grade("T7_top_lines", answer({k: v + 2 for k, v in truth.items()}))["correct"])
        self.assertFalse(tasks.grade("T7_top_lines", answer({**truth, "Extra.swift": 1}))["correct"])

    def test_list_answers_compare_base_names(self):
        paths = ["Sources/X/" + n for n in tasks.TASKS["T3_opencode_env"]["truth"]]
        self.assertTrue(tasks.grade("T3_opencode_env", answer(paths))["correct"])
        self.assertFalse(tasks.grade("T3_opencode_env", answer(paths[:2]))["correct"])

    def test_understand_grader_names_the_failed_check(self):
        truth = json.loads(json.dumps(tasks.TASKS["U2_slice_math"]["truth"]))
        self.assertTrue(tasks.grade("U2_slice_math", answer(truth))["correct"])
        truth["c_total_characters"] = 18
        g = tasks.grade("U2_slice_math", answer(truth))
        self.assertFalse(g["correct"]); self.assertEqual(g["failed_checks"], ["c_total_characters"])

    def test_edit_grader_rejects_missing_diff_and_unintended_files_before_applying(self):
        g = grade_edit("E3_label_cap", "nothing")
        self.assertEqual((g["failed_checks"], g["diff_block_count"]), (["no_diff_block"], 0))
        diff = "```diff\n--- a/README.md\n+++ b/README.md\n@@ -1 +1 @@\n-a\n+b\n```"
        g = grade_edit("E3_label_cap", diff)
        self.assertEqual((g["failed_checks"], g["diff_block_count"]), (["unintended_files:README.md"], 1))

    def test_edit_grader_rejects_more_than_one_diff_block_before_any_fixture_or_git_work(self):
        good = f"```diff\n{E3_APPLYING_DIFF}```"
        corrupt = "```diff\n--- a/x\n+++ b/x\n@@ -1 +1 @@\n-not in any file\n```"
        cases = {"corrupt then applying": [corrupt, good], "applying then corrupt": [good, corrupt],
                 "applying twice": [good, good], "three blocks": [corrupt, corrupt, good]}
        boom = mock.Mock(side_effect=AssertionError("grader touched fixture, git or swiftc"))
        with mock.patch.object(edit_grade, "head", boom), mock.patch.object(edit_grade.subprocess, "run", boom):
            for label, blocks in cases.items():
                g = grade_edit("E3_label_cap", "Answer.\n" + "\nAnd also:\n".join(blocks))
                self.assertEqual(g, {"correct": False, "score": 0.0, "parse": False, "applied": False, "apply_strict": False,
                                     "failed_checks": ["multiple_diff_blocks"], "diff_block_count": len(blocks)}, label)
        boom.assert_not_called()

    @unittest.skipUnless(has_truth_commit(), "truth commit not in local history (shallow clone?)")
    def test_edit_grader_does_not_pass_on_a_last_block_that_would_pass_alone(self):
        # Regression: the grader used the last block, so a passing final block hid earlier extra blocks.
        # Checks are stubbed to pass so "would pass" depends only on strict application at the truth commit.
        spec = {**edit_grade.EDIT_TASKS["E3_label_cap"], "checks": lambda: [("stub", lambda f, tmp: True)]}
        good = f"```diff\n{E3_APPLYING_DIFF}```"
        corrupt = "```diff\n--- a/x\n+++ b/x\n@@ -1 +1 @@\n-not in any file\n```"
        with mock.patch.dict(edit_grade.EDIT_TASKS, {"E3_label_cap": spec}):
            alone = grade_edit("E3_label_cap", good)
            self.assertEqual((alone["correct"], alone["apply_strict"], alone["diff_block_count"]), (True, True, 1))
            g = grade_edit("E3_label_cap", f"{corrupt}\n{good}")
        self.assertEqual((g["correct"], g["applied"], g["failed_checks"], g["diff_block_count"]),
                         (False, False, ["multiple_diff_blocks"], 2))

    @unittest.skipUnless(has_truth_commit(), "truth commit not in local history (shallow clone?)")
    def test_edit_grader_reports_a_diff_that_does_not_apply_at_the_truth_commit(self):
        p = "Sources/RepoPrompt/Infrastructure/VCS/GitWorktreeDisplayLabelHumanizer.swift"
        diff = f"```diff\n--- a/{p}\n+++ b/{p}\n@@ -1,1 +1,1 @@\n-this line is not in the file\n+x\n```"
        g = grade_edit("E3_label_cap", diff)
        self.assertEqual((g["applied"], g["failed_checks"], g["diff_block_count"]), (False, ["apply_failed"], 1))


class TruthPinTests(unittest.TestCase):
    @unittest.skipUnless(has_truth_commit(), "truth commit not in local history (shallow clone?)")
    def test_mechanical_truths_recompute_exactly_at_the_truth_commit(self):
        for tid, got in tasks.mechanical_truths().items():
            truth = tasks.TASKS[tid]["truth"]
            self.assertEqual(got, sorted(truth) if isinstance(truth, list) else truth, tid)

    def test_prompts_name_the_measured_repository(self):
        self.assertIn("/pinned/repo", tasks.prompt("T1_caps", "/pinned/repo"))
        self.assertIn("```diff", tasks.prompt("E1_rename_subtract", "/pinned/repo"))


class RunnerTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(); self.addCleanup(self.tmp.cleanup)
        saved = {k: getattr(C, k) for k in ("REPO", "CLI", "QJS_HOST", "SCRATCH", "CODEX_HOME", "CODEX_DISABLE_SERVERS")}
        self.addCleanup(lambda: [setattr(C, k, v) for k, v in saved.items()])
        t = Path(self.tmp.name)
        C.REPO, C.CLI, C.QJS_HOST, C.SCRATCH, C.CODEX_HOME = t / "repo", t / "cli", t / "host", t / "scratch", t / "codex"
        C.CODEX_DISABLE_SERVERS = ["RepoPromptCE"]

    def test_claude_stream_parse_price_weighting_and_native_tool_violations(self):
        out = "\n".join(json.dumps(x) for x in [
            {"type": "assistant", "message": {"content": [{"type": "tool_use", "name": "mcp__rp__read_file"},
                                                        {"type": "tool_use", "name": "Bash"}, {"type": "text"}]}},
            {"type": "result", "num_turns": 3, "result": "final answer", "total_cost_usd": 0.01,
             "usage": {"input_tokens": 100, "cache_creation_input_tokens": 1000, "cache_read_input_tokens": 10000, "output_tokens": 200}}])
        m = runner.parse("claude", out)
        self.assertEqual((m["tool_calls"], m["turns"], m["in_tokens"], m["out_tokens"], m["final"]), (2, 3, 11100, 200, "final answer"))
        self.assertEqual((m["shell_calls"], m["violation_tools"]), (1, ["Bash"]))  # the native Bash use is a violation; the lab tool is not
        c = runner.comps("claude", out)
        self.assertEqual(runner.wtok(c), round(100 + 1000 * 1.25 + 10000 * 0.1 + 200 * 5))

    def test_runner_marks_a_nonzero_exit_incorrect_but_keeps_the_answer_grade(self):
        truth = tasks.TASKS["T1_caps"]["truth"]
        out = json.dumps({"type": "result", "result": answer(truth), "num_turns": 1,
                          "usage": {"input_tokens": 10, "cache_creation_input_tokens": 0, "cache_read_input_tokens": 0, "output_tokens": 5}})
        done = subprocess.CompletedProcess([], 1, stdout=out, stderr="")
        res = Path(self.tmp.name) / "r.jsonl"
        with mock.patch.object(runner.subprocess, "run", return_value=done), mock.patch("sys.stdout"):
            runner.one(("cc_text", "T1_caps", 0), str(res))
        r = runner.load_rows(str(res))[0]
        self.assertEqual((r["rc"], r["answer_correct"], r["correct"], r["usable"]), (1, True, False, False))

    def test_codex_parse_reads_direct_calls_and_exec_scripts_from_the_rollout(self):
        roll = C.CODEX_HOME / "sessions" / "2026" / "10" / "17"; roll.mkdir(parents=True)
        payloads = [{"type": "function_call", "namespace": "mcp__rp", "name": "read_file"},   # direct RepoPrompt call
                    {"type": "custom_tool_call", "name": "exec"},                          # code-mode script
                    {"type": "function_call", "name": "update_plan"},                      # other tool, not direct rp
                    {"type": "message"}]
        (roll / "rollout-x-thread-1.jsonl").write_text("\n".join(json.dumps({"payload": p}) for p in payloads))
        out = "\n".join(json.dumps(x) for x in [
            {"type": "thread.started", "thread_id": "thread-1"},
            {"type": "item.completed", "item": {"type": "command_execution"}},
            {"type": "item.completed", "item": {"type": "agent_message", "text": "answer"}},
            {"type": "turn.completed", "usage": {"input_tokens": 1000, "cached_input_tokens": 800, "output_tokens": 50}}])
        m = runner.parse("codex", out)
        self.assertEqual((m["tool_calls"], m["turns"], m["shell_calls"], m["final"]), (3, 4, 1, "answer"))
        self.assertEqual((m["rp_direct_calls"], m["exec_calls"], m["rollout_found"]), (1, 1, True))
        self.assertEqual(runner.comps("codex", out), {"unc": 200, "cw": 0, "cr": 800, "out": 50})

    def test_claude_command_is_isolated_to_the_lab_proxy(self):
        rd = Path(self.tmp.name) / "run"; rd.mkdir()
        cmd, _ = runner.run_claude(runner.ARMS["cc_cm2"], str(rd), "prompt", str(rd / "proxy.log"), "T1_caps:0")
        self.assertIn("--strict-mcp-config", cmd)
        self.assertEqual(cmd[cmd.index("--allowedTools") + 1], "mcp__rp")
        self.assertIn("Bash", cmd[cmd.index("--disallowedTools") + 1].split(","))
        args = json.loads((rd / "mcp.json").read_text())["mcpServers"]["rp"]["args"]
        self.assertIn(f"CMLAB_REPO={C.REPO}", args); self.assertIn("PROXY_CODEMODE=1", args)
        self.assertTrue(args[-1].endswith("rp_proxy.py"))

    def test_codex_direct_arm_sets_namespace_key_and_repoprompt_launch_flags(self):
        cmd, _ = runner.run_codex(runner.ARMS["cx_dons_rpcm2"], self.tmp.name, "prompt", "log", "s")
        joined = " ".join(cmd)
        self.assertIn('features.code_mode.direct_only_tool_namespaces=["mcp__rp"]', joined)
        for flag in ("features.tool_search=false", "features.apps=false", "features.plugins=false", "features.tool_suggest=false",
                     "mcp_servers.RepoPromptCE.enabled=false"):
            self.assertIn(flag, cmd)
        base, _ = runner.run_codex(runner.ARMS["cx_text_rp"], self.tmp.name, "prompt", "log", "s")
        self.assertNotIn("direct_only_tool_namespaces", " ".join(base))

    def test_fault_seed_is_shared_across_arms_and_absent_without_faults(self):
        a = runner.proxy_env(runner.ARMS["cc_text_f1"], "log", "T7_top_lines:2")
        b = runner.proxy_env(runner.ARMS["cc_cm2_f1"], "log", "T7_top_lines:2")
        self.assertEqual((a["PROXY_FAULT_SEED"], a["PROXY_FAULT_ERR"]), (b["PROXY_FAULT_SEED"], b["PROXY_FAULT_ERR"]))
        self.assertNotIn("PROXY_FAULT_SEED", runner.proxy_env(runner.ARMS["cc_text"], "log", "T7_top_lines:2"))

    def test_preflight_reports_unpinned_repository_and_missing_tools(self):
        C.REPO = None
        with mock.patch.object(C, "SWIFTC", "/nonexistent/swiftc"):
            problems = C.preflight({"claude"}, need_codemode=True, need_swiftc=True)
        self.assertTrue(any("CMLAB_REPO is unset" in p for p in problems))
        self.assertTrue(any("QuickJS-ng host missing" in p for p in problems))
        self.assertTrue(any("swiftc not found" in p for p in problems))

    def test_preflight_refuses_the_homebrew_test_host_for_code_mode_arms(self):
        C.QJS_HOST.write_text("#!/bin/sh\n"); C.QJS_HOST.chmod(0o755)
        with mock.patch.object(C, "links_homebrew_qjs", return_value=True):
            self.assertTrue(any("Homebrew test build" in p for p in C.preflight(set(), need_codemode=True)))
            self.assertFalse(any("Homebrew" in p for p in C.preflight(set(), need_codemode=False)))

    def test_relative_lab_paths_resolve_against_the_working_directory(self):
        with mock.patch.dict(os.environ, {"CMLAB_TEST_REL": "rel/dir"}):
            self.assertEqual(C._path("CMLAB_TEST_REL", None), Path.cwd() / "rel" / "dir")

    def test_rows_record_settings_and_resume_refuses_other_settings(self):
        row_ok = {"arm": "cx_text_rp", "task": "T1_caps", "rep": 0, **runner.settings("codex")}
        self.assertEqual(runner.incompatible([row_ok], ["cx_text_rp"]), [])
        self.assertEqual(runner.settings("codex")["effort"], runner.EFFORT["codex"])
        with mock.patch.dict(runner.EFFORT, {"codex": "high"}):
            self.assertEqual(len(runner.incompatible([row_ok], ["cx_text_rp"])), 1)
        self.assertEqual(runner.incompatible([{**row_ok, "model": "other"}], ["cc_text"]), [])  # other arms are not checked

    def test_prune_moves_unusable_rows_aside_so_resume_repeats_them(self):
        out = Path(self.tmp.name) / "r.jsonl"
        good = {"arm": "cc_text", "task": "T1_caps", "rep": 0, "rc": 0, "wtok": 10, "upstream_errors": 0}
        bad = [{**good, "rep": 1, "rc": -9}, {**good, "rep": 2, "wtok": 0}, {**good, "rep": 3, "upstream_errors": 2}]
        out.write_text("".join(json.dumps(r) + "\n" for r in [good, *bad]))
        with mock.patch("sys.stdout"): runner.prune_unusable(str(out))
        self.assertEqual(runner.load_rows(str(out)), [good])
        self.assertEqual(runner.load_rows(f"{out}.unusable.jsonl"), bad)

    def test_proxy_stats_separate_tool_calls_code_mode_and_upstream_errors(self):
        log = Path(self.tmp.name) / "proxy.log"
        entries = [{"tool": "_startup", "upstream_error": True, "text_chars": 0, "error": True},
                   {"tool": "read_file", "text_chars": 7, "error": False},
                   {"tool": "code_mode", "nested": {"calls": 2, "child_chars": 40}, "out_chars": 9, "error": False, "upstream_error": True}]
        log.write_text("".join(json.dumps(e) + "\n" for e in entries))
        s = runner.proxy_stats(str(log))
        self.assertEqual((s["proxy_tool_calls"], s["proxy_tool_chars"], s["cm_calls"], s["cm_nested"], s["upstream_errors"]), (1, 7, 1, 2, 2))
        self.assertNotIn("rp_top_calls", s)
        self.assertFalse(C.row_is_usable({"rc": 0, "wtok": 5, **s}))


# FAKE_UPSTREAM_MODE: ok (default) | bind_error (bind_context isError, as with no matching workspace) |
# rpc_error (JSON-RPC error for read_file) | exit_on_call (helper exits on read_file) | silent (never replies) |
# silent_calls (binds and lists tools, then never answers a tool call) | slow_rpc_error (JSON-RPC error after 0.6 s).
FAKE_UPSTREAM = textwrap.dedent("""\
    import json, os, sys
    MODE = os.environ.get("FAKE_UPSTREAM_MODE", "ok")  # see the mode list above
    TOOLS = [{"name": n, "description": n, "inputSchema": {"type": "object"}}
             for n in ("read_file", "file_search", "get_code_structure", "get_file_tree", "git", "bind_context")]
    for line in sys.stdin:
        m = json.loads(line)
        if os.environ.get("FAKE_UPSTREAM_LOG"):
            with open(os.environ["FAKE_UPSTREAM_LOG"], "a") as f: f.write(json.dumps(m) + "\\n")
        if "id" not in m or MODE == "silent": continue
        p = m.get("params") or {}; a = p.get("arguments") or {}; reply = {"jsonrpc": "2.0", "id": m["id"]}
        if m["method"] == "initialize": res = {"protocolVersion": "2025-06-18", "capabilities": {}, "serverInfo": {"name": "fake"}}
        elif m["method"] == "tools/list": res = {"tools": TOOLS}
        elif p.get("name") == "bind_context":
            res = ({"content": [{"type": "text", "text": "no open workspace contains that directory"}], "isError": True}
                   if MODE == "bind_error" else {"content": [{"type": "text", "text": "bound"}]})
        elif MODE == "silent_calls": continue
        elif MODE == "slow_rpc_error":
            import time; time.sleep(0.6); res = None; reply["error"] = {"code": -32000, "message": "slow failure"}
        elif MODE == "exit_on_call": sys.exit(3)
        elif MODE == "rpc_error": res = None; reply["error"] = {"code": -32000, "message": "window closed"}
        elif a.get("_rawJSON"): res = {"content": [{"type": "text", "text": json.dumps({"path": a.get("path"), "total_lines": 3, "content": "a\\nb\\nc\\n"})}]}
        else: res = {"content": [{"type": "text", "text": "## File Read\\nmarkdown body"}]}
        if res is not None: reply["result"] = res
        print(json.dumps(reply), flush=True)
    """)


def fake_cli(tmp: Path) -> Path:
    cli = tmp / "fake_cli"; cli.write_text(f"#!{sys.executable}\n" + FAKE_UPSTREAM); cli.chmod(0o755)
    return cli


class Proxy:
    def __init__(self, tmp: Path, **env):
        self.log = tmp / "upstream.jsonl"; self.proxy_log = tmp / "proxy.log"
        full = {**os.environ, "CMLAB_REPO": str(tmp), "CMLAB_CLI": str(fake_cli(tmp)), "CMLAB_SCRATCH": str(tmp / "scratch"),
                "PROXY_LOG": str(tmp / "proxy.log"), "FAKE_UPSTREAM_LOG": str(self.log), **env}
        self.p = subprocess.Popen([sys.executable, str(LAB / "rp_proxy.py")], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                  stderr=subprocess.PIPE, text=True, env=full)
        self.q: queue.Queue = queue.Queue(); self.ids = 0
        threading.Thread(target=lambda: [self.q.put(json.loads(l)) for l in self.p.stdout], daemon=True).start()

    def req(self, method, params=None):
        self.ids += 1; mid = self.ids
        self.p.stdin.write(json.dumps({"jsonrpc": "2.0", "id": mid, "method": method, "params": params or {}}) + "\n"); self.p.stdin.flush()
        while True:
            m = self.q.get(timeout=30)
            if m.get("id") == mid: return m.get("result", m)

    def upstream_calls(self, name):
        return [m["params"]["arguments"] for m in map(json.loads, self.log.read_text().splitlines())
                if m.get("method") == "tools/call" and m["params"]["name"] == name]

    def close(self):
        self.p.stdin.close(); self.p.kill(); self.p.wait(); self.p.stdout.close(); self.p.stderr.close()


class ProxyTests(unittest.TestCase):
    def start(self, cached_tools=False, **env) -> Proxy:
        tmp = tempfile.TemporaryDirectory(); self.addCleanup(tmp.cleanup)
        if cached_tools:  # a previous good start left the tool list cache, so the proxy answers before upstream is ready
            cache = Path(tmp.name) / "scratch" / "tools_cache.json"; cache.parent.mkdir(parents=True)
            cache.write_text(json.dumps([{"name": n, "description": n, "inputSchema": {"type": "object"}} for n in rp_tools()]))
        p = Proxy(Path(tmp.name), **env); self.addCleanup(p.close)
        self.assertEqual(p.req("initialize", {"protocolVersion": "2025-06-18"})["serverInfo"]["name"], "rp")
        return p

    def test_text_mode_exposes_only_the_four_exploration_tools_and_passes_text_through(self):
        p = self.start(PROXY_MODE="text")
        tools = p.req("tools/list")["tools"]
        self.assertEqual(sorted(t["name"] for t in tools), sorted(["read_file", "file_search", "get_code_structure", "get_file_tree"]))
        self.assertFalse(any("outputSchema" in t for t in tools))
        res = p.req("tools/call", {"name": "read_file", "arguments": {"path": "a.swift", "_tabID": "x"}})
        self.assertEqual(res["content"][0]["text"], "## File Read\nmarkdown body"); self.assertNotIn("structuredContent", res)
        self.assertEqual(p.upstream_calls("read_file"), [{"path": "a.swift"}])  # underscore routing args are stripped
        self.assertEqual(p.req("tools/call", {"name": "git", "arguments": {}})["isError"], True)
        self.assertEqual(p.upstream_calls("bind_context")[0]["working_dirs"], [str(Path(p.log).parent)])

    def test_structured_mode_keeps_text_and_adds_structured_content_and_schemas(self):
        p = self.start(PROXY_MODE="structured")
        self.assertTrue(all("outputSchema" in t for t in p.req("tools/list")["tools"]))
        res = p.req("tools/call", {"name": "read_file", "arguments": {"path": "a.swift"}})
        self.assertEqual(res["content"][0]["text"], "## File Read\nmarkdown body")
        self.assertEqual(res["structuredContent"]["total_lines"], 3)
        self.assertEqual(sorted(json.dumps(a, sort_keys=True) for a in p.upstream_calls("read_file")),
                         sorted([json.dumps({"path": "a.swift"}), json.dumps({"_rawJSON": True, "path": "a.swift"}, sort_keys=True)]))

    def test_injected_transient_error_never_reaches_upstream(self):
        p = self.start(PROXY_FAULT_ERR="1.0", PROXY_FAULT_SEED="T1_caps:0")
        p.req("tools/list")
        res = p.req("tools/call", {"name": "read_file", "arguments": {"path": "a.swift"}})
        self.assertTrue(res["isError"]); self.assertEqual(res["content"][0]["text"], "RepoPrompt: transient error, please retry")
        self.assertEqual(p.upstream_calls("read_file"), [])

    def assert_upstream_failure(self, p, needle):
        t0 = time.time()
        res = p.req("tools/call", {"name": "read_file", "arguments": {"path": "a.swift"}})
        self.assertLess(time.time() - t0, 15)
        self.assertTrue(res["isError"]); self.assertIn("RepoPrompt upstream unavailable", res["content"][0]["text"])
        self.assertIn(needle, res["content"][0]["text"])
        self.assertGreaterEqual(runner.proxy_stats(str(p.proxy_log))["upstream_errors"], 1)

    def test_failed_bind_answers_tool_calls_with_an_error_and_marks_the_run(self):
        self.assert_upstream_failure(self.start(cached_tools=True, FAKE_UPSTREAM_MODE="bind_error"), "bind_context")

    def test_failed_bind_without_a_tool_cache_stops_the_proxy_with_the_reason(self):
        tmp = Path(tempfile.mkdtemp()); self.addCleanup(shutil.rmtree, tmp)
        env = {**os.environ, "CMLAB_REPO": str(tmp), "CMLAB_CLI": str(fake_cli(tmp)), "CMLAB_SCRATCH": str(tmp / "s"),
               "PROXY_LOG": str(tmp / "proxy.log"), "FAKE_UPSTREAM_MODE": "bind_error"}
        r = subprocess.run([sys.executable, str(LAB / "rp_proxy.py")], input="", capture_output=True, text=True, env=env, timeout=30)
        self.assertNotEqual(r.returncode, 0); self.assertIn("bind_context", r.stderr); self.assertIn("Recovery", r.stderr)

    def test_silent_upstream_is_bounded_by_the_startup_timeout(self):
        self.assert_upstream_failure(self.start(cached_tools=True, FAKE_UPSTREAM_MODE="silent", PROXY_STARTUP_TIMEOUT="1"), "timed out")

    def test_json_rpc_error_on_a_call_is_an_error_reply_not_an_empty_result(self):
        p = self.start(FAKE_UPSTREAM_MODE="rpc_error"); p.req("tools/list")
        self.assert_upstream_failure(p, "window closed")

    def test_helper_exit_during_a_call_replies_instead_of_hanging(self):
        p = self.start(FAKE_UPSTREAM_MODE="exit_on_call"); p.req("tools/list")
        self.assert_upstream_failure(p, "exited")


class ProbeTests(unittest.TestCase):
    """runner.py's startup preflight: the same connect-and-bind as the proxy, before any paid run."""
    def probe(self, mode):
        tmp = Path(tempfile.mkdtemp()); self.addCleanup(shutil.rmtree, tmp)
        with mock.patch.object(C, "CLI", fake_cli(tmp)), mock.patch.object(C, "REPO", tmp), \
             mock.patch.dict(os.environ, {"FAKE_UPSTREAM_MODE": mode}):
            return C.probe_upstream(timeout=2)

    def test_probe_accepts_a_bound_upstream(self):
        self.assertIsNone(self.probe("ok"))

    def test_probe_names_bind_failure_and_recovery(self):
        bad = self.probe("bind_error")
        self.assertIn("bind_context", bad); self.assertIn("CE debug app running", bad)

    def test_probe_times_out_on_a_silent_helper(self):
        self.assertIn("timed out", self.probe("silent"))

    def test_missing_helper_is_reported_not_raised(self):
        with mock.patch.object(C, "CLI", Path("/nonexistent/helper")), mock.patch.object(C, "REPO", Path("/tmp")):
            self.assertIn("cannot start", C.probe_upstream(timeout=1))


def rp_tools():
    return ("read_file", "file_search", "get_code_structure", "get_file_tree")


@lru_cache(maxsize=1)
def qjs_host() -> str | None:
    """Test host, built on first use only (Homebrew test build; never the gate binary path)."""
    explicit = os.environ.get("CMLAB_TEST_QJS_HOST")
    if explicit: return explicit if os.access(explicit, os.X_OK) else None
    if not shutil.which("brew"): return None
    out = Path(tempfile.gettempdir()) / f"cmlab-test-{os.getuid()}" / "cm_host_v2"
    r = subprocess.run([str(LAB / "build_qjs_host.sh"), "--homebrew", str(out)], capture_output=True, text=True)
    return str(out) if r.returncode == 0 else None


class CodeModeBridgeTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.host = qjs_host()
        if not cls.host: raise unittest.SkipTest("no QuickJS-ng host (set CMLAB_TEST_QJS_HOST or install Homebrew quickjs-ng)")

    def start(self, **env) -> Proxy:
        return ProxyTests.start(self, PROXY_CODEMODE="1", CMLAB_QJS_HOST=self.host, **env)

    def test_helper_silent_on_a_nested_call_is_final_and_unusable_when_the_script_stops(self):
        # Wall 1 s, settle 0.5 s: the nested call cannot outlive the script (deadline = wall + 5 s) and is not retried.
        p = self.start(FAKE_UPSTREAM_MODE="silent_calls", PROXY_CM_WALL_S="1", PROXY_CM_SETTLE_S="0.5")
        t0 = time.time()
        res = self.call(p, "await tools.read_file({path: 'a'}); return 'unreachable';")
        self.assertLess(time.time() - t0, 5)
        text = res["content"][0]["text"]
        self.assertTrue(res["isError"]); self.assertIn("wall time limit exceeded", text)
        self.assertIn("1 nested calls had no answer from RepoPrompt", text)
        entry = [json.loads(l) for l in p.proxy_log.read_text().splitlines() if '"code_mode"' in l][-1]
        self.assertEqual((entry["upstream_error"], entry["nested"]["unresolved_at_stop"], entry["nested"]["attempts"],
                          entry["retried"]), (True, 1, 0, 0))
        self.assertEqual(runner.proxy_stats(str(p.proxy_log))["upstream_errors"], 1)
        self.assertEqual(entry["nested"]["upstream_errors"], 1)   # the unresolved call, counted once
        time.sleep(max(0, t0 + 6.5 - time.time()))   # past the nested deadline: the timed-out call is not retried
        self.assertEqual(len(p.upstream_calls("read_file")), 1)
        self.assertEqual(len(p.proxy_log.read_text().splitlines()), 1)   # nothing logged after accounting was final
        # The late child finished its accounting without crashing its thread (it shares state with the finished run).
        p.p.stdin.close(); p.p.terminate(); p.p.wait(timeout=10)
        err = p.p.stderr.read()
        self.assertNotIn("Traceback", err); self.assertNotIn("Exception in thread", err)

    def test_nested_error_arriving_during_settle_is_counted_before_the_snapshot(self):
        # Script stops at 0.2 s; the helper fails the call at 0.6 s, inside the 3 s settle window: counted, not unresolved.
        p = self.start(FAKE_UPSTREAM_MODE="slow_rpc_error", PROXY_CM_WALL_S="0.2", PROXY_CM_SETTLE_S="3")
        res = self.call(p, "await tools.read_file({path: 'a'}); return 'unreachable';")
        self.assertTrue(res["isError"]); self.assertNotIn("had no answer", res["content"][0]["text"])
        entry = [json.loads(l) for l in p.proxy_log.read_text().splitlines() if '"code_mode"' in l][-1]
        nested = entry["nested"]
        self.assertEqual((nested["unresolved_at_stop"], nested["attempts"], nested["upstream_errors"], entry["retried"], entry["upstream_error"]),
                         (0, 1, 1, 0, True))
        self.assertEqual(len(p.upstream_calls("read_file")), 1)

    def test_homebrew_test_host_is_detected_as_such(self):
        if os.environ.get("CMLAB_TEST_QJS_HOST"): self.skipTest("explicit host")
        self.assertTrue(C.links_homebrew_qjs(Path(self.host)))

    def call(self, p, script):
        p.req("tools/list")
        return p.req("tools/call", {"name": "code_mode", "arguments": {"script": script}})

    def test_children_get_data_first_results_from_one_raw_call_each(self):
        p = self.start()
        self.assertIn("code_mode", [t["name"] for t in p.req("tools/list")["tools"]])
        res = self.call(p, "const r = await Promise.all(['a','b'].map(path => tools.read_file({path}))); "
                           "return r.map(x => [x.data.total_lines, 'text' in x]);")
        self.assertFalse(res["isError"]); self.assertEqual(json.loads(res["content"][0]["text"]), [[3, False], [3, False]])
        self.assertEqual(sorted(a["path"] for a in p.upstream_calls("read_file")), ["a", "b"])
        self.assertTrue(all(a.get("_rawJSON") is True for a in p.upstream_calls("read_file")))

    def test_failed_child_is_retried_once_then_rejects_with_a_failure_footer(self):
        p = self.start(PROXY_FAULT_ERR="1.0", PROXY_FAULT_SEED="T7_top_lines:0")
        res = self.call(p, "await tools.read_file({path: 'a'}); return 'unreachable';")
        text = res["content"][0]["text"]
        self.assertTrue(res["isError"]); self.assertIn("Script error", text); self.assertIn("⚠ 1 of 1 nested calls failed", text)
        entry = json.loads(Path(p.log).with_name("proxy.log").read_text().splitlines()[-1])
        self.assertEqual((entry["nested"]["attempts"], entry["retried"], entry["failed"]), (2, 1, 1))

    def test_allow_error_lets_the_script_handle_a_failed_child(self):
        p = self.start(PROXY_FAULT_ERR="1.0", PROXY_FAULT_SEED="T7_top_lines:0")
        res = self.call(p, "const r = await tools.read_file({path: 'a'}, {allowError: true}); return r.isError ? 'handled' : 'no';")
        self.assertFalse(res["isError"])
        self.assertEqual(res["content"][0]["text"].splitlines()[0], "handled"); self.assertIn("nested calls failed", res["content"][0]["text"])


def row(arm, task, kind, wtok, correct=True, rep=0, host="claude", **kw):
    return {"arm": arm, "task": task, "kind": kind, "wtok": wtok, "correct": correct, "rep": rep, "host": host, "rc": 0,
            "shell_calls": 0, **kw}


def runs(arm, ratio, reps=5, wrong=(), shell=0):
    out = []
    for task, kind in (("T1_caps", "single"), ("T2_smallread_wire", "multi"), ("T7_top_lines", "heavy")):
        for rep in range(reps):
            out.append(row(arm, task, kind, round(1000 * ratio.get(kind, 1.0)) + rep, task not in wrong, rep, shell_calls=shell if rep == 0 else 0))
    return out


class AnalyzeTests(unittest.TestCase):
    def test_gate_passes_within_the_cost_bound(self):
        g = analyze.gate(runs("cc_text", {}) + runs("cc_cm2", {"single": 1.08, "heavy": 0.5}), "cc_cm2", "cc_text", n=200)
        self.assertEqual(g["verdict"], "PASS"); self.assertAlmostEqual(g["per_kind"]["heavy"][0], 0.5, places=2)

    def test_gate_fails_on_cost_lost_majority_or_violations_and_marks_low_reps(self):
        base = runs("cc_text", {})
        self.assertTrue(analyze.gate(base + runs("x", {"multi": 1.2}), "x", "cc_text", n=200)["verdict"].startswith("FAIL"))
        g = analyze.gate(base + runs("x", {}, wrong=("T7_top_lines",)), "x", "cc_text", n=200)
        self.assertEqual((g["verdict"], g["lost_majority"]), ("FAIL", ["T7_top_lines"]))
        self.assertEqual(analyze.gate(base + runs("x", {}, shell=1), "x", "cc_text", n=200)["violations"], 3)
        self.assertIn("exploratory: 3 reps", analyze.gate(runs("cc_text", {}, 3) + runs("x", {}, 3), "x", "cc_text", n=200)["verdict"])

    def test_failed_attempts_count_against_correctness_but_not_costs(self):
        # 2 correct runs plus 3 runs that died without usage: the old wtok filter would have seen 2/2 correct.
        x = [r for r in runs("x", {}) if not (r["task"] == "T1_caps" and r["rep"] >= 2)]
        x += [row("x", "T1_caps", "single", 0, False, rep, rc=-9) for rep in (2, 3, 4)]
        g = analyze.gate(runs("cc_text", {}) + x, "x", "cc_text", n=200)
        self.assertEqual((g["verdict"][:4], g["lost_majority"], g["unusable_rows"]), ("FAIL", ["T1_caps"], 3))
        self.assertAlmostEqual(g["per_kind"]["single"][0], 1.0, places=2)  # costs from the 2 usable runs only

    def test_unusable_rows_missing_tasks_or_kinds_are_incomplete_not_pass(self):
        base = runs("cc_text", {})
        zero = runs("x", {}); zero[0] = {**zero[0], "wtok": 0}
        upstream = runs("x", {}); upstream[0] = {**upstream[0], "upstream_errors": 1}
        no_task = [r for r in runs("x", {}) if r["task"] != "T7_top_lines"]
        no_kind = [r for r in base + runs("x", {}) if r["kind"] != "heavy"]
        for rows, reason in ((base + zero, "1 unusable rows"), (base + upstream, "1 unusable rows"),
                             (base + no_task, "no usable rows for x/T7_top_lines"), (no_kind, "kind heavy")):
            g = analyze.gate(rows, "x", "cc_text", n=200)
            self.assertTrue(g["verdict"].startswith("INCOMPLETE"), (reason, g["verdict"]))
            self.assertTrue(any(reason in r for r in g["reasons"]), (reason, g["reasons"]))

    def test_session_rows_and_rows_without_task_kind_or_usage_are_refused(self):
        good = row("x", "T1_caps", "single", 10)
        self.assertIsNone(analyze.check_rows([good, {**good, "seq": "T1_caps", "turn": 0}]))  # historical single-turn shape
        for bad, msg in (({**good, "seq": "S1", "turn": 0}, "session"), ({**good, "seq": "T1_caps", "turn": 1}, "session"),
                         ({k: v for k, v in good.items() if k != "kind"}, "missing kind"),
                         ({k: v for k, v in good.items() if k != "wtok"}, "missing wtok"),
                         ({**good, "kind": "heavy"}, "expected 'single'")):
            with self.assertRaisesRegex(analyze.BadInput, msg): analyze.check_rows([bad])
        f = Path(tempfile.mkdtemp()) / "s.jsonl"; self.addCleanup(shutil.rmtree, f.parent)
        f.write_text(json.dumps({**good, "seq": "S1", "turn": 1}) + "\n")
        r = subprocess.run([sys.executable, str(LAB / "analyze.py"), str(f)], capture_output=True, text=True)
        self.assertNotEqual(r.returncode, 0); self.assertIn("multi-turn session row", r.stderr)

    def test_nonzero_exit_rows_count_as_incorrect_even_if_graded_correct(self):
        x = runs("x", {})
        x = [{**r, "rc": -9} if r["task"] == "T7_top_lines" and r["rep"] < 3 else r for r in x]
        g = analyze.gate(runs("cc_text", {}) + x, "x", "cc_text", n=200)
        self.assertEqual((g["verdict"][:4], g["lost_majority"]), ("FAIL", ["T7_top_lines"]))

    def test_mixed_recorded_settings_are_refused_and_unrecorded_arms_are_reported(self):
        s = {"model": "sonnet", "effort": "cli-default", "truth_commit": "d4cbd9d1"}
        a = row("x", "T1_caps", "single", 10, **s)
        self.assertEqual(analyze.check_settings([a, {**a, "rep": 1}, row("old", "T1_caps", "single", 10, truth_commit="d4cbd9d1")]), [])
        self.assertEqual(analyze.check_settings([row("old", "T1_caps", "single", 10)]), ["old"])
        with self.assertRaisesRegex(analyze.BadInput, "arm x mixes"): analyze.check_settings([a, {**a, "model": "opus"}])
        with self.assertRaisesRegex(analyze.BadInput, "arm x mixes"): analyze.check_settings([a, row("x", "T1_caps", "single", 10)])
        with self.assertRaisesRegex(analyze.BadInput, "truth commits"):
            analyze.check_settings([a, row("y", "T1_caps", "single", 10, **{**s, "truth_commit": "32902ec6"})])

    def test_gate_names_the_violating_tools(self):
        x = runs("x", {}); x[0] = {**x[0], "shell_calls": 1, "violation_tools": ["ToolSearch"]}
        g = analyze.gate(runs("cc_text", {}) + x, "x", "cc_text", n=200)
        self.assertEqual((g["verdict"][:4], g["violation_tools"]), ("FAIL", ["ToolSearch"]))

    def test_fault_arms_pair_with_the_baseline_under_the_same_fault_profile(self):
        rows = [row(a, "T1_caps", "single", 1) for a in ("cc_text", "cc_cm2", "cc_text_f1", "cc_cm2_f1")]
        rows += [row(a, "T1_caps", "single", 1, host="codex") for a in ("cx_text_rp", "cx_dons_rpcm2_f2", "cx_text_rp_f2")]
        self.assertEqual(analyze.default_pairs(rows), [("cc_cm2", "cc_text"), ("cc_cm2_f1", "cc_text_f1"), ("cx_dons_rpcm2_f2", "cx_text_rp_f2")])

    def test_arm_table_warns_when_a_direct_arm_shows_no_direct_rollout_calls(self):
        rows = [row("cx_dons_rpcm2", "T1_caps", "single", 5, host="codex", rp_direct_calls=n) for n in (2, 0)]
        rows.append(row("cx_dons_rpcm2", "T1_caps", "single", 5, host="codex"))  # historical row without the field
        with mock.patch("sys.stdout", new_callable=__import__("io").StringIO) as out: analyze.print_arm_table(rows)
        self.assertIn("2/3 runs have no recorded direct `mcp__rp` call", out.getvalue())



if __name__ == "__main__":
    unittest.main()
