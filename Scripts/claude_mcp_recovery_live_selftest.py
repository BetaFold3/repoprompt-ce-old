#!/usr/bin/env python3
"""Stdlib-only self-test for ``claude_mcp_recovery_live.py``'s pure helpers.

Needs no app, CLI, Claude process or network, and signals nothing:
  python3 -I Scripts/claude_mcp_recovery_live_selftest.py

The ``get_log`` fixtures under ``Scripts/Fixtures/claude_mcp_recovery_live/`` keep the
shape of real ``agent_manage get_log`` captures (keys, oldest-first ``turn_offset``,
raw unescaped row text, self-closing ``<tool_result name=.. status=../>`` rows) with
short placeholder text.
"""

from __future__ import annotations

import json
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))

import claude_mcp_recovery_live as live  # noqa: E402 - after the script-directory path setup

FIXTURES_DIR = SCRIPT_DIR / "Fixtures" / "claude_mcp_recovery_live"
GET_LOG_KEYS = {
    "completed_turn_count",
    "name",
    "returned_turn_count",
    "session_id",
    "total_turns",
    "transcript_xml",
    "turn_limit",
    "turn_offset",
}

RUN = "6F1C2A4B-0C1D-4E5F-8A9B-0C1D2E3F4A5B"
CONNECTION = "A1B2C3D4-E5F6-4A7B-8C9D-0E1F2A3B4C5D"
OTHER_CONNECTION = "B1B2C3D4-E5F6-4A7B-8C9D-0E1F2A3B4C5D"
CLAUDE_ARGS = (
    "/usr/local/bin/claude --print --output-format stream-json --input-format stream-json "
    "--resume 0A1B2C3D-4E5F-4A6B-8C7D-8E9F0A1B2C3D"
)
HELPER_SYMLINK_PATH = "/Users/me/Library/Application Support/RepoPrompt CE/repoprompt_ce_cli_debug"


def row(connection_id: str = CONNECTION, run_id: str | None = RUN, ancestors: list[int] | None = None, **extra):
    base = {
        "id": connection_id,
        "run_id": run_id,
        "helper_peer_pid": 5000,
        "helper_process_start": "1761400000.123456",
        "helper_ancestor_pids": ancestors if ancestors is not None else [4000, 3000],
    }
    base.update(extra)
    return base


def load_fixture(name: str) -> dict:
    with (FIXTURES_DIR / name).open(encoding="utf-8") as handle:
        return json.load(handle)


class UUIDNormalizationTests(unittest.TestCase):
    def test_both_sides_compare_canonically(self) -> None:
        self.assertEqual(live.uuid_key(RUN), RUN.lower())
        self.assertEqual(live.uuid_key(RUN.lower()), live.uuid_key(RUN))
        self.assertEqual(live.strict_uuid(RUN, "run_id"), RUN.lower())
        self.assertIsNone(live.uuid_key("not-a-uuid"))
        self.assertIsNone(live.uuid_key(None))
        with self.assertRaises(live.LiveAcceptanceError):
            live.strict_uuid("nope", "run_id")

    def test_uppercase_diagnostics_rows_match_lowercase_run_ids(self) -> None:
        run_ids = {live.strict_uuid(RUN.lower(), "run_id")}
        found = live.select_run_helpers([row()], run_ids, None)
        self.assertEqual(len(found), 1)
        self.assertEqual(found[0].connection_id, CONNECTION.lower())
        self.assertEqual(found[0].claude_pid, 4000)

    def test_exclusion_and_claude_filter_use_canonical_ids(self) -> None:
        run_ids = {RUN.lower()}
        rows = [row(), row(OTHER_CONNECTION, ancestors=[4100, 3000])]
        excluded = frozenset({live.uuid_key(CONNECTION)})
        self.assertEqual(
            [helper.connection_id for helper in live.select_run_helpers(rows, run_ids, None, excluded)],
            [OTHER_CONNECTION.lower()],
        )
        self.assertEqual(
            [helper.connection_id for helper in live.select_run_helpers(rows, run_ids, 4000)],
            [CONNECTION.lower()],
        )

    def test_unrouted_and_malformed_rows_are_skipped(self) -> None:
        run_ids = {RUN.lower()}
        rows = [
            row(run_id=None),
            row(helper_process_start="not-a-start"),
            row(helper_ancestor_pids=[]),
            row(connection_id="nope"),
        ]
        self.assertEqual(live.select_run_helpers(rows, run_ids, None), [])

    def test_tool_call_counts_are_keyed_by_connection_whether_or_not_routed(self) -> None:
        rows = [
            row(run_id=None, non_bookkeeping_tool_call_count=2),
            row(OTHER_CONNECTION, non_bookkeeping_tool_call_count=3),
            row("not-a-uuid", non_bookkeeping_tool_call_count=9),
            row("C1B2C3D4-E5F6-4A7B-8C9D-0E1F2A3B4C5D", non_bookkeeping_tool_call_count="4"),
        ]
        self.assertEqual(
            live.tool_call_counts_by_connection(rows),
            {CONNECTION.lower(): 2, OTHER_CONNECTION.lower(): 3},
        )

    def test_conversation_is_located_by_a_unique_marker_in_a_recent_transcript(self) -> None:
        conversation = "0A1B2C3D-4E5F-4A6B-8C7D-8E9F0A1B2C3D"
        with tempfile.TemporaryDirectory() as directory:
            projects = Path(directory)
            (projects / "proj").mkdir()
            (projects / "proj" / f"{conversation}.jsonl").write_text('{"m":"TURN1-PROMPT-abc"}\n', encoding="utf-8")
            (projects / "proj" / "other.jsonl").write_text('{"m":"unrelated"}\n', encoding="utf-8")
            self.assertEqual(live.conversation_id_from_marker(projects, "TURN1-PROMPT-abc", 0), conversation.lower())
            # Files older than the scenario start are ignored.
            self.assertIsNone(live.conversation_id_from_marker(projects, "TURN1-PROMPT-abc", 4_000_000_000))
            # An ambiguous marker yields no conversation.
            (projects / "proj" / "dup.jsonl").write_text('{"m":"TURN1-PROMPT-abc"}\n', encoding="utf-8")
            self.assertIsNone(live.conversation_id_from_marker(projects, "TURN1-PROMPT-abc", 0))


