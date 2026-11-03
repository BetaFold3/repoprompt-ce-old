"""Offline tests for live_ab.py against minimal redacted fixtures of the four 2026-11-03 smokes (qualification only, not gate
samples). No agent, provider, app or model patch is run."""
import contextlib, io, json, os, shutil, subprocess, sys, tempfile, threading, time, unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import analyze, lab_config as C, live_ab
from tasks import TASKS

FX = os.path.join(os.path.dirname(os.path.abspath(__file__)), "fixtures", "live_ab")
CC_NATIVE, CC_CAND = "66025435-DE27-4E09-8C32-99758CB373EB", "4E772844-F14B-444B-A625-EA84D4975A5B"
CX_NATIVE, CX_CAND = "6E6CF65E-9720-4C83-A7E7-D87D48162576", "967744B4-AEBF-4CD8-8367-F76E303E5880"
CC_RAW = "claude-session-f204942e-e16a-439a-8f25-420c53c61c25-20261103-151055.jsonl"
CX_ROLLOUT = "rollout-2026-11-03T22-10-54-01a1a1f6-97ac-7d62-af2e-5e1f0ce241a4.jsonl"
FIXTURE_ROOT = "/fixture-d4cbd9d1"
T1_ANSWER = '```json\n{"exclusive": 1, "control": 8, "smallRead": 2, "smallReadPerWindow": 2, "gitRead": 2, "gitReadPerRepository": 1, "fileSearch": 4}\n```'