class CommandLineTests(unittest.TestCase):
    def test_conversation_flags(self) -> None:
        self.assertEqual(live.conversation_flag_value("claude --resume abc", ("--resume", "--session-id")), "abc")
        self.assertEqual(live.conversation_flag_value("claude --resume=abc", ("--resume",)), "abc")
        self.assertEqual(live.conversation_flag_value("claude --session-id xyz", ("--resume", "--session-id")), "xyz")
        self.assertIsNone(live.conversation_flag_value("claude --session-id xyz", ("--resume",)))
        self.assertIsNone(live.conversation_flag_value("claude --resume", ("--resume",)))
        self.assertIsNone(live.conversation_flag_value(None, ("--resume",)))

    def test_helper_executable_names(self) -> None:
        self.assertTrue(live.is_helper_executable("/Applications/RepoPrompt CE.app/Contents/MacOS/repoprompt-mcp"))
        self.assertTrue(live.is_helper_executable(HELPER_SYMLINK_PATH), "a whole path with spaces")
        self.assertTrue(live.is_helper_executable("repoprompt_ce_cli_debug"))
        self.assertTrue(live.is_helper_executable("repoprompt_ce_cl"), "MAXCOMLEN-truncated ucomm")
        self.assertFalse(live.is_helper_executable("/Users/me/Library/Application"), "a space-split path fragment")
        self.assertFalse(live.is_helper_executable("bash"))
        self.assertFalse(live.is_helper_executable("repoprompt"))
        self.assertFalse(live.is_helper_executable(None))

    def test_claude_cli_shape(self) -> None:
        self.assertTrue(live.looks_like_claude_cli(CLAUDE_ARGS))
        self.assertTrue(live.looks_like_claude_cli(
            "node /x/claude-code/cli.js --input-format stream-json --output-format stream-json --session-id abc"
        ))
        self.assertFalse(live.looks_like_claude_cli("/bin/zsh -l"))
        self.assertFalse(live.looks_like_claude_cli("claude --input-format stream-json --output-format stream-json"))
        self.assertFalse(live.looks_like_claude_cli(None))

    def test_first_launch_is_recognised_by_the_app_launch_config(self) -> None:
        first_launch = (
            "/Users/me/.local/bin/claude -p --verbose --output-format stream-json --input-format stream-json "
            "--permission-prompt-tool stdio --mcp-config /Users/me/Library/Application Support/RepoPrompt CE/MCP/"
            "LaunchConfigs/discovery-D-1A55192C.json --strict-mcp-config"
        )
        self.assertTrue(live.looks_like_claude_cli(first_launch))
        # Without stream-json the launch config alone is not enough.
        self.assertFalse(live.looks_like_claude_cli(first_launch.replace("stream-json", "text")))
        # An --mcp-config outside the app's launch-config directory is not enough.
        self.assertFalse(live.looks_like_claude_cli(
            "claude --input-format stream-json --output-format stream-json --mcp-config /tmp/other.json"
        ))
        # The launch-config path without the flag is not enough.
        self.assertFalse(live.looks_like_claude_cli(
            "claude --input-format stream-json --output-format stream-json /x/MCP/LaunchConfigs/a.json"
        ))


class KillGuardTests(unittest.TestCase):
    """`executable` is `ps -o comm=` (a whole path, never split on spaces) and
    `accounting_name` is `ps -o ucomm=` (the kernel's MAXCOMLEN-truncated name)."""

    def setUp(self) -> None:
        self.helper = live.HelperIdentity(
            connection_id=CONNECTION.lower(), pid=5000, start="1761400000.123456", ancestors=[4000, 3000]
        )
        self.passing = {
            "observed_start": 1761400000,
            "executable": HELPER_SYMLINK_PATH,
            "accounting_name": "repoprompt_ce_cl",
            "live_chain": [4000, 3000],
            "args_by_pid": {4000: CLAUDE_ARGS, 3000: "/bin/zsh"},
            "own_pid": 9000,
            "own_ancestors": [8000, 1],
        }

    def refusal(self, **overrides) -> str | None:
        return live.kill_refusal(self.helper, **{**self.passing, **overrides})

    def test_all_checks_pass(self) -> None:
        self.assertIsNone(self.refusal())

    def test_a_helper_path_containing_spaces_is_matched_whole(self) -> None:
        self.assertIsNone(self.refusal(accounting_name="unrelated"))

    def test_either_ps_name_source_identifies_the_helper(self) -> None:
        self.assertIsNone(self.refusal(executable="/usr/local/bin/node"))
        self.assertIsNotNone(self.refusal(executable="/usr/local/bin/node", accounting_name="node"))

    def test_start_comparison_is_second_granular(self) -> None:
        # The app reports seconds.microseconds; `ps lstart` gives whole seconds only.
        self.assertEqual(self.helper.start_seconds, 1761400000)
        self.assertIsNone(self.refusal(observed_start=1761400000))

    def test_each_failed_check_refuses(self) -> None:
        cases = {
            "start": {"observed_start": 1761400001},
            "unreadable start": {"observed_start": None},
            "executable": {"executable": "/bin/sleep", "accounting_name": "sleep"},
            "unreadable names": {"executable": None, "accounting_name": None},
            "ancestry": {"live_chain": [3000]},
            "claude args": {"args_by_pid": {4000: "/bin/zsh"}},
            "self": {"own_pid": 5000},
            "own ancestor": {"own_ancestors": [5000, 1]},
        }
        for label, overrides in cases.items():
            with self.subTest(label):
                self.assertIsNotNone(self.refusal(**overrides))


class TranscriptEvidenceTests(unittest.TestCase):
    XML = "\n".join([
        "<transcript>",
        "<user>[TURN2-PROMPT] reply with exactly TURN2_OK_x</user>",
        '<tool_call name="mcp__RepoPromptCE__get_file_tree">{"max_depth":1}</tool_call>',
        '<tool_result name="mcp__RepoPromptCE__get_file_tree" status="success"/>',
        "<assistant>TURN2_OK_x</assistant>",
        "</transcript>",
    ])

    def test_reply_must_be_in_an_assistant_message(self) -> None:
        self.assertTrue(live.reply_in_assistant_message(self.XML, "TURN2_OK_x"))
        user_only = self.XML.replace("<assistant>TURN2_OK_x</assistant>", "<assistant>done</assistant>")
        self.assertFalse(live.reply_in_assistant_message(user_only, "TURN2_OK_x"), "the user prompt also contains it")

    def test_tool_success_requires_a_non_error_result(self) -> None:
        self.assertEqual(live.tool_results(self.XML), [("mcp__RepoPromptCE__get_file_tree", "success")])
        self.assertTrue(live.tool_succeeded(self.XML))
        self.assertFalse(live.tool_succeeded(self.XML.replace('status="success"', 'status="failed"')))
        pending = self.XML.replace('<tool_result name="mcp__RepoPromptCE__get_file_tree" status="success"/>', "")
        self.assertFalse(live.tool_succeeded(pending))

    def test_row_text_is_returned_raw(self) -> None:
        # The app writes row text unescaped, so an entity spelling in it is literal text.
        literal = "a " + live._AMP + "amp; b <c> & d"
        self.assertEqual(live.tagged_texts(f"<assistant>{literal}</assistant>", "assistant"), [literal])

    def test_tool_name_attribute_is_decoded(self) -> None:
        xml = '<tool_result name="x' + live._AMP + 'amp;y" status="success"/>'
        self.assertEqual(live.tool_results(xml), [("x&y", "success")])