class Fixture(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.mkdtemp(); self.addCleanup(shutil.rmtree, self.dir)
        for n in os.listdir(FX):
            with open(os.path.join(FX, n)) as fh: text = fh.read().replace("__FIXTURE__", self.dir)
            with open(os.path.join(self.dir, n), "w") as fh: fh.write(text)
        # Fresh rows need CMLAB_REPO, a clean fixture and the prepared prompt (inside a provenance wrapper) in the request.
        for patcher in (mock.patch.object(live_ab.C, "REPO", Path(FIXTURE_ROOT)), mock.patch.object(live_ab, "check_fixture", return_value=[])):
            patcher.start(); self.addCleanup(patcher.stop)
        for sid in (CC_NATIVE, CX_NATIVE):
            d = self.session(sid)
            d["transcript"]["turns"][0]["request"]["text"] = f"[provenance x]\n{live_ab.worker_prompt('T1_caps', FIXTURE_ROOT)}\n[/provenance]"
            self.save_session(sid, d)

    def session(self, sid):
        with open(self.path(f"AgentSession-{sid}.json")) as fh: return json.load(fh)

    def save_session(self, sid, d):
        with open(self.path(f"AgentSession-{sid}.json"), "w") as fh: json.dump(d, fh)

    def lines(self, name):
        with open(self.path(name)) as fh: return [json.loads(l) for l in fh]

    def save_lines(self, name, rows):
        with open(self.path(name), "w") as fh: fh.writelines(json.dumps(r) + "\n" for r in rows)

    def path(self, n): return os.path.join(self.dir, n)

    def collect(self, sid, arm, task="T1_caps", status="completed", turn_index=None, wait_s=0):
        return live_ab.collect(self.dir, sid, arm=arm, task=task, rep=0, wall_s=1.0, status=status, turn_index=turn_index,
                               raw_dir=self.dir, wait_s=wait_s, poll_s=0.05)


class CollectSmokes(Fixture):
    def test_claude_native_raw_usage_with_one_hour_writes(self):
        r = self.collect(CC_NATIVE, "app_cc_base")
        self.assertEqual(r["rc"], 0, r["collect_errors"])
        self.assertEqual((r["tok_unc"], r["tok_cw5m"], r["tok_cw1h"], r["tok_cr"], r["tok_out"]), (4, 0, 79283, 78819, 138))
        self.assertEqual((r["model"], r["effort"]), ("claude-sonnet-5-5", "medium"))
        self.assertEqual(r["aux_models_excluded"], ["claude-haiku-5-5"])   # auxiliary model usage is not added
        self.assertEqual((r["tool_calls"], r["rp_direct_calls"], r["cm_calls"], r["shell_calls"]), (1, 1, 0, 0))
        self.assertEqual(r["usage_contract"], "claude-native.tokens-only.v1@2.1.316")
        self.assertEqual((r["cm_advertised"], r["treatment"]), (False, "verified"))   # init.tools has no code_mode
        self.assertIsNone(r["upstream_errors"])   # not measured in-app, never a claimed 0

    def test_claude_candidate_counts_code_mode_not_child_cards(self):
        r = self.collect(CC_CAND, "app_cc_cm", turn_index=0)
        self.assertEqual(r["rc"], 0, r["collect_errors"])
        self.assertTrue(r["qualification_only"])
        self.assertEqual((r["tok_unc"], r["tok_cw1h"], r["tok_cr"], r["tok_out"]), (4, 80506, 79860, 191))
        self.assertEqual((r["tool_calls"], r["cm_calls"], r["rp_direct_calls"]), (1, 1, 1))   # direct = all direct RepoPrompt calls
        self.assertEqual((r["cm_advertised"], r["treatment"]), (True, "verified"))
        self.assertEqual((r["transcript_tool_cards"], r["cm_child_cards"]), (2, 1))

    def test_codex_native_exec_container_and_single_cache_subtraction(self):
        r = self.collect(CX_NATIVE, "app_cx_base")
        self.assertEqual(r["rc"], 0, r["collect_errors"])
        # Codex input_tokens (62076) includes cached (30720): subtracted exactly once; Claude input is never reduced.
        self.assertEqual((r["tok_unc"], r["tok_cr"], r["tok_out"], r["tok_input_total"]), (31356, 30720, 118, 62076))
        self.assertEqual((r["model"], r["effort"], r["effort_source"]), ("gpt-6.1-sol", "medium", "rollout turn_context"))
        self.assertEqual(self.session(CX_NATIVE)["codexReasoningEffort"], "high")   # persisted config is not used
        self.assertEqual((r["exec_calls"], r["exec_nested_calls"], r["rp_direct_calls"], r["shell_calls"]), (1, 1, 0, 0))
        # No code_mode call: Codex traces cannot prove the baseline treatment either way.
        self.assertEqual((r["cm_advertised"], r["treatment"], r["rp_servers_used"]), (None, "unverified", ["RepoPromptCE"]))

    def test_codex_candidate_direct_namespace(self):
        r = self.collect(CX_CAND, "app_cx_cm", turn_index=0)
        self.assertEqual(r["rc"], 0, r["collect_errors"])
        self.assertEqual((r["tok_unc"], r["tok_cr"], r["tok_out"]), (34101, 33536, 84))
        self.assertEqual((r["rp_direct_calls"], r["cm_calls"], r["exec_calls"], r["tool_calls"]), (1, 1, 0, 1))
        self.assertEqual(r["cm_child_cards"], 0)   # Codex child card has no parent id; none is invented
        self.assertTrue(any("unmeasured interval" in w for w in r["warnings"]))
        self.assertEqual((r["treatment"], r["rp_servers_used"]), ("verified", ["RepoPromptCE-Direct"]))

    def test_multi_turn_sessions_are_refused_without_turn_index(self):
        for sid, arm in ((CC_CAND, "app_cc_cm"), (CX_CAND, "app_cx_cm")):
            r = self.collect(sid, arm)
            self.assertEqual(r["rc"], 2); self.assertFalse(r["correct"]); self.assertFalse(r["usage_complete"])
            self.assertIn("fresh single-turn", r["collect_errors"][0])


class CollectFailures(Fixture):
    def test_missing_claude_usage_is_incomplete_not_zero(self):
        d = self.session(CC_NATIVE); d["providerUsage"]["turns"][0]["cacheReadInputTokens"] = None; self.save_session(CC_NATIVE, d)
        r = self.collect(CC_NATIVE, "app_cc_base")
        self.assertEqual(r["rc"], 0); self.assertFalse(r["usage_complete"]); self.assertIsNone(r["tok_cr"]); self.assertIsNone(r["tok_unc"])
        self.assertFalse(C.row_is_usable(r))
        w = live_ab.weigh([r], {"unc": 1, "cr": 0.1, "out": 5, "cw1h": 2}, "x")[0]
        self.assertEqual(w["wtok"], 0); self.assertFalse(C.row_is_usable(w))

    def test_missing_codex_interval_times_out_as_incorrect(self):
        d = self.session(CX_NATIVE); d["providerUsage"]["codexIntervals"] = []; self.save_session(CX_NATIVE, d)
        r = self.collect(CX_NATIVE, "app_cx_base", wait_s=0.15)
        self.assertEqual(r["rc"], 3); self.assertFalse(r["correct"]); self.assertFalse(r["graded"])
        self.assertIn("timed out waiting: no measured usage interval", r["collect_errors"][0])

    def test_missing_session_file_is_bounded(self):
        r = live_ab.collect(self.dir, "00000000-0000-0000-0000-000000000000", arm="app_cc_base", task="T1_caps", rep=0,
                            wall_s=1, status="completed", raw_dir=self.dir, wait_s=0.1, poll_s=0.05)
        self.assertEqual(r["rc"], 3)

    def test_usage_mismatch_with_raw_trace(self):
        d = self.session(CC_NATIVE); d["providerUsage"]["turns"][0]["outputTokens"] = 139; self.save_session(CC_NATIVE, d)
        r = self.collect(CC_NATIVE, "app_cc_base")
        self.assertFalse(r["usage_complete"]); self.assertTrue(any("outputTokens=139" in p for p in r["usage_problems"]))
        d = self.session(CX_NATIVE); d["providerUsage"]["codexIntervals"][0]["cachedInputTokens"] = 0; self.save_session(CX_NATIVE, d)
        r = self.collect(CX_NATIVE, "app_cx_base")
        self.assertFalse(r["usage_complete"]); self.assertTrue(any("cachedInputTokens" in p for p in r["usage_problems"]))

    def test_stale_usage_is_reread_until_it_settles(self):   # Oracle A F1
        good = self.session(CC_NATIVE); stale = json.loads(json.dumps(good))
        stale["providerUsage"]["turns"][0]["cacheCreationInputTokens"] = 78819; self.save_session(CC_NATIVE, stale)
        timer = threading.Timer(0.2, self.save_session, (CC_NATIVE, good)); timer.start(); self.addCleanup(timer.cancel)
        r = self.collect(CC_NATIVE, "app_cc_base", wait_s=5)
        self.assertTrue(r["usage_complete"], r["usage_problems"]); self.assertGreater(r["collect_reads"], 1)
        self.assertEqual(r["tok_cw1h"], 79283)

    def test_unsettled_usage_stays_incomplete_at_expiry(self):
        d = self.session(CX_NATIVE); d["providerUsage"]["codexIntervals"][0]["coverage"] = "partial"; self.save_session(CX_NATIVE, d)
        r = self.collect(CX_NATIVE, "app_cx_base", wait_s=0.2)
        self.assertEqual(r["rc"], 0); self.assertFalse(r["usage_complete"]); self.assertGreater(r["collect_reads"], 1)
        self.assertFalse(C.row_is_usable(r))

    def test_identity_error_stops_without_waiting(self):
        d = self.session(CC_NATIVE); d["id"] = "00000000-0000-0000-0000-000000000002"; self.save_session(CC_NATIVE, d)
        t0 = time.monotonic(); r = self.collect(CC_NATIVE, "app_cc_base", wait_s=5)
        self.assertEqual((r["rc"], r["collect_reads"]), (2, 1)); self.assertLess(time.monotonic() - t0, 1)

    def test_cache_ttl_breakdown_required(self):
        rows = self.lines(CC_RAW)
        for e in rows:
            if (e.get("payload") or {}).get("type") == "result": e["payload"]["usage"]["cache_creation"] = None
        self.save_lines(CC_RAW, rows)
        r = self.collect(CC_NATIVE, "app_cc_base")
        self.assertFalse(r["usage_complete"]); self.assertTrue(any("TTL breakdown" in p for p in r["usage_problems"]))

    def test_identity_mismatches(self):
        d = self.session(CC_NATIVE); d["providerUsage"]["turns"][0]["executionID"] = "00000000-0000-0000-0000-000000000001"
        self.save_session(CC_NATIVE, d)
        self.assertEqual(self.collect(CC_NATIVE, "app_cc_base")["rc"], 2)
        d = self.session(CX_NATIVE); d["codexConversationID"] = "01a1a1f6-0000-0000-0000-000000000000"; self.save_session(CX_NATIVE, d)
        r = self.collect(CX_NATIVE, "app_cx_base")
        self.assertEqual(r["rc"], 2); self.assertTrue(any("session_meta" in e for e in r["collect_errors"]))
        r = self.collect(CC_CAND, "app_cx_cm", turn_index=0)   # arm/host mismatch
        self.assertEqual(r["rc"], 2); self.assertIn("is a codex arm", r["collect_errors"][-1])

    def test_claude_violations_and_subagents(self):
        rows = self.lines(CC_RAW)
        asst = next(e for e in rows if (e.get("payload") or {}).get("type") == "assistant")
        asst["payload"]["message"]["content"] += [{"type": "tool_use", "name": "Bash"}, {"type": "tool_use", "name": "mcp__RepoPromptCE__ask_oracle"}]
        sub = json.loads(json.dumps(asst)); sub["payload"]["parent_tool_use_id"] = "toolu_x"
        sub["payload"]["message"]["content"] = [{"type": "tool_use", "name": "mcp__RepoPromptCE__read_file"}]
        rows.insert(rows.index(asst) + 1, sub); self.save_lines(CC_RAW, rows)
        r = self.collect(CC_NATIVE, "app_cc_base")
        self.assertEqual(r["violation_tools"], ["Bash", "mcp__RepoPromptCE__ask_oracle", "subagent:mcp__RepoPromptCE__read_file"])
        self.assertEqual(r["shell_calls"], 3)

    def test_codex_violations_shell_and_exec_dispatch(self):
        rows = self.lines(CX_ROLLOUT); turn = next(e["payload"]["turn_id"] for e in rows if e["payload"].get("type") == "task_started")
        i = next(k for k, e in enumerate(rows) if e["payload"].get("type") == "custom_tool_call")
        rows[i + 1:i + 1] = [
            {"type": "response_item", "payload": {"type": "function_call", "name": "exec_command", "namespace": None}},
            {"type": "event_msg", "payload": {"type": "item_completed", "turn_id": turn, "item": {"type": "CommandExecution", "id": "x"}}},
            {"type": "event_msg", "payload": {"type": "item_completed", "turn_id": turn,
                                              "item": {"type": "McpToolCall", "id": "exec-1", "server": "RepoPromptCE", "tool": "apply_edits"}}}]
        self.save_lines(CX_ROLLOUT, rows)
        r = self.collect(CX_NATIVE, "app_cx_base")
        self.assertEqual(r["violation_tools"], ["exec>RepoPromptCE.apply_edits", "exec_command", "item:CommandExecution"])
        self.assertEqual(r["exec_nested_calls"], 2)

    def test_exec_nested_code_mode_counts_and_is_flagged(self):   # Oracle A F3
        rows = self.lines(CX_ROLLOUT); turn = next(e["payload"]["turn_id"] for e in rows if e["payload"].get("type") == "task_started")
        i = next(k for k, e in enumerate(rows) if e["payload"].get("type") == "custom_tool_call")
        rows.insert(i + 1, {"type": "event_msg", "payload": {"type": "item_completed", "turn_id": turn,
                            "item": {"type": "McpToolCall", "id": "exec-2", "server": "RepoPromptCE", "tool": "code_mode"}}})
        self.save_lines(CX_ROLLOUT, rows)
        r = self.collect(CX_NATIVE, "app_cx_cm")
        self.assertEqual(r["rc"], 0, r["collect_errors"])
        self.assertEqual((r["cm_calls"], r["cm_direct_calls"], r["exec_nested_calls"]), (1, 0, 2))
        self.assertEqual(r["violation_tools"], ["exec>RepoPromptCE.code_mode (nested code_mode route)"])

    def test_direct_code_mode_completion_item_not_double_counted(self):
        r = self.collect(CX_CAND, "app_cx_cm", turn_index=0)
        self.assertEqual((r["cm_calls"], r["cm_direct_calls"], r["exec_nested_calls"], r["shell_calls"]), (1, 1, 0, 0))

    def test_claude_raw_file_missing_is_pending(self):
        os.remove(self.path(CC_RAW))
        r = self.collect(CC_NATIVE, "app_cc_base", wait_s=0.1)
        self.assertEqual(r["rc"], 3); self.assertIn("no raw event file", r["collect_errors"][0])

    def test_aborted_codex_turn_records_rc1_without_usage(self):   # Oracle R1: no measured interval ever arrives
        r = self.collect(CX_CAND, "app_cx_cm", status="cancelled", turn_index=5, wait_s=0.1)
        self.assertEqual((r["rc"], r["usage_complete"], r["provider_terminal"]), (1, False, "turn_aborted"), r["collect_errors"])
        self.assertTrue(any("no measured usage interval" in p for p in r["usage_problems"]))
        self.assertEqual(r["wtok"], 0)

    def test_same_turn_null_thread_interval_is_incomplete(self):   # Oracle B P2-6
        d = self.session(CX_NATIVE); iv = d["providerUsage"]["codexIntervals"][0]
        d["providerUsage"]["codexIntervals"].append({**iv, "threadID": None, "coverage": "unavailable", "inputTokens": None})
        self.save_session(CX_NATIVE, d)
        r = self.collect(CX_NATIVE, "app_cx_base")
        self.assertFalse(r["usage_complete"]); self.assertTrue(any("without this thread" in p for p in r["usage_problems"]))
        d["providerUsage"]["codexIntervals"][-1]["turnID"] = "other-turn"; self.save_session(CX_NATIVE, d)
        self.assertIn("intervals for other turns", self.collect(CX_NATIVE, "app_cx_base")["collect_errors"][0])

    def test_transcript_card_violation(self):
        d = self.session(CX_NATIVE)
        d["transcript"]["turns"][0]["responseSpans"][0]["activities"][0]["toolExecution"]["toolName"] = "bash"
        self.save_session(CX_NATIVE, d)
        self.assertEqual(self.collect(CX_NATIVE, "app_cx_base")["violation_tools"], ["card:bash"])


class StartupStatus(Fixture):   # pre-measurement amendment: host base instructions require one startup set_status
    def test_claude_one_status_allowed_repeat_violates_and_calls_counted(self):
        rows = self.lines(CC_RAW)
        asst = next(e for e in rows if (e.get("payload") or {}).get("type") == "assistant")
        asst["payload"]["message"]["content"].insert(0, {"type": "tool_use", "name": "mcp__RepoPromptCE__set_status"})
        self.save_lines(CC_RAW, rows)
        r = self.collect(CC_NATIVE, "app_cc_base")
        self.assertEqual(r["rc"], 0, r["collect_errors"])
        self.assertEqual((r["tool_calls"], r["admin_calls"], r["rp_direct_calls"], r["shell_calls"]), (2, 1, 1, 0))
        self.assertEqual((r["tok_cw1h"], r["tok_out"]), (79283, 138))   # its cost stays in the row
        asst["payload"]["message"]["content"].append({"type": "tool_use", "name": "mcp__RepoPromptCE__set_status"})
        self.save_lines(CC_RAW, rows)
        r = self.collect(CC_NATIVE, "app_cc_base")
        self.assertEqual((r["tool_calls"], r["admin_calls"], r["shell_calls"]), (3, 2, 1))
        self.assertEqual(r["violation_tools"], ["set_status repeated (only one startup call allowed)"])

    def test_codex_exec_nested_status_allowed_then_direct_repeat_violates(self):
        rows = self.lines(CX_ROLLOUT); turn = next(e["payload"]["turn_id"] for e in rows if e["payload"].get("type") == "task_started")
        i = next(k for k, e in enumerate(rows) if e["payload"].get("type") == "custom_tool_call")
        rows.insert(i + 1, {"type": "event_msg", "payload": {"type": "item_completed", "turn_id": turn,
                            "item": {"type": "McpToolCall", "id": "exec-0", "server": "RepoPromptCE", "tool": "set_status"}}})
        self.save_lines(CX_ROLLOUT, rows)
        r = self.collect(CX_NATIVE, "app_cx_base")
        self.assertEqual(r["rc"], 0, r["collect_errors"])
        self.assertEqual((r["admin_calls"], r["exec_nested_calls"], r["shell_calls"]), (1, 2, 0))
        rows[i + 1:i + 1] = [
            {"type": "response_item", "payload": {"type": "function_call", "name": "set_status", "namespace": "mcp__RepoPromptCE_Direct"}},
            {"type": "event_msg", "payload": {"type": "item_completed", "turn_id": turn,
                                              "item": {"type": "McpToolCall", "id": "call_s", "server": "RepoPromptCE-Direct", "tool": "set_status"}}}]
        self.save_lines(CX_ROLLOUT, rows)
        r = self.collect(CX_NATIVE, "app_cx_base")
        self.assertEqual((r["tool_calls"], r["admin_calls"], r["shell_calls"]), (2, 2, 1))   # completion item not double counted
        self.assertEqual(r["violation_tools"], ["set_status repeated (only one startup call allowed)"])

    def test_status_on_other_routes_is_a_violation(self):
        rows = self.lines(CX_ROLLOUT); turn = next(e["payload"]["turn_id"] for e in rows if e["payload"].get("type") == "task_started")
        i = next(k for k, e in enumerate(rows) if e["payload"].get("type") == "custom_tool_call")
        rows.insert(i + 1, {"type": "event_msg", "payload": {"type": "item_completed", "turn_id": turn,
                            "item": {"type": "McpToolCall", "id": "exec-0", "server": "other", "tool": "set_status"}}})
        self.save_lines(CX_ROLLOUT, rows)
        r = self.collect(CX_NATIVE, "app_cx_base")
        self.assertEqual((r["admin_calls"], r["violation_tools"]), (0, ["exec>other.set_status"]))
        rows = self.lines(CC_RAW)   # Claude subagent status is not the startup route
        asst = next(e for e in rows if (e.get("payload") or {}).get("type") == "assistant")
        sub = json.loads(json.dumps(asst)); sub["payload"]["parent_tool_use_id"] = "toolu_x"
        sub["payload"]["message"]["content"] = [{"type": "tool_use", "name": "mcp__RepoPromptCE__set_status"}]
        rows.insert(rows.index(asst) + 1, sub); self.save_lines(CC_RAW, rows)
        r = self.collect(CC_NATIVE, "app_cc_base")
        self.assertEqual((r["admin_calls"], r["violation_tools"]), (0, ["subagent:mcp__RepoPromptCE__set_status"]))
        self.assertNotIn("set_status", live_ab.ALLOWED_TOOLS + live_ab.READ_TOOLS)

    def test_status_cards_one_allowed_code_mode_child_or_repeat_flagged(self):
        d = self.session(CX_NATIVE); acts = d["transcript"]["turns"][0]["responseSpans"][0]["activities"]
        card = next(a for a in acts if a.get("toolExecution"))
        status = json.loads(json.dumps(card)); status["id"] = "status-card"; status["toolExecution"]["toolName"] = "set_status"
        acts.insert(0, status); self.save_session(CX_NATIVE, d)
        self.assertEqual(self.collect(CX_NATIVE, "app_cx_base")["violation_tools"], [])
        status["toolExecution"]["codeModeParentInvocationID"] = "cm-1"; self.save_session(CX_NATIVE, d)
        self.assertEqual(self.collect(CX_NATIVE, "app_cx_base")["violation_tools"], ["card:set_status (code_mode child)"])
        status["toolExecution"]["codeModeParentInvocationID"] = None; acts.insert(0, json.loads(json.dumps(status)))
        self.save_session(CX_NATIVE, d)
        self.assertEqual(self.collect(CX_NATIVE, "app_cx_base")["violation_tools"], ["card:set_status (repeated)"])


class TreatmentLabelAndCLI(Fixture):   # Oracle B P1-1, P1-2, P2-8, P3-11
    def test_claude_treatment_mismatch_is_refused(self):
        r = self.collect(CC_NATIVE, "app_cc_cm")
        self.assertEqual(r["rc"], 2); self.assertTrue(any("treatment mismatch" in e for e in r["collect_errors"]))
        r = self.collect(CC_CAND, "app_cc_base", turn_index=0)
        self.assertEqual(r["rc"], 2); self.assertTrue(any("code_mode offered" in e for e in r["collect_errors"]))

    def test_claude_without_init_tools_is_unverified_and_withheld(self):
        rows = self.lines(CC_RAW)
        for e in rows: (e.get("payload") or {}).pop("tools", None)
        self.save_lines(CC_RAW, rows)
        r = self.collect(CC_NATIVE, "app_cc_base")
        self.assertEqual((r["rc"], r["treatment"], r["cm_advertised"]), (0, "unverified", None))
        w = live_ab.parse_weights("unc=1,cw1h=2,cr=0.1,out=5")
        self.assertEqual(live_ab.weigh([r], w, "x")[0]["wtok"], 0)
        held = live_ab.weigh([r], w, "x", allow_unverified_treatment=True)[0]   # Oracle R3: attestation is Codex-only
        self.assertEqual((held["wtok"], held["wtok_unverified_treatment_allowed"]), (0, False))

    def test_codex_unverified_weighted_only_with_attestation(self):   # Oracle R3
        r = self.collect(CX_NATIVE, "app_cx_base"); w = live_ab.parse_weights("unc=1,cr=0.1,out=5")
        self.assertEqual(live_ab.weigh([r], w, "x")[0]["wtok"], 0)
        allowed = live_ab.weigh([r], w, "x", allow_unverified_treatment=True)[0]
        self.assertGreater(allowed["wtok"], 0); self.assertTrue(allowed["wtok_unverified_treatment_allowed"])
        r["treatment"] = "verified"
        self.assertFalse(live_ab.weigh([r], w, "x", allow_unverified_treatment=True)[0]["wtok_unverified_treatment_allowed"])

    def test_codex_baseline_using_direct_companion_is_refused(self):   # Oracle R4
        rows = self.lines(CX_ROLLOUT); turn = next(e["payload"]["turn_id"] for e in rows if e["payload"].get("type") == "task_started")
        i = next(k for k, e in enumerate(rows) if e["payload"].get("type") == "custom_tool_call")
        rows[i:i] = [
            {"type": "response_item", "payload": {"type": "function_call", "name": "read_file", "namespace": "mcp__RepoPromptCE_Direct"}},
            {"type": "event_msg", "payload": {"type": "item_completed", "turn_id": turn,
                                              "item": {"type": "McpToolCall", "id": "call_d", "server": "RepoPromptCE-Direct", "tool": "read_file"}}}]
        self.save_lines(CX_ROLLOUT, rows)
        r = self.collect(CX_NATIVE, "app_cx_base")
        self.assertEqual(r["rc"], 2); self.assertTrue(any("Direct companion" in e for e in r["collect_errors"]))
        r = self.collect(CX_NATIVE, "app_cx_cm")   # no code_mode call: consistent with the candidate, still unverified
        self.assertEqual((r["rc"], r["treatment"]), (0, "unverified"))

    def test_codex_baseline_with_code_mode_call_is_refused(self):
        rows = self.lines(CX_ROLLOUT)
        i = next(k for k, e in enumerate(rows) if e["payload"].get("type") == "custom_tool_call")
        rows.insert(i, {"type": "response_item", "payload": {"type": "function_call", "name": "code_mode", "namespace": "mcp__RepoPromptCE_Direct"}})
        self.save_lines(CX_ROLLOUT, rows)
        r = self.collect(CX_NATIVE, "app_cx_base")
        self.assertEqual(r["rc"], 2); self.assertTrue(any("treatment mismatch" in e for e in r["collect_errors"]))
        self.assertEqual(self.collect(CX_NATIVE, "app_cx_cm")["treatment"], "verified")

    def test_task_label_and_fixture_checks(self):
        self.assertTrue(any("does not contain the prepared T7_top_lines prompt" in e
                            for e in self.collect(CC_NATIVE, "app_cc_base", task="T7_top_lines")["collect_errors"]))
        with mock.patch.object(live_ab.C, "REPO", None):
            self.assertIn("CMLAB_REPO unset", self.collect(CC_NATIVE, "app_cc_base")["collect_errors"][0])
            self.assertEqual(self.collect(CC_CAND, "app_cc_cm", turn_index=0)["rc"], 0)   # qualification bypasses the label
        with mock.patch.object(live_ab, "check_fixture", return_value=["not clean"]):
            self.assertEqual(self.collect(CC_NATIVE, "app_cc_base")["collect_errors"], ["fixture: not clean"])
        with self.assertRaises(ValueError): self.collect(CC_NATIVE, "app_cc_base", status="complete")

    def cli(self, *args):
        out = io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit) as cm:
            live_ab.main(["collect", "--sessions-dir", self.dir, "--claude-raw-dir", self.dir, "--wait-s", "0", "--wall-s", "1",
                          "--status", "completed", "--task", "T1_caps", *args])
        return cm.exception.code

    def test_cli_records_attempts_once_and_keeps_problems_for_inspection(self):
        out = self.path("rows.jsonl")
        self.assertEqual(self.cli("--session-id", CC_NATIVE, "--arm", "app_cc_base", "--rep", "0", "--out", out), 0)
        self.assertEqual(self.cli("--session-id", CC_NATIVE, "--arm", "app_cc_base", "--rep", "1", "--out", out), 4)   # same session
        self.assertEqual(self.cli("--session-id", CX_NATIVE, "--arm", "app_cx_base", "--rep", "0", "--out", out), 0)
        self.assertEqual(self.cli("--session-id", CC_CAND, "--arm", "app_cc_cm", "--rep", "1", "--out", out), 2)   # multi-turn
        self.assertEqual(self.cli("--session-id", CX_CAND, "--arm", "app_cx_base", "--rep", "0", "--out", out), 4)   # same (arm, task, rep)
        with open(out) as fh: self.assertEqual([json.loads(l)["session_id"] for l in fh], [CC_NATIVE, CX_NATIVE])
        with open(out + ".inspect.jsonl") as fh: self.assertEqual([json.loads(l)["rc"] for l in fh], [2])
        self.assertEqual(self.cli("--session-id", CX_CAND, "--arm", "app_cx_cm", "--rep", "5", "--out", out, "--no-grade"), 2)  # argparse error
        self.assertEqual(self.cli("--session-id", CX_NATIVE, "--arm", "app_cx_base", "--rep", "9", "--task", "T1_typo", "--out", out), 2)  # Oracle R2
        # Oracle R1: an aborted Codex attempt is recorded once (rc 1), not left for endless re-collection.
        self.assertEqual(self.cli("--session-id", CX_CAND, "--arm", "app_cx_cm", "--rep", "2", "--status", "cancelled",
                                  "--turn-index", "5", "--out", out), 1)
        with open(out) as fh: self.assertEqual([json.loads(l)["rc"] for l in fh], [0, 0, 1])