class GetLogFixtureTests(unittest.TestCase):
    def test_fixtures_keep_the_captured_key_set(self) -> None:
        for name in ("get_log_one_turn_offset0.json", "get_log_two_turns_offset1.json"):
            with self.subTest(name):
                self.assertEqual(set(load_fixture(name)), GET_LOG_KEYS)

    def test_one_turn_page(self) -> None:
        payload = load_fixture("get_log_one_turn_offset0.json")
        self.assertEqual(live.total_turns_of(payload), 1)
        xml = live.transcript_slice(payload, 0)
        self.assertEqual(len(live.tagged_texts(xml, "user")), 1)
        self.assertIn("R&D", live.tagged_texts(xml, "system")[0])
        assistant = live.tagged_texts(xml, "assistant")
        self.assertEqual(len(assistant), 1)
        self.assertIn("`<dir>/notes` & logged.", assistant[0], "raw text, including a literal tag and ampersand")
        self.assertEqual(live.tool_results(xml), [("get_file_tree", "success"), ("read_file", "success")])
        self.assertTrue(live.tool_succeeded(xml))
        self.assertTrue(live.reply_in_assistant_message(xml, "WS5_TURN1_OK"))

    def test_turn_two_slice_uses_the_oldest_first_offset(self) -> None:
        payload = load_fixture("get_log_two_turns_offset1.json")
        self.assertEqual(live.total_turns_of(payload), 2)
        turns_before_steer = 1
        xml = live.transcript_slice(payload, turns_before_steer)
        self.assertEqual(live.tagged_texts(xml, "assistant"), ["Calling the probe tool.", "WS5_TURN2_OK"])
        self.assertTrue(live.reply_in_assistant_message(xml, "WS5_TURN2_OK"))
        self.assertFalse(live.reply_in_assistant_message(xml, "WS5_TURN1_OK"), "turn 1 is outside the slice")
        without_reply = xml.replace("<assistant>WS5_TURN2_OK</assistant>", "")
        self.assertIn("WS5_TURN2_OK", live.tagged_texts(without_reply, "user")[0])
        self.assertFalse(live.reply_in_assistant_message(without_reply, "WS5_TURN2_OK"), "the prompt alone is not a reply")
        self.assertEqual(live.tool_results(xml), [("get_file_tree", "success"), ("bash", "failed")])
        self.assertTrue(live.tool_succeeded(xml))
        self.assertFalse(live.tool_succeeded(xml, "bash"))

    def test_a_page_for_another_offset_or_without_a_transcript_is_rejected(self) -> None:
        payload = load_fixture("get_log_two_turns_offset1.json")
        with self.assertRaises(live.LiveAcceptanceError):
            live.transcript_slice(payload, 0)
        with self.assertRaises(live.LiveAcceptanceError):
            live.transcript_slice({**payload, "transcript_xml": None}, 1)
        with self.assertRaises(live.LiveAcceptanceError):
            live.total_turns_of({})


class ClaudeTranscriptTests(unittest.TestCase):
    MARKER = "TURN1-PROMPT-abc"

    def lines(self) -> list[str]:
        return [
            '{"type":"user","message":{"role":"user","content":"[TURN1-PROMPT-abc] call the tool"}}',
            '{"type":"user","message":{"role":"user","content":[{"type":"text","text":"[TURN2-PROMPT-abc]"}]}}',
            '{"type":"user","message":{"role":"user","content":[{"type":"tool_result","content":"TURN1-PROMPT-abc"}]}}',
            '{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"TURN1-PROMPT-abc"}]}}',
            '{"type":"queue-operation","content":"TURN1-PROMPT-abc"}',
            "not json",
        ]

    def test_counts_user_prompts_only(self) -> None:
        self.assertEqual(live.count_user_prompt_occurrences(self.lines(), self.MARKER), 1)

    def test_a_replayed_prompt_counts_twice(self) -> None:
        replay = '{"type":"user","message":{"role":"user","content":[{"type":"text","text":"[TURN1-PROMPT-abc] again"}]}}'
        self.assertEqual(live.count_user_prompt_occurrences([*self.lines(), replay], self.MARKER), 2)

    def test_finds_the_unique_transcript_case_insensitively(self) -> None:
        conversation = "0A1B2C3D-4E5F-4A6B-8C7D-8E9F0A1B2C3D"
        with tempfile.TemporaryDirectory() as directory:
            projects = Path(directory)
            self.assertIsNone(live.find_claude_transcript(projects, conversation))
            target = projects / "-Users-me-repo" / f"{conversation.lower()}.jsonl"
            target.parent.mkdir()
            target.write_text("")
            self.assertEqual(live.find_claude_transcript(projects, conversation), target)
            duplicate = projects / "-Users-me-other" / f"{conversation.lower()}.jsonl"
            duplicate.parent.mkdir()
            duplicate.write_text("")
            self.assertIsNone(live.find_claude_transcript(projects, conversation), "ambiguous")
        with self.assertRaises(live.LiveAcceptanceError):
            live.find_claude_transcript(Path("."), "../escape")


class LaterTurnRouteTests(unittest.TestCase):
    def test_the_scenario_is_registered_with_the_helper_exit_marker(self) -> None:
        self.assertIn("laterturn-kill", live.SCENARIOS)
        self.assertEqual(live.REASON_MARKERS["laterturn-kill"], "the RepoPrompt MCP helper process exited")
        self.assertGreater(live.LATERTURN_ROUTE_CHECK_SECONDS, 10.0, "must outlast the 10 s routing wait")

    def test_a_still_routed_connection_yields_its_helper(self) -> None:
        helper, detail = live.preserved_route_helper(
            [row(OTHER_CONNECTION, ancestors=[4100, 3000]), row()],
            live.uuid_key(CONNECTION),
            {RUN.lower()},
        )
        self.assertIsNotNone(helper)
        self.assertEqual(helper.connection_id, CONNECTION.lower())
        self.assertEqual((helper.pid, helper.claude_pid), (5000, 4000))
        self.assertIn("run_id=", detail)

    def test_an_unrouted_rerouted_missing_or_malformed_connection_yields_none(self) -> None:
        connection = live.uuid_key(CONNECTION)
        run_ids = {RUN.lower()}
        cases = {
            "unrouted": [row(run_id=None)],
            "another run": [row(run_id="7F1C2A4B-0C1D-4E5F-8A9B-0C1D2E3F4A5B")],
            "missing": [row(OTHER_CONNECTION)],
            "no helper identity": [row(helper_ancestor_pids=[])],
        }
        for name, rows in cases.items():
            with self.subTest(name):
                helper, detail = live.preserved_route_helper(rows, connection, run_ids)
                self.assertIsNone(helper)
                self.assertIn(connection, detail)

    def test_remaining_wait_counts_from_the_submit_time(self) -> None:
        self.assertEqual(live.remaining_wait(100.0, 104.0, 15.0), 11.0)
        self.assertEqual(live.remaining_wait(100.0, 115.0, 15.0), 0.0)
        self.assertEqual(live.remaining_wait(100.0, 130.0, 15.0), 0.0)

    def test_turn_two_must_reuse_the_same_helper_instance(self) -> None:
        turn1 = live.helper_from_row(row())
        self.assertIsNotNone(turn1)
        self.assertTrue(live.same_helper_instance(turn1, live.helper_from_row(row())))
        others = {
            "another connection": row(OTHER_CONNECTION),
            "another pid": row(helper_peer_pid=5001),
            "another start": row(helper_process_start="1761400999.000001"),
        }
        for name, other in others.items():
            with self.subTest(name):
                self.assertFalse(live.same_helper_instance(turn1, live.helper_from_row(other)))


def routing_event(seq: int, name: str, **fields: str) -> dict:
    return {"seq": seq, "event": name, "run_id": RUN, "connection_id": None, "fields": fields}