class Grading(Fixture):
    def set_claude_answer(self, text, is_error=False):
        rows = self.lines(CC_RAW)
        for e in rows:
            if (e.get("payload") or {}).get("type") == "result": e["payload"].update(result=text, is_error=is_error)
        self.save_lines(CC_RAW, rows)

    def test_correct_answer_graded_after_terminal_check(self):
        self.set_claude_answer(T1_ANSWER)
        r = self.collect(CC_NATIVE, "app_cc_base")
        self.assertTrue(r["correct"]); self.assertTrue(r["graded"])
        self.assertTrue(any("differs from the transcript" in w for w in r["warnings"]))

    def test_non_completed_status_is_incorrect_and_ungraded(self):
        self.set_claude_answer(T1_ANSWER)
        for status in ("timeout", "failed"):
            r = self.collect(CC_NATIVE, "app_cc_base", status=status)
            self.assertEqual(r["rc"], 1); self.assertFalse(r["correct"]); self.assertIsNone(r["answer_correct"])

    def test_provider_error_result_is_incorrect(self):
        self.set_claude_answer(T1_ANSWER, is_error=True)
        r = self.collect(CC_NATIVE, "app_cc_base")
        self.assertEqual(r["rc"], 1); self.assertFalse(r["correct"])


class PrepareAndWeigh(unittest.TestCase):
    def test_prompt_starts_with_prohibition_and_names_real_tools(self):
        for tid in TASKS:
            p = live_ab.worker_prompt(tid, "/fixture")
            self.assertTrue(p.startswith(live_ab.PROHIBITION + "\n\n"))
            self.assertNotIn("`rp`", p)
            for tool in live_ab.READ_TOOLS + ("code_mode", "/fixture"): self.assertIn(tool, p)
            self.assertNotIn("must use code_mode", p)
            self.assertIn("you may call set_status once at startup; do not call it again", p)
        p = live_ab.worker_prompt("T2_smallread_wire", "/fixture")
        for leaked in ("oracle_chat_log", "get_file_tree\", \"oracle"): self.assertNotIn(leaked, p)
        p = live_ab.worker_prompt("T3_opencode_env", "/fixture")
        for name in TASKS["T3_opencode_env"]["truth"]: self.assertNotIn(name, p)

    def test_fixture_check_requires_clean_truth_commit(self):
        d = tempfile.mkdtemp(); self.addCleanup(shutil.rmtree, d)
        self.assertTrue(live_ab.check_fixture(None))
        subprocess.run(["git", "init", "-q", d], check=True)
        subprocess.run(["git", "-C", d, "-c", "user.email=t@t", "-c", "user.name=t", "-c", "commit.gpgsign=false", "commit", "-q", "--allow-empty", "-m", "x"], check=True)
        self.assertIn("not " + C.TRUTH_COMMIT, live_ab.check_fixture(d)[0])
        with self.assertRaises(SystemExit): live_ab.prepare(["T1_caps"], d)

    def test_weigh_requires_declared_weights(self):
        row = {"arm": "app_cc_base", "task": "T1_caps", "rep": 0, "usage_complete": True, "treatment": "verified",
               "tok_unc": 4, "tok_cw5m": 0, "tok_cw1h": 79283, "tok_cw": 0, "tok_cr": 78819, "tok_out": 138}
        with self.assertRaises(ValueError): live_ab.weigh([row], {"unc": 1, "cr": 0.1, "out": 5}, "x")   # 1h writes undeclared
        with self.assertRaises(ValueError): live_ab.parse_weights("unc=1,out=5")
        w = live_ab.weigh([row], live_ab.parse_weights("unc=1,cw1h=2,cr=0.1,out=5"), "declared-1h-2x")[0]
        self.assertEqual(w["wtok"], round(4 + 2 * 79283 + 0.1 * 78819 + 5 * 138))
        self.assertEqual(w["wtok_label"], "declared-1h-2x")

    def live_rows(self):
        rows = []
        for arm in ("app_cc_base", "app_cc_cm"):
            for t in ("T1_caps", "T2_smallread_wire", "T7_top_lines"):
                rows.append({"arm": arm, "host": "claude", "task": t, "kind": TASKS[t]["kind"], "rep": 0, "rc": 0, "correct": True,
                             "usage_complete": True, "tok_unc": 4, "tok_cw5m": 0, "tok_cw1h": 1000, "tok_cw": 0, "tok_cr": 500,
                             "tok_out": 10, "wtok": 0, "upstream_errors": None, "shell_calls": 0, "model": "m", "effort": "e",
                             "cli_version": "v1", "treatment": "verified", "graded": True, "truth_commit": C.TRUTH_COMMIT[:8]})
        return rows

    def test_weigh_refuses_version_drift_within_a_host(self):   # Oracle B P2-4
        rows = self.live_rows(); rows[4] = {**rows[4], "cli_version": "v2"}
        with self.assertRaisesRegex(ValueError, "drift"): live_ab.weigh(rows, live_ab.parse_weights("unc=1,cw1h=2,cr=0.1,out=5"), "x")

    def test_ungraded_completed_rows_refused_by_analyzer(self):   # Oracle B P2-7
        rows = live_ab.weigh(self.live_rows(), live_ab.parse_weights("unc=1,cw1h=2,cr=0.1,out=5"), "x")
        rows[1] = {**rows[1], "graded": False}
        with self.assertRaisesRegex(analyze.BadInput, "never graded"): analyze.gate(rows, "app_cc_cm", "app_cc_base", n=50)
        rows[1] = {**rows[1], "rc": 1, "correct": False}   # a failed attempt is legitimately ungraded
        analyze.gate(rows, "app_cc_cm", "app_cc_base", n=50)

    def test_weighted_rows_feed_analyze(self):
        rows = self.live_rows()
        g = analyze.gate(live_ab.weigh(rows, live_ab.parse_weights("unc=1,cw1h=2,cr=0.1,out=5"), "x"), "app_cc_cm", "app_cc_base", n=50)
        self.assertTrue(g["verdict"].startswith("PASS (exploratory"))
        self.assertAlmostEqual(g["all"][0], 1.0)

    def test_baseline_violation_fails_comparison(self):   # Oracle A F2
        rows = live_ab.weigh(self.live_rows(), live_ab.parse_weights("unc=1,cw1h=2,cr=0.1,out=5"), "x")
        rows[0] = {**rows[0], "shell_calls": 1, "violation_tools": ["Bash"]}
        self.assertEqual(rows[0]["arm"], "app_cc_base")
        g = analyze.gate(rows, "app_cc_cm", "app_cc_base", n=50)
        self.assertTrue(g["verdict"].startswith("FAIL"))
        self.assertEqual((g["violations"], g["baseline_violations"], g["violation_tools"]), (1, 1, ["Bash"]))

    def test_qualification_rows_refused_by_analyzer(self):   # Oracle A F4
        rows = live_ab.weigh(self.live_rows(), live_ab.parse_weights("unc=1,cw1h=2,cr=0.1,out=5"), "x")
        rows[3] = {**rows[3], "qualification_only": True}
        with self.assertRaisesRegex(analyze.BadInput, "qualification-only"): analyze.gate(rows, "app_cc_cm", "app_cc_base", n=50)
        rows[3]["qualification_only"] = False
        analyze.gate(rows, "app_cc_cm", "app_cc_base", n=50)


if __name__ == "__main__":
    unittest.main()