class RetentionRoutingHistoryTests(unittest.TestCase):
    def test_an_early_release_or_a_preserving_revocation_passes(self) -> None:
        for name in live.RETENTION_EARLY_RELEASE_EVENTS:
            with self.subTest(name):
                verdict, detail = live.retention_routing_verdict([routing_event(11, name)], 10)
                self.assertIs(verdict, True)
                self.assertIn(name, detail)
        verdict, _ = live.retention_routing_verdict(
            [routing_event(11, "policy_revoked", client_name="claude-code", routing_preserved="true")], 10
        )
        self.assertIs(verdict, True)

    def test_a_clearing_revocation_fails(self) -> None:
        verdict, detail = live.retention_routing_verdict(
            [routing_event(11, "policy_revoked", routing_preserved="false")], 10
        )
        self.assertIs(verdict, False)
        self.assertIn("routing cleared", detail)

    def test_the_old_unconditional_cleanup_fails(self) -> None:
        # Before route retention, `policy_revoked` carried only the client and window.
        verdict, detail = live.retention_routing_verdict(
            [routing_event(11, "policy_revoked", client_name="claude-code", window_id="1")], 10
        )
        self.assertIs(verdict, False)
        self.assertIn("routing_preserved=None", detail)

    def test_a_clearing_revocation_outweighs_a_kept_route(self) -> None:
        verdict, _ = live.retention_routing_verdict(
            [
                routing_event(11, "route_wait_skipped_proven_route"),
                routing_event(12, "policy_revoked", routing_preserved="false"),
            ],
            10,
        )
        self.assertIs(verdict, False)

    def test_events_up_to_the_baseline_and_unrelated_events_are_ignored(self) -> None:
        events = [
            routing_event(9, "policy_revoked", routing_preserved="false"),
            routing_event(10, "route_wait_skipped_proven_route"),
            routing_event(11, "route_wait_started"),
            {"seq": "12", "event": "policy_revoked", "fields": {"routing_preserved": "false"}},
        ]
        verdict, detail = live.retention_routing_verdict(events, 10)
        self.assertIsNone(verdict)
        self.assertIn("no lease outcome", detail)

    def test_the_early_release_path_needs_both_events(self) -> None:
        events = [
            routing_event(11, "policy_released_for_proven_route"),
            routing_event(12, "route_wait_skipped_proven_route"),
        ]
        ok, detail = live.later_turn_routing_path(events, 10)
        self.assertIs(ok, True)
        self.assertIn("early release", detail)
        ok, detail = live.later_turn_routing_path(events[:1], 10)
        self.assertIs(ok, False)
        self.assertIn("incomplete early release", detail)

    def test_the_wait_path_fails_with_a_clear_reason(self) -> None:
        ok, detail = live.later_turn_routing_path(
            [routing_event(11, "policy_revoked", routing_preserved="true", pruned_connection_count="0")], 10
        )
        self.assertIs(ok, False)
        self.assertIn("early release did not apply; 10 s wait path", detail)

    def test_the_wait_path_after_a_prune_that_removed_the_window_mapping_is_the_documented_fallback(self) -> None:
        for prune in (
            routing_event(
                5, "policy_revoked", routing_preserved="true", pruned_connection_count="1", window_mapping_removed="true"
            ),
            routing_event(
                9, "routing_cleanup_if_unproven", routing_preserved="true", pruned_connection_count="2",
                window_mapping_removed="true",
            ),
            routing_event(10, "proof_lost_routes_unrouted", unrouted_connection_count="1", window_mapping_removed="true"),
        ):
            with self.subTest(prune["event"]):
                # The run's route was assigned in turn 1 (seq 3); the prune came after it.
                events = [
                    routing_event(3, "policy_applied"),
                    prune,
                    routing_event(11, "policy_revoked", routing_preserved="true", pruned_connection_count="0"),
                ]
                ok, detail = live.later_turn_routing_path(events, 10)
                self.assertIs(ok, True)
                self.assertIn("documented fallback after a prune removed the window mapping", detail)

    def test_a_prune_excuses_the_wait_path_only_after_the_runs_last_route_assignment(self) -> None:
        prune = routing_event(5, "proof_lost_routes_unrouted", unrouted_connection_count="1", window_mapping_removed="true")
        revoke = routing_event(11, "policy_revoked", routing_preserved="true", pruned_connection_count="0")
        excused_detail = "documented fallback after a prune removed the window mapping"
        for label, events, after_seq, excused in (
            ("after the last assignment", [routing_event(3, "policy_applied"), prune, revoke], 10, True),
            ("a later assignment re-created the mapping", [routing_event(3, "policy_applied"), prune,
                                                          routing_event(7, "policy_applied"), revoke], 10, False),
            ("no assignment, before the turn boundary", [prune, revoke], 10, False),
            ("no assignment, after the turn boundary", [prune, revoke], 4, True),
            ("an assignment after the revoke does not move the bound", [routing_event(3, "policy_applied"), prune,
                                                                       revoke, routing_event(12, "policy_applied")],
             10, True),
            ("a later live-affinity restore re-created the mapping",
             [routing_event(3, "policy_applied"), prune, routing_event(7, "live_affinity_route_restored"), revoke],
             10, False),
            ("after a live-affinity restore", [routing_event(3, "live_affinity_route_restored"), prune, revoke], 10, True),
        ):
            with self.subTest(label):
                ok, detail = live.later_turn_routing_path(events, after_seq)
                self.assertIs(ok, excused)
                if excused:
                    self.assertIn(excused_detail, detail)
                else:
                    self.assertIn("early release did not apply; 10 s wait path", detail)

    def test_a_request_path_filling_the_empty_slot_is_a_route_assignment_and_a_yield_is_not(self) -> None:
        prune = routing_event(5, "proof_lost_routes_unrouted", unrouted_connection_count="1", window_mapping_removed="true")
        revoke = routing_event(11, "policy_revoked", routing_preserved="true", pruned_connection_count="0")
        for label, later, excused in (
            ("the kept helper's rebind filled the empty slot", routing_event(7, "run_tab_rebound_empty_slot", source="tool_call"), False),
            ("the rebind yielded to a different holder", routing_event(7, "tab_rebind_yielded_to_holder", source="tool_call"), True),
            ("the run mapping yielded to a different holder",
             routing_event(7, "run_mapping_yielded_to_holder", source="tool_call_affinity_restore"), True),
        ):
            with self.subTest(label):
                ok, detail = live.later_turn_routing_path([routing_event(3, "policy_applied"), prune, later, revoke], 10)
                self.assertIs(ok, excused)
                if excused:
                    self.assertIn("documented fallback after a prune removed the window mapping", detail)
                else:
                    self.assertIn("early release did not apply; 10 s wait path", detail)

    def test_a_prune_excuses_the_wait_path_only_when_it_removed_the_window_mapping_first(self) -> None:
        revoke = routing_event(11, "policy_revoked", routing_preserved="true", pruned_connection_count="0")
        for label, prune in (
            ("mapping kept", routing_event(5, "policy_revoked", routing_preserved="true", pruned_connection_count="1",
                                           window_mapping_removed="false")),
            ("no field", routing_event(5, "policy_revoked", routing_preserved="true", pruned_connection_count="1")),
            ("after the revoke", routing_event(12, "proof_lost_routes_unrouted", unrouted_connection_count="1",
                                               window_mapping_removed="true")),
            ("zero count", routing_event(5, "policy_revoked", routing_preserved="true", pruned_connection_count="0",
                                         window_mapping_removed="true")),
            ("negative count", routing_event(5, "policy_revoked", routing_preserved="true", pruned_connection_count="-1",
                                             window_mapping_removed="true")),
            ("non-integer count", routing_event(5, "policy_revoked", routing_preserved="true", pruned_connection_count="1.5",
                                                window_mapping_removed="true")),
        ):
            with self.subTest(label):
                # After the run's turn-1 route assignment (seq 3), so only the prune's fields decide.
                ok, detail = live.later_turn_routing_path([routing_event(3, "policy_applied"), prune, revoke], 10)
                self.assertIs(ok, False)
                self.assertIn("early release did not apply; 10 s wait path", detail)

    def test_positive_count_accepts_only_positive_integers(self) -> None:
        self.assertEqual(live.positive_count("3"), 3)
        self.assertEqual(live.positive_count(2), 2)
        for value in ("0", "-1", "1.0", "", " 1", "x", None, True, 0, -2, "\u0661"):
            with self.subTest(repr(value)):
                self.assertIsNone(live.positive_count(value))

    def test_a_clearing_revocation_or_no_outcome_is_not_the_early_release(self) -> None:
        ok, detail = live.later_turn_routing_path([routing_event(11, "policy_revoked", routing_preserved="false")], 10)
        self.assertIs(ok, False)
        self.assertIn("routing cleared", detail)
        ok, detail = live.later_turn_routing_path(
            [routing_event(9, "route_wait_skipped_proven_route"), routing_event(10, "policy_released_for_proven_route")], 10
        )
        self.assertIsNone(ok)
        self.assertIn("no lease outcome", detail)

    def with_raw_call(self, returncode: int, stdout: object, stderr: str = ""):
        """Patches the diagnostics CLI call for one test; `stdout` is JSON-encoded unless bytes."""
        original = live.diagnostics_raw_call
        body = stdout if isinstance(stdout, bytes) else json.dumps(stdout).encode()

        def raw_call(*_args, **_kwargs):
            return returncode, body, stderr.encode()

        live.diagnostics_raw_call = raw_call
        self.addCleanup(setattr, live, "diagnostics_raw_call", original)

    def history(self):
        return live.routing_history(Path("/nonexistent"), 1, {RUN.lower()})

    def test_a_supported_lookup_returns_events_and_the_latest_sequence(self) -> None:
        self.with_raw_call(0, {"ok": True, "op": "run_routing_history", "events": [routing_event(3, "x")], "latest_seq": 7})
        events, latest = self.history()
        self.assertEqual((len(events), latest), (1, 7))

    def test_an_unknown_op_is_unsupported(self) -> None:
        self.with_raw_call(0, {"ok": False, "op": "run_routing_history", "code": "unknown_op", "error": "Unknown debug diagnostics op: run_routing_history"})
        with self.assertRaises(live.RoutingHistoryUnsupported):
            self.history()

    def test_an_unknown_tool_is_unsupported(self) -> None:
        # A non-DEBUG build has no diagnostics tool at all.
        self.with_raw_call(1, b"", "Unknown tool: __repoprompt_debug_diagnostics")
        with self.assertRaises(live.RoutingHistoryUnsupported):
            self.history()

    def test_a_failed_supported_lookup_is_a_failure_not_unsupported(self) -> None:
        cases = [
            ("error payload", 0, {"ok": False, "op": "run_routing_history", "code": "internal", "error": "boom"}, ""),
            ("nonzero exit", 1, b"", "connection refused"),
            ("malformed JSON", 0, b"{not json", ""),
            ("missing latest_seq", 0, {"ok": True, "op": "run_routing_history", "events": []}, ""),
            ("events not a list", 0, {"ok": True, "op": "run_routing_history", "events": {}, "latest_seq": 1}, ""),
        ]
        for name, returncode, stdout, stderr in cases:
            with self.subTest(name):
                self.with_raw_call(returncode, stdout, stderr)
                with self.assertRaises(live.LiveAcceptanceError) as raised:
                    self.history()
                self.assertNotIsInstance(raised.exception, live.RoutingHistoryUnsupported)

    def test_required_history_fails_the_check_with_a_clear_reason(self) -> None:
        cases = [
            ("unsupported", 0, {"ok": False, "op": "run_routing_history", "code": "unknown_op", "error": "x"}, "DEBUG CE build"),
            ("failed", 1, b"", "lookup failed"),
        ]
        for name, returncode, stdout, reason in cases:
            with self.subTest(name):
                self.with_raw_call(returncode, stdout, "connection refused")
                result = live.ScenarioResult("laterturn-kill")
                with self.assertRaises(live.LiveAcceptanceError) as raised:
                    live.required_routing_history(
                        result, Path("/nonexistent"), 1, {RUN.lower()}, "routing history shows turn 2 kept the route",
                        "after turn 2 (the pre-turn lookup succeeded)",
                    )
                self.assertIn(reason, str(raised.exception))
                self.assertIn("nothing killed", str(raised.exception))
                self.assertEqual(result.checks[-1][0], "routing history shows turn 2 kept the route")
                self.assertIs(result.checks[-1][1], False)
                self.assertIn("after turn 2", result.checks[-1][2])
                self.assertFalse(result.passed)

    def test_a_post_turn_failure_after_a_successful_pre_turn_lookup_fails(self) -> None:
        result = live.ScenarioResult("laterturn-kill")
        self.with_raw_call(0, {"ok": True, "op": "run_routing_history", "events": [], "latest_seq": 4})
        before = live.required_routing_history(result, Path("/nonexistent"), 1, {RUN.lower()}, "before", "before turn 2")
        self.assertEqual(before[1], 4)
        self.with_raw_call(1, b"", "timed out")
        with self.assertRaises(live.LiveAcceptanceError):
            live.required_routing_history(result, Path("/nonexistent"), 1, {RUN.lower()}, "after", "after turn 2")
        self.assertEqual([(name, ok) for name, ok, _ in result.checks], [("after", False)])
        self.assertFalse(result.passed)


if __name__ == "__main__":
    unittest.main(verbosity=2)
