#!/usr/bin/env python3
"""Focused tests for conductor concise output summaries."""

from __future__ import annotations

import contextlib
import errno
import fcntl
import importlib.util
import io
import itertools
import json
import os
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from pathlib import Path
from typing import Any, Optional
from unittest import mock

SCRIPT_DIR = Path(__file__).resolve().parent
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))

import conductor  # noqa: E402


def summarize(operation: str, state: str, exit_code: Optional[int], lines: list[str]) -> dict:
    return conductor.OutputSummarizer.summarize_lines(operation, {}, state, exit_code, False, lines)


def section(summary: dict, title: str) -> list[str]:
    for item in summary.get("sections", []):
        if item.get("title") == title:
            return item.get("lines") or []
    return []


def app_payload(subcommand: str, state: str, exit_code: int, lines: list[str], **extra: object) -> dict:
    payload = {
        "ticket": "ticket",
        "operation": "app",
        "operationLabel": f"app {subcommand}",
        "args": {"subcommand": subcommand},
        "state": state,
        "exitCode": exit_code,
        "timedOut": False,
        "logPath": "/tmp/job.log",
        "outputSummary": conductor.OutputSummarizer.summarize_lines(
            "app", {"subcommand": subcommand}, state, exit_code, False, lines
        ),
    }
    payload.update(extra)
    return payload


def rendered_terminal_output(payload: dict) -> str:
    with contextlib.redirect_stdout(io.StringIO()) as output:
        conductor.print_terminal_job_output(payload)
    return output.getvalue()


class OutputSummarizerTests(unittest.TestCase):
    def test_success_package_summary_omits_raw_build_noise(self) -> None:
        lines = ["==> Building RepoPrompt\n"]
        lines.extend(f"CompileSwift noisy file {index}\n" for index in range(200))
        lines.append("Created: /tmp/RepoPrompt.app\n")

        summary = summarize("build", "completed", 0, lines)

        self.assertIn("Created: /tmp/RepoPrompt.app", section(summary, "Artifacts"))
        rendered = "\n".join(line for item in summary["sections"] for line in item["lines"])
        self.assertNotIn("CompileSwift noisy file", rendered)

    def test_swift_compiler_failure_extracts_file_error_and_context(self) -> None:
        lines = [
            "==> Building\n",
            "previous context one\n",
            "previous context two\n",
            "Sources/Foo.swift:10:5: error: cannot find 'x' in scope\n",
            "let y = x\n",
            "    ^\n",
        ]

        summary = summarize("swift-build", "failed", 1, lines)
        swift_errors = section(summary, "Swift compiler errors")

        self.assertTrue(any("Sources/Foo.swift:10:5: error" in line for line in swift_errors))
        self.assertIn("previous context two", swift_errors)
        self.assertIn("let y = x", swift_errors)

    def test_xctest_failure_extracts_failing_test(self) -> None:
        summary = summarize(
            "test",
            "failed",
            1,
            [
                "Test Case 'RepoPromptTests.FooTests.testBar' failed (0.1 seconds)\n",
                "Executed 1 test, with 1 failure (0 unexpected) in 0.1 seconds\n",
            ],
        )

        test_failures = section(summary, "Test failures")
        self.assertTrue(any("FooTests.testBar" in line for line in test_failures))
        self.assertTrue(any("Executed 1 test" in line for line in test_failures))

    def test_xctest_active_deadline_summary_preserves_budget_diagnostic(self) -> None:
        deadline = (
            "XCTest ACTIVE-METHOD deadline triggered; "
            "active test method=-[RepoPromptTests.FooTests testBar]; "
            "budget=90.000s; budget source=ledger-derived; previous=<none>"
        )

        summary = summarize("test", "failed", 70, [deadline + "\n"])

        self.assertIn(deadline, section(summary, "Timeout or cancellation"))

    def test_completion_header_includes_global_heavy_slot_wait(self) -> None:
        payload = {
            "ticket": "ticket",
            "operation": "test",
            "args": {},
            "state": "completed",
            "exitCode": 0,
            "logPath": "/tmp/job.log",
            "globalHeavySlotWaitSeconds": 2.5,
            "outputSummary": {"headline": "completed successfully", "sections": []},
        }

        rendered = rendered_terminal_output(payload)

        self.assertIn("global-wait=2.5s", rendered)

    def test_stale_artifact_pass_wording_only_renders_for_completed_exit_zero(self) -> None:
        base = {
            "ticket": "ticket",
            "operation": "test-artifact",
            "args": {"filter": "AlphaTests"},
            "logPath": "/tmp/job.log",
            "artifactScope": "stale",
            "artifactScopeDifferences": ["dirty digest"],
            "artifactScopeMessage": (
                "artifact_scope: stale — current source was NOT validated; differs: dirty digest"
            ),
            "outputSummary": {"headline": "test result", "sections": []},
        }

        completed = rendered_terminal_output({**base, "state": "completed", "exitCode": 0})
        failed = rendered_terminal_output({**base, "state": "failed", "exitCode": 1})
        canceled = rendered_terminal_output({**base, "state": "canceled", "exitCode": 130})

        self.assertIn("artifact passed", completed)
        self.assertNotIn("artifact passed", failed)
        self.assertNotIn("artifact passed", canceled)
        self.assertIn("current source was NOT validated", failed)
        self.assertIn("current source was NOT validated", canceled)

    def test_style_findings_extract_swiftlint_lines(self) -> None:
        summary = summarize(
            "lint",
            "failed",
            1,
            [
                "Running SwiftLint\n",
                "Sources/Foo.swift:12:3: warning: Todo Violation: TODOs should be resolved\n",
                "ERROR: Missing required Swift style tools\n",
            ],
        )

        findings = section(summary, "Style findings")
        self.assertTrue(any("SwiftLint" in line for line in findings))
        self.assertTrue(any("Sources/Foo.swift:12:3: warning" in line for line in findings))

    def test_timeout_lines_are_prioritized(self) -> None:
        summary = summarize(
            "test",
            "failed",
            124,
            ["timed out after 300.0s\n", "terminating process group: timed out after 300.0s\n"],
        )

        timeout_lines = section(summary, "Timeout or cancellation")
        self.assertTrue(any("timed out after 300.0s" in line for line in timeout_lines))
        self.assertTrue(any("terminating process group" in line for line in timeout_lines))

    def test_progress_line_selection_filters_noise_and_caps_output(self) -> None:
        lines = ["CompileSwift noisy file\n", "==> Build\n"]
        lines.extend(f"Created: /tmp/artifact-{index}\n" for index in range(20))
        lines.append("plain final noise\n")

        selected = conductor.select_progress_lines("build", lines)

        self.assertLessEqual(len(selected), conductor.PROGRESS_MAX_LINES_PER_POLL)
        self.assertIn("==> Build", selected)
        self.assertTrue(any("Created: /tmp/artifact-" in line for line in selected))
        self.assertFalse(any("CompileSwift noisy file" in line for line in selected))
        self.assertFalse(any("plain final noise" in line for line in selected))

    def test_app_lifecycle_summary_and_progress_prioritize_confirmed_transition(self) -> None:
        lines = [
            "==> Stopping existing RepoPrompt CE debug app instance\n",
            "==> Waiting for existing RepoPrompt CE debug app process to exit\n",
            "RepoPrompt CE debug app stop confirmed.\n",
            "==> Launching /tmp/RepoPrompt.app\n",
            "==> Confirming launched RepoPrompt CE debug app process\n",
            "Observed launched RepoPrompt CE debug PID(s): 123\n",
        ]

        summary = summarize("run", "completed", 0, lines)
        lifecycle = section(summary, "App lifecycle")
        titles = [item["title"] for item in summary["sections"]]
        progress = conductor.select_progress_lines(
            "run",
            ["RepoPrompt CE debug app stop confirmed.\n", "Observed launched RepoPrompt CE debug PID(s): 123\n"],
        )

        self.assertIn("RepoPrompt CE debug app stop confirmed.", lifecycle)
        self.assertIn("Observed launched RepoPrompt CE debug PID(s): 123", lifecycle)
        self.assertTrue(summary["launchLifecycle"]["transitionStarted"])
        self.assertTrue(summary["launchLifecycle"]["launchRequested"])
        self.assertTrue(summary["launchLifecycle"]["launchConfirmed"])
        self.assertLess(titles.index("App lifecycle"), titles.index("Phases"))
        self.assertIn("RepoPrompt CE debug app stop confirmed.", progress)
        self.assertIn("Observed launched RepoPrompt CE debug PID(s): 123", progress)

    def test_app_operation_display_name_is_precise(self) -> None:
        self.assertEqual(conductor.operation_display_name("app", {"subcommand": "stop"}), "app stop")
        self.assertEqual(conductor.operation_display_name("app", {"subcommand": "relaunch"}), "app relaunch")

    def test_failed_relaunch_before_transition_reports_safe_rebuild_failure_and_source_edit_guidance(self) -> None:
        payload = app_payload(
            "relaunch",
            "failed",
            1,
            [
                "==> Packaging debug app\n",
                "error: input file '/tmp/Sources/Foo.swift' was modified during the build\n",
            ],
        )

        summary = payload["outputSummary"]
        rendered = rendered_terminal_output(payload)

        self.assertFalse(summary["launchLifecycle"]["transitionStarted"])
        self.assertTrue(summary["launchLifecycle"]["sourceChangedDuringBuild"])
        self.assertIn("Rebuild/package failed before this relaunch ticket reached app stop/open.", rendered)
        self.assertIn("This ticket did not stop or reopen RepoPrompt.", rendered)
        self.assertIn("source files changed during the build", rendered)
        self.assertIn("retry after edits settle", rendered)
        self.assertNotIn("superseded", rendered)

    def test_failed_relaunch_after_transition_advises_status_instead_of_preservation(self) -> None:
        payload = app_payload(
            "relaunch",
            "failed",
            1,
            [
                "==> Packaging debug app\n",
                "==> Stopping existing RepoPrompt CE debug app instance\n",
                "ERROR: open failed\n",
            ],
        )

        rendered = rendered_terminal_output(payload)

        self.assertTrue(payload["outputSummary"]["launchLifecycle"]["transitionStarted"])
        self.assertIn("failed after this ticket began app stop/open lifecycle work", rendered)
        self.assertIn("Check app status before retrying.", rendered)
        self.assertNotIn("did not stop or reopen", rendered)

    def test_canceled_lifecycle_output_distinguishes_supersession_from_cancellation(self) -> None:
        superseded = rendered_terminal_output(
            app_payload(
                "relaunch",
                "canceled",
                130,
                ["terminating process group: superseded by app stop replacement\n"],
                supersededByOperation="app stop",
                supersededByTicket="replacement",
            )
        )
        superseded_stop = rendered_terminal_output(
            app_payload(
                "stop",
                "canceled",
                130,
                ["job superseded before start by app relaunch replacement\n"],
                supersededByOperation="app relaunch",
                supersededByTicket="replacement",
            )
        )
        canceled = rendered_terminal_output(app_payload("stop", "canceled", 130, ["job canceled before start\n"]))

        self.assertIn("superseded by newer app stop intent (ticket replacement)", superseded)
        self.assertIn("superseded by newer app relaunch intent (ticket replacement)", superseded_stop)
        self.assertIn("This app stop ticket was canceled before completion.", canceled)
        self.assertNotIn("superseded", canceled)

    def test_failed_relaunch_recomputes_legacy_summary_for_lifecycle_classification(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            log = Path(tmp) / "job.log"
            log.write_text(
                "==> Packaging debug app\nerror: input file '/tmp/Foo.swift' was modified during the build\n",
                encoding="utf-8",
            )
            payload = {
                "ticket": "ticket",
                "operation": "app",
                "operationLabel": "app relaunch",
                "args": {"subcommand": "relaunch"},
                "state": "failed",
                "exitCode": 1,
                "timedOut": False,
                "logPath": str(log),
                "outputSummary": {"headline": "failed with exit code 1", "sections": []},
            }

            summary = conductor.output_summary_for_payload(payload)
            enriched = conductor.payload_with_output_summary(payload)

        self.assertTrue(summary["launchLifecycle"]["sourceChangedDuringBuild"])
        self.assertFalse(summary["launchLifecycle"]["transitionStarted"])
        self.assertTrue(enriched["outputSummary"]["launchLifecycle"]["sourceChangedDuringBuild"])
        self.assertFalse(enriched["outputSummary"]["launchLifecycle"]["transitionStarted"])

    def test_huge_log_is_capped(self) -> None:
        lines = [f"Sources/Foo.swift:{index}:1: error: boom {index}\n" for index in range(500)]
        summary = summarize("swift-build", "failed", 1, lines)

        rendered_lines = [line for item in summary["sections"] for line in item["lines"]]
        rendered_chars = sum(len(line) for line in rendered_lines)
        self.assertLessEqual(len(rendered_lines), conductor.SUMMARY_FAILURE_MAX_LINES)
        self.assertLessEqual(rendered_chars, conductor.SUMMARY_MAX_CHARS)
        self.assertTrue(summary["truncated"] or summary["omittedLineCount"] > 0)

    def test_ansi_and_long_lines_are_cleaned(self) -> None:
        long_error = "\x1b[31mERROR: " + ("x" * 1000) + "\x1b[0m\n"
        summary = summarize("build", "failed", 1, [long_error])
        highlights = section(summary, "Failure highlights")

        self.assertEqual(len(highlights), 1)
        self.assertNotIn("\x1b", highlights[0])
        self.assertLessEqual(len(highlights[0]), conductor.SUMMARY_LINE_MAX_CHARS)

    def test_summarize_file_preserves_artifact(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            log = Path(tmp) / "job.log"
            log.write_text("==> Package\nCreated: /tmp/App.app\n", encoding="utf-8")
            summary = conductor.OutputSummarizer.summarize_file(
                "build", {}, "completed", 0, False, log
            )
        self.assertIn("Created: /tmp/App.app", section(summary, "Artifacts"))

    def test_phase_summary_keeps_recent_phases(self) -> None:
        lines = [f"==> Phase {index}\n" for index in range(25)]
        summary = summarize("build", "failed", 1, lines)
        phases = section(summary, "Phases")

        self.assertNotIn("==> Phase 0", phases)
        self.assertIn("==> Phase 24", phases)
        self.assertLessEqual(len(phases), 20)

    def test_generic_failure_includes_recent_output(self) -> None:
        summary = summarize(
            "build",
            "failed",
            1,
            ["setup\n", "ERROR: command failed\n", "tail detail one\n", "tail detail two\n"],
        )

        self.assertIn("ERROR: command failed", section(summary, "Failure highlights"))
        self.assertIn("tail detail two", section(summary, "Recent output"))

    def test_payload_with_output_summary_adds_client_side_json_fallback_without_log_tail(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            log = Path(tmp) / "job.log"
            log.write_text("==> Package\nCreated: /tmp/App.app\n", encoding="utf-8")
            payload = {
                "ticket": "ticket",
                "operation": "build",
                "args": {},
                "state": "completed",
                "exitCode": 0,
                "timedOut": False,
                "logPath": str(log),
                "logTail": [f"line {index}\n" for index in range(40)],
            }

            enriched = conductor.payload_with_output_summary(payload)

        self.assertIsNot(enriched, payload)
        self.assertIn("outputSummary", enriched)
        self.assertIn("Created: /tmp/App.app", section(enriched["outputSummary"], "Artifacts"))
        self.assertNotIn("logTail", enriched)
        self.assertEqual(str(log), enriched["logPath"])

    def test_payload_with_output_summary_can_preserve_trimmed_log_tail_for_compatibility(self) -> None:
        payload = {
            "ticket": "ticket",
            "operation": "build",
            "args": {},
            "state": "completed",
            "exitCode": 0,
            "timedOut": False,
            "outputSummary": {"headline": "completed successfully", "sections": []},
            "logTail": [f"line {index}\n" for index in range(40)],
        }

        enriched = conductor.payload_with_output_summary(payload, include_log_tail=True)

        self.assertEqual(len(enriched["logTail"]), conductor.LOG_TAIL_LINES)
        self.assertEqual(enriched["logTail"][0], "line 10\n")

    def test_payload_with_output_summary_drops_existing_tail_when_summary_is_present(self) -> None:
        payload = {
            "ticket": "ticket",
            "operation": "build",
            "state": "completed",
            "exitCode": 0,
            "outputSummary": {"headline": "completed successfully", "sections": []},
            "logTail": ["redundant raw tail\n"],
        }

        enriched = conductor.payload_with_output_summary(payload)

        self.assertIn("outputSummary", enriched)
        self.assertNotIn("logTail", enriched)

    def test_job_payload_exposes_additive_process_timing_and_lifecycle_metadata(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            diagnostic = root / "stall.sample.txt"
            job = conductor.Job(
                ticket="ticket",
                request_key=None,
                fingerprint="fingerprint",
                operation="test",
                args={},
                lanes=["build"],
                timeout=None,
                verbose=False,
                env={},
                created_at=10.0,
                started_at=12.5,
                finished_at=20.0,
                process_started_at=13.0,
                process_finished_at=19.25,
                progress_transport="pty",
                test_evidence_scope="full-root",
                build_phase_seconds=2.5,
                run_phase_seconds=3.75,
                xctest_progress_sequence=17,
                xctest_last_progress_test="RepoPromptTests.ExampleTests.testProgress",
                xctest_last_progress_action="started",
                xctest_last_progress_observed_at=18.75,
                log_path=root / "ticket.log",
                state="completed",
                exit_code=0,
                diagnostic_paths=[diagnostic],
            )

            payload = job.to_payload()

        self.assertEqual(payload["queuedAt"], 10.0)
        self.assertEqual(payload["processStartedAt"], 13.0)
        self.assertEqual(payload["processFinishedAt"], 19.25)
        self.assertEqual(payload["queueWaitSeconds"], 2.5)
        self.assertEqual(payload["executionSeconds"], 6.25)
        self.assertEqual(payload["testEvidenceScope"], "full-root")
        self.assertEqual(payload["buildPhaseSeconds"], 2.5)
        self.assertEqual(payload["runPhaseSeconds"], 3.75)
        self.assertFalse(payload["measurementInvalid"])
        self.assertEqual(payload["progressTransport"], "pty")
        self.assertEqual(payload["progressSequence"], 17)
        self.assertEqual(payload["lastProgressTest"], "RepoPromptTests.ExampleTests.testProgress")
        self.assertEqual(payload["lastProgressAction"], "started")
        self.assertEqual(payload["lastProgressObservedAt"], 18.75)
        self.assertEqual(payload["diagnosticPaths"], [str(diagnostic)])

    def test_terminal_job_status_attaches_missing_output_summary(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            jobs_dir = root / "jobs"
            jobs_dir.mkdir()
            paths = conductor.Paths(
                repo_root=root,
                repo_hash="test",
                state_dir=root,
                socket_path=root / "conductor.sock",
                pid_path=root / "conductor.pid",
                lock_path=root / "conductor.lock",
                jobs_dir=jobs_dir,
                daemon_log_path=root / "daemon.log",
                daemon_meta_path=root / "daemon.json",
                running_processes_path=root / "running.json",
            )
            log = jobs_dir / "ticket.log"
            log.write_text("==> Package\nCreated: /tmp/App.app\n", encoding="utf-8")
            state = conductor.DaemonState(paths)
            state.jobs["ticket"] = conductor.Job(
                ticket="ticket",
                request_key=None,
                fingerprint="fingerprint",
                operation="build",
                args={},
                lanes=[],
                timeout=None,
                verbose=False,
                env={},
                created_at=conductor.now(),
                log_path=log,
                state="completed",
                finished_at=conductor.now(),
                exit_code=0,
                result_summary="completed successfully",
            )

            payload = state.job_status("ticket", None)

        self.assertIn("outputSummary", payload)
        self.assertIn("Created: /tmp/App.app", section(payload["outputSummary"], "Artifacts"))

    def test_json_full_log_is_rejected(self) -> None:
        with self.assertRaises(conductor.ConductorError):
            conductor.split_operation_flags(["--json", "--full-log"])

    def test_async_full_log_is_rejected(self) -> None:
        with self.assertRaises(conductor.ConductorError):
            conductor.split_operation_flags(["--async", "--full-log"])

    def test_job_list_omits_output_summary(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            jobs_dir = root / "jobs"
            jobs_dir.mkdir()
            paths = conductor.Paths(
                repo_root=root,
                repo_hash="test",
                state_dir=root,
                socket_path=root / "conductor.sock",
                pid_path=root / "conductor.pid",
                lock_path=root / "conductor.lock",
                jobs_dir=jobs_dir,
                daemon_log_path=root / "daemon.log",
                daemon_meta_path=root / "daemon.json",
                running_processes_path=root / "running.json",
            )
            state = conductor.DaemonState(paths)
            state.jobs["ticket"] = conductor.Job(
                ticket="ticket",
                request_key=None,
                fingerprint="fingerprint",
                operation="build",
                args={},
                lanes=[],
                timeout=None,
                verbose=False,
                env={},
                created_at=conductor.now(),
                log_path=jobs_dir / "ticket.log",
                state="completed",
                output_summary={"headline": "completed successfully", "sections": []},
            )

            payload = state.list_jobs(None)

        self.assertNotIn("outputSummary", payload["jobs"][0])


class CanonicalSwiftCommandTests(unittest.TestCase):
    def test_build_and_test_pin_native_engine_without_changing_other_arguments(self) -> None:
        # Intercept only exec: exercise the actual shell argument construction
        # without starting Swift or depending on the installed Xcode version.
        for arguments in (
            ["build", "-c", "debug", "--product", "RepoPrompt"],
            ["build", "--show-bin-path"],
            ["build", "--build-tests"],
            ["test", "list", "--skip-build"],
            ["test", "--skip-build", "--filter", "Suite/test with spaces"],
            ["--version"],
            [],
        ):
            with self.subTest(arguments=arguments):
                result = self.run_wrapper(arguments)[0]
                self.assertEqual(result.returncode, 0)
                argv = result.stdout.decode().split("\0")[:-1]
                swift_index = argv.index("/usr/bin/swift")
                expected = list(arguments)
                if arguments and arguments[0] in {"build", "test"}:
                    expected[1:1] = ["--build-system", "native", "--disable-index-store", "--no-color-diagnostics"]
                self.assertEqual(argv[swift_index + 1:], expected)
                self.assertEqual(argv[:2], ["/usr/bin/env", "-i"])

    # Step 10: debug dSYM policy in the wrapper (classifier, banner, exact hook only).

    def run_wrapper(self, arguments, extra_env=None, wrapper=None):
        env = {key: value for key, value in os.environ.items()
               if key not in {"RPCE_DEBUG_DSYM", "RPCE_INDEX_STORE", "REPOPROMPT_ENABLE_SENTRY",
                              "SWIFT_DRIVER_DSYMUTIL_EXEC"}}
        env.update(extra_env or {})
        result = subprocess.run(
            [
                "/bin/bash", "-c",
                'exec() { printf "%s\\0" "$@"; }; wrapper="$1"; shift; source "$wrapper" "$@"',
                "canonical-swift-test", str(wrapper or SCRIPT_DIR / "canonical_swift.sh"), *arguments,
            ],
            check=False, capture_output=True, env=env,
        )
        argv = result.stdout.decode().split("\0")[:-1]
        if not argv:
            return result, None, []
        swift_index = argv.index("/usr/bin/swift")
        return result, argv[2:swift_index], argv[swift_index + 1:]

    def test_unset_policy_is_debug_skip_with_the_exact_hook_and_one_banner(self) -> None:
        result, child_env, swift_args = self.run_wrapper(["build", "--product", "RepoPrompt"],
                                                         {"SWIFT_DRIVER_DSYMUTIL_EXEC": "/caller/value"})
        self.assertEqual(result.returncode, 0)
        hooks = [item for item in child_env if item.startswith("SWIFT_DRIVER_DSYMUTIL_EXEC=")]
        self.assertEqual(hooks, ["SWIFT_DRIVER_DSYMUTIL_EXEC=/usr/bin/true"])
        self.assertFalse(any(item.startswith("RPCE_DEBUG_DSYM=") for item in child_env))
        self.assertEqual(swift_args, ["build", "--build-system", "native", "--disable-index-store",
                                      "--no-color-diagnostics", "--product", "RepoPrompt"])
        stderr = result.stderr.decode()
        self.assertEqual(stderr.count("rpce-debug-dsym:"), 1)
        self.assertIn("requested=off effective=off reason=debug_skip", stderr)
        self.assertNotIn(b"rpce-debug-dsym", result.stdout)

    def test_eligible_debug_invocations_share_one_child_environment(self) -> None:
        environments = set()
        for arguments in (["build", "--product", "RepoPrompt"], ["build", "--build-tests"], ["build", "--show-bin-path"],
                          ["test", "list", "--skip-build"], ["test", "--skip-build", "--filter", "X"],
                          ["build", "-c", "debug", "--product", "repoprompt-mcp"]):
            for extra in ({}, {"RPCE_DEBUG_DSYM": "off"}):
                with self.subTest(arguments=arguments, extra=extra):
                    result, child_env, _ = self.run_wrapper(arguments, extra)
                    self.assertEqual(result.returncode, 0)
                    environments.add(tuple(child_env))
        self.assertEqual(len(environments), 1)

    def test_full_environment_cases_add_no_hook(self) -> None:
        cases = (
            (["build"], {"RPCE_DEBUG_DSYM": "on"}, "reason=requested_on", False),
            (["build", "-c", "release", "--product", "RepoPrompt"], {}, "reason=configuration_release", True),
            (["build", "-c", "debug", "-c", "release"], {"RPCE_DEBUG_DSYM": "off"}, "reason=configuration_conflicting", True),
            (["build", "--unknown-option", "x"], {}, "reason=configuration_unknown", True),
            (["build"], {"REPOPROMPT_ENABLE_SENTRY": "1"}, "reason=sentry", True),
        )
        for arguments, extra, reason, warned in cases:
            with self.subTest(arguments=arguments, extra=extra):
                result, child_env, swift_args = self.run_wrapper(arguments, extra)
                self.assertEqual(result.returncode, 0)
                self.assertFalse(any(item.startswith("SWIFT_DRIVER_DSYMUTIL_EXEC=") for item in child_env))
                self.assertFalse(any(item.startswith("RPCE_DEBUG_DSYM=") for item in child_env))
                stderr = result.stderr.decode()
                self.assertIn(reason, stderr)
                self.assertEqual(stderr.count("rpce-debug-dsym:"), 1)
                self.assertEqual("warning=skip-not-applied" in stderr, warned)
                self.assertEqual(swift_args[0], arguments[0])
                # Index store: requested dSYM on stays index-disabled; ineligible configurations are untouched.
                self.assertEqual("--disable-index-store" in swift_args, reason == "reason=requested_on")
        _, sentry_env, _ = self.run_wrapper(["build"], {"REPOPROMPT_ENABLE_SENTRY": "1"})
        self.assertIn("REPOPROMPT_ENABLE_SENTRY=1", sentry_env)

    def test_invalid_policy_exits_2_before_swift(self) -> None:
        for value in ("", "ON", "true", "skip"):
            with self.subTest(value=value):
                result, child_env, _ = self.run_wrapper(["build"], {"RPCE_DEBUG_DSYM": value})
                self.assertEqual(result.returncode, 2)
                self.assertIsNone(child_env)
                self.assertIn(b"must be 'on' or 'off'", result.stderr)

    # Step 3 (2026-10-08 follow-ups): index store policy.

    def test_index_store_policy_is_argv_only_and_on_adds_nothing(self) -> None:
        arguments = ["build", "--product", "RepoPrompt"]
        disabled = ["build", "--build-system", "native", "--disable-index-store", "--no-color-diagnostics",
                    "--product", "RepoPrompt"]
        for extra, expected in (({}, disabled), ({"RPCE_INDEX_STORE": "off"}, disabled),
                                ({"RPCE_INDEX_STORE": "off", "RPCE_DEBUG_DSYM": "on"}, disabled),
                                ({"RPCE_INDEX_STORE": "on"},
                                 ["build", "--build-system", "native", "--no-color-diagnostics", "--product", "RepoPrompt"]),
                                ({"RPCE_INDEX_STORE": "on", "RPCE_DEBUG_DSYM": "on"},
                                 ["build", "--build-system", "native", "--no-color-diagnostics", "--product", "RepoPrompt"])):
            with self.subTest(extra=extra):
                result, child_env, swift_args = self.run_wrapper(arguments, extra)
                self.assertEqual(result.returncode, 0)
                self.assertEqual(swift_args, expected)
                self.assertFalse(any(item.startswith("RPCE_INDEX_STORE=") for item in child_env))
                self.assertEqual(result.stderr.decode().count("rpce-debug-dsym:"), 1)
        for arguments in (["--version"], ["package", "resolve"]):
            with self.subTest(arguments=arguments):
                _, _, swift_args = self.run_wrapper(arguments)
                self.assertEqual(swift_args, arguments)

    def test_queries_and_test_invocations_share_the_index_store_argv_prefix(self) -> None:
        for extra in ({}, {"RPCE_DEBUG_DSYM": "on"}, {"RPCE_INDEX_STORE": "on"}):
            prefixes = set()
            for arguments in (["build", "--product", "RepoPrompt"], ["build", "-c", "debug", "--show-bin-path"],
                              ["test", "list", "--skip-build"], ["test", "--skip-build", "--filter", "X"]):
                with self.subTest(extra=extra, arguments=arguments):
                    _, _, swift_args = self.run_wrapper(arguments, extra)
                    self.assertIn("--no-color-diagnostics", swift_args)
                    prefixes.add(tuple(swift_args[1:4]) if "--disable-index-store" in swift_args else tuple(swift_args[1:3]))
            self.assertEqual(len(prefixes), 1)

    def test_invalid_index_store_policy_exits_2_before_swift(self) -> None:
        for value in ("", "ON", "bogus"):
            with self.subTest(value=value):
                result, child_env, _ = self.run_wrapper(["build"], {"RPCE_INDEX_STORE": value})
                self.assertEqual(result.returncode, 2)
                self.assertIsNone(child_env)
                self.assertIn(b"RPCE_INDEX_STORE must be 'on' or 'off'", result.stderr)
                self.assertNotIn(b"rpce-debug-dsym:", result.stderr)

    def test_index_store_eligibility_recheck_fails_loudly(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            wrapper = Path(tmp) / "canonical_swift.sh"
            wrapper.write_bytes((SCRIPT_DIR / "canonical_swift.sh").read_bytes())
            helper = Path(tmp) / "debug_dsym.py"
            for recheck, code in ("raise SystemExit(5)", 5), ("print('maybe')", 70):
                with self.subTest(recheck=recheck):
                    helper.write_text("import os\nif os.environ.get('RPCE_DEBUG_DSYM') == 'off':\n    "
                                      f"{recheck}\nprint('on')\n")
                    result, child_env, _ = self.run_wrapper(["build"], {"RPCE_DEBUG_DSYM": "on"}, wrapper=wrapper)
                    self.assertEqual(result.returncode, code)
                    self.assertIsNone(child_env)
                    self.assertIn(b"index store eligibility", result.stderr)

    def test_conductor_forwards_index_store_policy_verbatim(self) -> None:
        self.assertIn("RPCE_INDEX_STORE", conductor.OperationRegistry.PASSTHROUGH_ENV_KEYS)
        for value in ("on", "off", "", "bogus"):
            with self.subTest(value=value), mock.patch.dict(os.environ, {"RPCE_INDEX_STORE": value}):
                self.assertEqual(conductor.OperationRegistry.client_env_snapshot()["RPCE_INDEX_STORE"], value)
                request = {"operation": "build", "args": {}, "env": {"RPCE_INDEX_STORE": value}}
                self.assertEqual(conductor.OperationRegistry._request_env_snapshot(request)["RPCE_INDEX_STORE"], value)

    def test_classifier_failure_fails_before_swift(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            wrapper = Path(tmp) / "canonical_swift.sh"
            wrapper.write_bytes((SCRIPT_DIR / "canonical_swift.sh").read_bytes())
            result, child_env, _ = self.run_wrapper(["build"], wrapper=wrapper)  # no adjacent helper
            self.assertNotEqual(result.returncode, 0)
            self.assertIsNone(child_env)
            (Path(tmp) / "debug_dsym.py").write_text("import sys\nprint('maybe')\n")
            result, child_env, _ = self.run_wrapper(["build"], wrapper=wrapper)
            self.assertEqual(result.returncode, 70)
            self.assertIsNone(child_env)

    def test_final_exec_line_is_unchanged_and_the_wrapper_never_touches_symbols(self) -> None:
        text = (SCRIPT_DIR / "canonical_swift.sh").read_text()
        lines = [line for line in text.splitlines() if line.strip()]
        self.assertEqual(lines[-1], 'exec /usr/bin/env -i "${swift_env[@]}" /usr/bin/swift "$@"')
        code = "\n".join(line for line in lines if not line.lstrip().startswith("#"))
        for forbidden in ("rm ", "rmdir", "mv ", "xcrun", "dsymutil ", "find "):
            self.assertNotIn(forbidden, code)


class JobTicketEnvEligibilityTests(unittest.TestCase):
    def test_direct_swift_invocations_do_not_receive_job_ticket_env(self) -> None:
        self.assertFalse(conductor.job_ticket_env_eligible(["swift", "test", "--filter", "X"]))
        self.assertFalse(conductor.job_ticket_env_eligible(["/usr/bin/swift", "build", "--product", "RepoPrompt"]))
        self.assertFalse(
            conductor.job_ticket_env_eligible(
                ["/repo/Scripts/canonical_swift.sh", "build", "--product", "RepoPrompt"]
            )
        )

    def test_delegated_scripts_receive_job_ticket_env(self) -> None:
        self.assertTrue(conductor.job_ticket_env_eligible(["/repo/Scripts/package_app.sh", "debug"]))
        self.assertTrue(conductor.job_ticket_env_eligible(["python3", "Scripts/debug_app_process.py"]))
        self.assertTrue(conductor.job_ticket_env_eligible([]))


# ---------------------------------------------------------------------------
# Step 2 passive timing integration

metrics = conductor.PIPELINE_METRICS

TELEMETRY_STREAMS = {
    "lf-lines": [b"[1/3] Compiling Foo a.swift\n", b"[2/3] Compiling Foo b.swift\n[3/3] Linking foo\n", b""],
    "bare-cr-progress": [b"[1/4] Compiling A a.swift\r[2/4] Comp", b"iling A b.swift\r", b"\n[3/4] Linking a\n", b""],
    "crlf-across-reads": [b"Build complete! (0.10s)\r", b"\nTest Suite 'All tests' started at 2026-10-05 10:00:00.000.\r\n", b""],
    "split-utf8-and-tail": [b"\xe2\x9c", b"\x93 done\n\xff bad\rTest Case '-[A.B testC]' started.\n", b"unterminated", b""],
    "xctest-methods": [
        b"Test Case '-[A.B testOne]' started.\nTest Case '-[A.B testOne]' passed (0.001 seconds).\n",
        b"Test Case '-[A.B testTwo]' started.\nTest Case '-[A.B testTwo]' failed (0.002 seconds).\n",
        b"",
    ],
    "onlcr-pty": [b"[1/2] Compiling P p.swift\r\r\n[2/2] Linking p\r\n", b"$ next\r\n", b""],
}


def timing_paths(root: Path) -> conductor.Paths:
    jobs_dir = root / "jobs"
    jobs_dir.mkdir(parents=True, exist_ok=True)
    return conductor.Paths(
        repo_root=root,
        repo_hash="test",
        state_dir=root,
        socket_path=root / "conductor.sock",
        pid_path=root / "conductor.pid",
        lock_path=root / "conductor.lock",
        jobs_dir=jobs_dir,
        daemon_log_path=root / "daemon.log",
        daemon_meta_path=root / "daemon.json",
        running_processes_path=root / "running.json",
    )


def timing_state(root: Path, timing: str = "on") -> conductor.DaemonState:
    env = {key: value for key, value in os.environ.items() if key != "RPCE_CONDUCTOR_TIMING"}
    if timing == "off":
        env["RPCE_CONDUCTOR_TIMING"] = "off"
    with mock.patch.dict(os.environ, env, clear=True):
        return conductor.DaemonState(timing_paths(root))


def timing_job(state: conductor.DaemonState, ticket: str, operation: str = "build") -> conductor.Job:
    job = conductor.Job(
        ticket=ticket,
        request_key=None,
        fingerprint="fingerprint",
        operation=operation,
        args={},
        lanes=["style"],
        timeout=None,
        verbose=False,
        env={},
        created_at=conductor.now(),
        log_path=state.paths.jobs_dir / f"{ticket}.log",
        state="running",
        telemetry=state.attach_job_telemetry(operation),
    )
    state.jobs[ticket] = job
    return job


def capture_pump(state: conductor.DaemonState, job: conductor.Job, chunks: list[bytes], observed: bool) -> dict:
    writes: list[bytes] = []
    progress: list[str] = []
    sink = mock.Mock()
    sink.write.side_effect = writes.append
    original_apply = state._apply_xctest_progress_line_locked

    def record_progress(target: conductor.Job, line: str, marker: Any, timestamp: float, observed_at: float) -> Any:
        progress.append(line)
        return original_apply(target, line, marker, timestamp, observed_at)

    with mock.patch.object(state, "_apply_xctest_progress_line_locked", side_effect=record_progress):
        cursor = None
        if observed:
            cursor = state._output_telemetry_cursor(job.ticket)
            assert cursor is not None
        state._pump_output(job.ticket, iter(chunks).__next__, sink, cursor)
    return {
        "writes": writes,
        "flushes": sink.flush.call_count,
        "tail": list(job.tail),
        "progress": progress,
        "xctest": (job.xctest_started_count, job.xctest_last_progress_test, job.xctest_last_progress_action),
    }


class GuardedRecorderLock:
    """Recorder lock proxy that records any acquisition under the scheduler lock."""

    def __init__(self, inner: Any, state: conductor.DaemonState, held: threading.local, violations: list[str]) -> None:
        self.inner = inner
        self.state = state
        self.held = held
        self.violations = violations

    def __enter__(self) -> Any:
        if self.state.lock._is_owned():
            self.violations.append("recorder lock taken while holding self.condition")
        result = self.inner.__enter__()
        self.held.depth = getattr(self.held, "depth", 0) + 1
        return result

    def __exit__(self, *exc: Any) -> Any:
        self.held.depth -= 1
        return self.inner.__exit__(*exc)


class GuardedSchedulerLock:
    """Scheduler lock/condition proxy that records acquisition under a recorder lock."""

    def __init__(self, inner: Any, held: threading.local, violations: list[str]) -> None:
        self.inner = inner
        self.held = held
        self.violations = violations

    def __enter__(self) -> Any:
        if getattr(self.held, "depth", 0):
            self.violations.append("self.condition taken while holding the recorder lock")
        return self.inner.__enter__()

    def __exit__(self, *exc: Any) -> Any:
        return self.inner.__exit__(*exc)

    def __getattr__(self, name: str) -> Any:
        return getattr(self.inner, name)


@unittest.skipIf(metrics is None, "swift_pipeline_metrics.py is unavailable")
class PhaseTimingIntegrationTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)

    def make_state(self, name: str, timing: str = "on") -> conductor.DaemonState:
        state = timing_state(self.root / name, timing)
        # Persistence finishes after ``job_wait`` (A009); drain before the tempdir goes.
        self.addCleanup(state._await_job_telemetry, 10.0)
        return state

    def settled(self, state: conductor.DaemonState, waited: dict) -> dict:
        """Private drain, then the job's status: timing is published after the result."""
        self.assertEqual(waited["state"], "completed")
        self.assertIsNotNone(waited.get("outputSummary"))
        self.assertTrue(state._await_job_telemetry(10.0, state.jobs[waited["ticket"]]))
        return state.job_status(waited["ticket"], None)

    def install_lock_guards(self, state: conductor.DaemonState) -> list[str]:
        violations: list[str] = []
        held = threading.local()
        state.condition = GuardedSchedulerLock(state.condition, held, violations)
        state.lock = GuardedSchedulerLock(state.lock, held, violations)
        original_attach = state.attach_job_telemetry

        def attach(operation: str, accepted_ns: Optional[int] = None) -> Any:
            recorder = original_attach(operation, accepted_ns)
            if recorder is not None:
                recorder._lock = GuardedRecorderLock(recorder._lock, state, held, violations)
            return recorder

        state.attach_job_telemetry = attach  # type: ignore[method-assign]
        return violations

    def run_child_job(self, state: conductor.DaemonState, child: str, request_extra: Optional[dict] = None) -> dict:
        argv = [sys.executable, "-u", "-c", child]
        request = {"operation": "build", "args": {}, "env": {}}
        request.update(request_extra or {})
        with mock.patch.object(
            state.registry,
            "prepare",
            side_effect=lambda _request: (argv, ["style"], state.paths.repo_root, {"PATH": os.environ.get("PATH", "")}, 30.0),
        ), mock.patch.object(conductor, "operation_requires_global_heavy_slot", return_value=False):
            enqueued = state.enqueue(request)
            return state.job_wait(enqueued["ticket"], None, 30.0)

    CHILD = (
        "import sys\n"
        "print('[1/3] Compiling Foo a.swift', flush=True)\n"
        "sys.stdout.write('[2/3] Compiling Foo b.swift\\r[3/3] Linking foo\\r\\n'); sys.stdout.flush()\n"
        "sys.stdout.write('Build complete! (0.10s)\\nno newline'); sys.stdout.flush()\n"
    )

    def test_helper_is_loaded_next_to_conductor_and_digest_is_reported(self) -> None:
        self.assertEqual(Path(metrics.__file__).resolve(), Path(conductor.__file__).resolve().with_name("swift_pipeline_metrics.py"))
        self.assertTrue(str(conductor.CONDUCTOR_DIGEST).startswith("sha256:"))
        state = self.make_state("status")
        status = state.status_payload()
        self.assertEqual(status["conductorDigest"], conductor.CONDUCTOR_DIGEST)
        self.assertTrue(status["timingEnabled"])
        self.assertEqual(status["protocolVersion"], conductor.PROTOCOL_VERSION)
        self.assertEqual(status["protocolVersion"], 20)
        self.assertFalse(self.make_state("off", timing="off").status_payload()["timingEnabled"])

    def test_observed_pump_preserves_raw_bytes_tail_and_progress_for_every_stream(self) -> None:
        for name, chunks in TELEMETRY_STREAMS.items():
            with self.subTest(stream=name):
                legacy_state = self.make_state(f"legacy-{name}", timing="off")
                legacy = capture_pump(legacy_state, timing_job(legacy_state, "t"), chunks, observed=False)
                observed_state = self.make_state(f"observed-{name}")
                observed_job = timing_job(observed_state, "t")
                observed = capture_pump(observed_state, observed_job, chunks, observed=True)
                self.assertEqual(observed, legacy)
                self.assertEqual(observed["writes"], [chunk for chunk in chunks if chunk])
                # Telemetry equals the reference splitter fed the same reads.
                splitter = metrics.RecordSplitter()
                reference = metrics.PipelineRecorder(origin_ns=0)
                for chunk in chunks[:-1]:
                    reference.observe_records(splitter.feed(chunk, 0))
                reference.observe_records(splitter.finish(0))
                payload = observed_job.telemetry.finalize()
                self.assertTrue(payload["output"]["complete"])
                self.assertEqual(payload["output"]["records"], reference.finalize()["output"]["records"])

    def test_receipt_timestamp_precedes_write_flush_and_scheduler_lock(self) -> None:
        state = self.make_state("order")
        job = timing_job(state, "t")
        order: list[str] = []
        chunks = [b"[1/2] Compiling A a.swift\n", b"partial\r", b""]
        reads = iter(chunks)
        real_monotonic_ns = time.monotonic_ns

        def read_chunk() -> bytes:
            order.append("read")
            return next(reads)

        def stamp() -> int:
            order.append("stamp-locked" if state.lock._is_owned() else "stamp")
            return real_monotonic_ns()

        sink = mock.Mock()
        sink.write.side_effect = lambda _chunk: order.append("write")
        sink.flush.side_effect = lambda: order.append("flush")
        cursor = state._output_telemetry_cursor(job.ticket)
        with mock.patch.object(conductor.time, "monotonic_ns", side_effect=stamp):
            state._pump_output(job.ticket, read_chunk, sink, cursor)
        self.assertEqual(order[:4], ["read", "stamp", "write", "flush"])
        self.assertEqual(order[4:8], ["read", "stamp", "write", "flush"])
        self.assertEqual(order[8:10], ["read", "stamp"])
        self.assertNotIn("stamp-locked", order)
        payload = job.telemetry.finalize()
        self.assertEqual(payload["output"]["records"], 2)

    def test_read_process_output_passes_no_cursor_without_a_recorder(self) -> None:
        # Step 3: one bounded pump for every job; telemetry only adds a cursor.
        for timing, attach, expect_cursor in (("off", True, False), ("on", False, False), ("on", True, True)):
            with self.subTest(timing=timing, attach=attach):
                state = self.make_state(f"dispatch-{timing}-{attach}", timing)
                job = timing_job(state, "t")
                if not attach:
                    job.telemetry = None
                transport = mock.Mock()
                transport.read_chunk.side_effect = [b"line\n", b""]
                with mock.patch.object(state, "_pump_output", wraps=state._pump_output) as pump:
                    state._read_process_output(job.ticket, mock.Mock(), io.BytesIO(), transport)
                pump.assert_called_once()
                self.assertEqual(pump.call_args.args[3] is not None, expect_cursor)
                self.assertEqual(list(job.tail), ["line\n"])
                transport.close_reader.assert_called_once()

    def test_end_to_end_job_records_boundaries_persists_and_reports_phase_metrics(self) -> None:
        state = self.make_state("e2e")
        violations = self.install_lock_guards(state)
        client = [
            {"name": "artifact_evaluation", "durationNs": 1500, "counters": {"bytesHashed": 7}},
            {"name": 5, "durationNs": 1},
            "junk",
        ]
        payload = self.settled(state, self.run_child_job(state, self.CHILD, {"clientMetrics": client}))

        self.assertEqual(violations, [])
        self.assertEqual(payload["state"], "completed")
        self.assertEqual(payload["conductorDigest"], conductor.CONDUCTOR_DIGEST)
        phase = payload["phaseMetrics"]
        self.assertEqual(phase["schema"], 1)
        self.assertEqual(phase["status"], "complete", phase)
        for name in ("queueWait", "prepare", "spawn", "spawnToFirstOutput", "processObserved", "postRunProvenance", "exitToLaneRelease", "acceptedToLaneRelease"):
            self.assertIsInstance(phase["intervals"][name]["ns"], int, name)
        self.assertEqual(phase["intervals"]["sourceSnapshot"]["quality"], "not_applicable")
        self.assertEqual(phase["output"]["records"], 5)
        self.assertTrue(phase["output"]["complete"])
        self.assertEqual(phase["commandCount"], 1)
        operations = {(item["name"], item["origin"]): item for item in phase["operations"]}
        self.assertEqual(operations[("output_summary", "daemon.summary")]["calls"], 1)
        self.assertIn(("retention_pass", "daemon.enqueue"), operations)
        self.assertIn(("retention_pass", "daemon.lane_release"), operations)
        self.assertEqual(operations[("output_reader_cpu", "daemon.reader")]["total"]["quality"], "measured_cpu")
        client_op = operations[("artifact_evaluation", "client")]
        self.assertEqual(client_op["total"], {"ns": 1500, "quality": "reported_duration"})
        self.assertEqual(client_op["counters"], {"bytesHashed": 7})
        self.assertEqual(phase["invalidInputs"], 0)

        ticket = payload["ticket"]
        jobs_dir = state.paths.jobs_dir
        events = [json.loads(line) for line in (jobs_dir / f"{ticket}.timing-events.jsonl").read_text().splitlines()]
        boundaries = [event["name"] for event in events if event["k"] == "boundary"]
        self.assertEqual(
            boundaries,
            ["request_accepted", "lane_dispatched", "prepare_start", "prepare_end", "command_start",
             "popen_before", "popen_after", "exit_observed", "provenance_start", "provenance_end", "lane_released"],
        )
        self.assertTrue(set(boundaries) <= metrics.KNOWN_BOUNDARIES)
        timings = json.loads((jobs_dir / f"{ticket}.timings.json").read_text())
        self.assertEqual(timings["conductorDigest"], conductor.CONDUCTOR_DIGEST)
        self.assertEqual(timings["phaseMetrics"], phase)
        self.assertIsNone(timings["runner"])
        rows, malformed = metrics.RotatingJsonl(conductor.timing_history_path(state.paths)).read_rows()
        self.assertEqual(malformed, 0)
        self.assertEqual([row["ticket"] for row in rows], [ticket])
        self.assertEqual(rows[0]["conductorDigest"], conductor.CONDUCTOR_DIGEST)
        self.assertEqual(rows[0]["exitCode"], 0)
        # Status listings stay compact: no phaseMetrics without include_summary.
        self.assertNotIn("phaseMetrics", state.list_jobs(None)["jobs"][0])

    def test_kill_switch_produces_identical_output_and_no_timing_artifacts(self) -> None:
        on_state = self.make_state("on")
        off_state = self.make_state("off", timing="off")
        on = self.run_child_job(on_state, self.CHILD)
        off = self.run_child_job(off_state, self.CHILD)
        self.assertEqual(off["phaseMetrics"], {"schema": 1, "status": "disabled"})
        self.assertIsNone(off_state.jobs[off["ticket"]].telemetry)
        self.assertEqual(
            Path(on["logPath"]).read_bytes(), Path(off["logPath"]).read_bytes()
        )
        self.assertEqual(on["logTail"], off["logTail"])
        self.assertEqual(on["outputSummary"], off["outputSummary"])
        self.assertEqual(sorted(path.name for path in off_state.paths.jobs_dir.iterdir()), [f"{off['ticket']}.log"])
        self.assertFalse((off_state.paths.state_dir / "metrics").exists())

    def test_telemetry_failures_never_change_job_result_or_output(self) -> None:
        baseline = self.run_child_job(self.make_state("baseline", timing="off"), self.CHILD)

        classifier_state = self.make_state("classifier")
        with mock.patch.object(metrics, "classify_record", side_effect=RuntimeError("boom")):
            failed = self.settled(classifier_state, self.run_child_job(classifier_state, self.CHILD))
        self.assertEqual(failed["state"], "completed")
        self.assertEqual(Path(failed["logPath"]).read_bytes(), Path(baseline["logPath"]).read_bytes())
        self.assertEqual(failed["logTail"], baseline["logTail"])
        self.assertEqual(failed["phaseMetrics"]["status"], "partial")
        self.assertFalse(failed["phaseMetrics"]["output"]["complete"])
        self.assertIn("RuntimeError", failed["phaseMetrics"]["output"]["error"])

        persist_state = self.make_state("persist")
        with mock.patch.object(metrics, "write_events_jsonl", side_effect=OSError("disk full")):
            persisted = self.settled(persist_state, self.run_child_job(persist_state, self.CHILD))
        self.assertEqual(persisted["state"], "completed")
        self.assertEqual(persisted["exitCode"], 0)
        self.assertIn("disk full", persisted["phaseMetricsPersistError"])
        self.assertEqual(persisted["phaseMetrics"]["status"], "complete")
        self.assertFalse((persist_state.paths.state_dir / "metrics").exists())

        recorder_state = self.make_state("recorder")
        with mock.patch.object(metrics.PipelineRecorder, "record_boundary", side_effect=RuntimeError("x")):
            boundary_failed = self.run_child_job(recorder_state, self.CHILD)
        self.assertEqual(boundary_failed["state"], "completed")
        self.assertEqual(Path(boundary_failed["logPath"]).read_bytes(), Path(baseline["logPath"]).read_bytes())

    def test_slot_wait_records_contention_only_when_a_foreign_holder_blocks(self) -> None:
        state = self.make_state("slots")
        lock_root = self.root / "machine-locks"
        lock_root.mkdir(mode=0o700)
        with mock.patch.object(conductor, "machine_lock_dir", return_value=lock_root), mock.patch.object(
            conductor, "GLOBAL_HEAVY_SLOT_POLL_SECONDS", 0.01
        ):
            free_job = timing_job(state, "free")
            slot = state._acquire_global_slot("free", "heavy")
            state._release_global_slot(slot)

            busy_job = timing_job(state, "busy")
            holder = (lock_root / "global-heavy-0.lock").open("a+")
            fcntl.flock(holder.fileno(), fcntl.LOCK_EX)
            releaser = threading.Timer(0.1, lambda: (fcntl.flock(holder.fileno(), fcntl.LOCK_UN), holder.close()))
            releaser.start()
            slot = state._acquire_global_slot("busy", "heavy")
            releaser.join()
            state._release_global_slot(slot)

        free = free_job.telemetry.finalize()["slotWaits"]
        busy = busy_job.telemetry.finalize()["slotWaits"]
        self.assertEqual([(item["slot"], item["contended"]) for item in free], [("heavy", False)])
        self.assertEqual([(item["slot"], item["contended"]) for item in busy], [("heavy", True)])
        self.assertGreaterEqual(busy[0]["ns"], 50_000_000)

    def test_retention_removes_timing_files_of_pruned_and_orphaned_tickets(self) -> None:
        state = self.make_state("retention")
        jobs_dir = state.paths.jobs_dir
        kept = timing_job(state, "kept")
        kept.state = "completed"
        kept.finished_at = conductor.now()
        pruned = timing_job(state, "pruned")
        pruned.state = "completed"
        pruned.finished_at = conductor.now() - conductor.TERMINAL_RETENTION_SECONDS - 10
        old = time.time() - conductor.TERMINAL_RETENTION_SECONDS - 10
        # Orphan sweeps match only daemon-generated (uuid) tickets (Step 5).
        orphan, fresh_orphan = "0d6f2c1e-5a7b-4c3d-9e8f-102938475601", "0d6f2c1e-5a7b-4c3d-9e8f-102938475602"
        for ticket in ("kept", "pruned", orphan, fresh_orphan):
            for suffix in conductor.TIMING_FILE_SUFFIXES:
                path = jobs_dir / f"{ticket}{suffix}"
                path.write_text("{}")
                if ticket != fresh_orphan:
                    os.utime(path, (old, old))
        with state.condition:
            state._retention_pass_locked()
        # Step 5: the pass only decides; the maintenance worker deletes off the lock.
        self.assertTrue(state._await_maintenance(10.0))
        remaining = sorted(path.name for path in jobs_dir.iterdir() if "timing" in path.name)
        expected = sorted(f"{ticket}{suffix}" for ticket in ("kept", fresh_orphan) for suffix in conductor.TIMING_FILE_SUFFIXES)
        self.assertEqual(remaining, expected)
        self.assertNotIn("pruned", state.jobs)

    def test_metrics_command_reads_history_client_side_with_filters(self) -> None:
        state = self.make_state("cli")
        history = metrics.RotatingJsonl(conductor.timing_history_path(state.paths))
        for ticket, kind in (("a", "build"), ("b", "test"), ("c", "build")):
            history.append({"ticket": ticket, "kind": kind, "status": "complete", "intervals": {"queueWait": {"ns": 2_000_000, "quality": "measured_wall"}}})
        with mock.patch.object(conductor, "request_daemon", side_effect=AssertionError("no daemon")):
            with contextlib.redirect_stdout(io.StringIO()) as output:
                self.assertEqual(conductor.handle_metrics_command(state.paths, ["--kind", "build", "--last", "1", "--json"]), 0)
            report = json.loads(output.getvalue())
            self.assertEqual([row["ticket"] for row in report["rows"]], ["c"])
            self.assertEqual(report["totalRows"], 3)
            with contextlib.redirect_stdout(io.StringIO()) as output:
                self.assertEqual(conductor.handle_metrics_command(state.paths, ["--ticket", "b"]), 0)
        text = output.getvalue()
        self.assertIn("1 of 3 rows", text)
        self.assertIn("queue=2.0ms", text)
        with self.assertRaises(conductor.ConductorError):
            conductor.handle_metrics_command(state.paths, ["--last", "-1"])
        self.assertIn("./conductor metrics [--last N] [--kind K] [--ticket T] [--json]", conductor.HELP)
        self.assertIn("RPCE_CONDUCTOR_TIMING=off", conductor.HELP)

    def test_client_metrics_are_outside_request_identity(self) -> None:
        state = self.make_state("identity")
        request = {"operation": "build", "args": {}, "env": {}}
        with_metrics = dict(request, clientMetrics=[{"name": "artifact_evaluation", "durationNs": 5}])
        self.assertEqual(state.registry.fingerprint(request), state.registry.fingerprint(with_metrics))
        collected: list[dict] = []
        sink = conductor.client_metrics_sink(collected)
        for index in range(conductor.CLIENT_METRICS_MAX_ITEMS + 5):
            sink("op", index, {"bytesHashed": 1})
        sink("missing", None)
        self.assertEqual(len(collected), conductor.CLIENT_METRICS_MAX_ITEMS)
        self.assertEqual(collected[0], {"name": "op", "durationNs": 0, "counters": {"bytesHashed": 1}})

    def test_artifact_fingerprint_sink_counts_bytes_and_files_without_changing_result(self) -> None:
        artifact = self.root / "products" / "Example.xctest"
        executable = artifact / "Contents" / "MacOS" / "Example"
        executable.parent.mkdir(parents=True)
        executable.write_bytes(b"x" * 3000)
        (artifact / "Contents" / "Info.plist").write_bytes(b"y" * 200)
        bundle = self.root / "products" / "Resources.bundle"
        bundle.mkdir()
        (bundle / "data").write_bytes(b"z" * 50)
        calls: list[tuple] = []
        plain = conductor.test_artifact_fingerprint(artifact)
        explicit = conductor.test_artifact_fingerprint(artifact, sink=lambda *call: calls.append(call))
        with conductor.artifact_operation_sink(lambda *call: calls.append(call)):
            ambient = conductor.test_artifact_fingerprint(artifact)
        self.assertEqual(plain, explicit)
        self.assertEqual(plain, ambient)
        self.assertEqual([call[0] for call in calls], ["artifact_fingerprint", "artifact_fingerprint"])
        self.assertEqual(calls[0][2], {"bytesHashed": 3250, "filesHashed": 3})
        self.assertIsInstance(calls[0][1], int)
        failing = conductor.test_artifact_fingerprint(artifact, sink=mock.Mock(side_effect=RuntimeError("sink")))
        self.assertEqual(failing, plain)

    def test_runner_writes_its_own_timings_and_hides_the_path_from_descendants(self) -> None:
        target = self.root / "jobs-runner"
        target.mkdir()
        path = target / "t.runner-timings.json"
        env = {conductor.TIMING_RUNNER_PATH_ENV_KEY: str(path), "REPOPROMPT_CONDUCTOR_JOB_TICKET": "t"}
        with mock.patch.dict(os.environ, env), contextlib.redirect_stderr(io.StringIO()):
            code = conductor.run_operation_runner(json.dumps({"kind": "no-such-kind", "repoRoot": str(self.root)}))
            self.assertNotIn(conductor.TIMING_RUNNER_PATH_ENV_KEY, os.environ)
        self.assertEqual(code, 2)
        runner = json.loads(path.read_text())
        self.assertEqual(runner["process"], "runner")
        self.assertEqual(runner["ticket"], "t")
        self.assertEqual(runner["conductorDigest"], conductor.CONDUCTOR_DIGEST)
        self.assertEqual(runner["phaseMetrics"]["process"], "runner")
        self.assertEqual(conductor.read_runner_timings(path), runner)
        with contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(conductor.run_operation_runner(json.dumps({"kind": "no-such-kind"})), 2)

    def test_runner_timing_path_is_only_given_to_conductor_runner_children(self) -> None:
        state = self.make_state("runner-env")
        seen: list[dict] = []
        real_popen = conductor.subprocess.Popen
        runner_argv = state.registry._internal_argv("app_status", {})
        plain_argv = [sys.executable, "-c", "pass"]

        def capture(argv: Any, *args: Any, **kwargs: Any) -> Any:
            if argv in (runner_argv, plain_argv):
                seen.append(dict(kwargs["env"]))
                return real_popen(plain_argv, *args, **kwargs)
            return real_popen(argv, *args, **kwargs)

        tickets: list[str] = []
        for argv in (runner_argv, plain_argv):
            with mock.patch.object(
                state.registry, "prepare", return_value=(argv, ["style"], self.root, {}, 30.0)
            ), mock.patch.object(conductor, "operation_requires_global_heavy_slot", return_value=False), mock.patch.object(
                conductor.subprocess, "Popen", side_effect=capture
            ):
                enqueued = state.enqueue({"operation": "build", "args": {}, "env": {}})
                tickets.append(enqueued["ticket"])
                self.assertEqual(state.job_wait(enqueued["ticket"], None, 30.0)["state"], "completed")
        self.assertEqual(len(seen), 2)
        self.assertEqual(
            seen[0][conductor.TIMING_RUNNER_PATH_ENV_KEY],
            str(state.paths.jobs_dir / f"{tickets[0]}.runner-timings.json"),
        )
        self.assertNotIn(conductor.TIMING_RUNNER_PATH_ENV_KEY, seen[1])

    # -- review r2 Step 2 P1 regressions ----------------------------------------

    def hold_history_lock(self, state: conductor.DaemonState) -> Any:
        history = conductor.timing_history_path(state.paths)
        history.parent.mkdir(parents=True, exist_ok=True)
        holder = history.with_name(history.name + ".lock").open("a+")
        fcntl.flock(holder.fileno(), fcntl.LOCK_EX)
        self.addCleanup(holder.close)
        return holder

    def test_held_history_lock_never_delays_the_job_result(self) -> None:
        # OracleA-009: optional persistence must not gate the result or summary.
        state = self.make_state("history-lock")
        state.timing_history.lock_timeout = 30.0
        holder = self.hold_history_lock(state)
        safety = threading.Timer(8.0, lambda: fcntl.flock(holder.fileno(), fcntl.LOCK_UN))
        safety.start()
        self.addCleanup(safety.cancel)
        started = time.monotonic()
        waited = self.run_child_job(state, self.CHILD)
        elapsed = time.monotonic() - started
        job = state.jobs[waited["ticket"]]
        self.assertLess(elapsed, 3.0)
        self.assertEqual((waited["state"], waited["exitCode"]), ("completed", 0))
        self.assertIsNotNone(waited["outputSummary"])
        self.assertFalse(job.telemetry_persisted)  # still blocked on the history lock
        self.assertIn(waited["phaseMetrics"]["status"], {"pending", "complete"})
        fcntl.flock(holder.fileno(), fcntl.LOCK_UN)
        status = self.settled(state, waited)
        self.assertNotIn("phaseMetricsPersistError", status)
        self.assertEqual(status["phaseMetrics"]["status"], "complete")
        rows, _ = metrics.RotatingJsonl(conductor.timing_history_path(state.paths)).read_rows()
        self.assertEqual([row["ticket"] for row in rows], [waited["ticket"]])

        # A lock held past the bounded deadline becomes a persistence error.
        stuck = self.make_state("history-lock-timeout")
        stuck.timing_history.lock_timeout = 0.2
        self.hold_history_lock(stuck)
        waited = self.run_child_job(stuck, self.CHILD)
        status = self.settled(stuck, waited)
        self.assertEqual(status["exitCode"], 0)
        self.assertIn("history lock busy", status["phaseMetricsPersistError"])
        self.assertTrue((stuck.paths.jobs_dir / f"{waited['ticket']}.timings.json").exists())

    def enqueue_blocked(self, state: conductor.DaemonState, lane: str) -> conductor.Job:
        """Enqueue a job that stays queued: its lane is held by a foreign ticket."""
        argv = [sys.executable, "-c", "pass"]
        with state.condition:
            state.active_lanes[lane] = "blocker"
        with mock.patch.object(
            state.registry, "prepare", return_value=(argv, [lane], state.paths.repo_root, {}, 30.0)
        ), mock.patch.object(conductor, "operation_requires_global_heavy_slot", return_value=False):
            ticket = state.enqueue({"operation": "build", "args": {}, "env": {}})["ticket"]
        job = state.jobs[ticket]
        self.assertEqual(job.state, "queued")
        return job

    def assert_undispatched_timing_persisted(self, state: conductor.DaemonState, job: conductor.Job) -> None:
        self.assertEqual((job.state, job.exit_code), ("canceled", 130))
        self.assertIsNone(job.telemetry_dispatch_ns)
        self.assertTrue(state._await_job_telemetry(10.0))  # private drain; no status/wait query
        self.assertIsNone(job.telemetry_persist_error)
        jobs_dir = state.paths.jobs_dir
        timings = json.loads((jobs_dir / f"{job.ticket}.timings.json").read_text())
        self.assertTrue((jobs_dir / f"{job.ticket}.timing-events.jsonl").exists())
        phase = timings["phaseMetrics"]
        self.assertEqual(job.phase_metrics, phase)
        self.assertEqual(phase["intervals"]["queueWait"]["quality"], "unavailable")
        self.assertEqual(phase["intervals"]["acceptedToLaneRelease"]["quality"], "unavailable")
        rows, _ = metrics.RotatingJsonl(conductor.timing_history_path(state.paths)).read_rows()
        self.assertEqual([(row["ticket"], row["exitCode"]) for row in rows], [(job.ticket, 130)])

    def test_queued_cancel_persists_timing_without_a_status_or_wait_query(self) -> None:
        # OracleA-008: terminal before dispatch, never queried.
        state = self.make_state("queued-cancel")
        violations = self.install_lock_guards(state)
        job = self.enqueue_blocked(state, "style")
        state.job_cancel(job.ticket, None)
        self.assert_undispatched_timing_persisted(state, job)
        self.assertEqual(violations, [])

    def test_queued_supersede_persists_timing_without_a_status_or_wait_query(self) -> None:
        state = self.make_state("queued-supersede")
        job = self.enqueue_blocked(state, "liveApp")
        with state.condition:
            superseded, _ = state._supersede_live_app_jobs_locked(mock.Mock(ticket="newer"), "app relaunch")
        self.assertEqual([(item["ticket"], item["cancellationState"]) for item in superseded], [(job.ticket, "canceled")])
        self.assert_undispatched_timing_persisted(state, job)

    def test_queued_force_stop_persists_timing_without_a_status_or_wait_query(self) -> None:
        state = self.make_state("queued-stop")
        job = self.enqueue_blocked(state, "style")
        state.stop(force=True)
        self.assert_undispatched_timing_persisted(state, job)

    @contextlib.contextmanager
    def failing_timing_worker(self, failure: str) -> Any:
        """Fail only the timing worker's thread construction or start; other threads run."""
        real_thread = threading.Thread

        class SelectiveThread(real_thread):  # type: ignore[misc, valid-type]
            def __init__(self, *args: Any, **kwargs: Any) -> None:
                if failure == "construct" and str(kwargs.get("name", "")).startswith("timing-"):
                    raise RuntimeError("injected timing worker construction failure")
                super().__init__(*args, **kwargs)

            def start(self) -> None:
                if failure == "start" and self.name.startswith("timing-"):
                    raise RuntimeError("can't start new thread (injected)")
                super().start()

        with mock.patch.object(conductor.threading, "Thread", SelectiveThread):
            yield

    def assert_timing_worker_failure_recorded(self, state: conductor.DaemonState, job: conductor.Job) -> None:
        self.assertEqual((job.state, job.exit_code), ("canceled", 130))
        self.assertNotIn(job.ticket, state.queue)
        self.assertEqual(state._telemetry_completions, 0)
        self.assertTrue(job.telemetry_persisted)
        self.assertIn("timing worker", job.telemetry_persist_error)
        self.assertTrue(state._await_job_telemetry(1.0))
        status = state.job_status(job.ticket, None)
        self.assertEqual(status["state"], "canceled")
        self.assertEqual(status["phaseMetrics"], {"schema": 1, "status": "failed", "telemetryError": job.telemetry_persist_error})
        self.assertEqual(status["phaseMetricsPersistError"], job.telemetry_persist_error)
        self.assertFalse((state.paths.jobs_dir / f"{job.ticket}.timings.json").exists())
        self.assertFalse(conductor.timing_history_path(state.paths).exists())

    def test_timing_worker_failure_never_escapes_queued_cancel(self) -> None:
        # R3-S2-P1-01: optional timing must not turn a cancellation into an RPC error.
        for failure in ("construct", "start"):
            with self.subTest(failure=failure):
                state = self.make_state(f"cancel-worker-{failure}")
                violations = self.install_lock_guards(state)
                job = self.enqueue_blocked(state, "style")
                with self.failing_timing_worker(failure):
                    payload = state.job_cancel(job.ticket, None)
                self.assertEqual((payload["state"], payload["exitCode"]), ("canceled", 130))
                self.assert_timing_worker_failure_recorded(state, job)
                self.assertEqual(violations, [])

    def test_timing_worker_failure_never_escapes_queued_supersession(self) -> None:
        for failure in ("construct", "start"):
            with self.subTest(failure=failure):
                state = self.make_state(f"supersede-worker-{failure}")
                violations = self.install_lock_guards(state)
                jobs = [self.enqueue_blocked(state, "liveApp") for _ in range(2)]
                with self.failing_timing_worker(failure), state.condition:
                    superseded, _ = state._supersede_live_app_jobs_locked(mock.Mock(ticket="newer"), "app relaunch")
                self.assertEqual(
                    [(item["ticket"], item["cancellationState"]) for item in superseded],
                    [(job.ticket, "canceled") for job in jobs],
                )
                for job in jobs:
                    self.assert_timing_worker_failure_recorded(state, job)
                self.assertEqual(violations, [])

    def test_timing_worker_failure_never_escapes_queued_force_stop(self) -> None:
        for failure in ("construct", "start"):
            with self.subTest(failure=failure):
                state = self.make_state(f"stop-worker-{failure}")
                violations = self.install_lock_guards(state)
                jobs = [self.enqueue_blocked(state, "style") for _ in range(3)]
                server = mock.Mock()
                state.server = server
                with self.failing_timing_worker(failure):
                    payload = state.stop(force=True)
                self.assertTrue(payload["shutdownRequested"])
                deadline = time.monotonic() + 5.0
                while not server.shutdown.called and time.monotonic() < deadline:
                    time.sleep(0.01)
                server.shutdown.assert_called_once_with()  # the original shutdown thread still ran
                for job in jobs:
                    self.assert_timing_worker_failure_recorded(state, job)
                self.assertEqual(violations, [])

    def test_launchd_plist_forwards_the_kill_switch_and_status_reports_the_mode(self) -> None:
        # OracleA-007 / RV-R2-S2-P1-01: launchd does not inherit the client environment.
        paths = timing_paths(self.root / "launchd")
        script = Path(conductor.__file__).resolve()
        for setting in ("off", "on", None):
            env = {key: value for key, value in os.environ.items() if key != conductor.TIMING_ENV_KEY}
            if setting is not None:
                env[conductor.TIMING_ENV_KEY] = setting
            with self.subTest(setting=setting), mock.patch.dict(os.environ, env, clear=True):
                bootstrapped: list[list[str]] = []
                with mock.patch.object(conductor, "bootout_daemon_launchd"), mock.patch.object(
                    conductor, "run_launchctl", side_effect=lambda args: bootstrapped.append(list(args)) or 0
                ), mock.patch.object(conductor, "spawn_daemon_direct") as direct:
                    conductor.spawn_daemon(paths, script)
                direct.assert_not_called()
                plist_path = conductor.daemon_launchd_plist_path(paths)
                self.assertEqual(bootstrapped, [["bootstrap", f"gui/{os.getuid()}", str(plist_path)]])
                with plist_path.open("rb") as handle:
                    environment = conductor.plistlib.load(handle)["EnvironmentVariables"]
                expected = {
                    "REPOPROMPT_DEV_DAEMON_STATE_DIR": str(paths.state_dir),
                    "REPOPROMPT_DEV_DAEMON_SOCKET": str(paths.socket_path),
                }
                if setting is not None:
                    expected[conductor.TIMING_ENV_KEY] = setting
                self.assertEqual(environment, expected)
                # The daemon started with that environment reports the effective mode.
                with mock.patch.dict(os.environ, environment):
                    started = conductor.DaemonState(timing_paths(self.root / f"launchd-{setting}"))
                status = started.status_payload()
                self.assertEqual(status["timingEnabled"], setting != "off")
                self.assertEqual(status["timing"]["setting"], setting)
                self.assertEqual(status["timing"]["readAt"], "daemon start")
                with contextlib.redirect_stdout(io.StringIO()) as rendered:
                    conductor.render_daemon_status(status)
                source = f"RPCE_CONDUCTOR_TIMING={setting}" if setting is not None else "RPCE_CONDUCTOR_TIMING unset"
                mode = "disabled" if setting == "off" else "enabled"
                self.assertIn(f"timing:   {mode} ({source} at daemon start)", rendered.getvalue())
        # The kill switch never enters request identity or job environments.
        state = self.make_state("identity-env")
        request = {"operation": "build", "args": {}, "env": {conductor.TIMING_ENV_KEY: "off"}}
        self.assertNotIn(conductor.TIMING_ENV_KEY, state.registry._request_env_snapshot(request))
        self.assertNotIn(conductor.TIMING_ENV_KEY, conductor.OperationRegistry.PASSTHROUGH_ENV_KEYS)

    def test_daemon_start_reports_a_running_daemon_timing_mismatch_without_restarting(self) -> None:
        paths = timing_paths(self.root / "mismatch")
        running = self.make_state("mismatch-running").status_payload()  # enabled, variable unset
        env = dict(os.environ, **{conductor.TIMING_ENV_KEY: "off"})
        with mock.patch.dict(os.environ, env, clear=True), mock.patch.object(
            conductor, "ensure_daemon", return_value=running
        ) as ensure, mock.patch.object(conductor, "spawn_daemon") as spawn, mock.patch.object(
            conductor, "request_daemon"
        ) as request:
            with contextlib.redirect_stdout(io.StringIO()) as out, contextlib.redirect_stderr(io.StringIO()) as err:
                self.assertEqual(conductor.handle_daemon_command(paths, ["start", "--json"]), 0)
        ensure.assert_called_once_with(paths, start_if_needed=True)
        spawn.assert_not_called()
        request.assert_not_called()
        notice = json.loads(out.getvalue())["timingNotice"]
        self.assertEqual(err.getvalue().strip(), notice)
        self.assertIn("has timing enabled (RPCE_CONDUCTOR_TIMING unset at its start)", notice)
        self.assertIn("asks for disabled", notice)
        self.assertIn("was not restarted", notice)
        self.assertIsNone(conductor.daemon_timing_notice(running, {}))
        self.assertIsNone(conductor.daemon_timing_notice(running, {conductor.TIMING_ENV_KEY: "on"}))
        self.assertIsNone(conductor.daemon_timing_notice({"pid": 1}, {conductor.TIMING_ENV_KEY: "off"}))
        # A daemon whose helper failed to load names that cause, not the variable.
        no_helper = dict(running, timingEnabled=False, timing=dict(running["timing"], enabled=False, helperLoaded=False))
        self.assertIn("(timing helper not loaded at its start)", conductor.daemon_timing_notice(no_helper, {}))
        with contextlib.redirect_stdout(io.StringIO()) as rendered:
            conductor.render_daemon_status(no_helper)
        self.assertIn("timing:   disabled (timing helper not loaded at daemon start)", rendered.getvalue())



# ---------------------------------------------------------------------------
# Step 3: shared streaming splitter, batched reader, bounded tail, summaries.

OUT = conductor.CONDUCTOR_OUTPUT


def split_all(chunks: list[bytes], **kwargs: Any) -> list:
    splitter = OUT.RecordSplitter(**kwargs)
    records: list = []
    for index, chunk in enumerate(chunks):
        records.extend(splitter.feed(chunk, index + 1))
    records.extend(splitter.finish(len(chunks) + 1))
    return records


def shape(records: list) -> list[tuple]:
    return [(record.text, record.delimiter) for record in records]


class Step3SplitterTests(unittest.TestCase):
    def test_helper_is_loaded_next_to_conductor_and_is_part_of_the_digest(self) -> None:
        self.assertEqual(Path(OUT.__file__).resolve(), Path(conductor.__file__).resolve().with_name("conductor_output.py"))
        # conductorDigest (implementation identity) covers the output helper's bytes.
        with tempfile.TemporaryDirectory() as tmp:
            scripts = Path(tmp)
            for name in ("conductor.py", "swift_pipeline_metrics.py", "debug_app_process.py", "conductor_output.py", "conductor_entry.py"):
                (scripts / name).write_bytes((SCRIPT_DIR / name).read_bytes())
            with mock.patch.object(conductor, "__file__", str(scripts / "conductor.py")):
                before = conductor.compute_conductor_digest()
                self.assertEqual(before, conductor.CONDUCTOR_DIGEST)
                # Step 6: the cached-import entry is covered too.
                for name in ("conductor_output.py", "conductor_entry.py"):
                    with (scripts / name).open("a", encoding="utf-8") as handle:
                        handle.write("\n# changed\n")
                    changed = conductor.compute_conductor_digest()
                    self.assertNotEqual(changed, before, name)
                    before = changed

    def test_delimiters_and_cr_swallows_one_lf_across_reads(self) -> None:
        records = split_all([b"a\r", b"\nb\r", b"\r\nc\n\r", b"\n\nd"])
        self.assertEqual(shape(records), [("a", "cr"), ("b", "cr"), ("", "crlf"), ("c", "lf"), ("", "cr"), ("", "lf"), ("d", "eof")])
        self.assertEqual([record.seq for record in records], list(range(7)))

    def test_bare_cr_emits_immediately_with_its_receive_time(self) -> None:
        splitter = OUT.RecordSplitter()
        self.assertEqual(shape(splitter.feed(b"progress 1\r", 10)), [("progress 1", "cr")])
        self.assertEqual(splitter.feed(b"\n", 20), [])  # the swallowed LF emits nothing
        self.assertEqual(splitter.feed(b"\n", 30)[0][1:4], (30, "", "lf"))

    def test_split_utf8_crlf_and_record_completed_by_a_later_read(self) -> None:
        splitter = OUT.RecordSplitter()
        self.assertEqual(splitter.feed(b"\xe2\x9c", 1), [])
        self.assertEqual(splitter.feed(b"\x93 done\r", 2)[0][1:4], (2, "✓ done", "cr"))
        self.assertEqual(splitter.feed(b"\nx\r", 3)[0][1:4], (3, "x", "cr"))
        self.assertEqual(splitter.feed(b"\n", 4), [])
        self.assertEqual(splitter.feed(b"y\r", 5)[0][1:4], (5, "y", "cr"))
        self.assertEqual(splitter.feed(b"z", 6), [])  # the CR did not swallow a non-LF byte
        self.assertEqual(splitter.finish(7)[0][1:4], (7, "z", "eof"))
        self.assertEqual(splitter.finish(8), [])

    def test_bulk_path_equals_the_reference_loop_and_universal_newlines(self) -> None:
        import random

        rng = random.Random(3)
        alphabet = [b"a", b"\xc3\xa9", b"\xe2\x9c\x93", b"\xff", b"\r", b"\n", b"\r\n", b"\x1b[31m", b" ", b"\x0c"]
        for trial in range(40):
            data = b"".join(rng.choice(alphabet) for _ in range(rng.randrange(1, 30000)))
            cuts = sorted(rng.sample(range(1, len(data)), min(len(data) - 1, rng.randrange(0, 12)))) if len(data) > 1 else []
            chunks = [data[start:end] for start, end in zip([0] + cuts, cuts + [len(data)])]
            with self.subTest(trial=trial):
                bulk = split_all(chunks)
                with mock.patch.object(OUT, "_BULK_MIN_BYTES", 1 << 40):
                    slow = split_all(chunks)
                self.assertEqual([record[2:] for record in bulk], [record[2:] for record in slow])
                self.assertEqual([record.seq for record in bulk], list(range(len(bulk))))
                # Universal-newline text reading (the parent summarizer) splits identically.
                universal = [line.rstrip("\n") for line in io.TextIOWrapper(io.BytesIO(data), encoding="utf-8", errors="replace")]
                self.assertEqual([record.text for record in bulk], universal)

    def test_dense_empty_records(self) -> None:
        records = split_all([b"\n" * 5000, b"\r\n" * 3000, b"\r" * 2000])
        self.assertEqual(len(records), 10000)
        self.assertTrue(all(record.text == "" for record in records))
        self.assertEqual({record.delimiter for record in records}, {"lf", "crlf", "cr"})

    def test_unterminated_multi_megabyte_output_is_capped_with_diagnostics(self) -> None:
        splitter = OUT.RecordSplitter()
        payload = bytes(range(32, 127)) * 40000  # ~3.6 MiB, no delimiter
        for start in range(0, len(payload), OUT.READ_CHUNK_BYTES):
            self.assertEqual(splitter.feed(payload[start:start + OUT.READ_CHUNK_BYTES], 1), [])
            self.assertLessEqual(len(splitter._pending), OUT.MAX_PENDING_RECORD_BYTES)
        record = splitter.feed(b"\nnext\n", 2)[0]
        self.assertTrue(record.truncated)
        self.assertEqual(record.text.encode(), payload[: OUT.MAX_PENDING_RECORD_BYTES])
        self.assertEqual(record.dropped_bytes, len(payload) - OUT.MAX_PENDING_RECORD_BYTES)
        self.assertEqual(record.suffix.encode(), payload[-OUT.TRUNCATED_SUFFIX_BYTES:])
        self.assertEqual((splitter.truncated_records, splitter.dropped_bytes), (1, record.dropped_bytes))
        self.assertEqual(shape(splitter.finish(3)), [])
        self.assertFalse(OUT.RecordSplitter().feed(b"ok\n", 1)[0].truncated)

    def test_batches_hold_at_most_256_records_and_64_kib_in_order(self) -> None:
        records = split_all([b"x\n" * 1000 + ("é" * 3000 + "\n").encode() * 60 + b"y" * 200000 + b"\n" + b"z\n" * 10])
        batches = list(OUT.record_batches(records))
        self.assertEqual([record for batch in batches for record in batch], records)
        for batch in batches:
            self.assertLessEqual(len(batch), OUT.BATCH_MAX_RECORDS)
            size = sum(len(record.text.encode()) for record in batch)
            self.assertTrue(size <= OUT.BATCH_MAX_BYTES or len(batch) == 1, size)


class Step3TailTests(unittest.TestCase):
    def test_entries_are_ansi_stripped_capped_and_terminated_except_eof(self) -> None:
        self.assertEqual(OUT.tail_entry("\x1b[1;31merror\x1b[0m: x\x1b[K"), ("error: x\n", 9))
        self.assertEqual(OUT.tail_entry("last", terminated=False), ("last", 4))
        long_entry, size = OUT.tail_entry("é" * 5000)
        self.assertEqual(size, len(long_entry.encode()))
        self.assertLessEqual(size, OUT.TAIL_ENTRY_MAX_BYTES)
        self.assertTrue(long_entry.endswith("…\n"))
        self.assertTrue(long_entry.startswith("é" * 2000))

    def test_tail_keeps_the_last_30_entries_within_64_kib(self) -> None:
        tail = OUT.OutputTail()
        tail.extend_sized(OUT.tail_entry(str(index)) for index in range(100))
        self.assertEqual(list(tail), [f"{index}\n" for index in range(70, 100)])
        tail.extend_sized(OUT.tail_entry("w" * 10000) for _ in range(20))
        self.assertEqual(len(tail), 16)  # 16 * 4 KiB = 64 KiB
        self.assertEqual(tail.byte_count, sum(len(entry.encode()) for entry in tail))
        self.assertLessEqual(tail.byte_count, OUT.TAIL_MAX_BYTES)

    def test_system_lines_join_the_same_bounded_tail(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            state = timing_state(Path(tmp), "off")
            job = timing_job(state, "t")
            state._pump_output(job.ticket, iter([b"one\r\ntwo", b""]).__next__, io.BytesIO())
            with state.condition:
                state._append_tail_locked(job, "\x1b[2mconductor: done\x1b[0m\nsecond")
            self.assertEqual(list(job.tail), ["one\n", "two", "conductor: done\n", "second"])


def xctest_job(state: conductor.DaemonState, ticket: str = "x") -> conductor.Job:
    job = timing_job(state, ticket, operation="test")
    job.telemetry = None
    return job


class Step3ReaderTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.state = timing_state(Path(self.tmp.name), "off")

    def pump(self, job: conductor.Job, chunks: list[bytes], stamps: Optional[list[int]] = None) -> bytes:
        sink = io.BytesIO()
        reads = iter(chunks)
        if stamps is None:
            self.state._pump_output(job.ticket, reads.__next__, sink)
        else:
            clock = iter(stamps)
            with mock.patch.object(conductor.time, "monotonic_ns", side_effect=lambda: next(clock)):
                self.state._pump_output(job.ticket, reads.__next__, sink)
        return sink.getvalue()

    def test_passed_and_started_in_one_chunk_apply_both_transitions_in_order(self) -> None:
        job = xctest_job(self.state)
        applied: list[tuple] = []
        original = self.state._apply_xctest_progress_line_locked

        def record(target: Any, line: str, marker: Any, timestamp: float, observed_at: float) -> bool:
            before = target.xctest_progress_sequence
            result = original(target, line, marker, timestamp, observed_at)
            applied.append((line, before, target.xctest_progress_sequence, timestamp))
            return result

        chunk = (
            b"Test Case '-[M.S testA]' started.\n"
            b"\x1b[32mTest Case '-[M.S testA]' passed (0.001 seconds).\x1b[0m\r\n"
            b"Test Case '-[M.S testB]' started.\n"
        )
        with mock.patch.object(self.state, "_apply_xctest_progress_line_locked", side_effect=record):
            self.pump(job, [chunk, b""], stamps=[7_000_000_000, 9_000_000_000, 9_000_000_000])
        self.assertEqual([item[0] for item in applied], [
            "Test Case '-[M.S testA]' started.",
            "Test Case '-[M.S testA]' passed (0.001 seconds).",
            "Test Case '-[M.S testB]' started.",
        ])
        self.assertEqual([(item[1], item[2]) for item in applied], [(0, 1), (1, 2), (2, 3)])
        self.assertEqual({item[3] for item in applied}, {7.0})
        self.assertEqual(job.xctest_started_count, 2)
        self.assertEqual((job.xctest_current_test, job.xctest_previous_test), ("-[M.S testB]", "-[M.S testA]"))
        self.assertEqual(job.xctest_deadline_phase, "active-method")
        self.assertEqual(job.xctest_progress_deadline, 7.0 + job.xctest_active_method_budget_seconds)

    def test_record_split_across_reads_takes_the_completing_reads_time(self) -> None:
        job = xctest_job(self.state)
        self.pump(job, [b"Test Case '-[M.S tes", b"tC]' started.\n", b""], stamps=[1_000_000_000, 5_000_000_000, 6_000_000_000])
        self.assertEqual(job.xctest_current_test, "-[M.S testC]")
        self.assertEqual(job.xctest_progress_deadline, 5.0 + job.xctest_active_method_budget_seconds)

    def test_delayed_lock_acquisition_keeps_the_receive_time(self) -> None:
        job = xctest_job(self.state)
        locked = threading.Event()
        release = threading.Event()

        def hold() -> None:
            with self.state.condition:
                locked.set()
                release.wait(5)

        reads = iter([b"Build complete! (1s)\nTest Case '-[M.S testD]' started.\n", b""])
        stamps: list[int] = []

        def read_chunk() -> bytes:
            chunk = next(reads)
            if chunk:
                holder = threading.Thread(target=hold)
                holder.start()
                locked.wait(5)
                threading.Timer(0.3, release.set).start()
            return chunk

        real = time.monotonic_ns

        def stamp() -> int:
            value = real()
            stamps.append(value)
            return value

        before_wall = time.time()
        with mock.patch.object(conductor.time, "monotonic_ns", side_effect=stamp):
            self.state._pump_output(job.ticket, read_chunk, io.BytesIO())
        self.assertGreaterEqual(real() - stamps[0], 250_000_000)  # the lock really was delayed
        self.assertEqual(job.xctest_progress_deadline, stamps[0] / 1e9 + job.xctest_active_method_budget_seconds)
        self.assertLess(job.xctest_last_progress_observed_at - before_wall, 0.2)

    def test_reader_error_flushes_the_pending_record_through_progress(self) -> None:
        job = xctest_job(self.state)
        reads = iter([b"x\nTest Case '-[M.S testE]' started."])

        def read_chunk() -> bytes:
            try:
                return next(reads)
            except StopIteration:
                raise OSError("reader failed")

        with self.assertRaises(OSError):
            self.state._pump_output(job.ticket, read_chunk, io.BytesIO())
        self.assertEqual(job.xctest_current_test, "-[M.S testE]")
        # (A diagnostic system line about the absent runtime ledger may follow.)
        self.assertEqual(list(job.tail)[:2], ["x\n", "Test Case '-[M.S testE]' started."])

    def test_raw_log_is_byte_identical_and_lock_is_taken_once_per_batch(self) -> None:
        import random

        rng = random.Random(11)
        data = b"".join(rng.choice([b"line\n", b"\r", b"\r\n", b"\xe2\x9c\x93", b"\x1b[1m", b"\xff", b"x" * 300]) for _ in range(20000))
        chunks = [data[start:start + 4093] for start in range(0, len(data), 4093)] + [b""]
        job = xctest_job(self.state)
        entries: list[int] = []
        notifies: list[int] = []
        inner = self.state.condition

        class Counting:
            def __enter__(self) -> Any:
                entries.append(1)
                return inner.__enter__()

            def __exit__(self, *exc: Any) -> Any:
                return inner.__exit__(*exc)

            def notify_all(self) -> None:
                notifies.append(1)
                inner.notify_all()

        records = split_all(chunks[:-1])
        self.state.condition = Counting()  # type: ignore[assignment]
        try:
            raw = self.pump(job, chunks)
        finally:
            self.state.condition = inner
        self.assertEqual(raw, data)
        splitter = OUT.RecordSplitter()
        expected_batches = 0
        for chunk in chunks[:-1]:
            expected_batches += len(list(OUT.record_batches(splitter.feed(chunk, 0))))
        expected_batches += len(list(OUT.record_batches(splitter.finish(0))))
        self.assertEqual(len(notifies), expected_batches)
        self.assertEqual(len(entries), expected_batches + 1)  # plus the one watchdog check
        self.assertEqual(list(job.tail), [entry for entry, _size in OUT.tail_entries(records)][-30:])


SUMMARY_PRECHECK_LINES = [
    "ERROR: x", "error: lower", "something FAILED", "x failed with 2", "process exited with status 3", "fatal error: y",
    "Traceback (most recent call last):", "ValueError Exception", "Permission denied", "No such file or directory",
    "it timed out", "killing process group 1", "terminating process tree 2", "Killing Process Tree 3",
    "a.swift:1:2: error: bad", "error: emit-module command failed", "Command SwiftCompile failed", "Command CompileSwift failed",
    "a.swift:3:4: warning: w", "WARNING: upper", "Warning: mixed", "Test Case '-[A b]' failed (0.1 seconds).", "XCTAssertEqual failed",
    "x.swift:1: error: -[ATest t] : XCTAssert", "Executed 3 tests, with 1 failure (0 unexpected) in 0.1 seconds",
    "Failing tests:", "error: Exited with unexpected signal code 11", "error: terminated(1)", "SwiftFormat failed", "SwiftLint", "linting",
    "Missing required tool swiftformat", "Run 'make install-format-tools'", "ERROR: Missing required Swift style tools",
    "timed out after 10s", "XCTest STARTUP deadline triggered", "canceled", "CANCELED by user", "==> phase", "$ make", "+ step",
    "Created: x", "APP_BUNDLE=/a", "COMPAT_APP_BUNDLE=/b", "CLI_PATH=/c", "Output written to: d", "Agent Mode diagnostics enabled",
    "Resolved rpce-cli-debug: e", "Build cache diagnostics", "Current .build: f", "Managed worktree container: g",
    "Worktree .build total: h", "Top .build directories: i", "   12.5 GiB  .build", "\t3 KB x",
    "Stopping existing RepoPrompt", "Waiting for existing RepoPrompt", "Launching /x/RepoPrompt.app", "Confirming launched RepoPrompt",
    "Observed launched RepoPrompt", "Guarding against a delayed RepoPrompt", "Delayed launch guard confirmed",
    "RepoPrompt CE debug app stop confirmed", "RepoPrompt stop confirmed", "RepoPrompt was not running", "RepoPrompt was already stopped",
    "terminating process group 7", "Terminating Process Group 8",
    "input file 'a.swift' was modified during the build", "INPUT FILE b WAS MODIFIED DURING THE BUILD",
    "plain line", "", "ERRORS: none", "failedness", "   ", "Ｅrror: fullwidth", "ﬁle error： full colon", "KILLING PROCESS GROUP 4",
    "timed out after 3s (killing process tree 9)", "KILLING process group 5", "ſwiftformat", "résumé error: é", "日本 warning: 語",
]


class Step3SummaryTests(unittest.TestCase):
    def test_summary_version_is_2(self) -> None:
        self.assertEqual(conductor.SUMMARY_VERSION, 2)
        summary = summarize("build", "failed", 1, ["error: x"])
        self.assertEqual(summary["version"], 2)
        self.assertEqual((summary["deduplicationLimited"], summary["omittedLineCountQuality"]), (False, "exact"))

    def test_keyword_precheck_equals_unconditional_matching(self) -> None:
        lines = SUMMARY_PRECHECK_LINES + [line.lower() for line in SUMMARY_PRECHECK_LINES] + [line.upper() for line in SUMMARY_PRECHECK_LINES]
        for operation in ("build", "lint", "test", "app"):
            for state, exit_code in (("completed", 0), ("failed", 1)):
                with self.subTest(operation=operation, state=state):
                    for single in lines:
                        prechecked = summarize(operation, state, exit_code, [single])
                        with mock.patch.object(conductor.OutputSummarizer, "KEYWORD_PRECHECK", False):
                            unconditional = summarize(operation, state, exit_code, [single])
                        self.assertEqual(prechecked, unconditional, single)
                    prechecked = summarize(operation, state, exit_code, lines)
                    with mock.patch.object(conductor.OutputSummarizer, "KEYWORD_PRECHECK", False):
                        self.assertEqual(prechecked, summarize(operation, state, exit_code, lines))

    def test_streamed_file_summary_equals_universal_newline_lines(self) -> None:
        data = "\r\n".join(SUMMARY_PRECHECK_LINES).encode() + b"\rprogress\r\n\xff tail"
        with tempfile.TemporaryDirectory() as tmp:
            log = Path(tmp) / "job.log"
            log.write_bytes(data)
            streamed = conductor.OutputSummarizer.summarize_file("build", {}, "failed", 1, False, log)
            with log.open("r", encoding="utf-8", errors="replace") as handle:
                reference = conductor.OutputSummarizer.summarize_lines("build", {}, "failed", 1, False, handle)
        self.assertEqual(streamed, reference)

    def test_seen_is_bounded_at_one_million_unique_records(self) -> None:
        builder = conductor.SummarySectionBuilder("Failure highlights", 10)
        for index in range(1_000_000):
            builder.add(f"error: {index}")
        self.assertEqual(len(builder.seen), conductor.SUMMARY_SEEN_MAX_ENTRIES)
        payload = builder.payload()
        self.assertTrue(payload["deduplicationLimited"])
        self.assertEqual(payload["omittedLineCountQuality"], "upper_bound")
        self.assertEqual(payload["omittedLineCount"], 1_000_000 - 10)  # all unique: the bound is exact here
        self.assertEqual(payload["lines"], [f"error: {index}" for index in range(10)])

    def test_dedup_is_exact_before_saturation_and_flags_after(self) -> None:
        lines = [f"error: {index % 6}" for index in range(60)]
        with mock.patch.object(conductor, "SUMMARY_SEEN_MAX_ENTRIES", 6):
            exact = summarize("build", "failed", 1, lines)
        self.assertFalse(exact["deduplicationLimited"])
        with mock.patch.object(conductor, "SUMMARY_SEEN_MAX_ENTRIES", 10**9):
            self.assertEqual(exact, summarize("build", "failed", 1, lines))
        with mock.patch.object(conductor, "SUMMARY_SEEN_MAX_ENTRIES", 3):
            limited = summarize("build", "failed", 1, lines)
        self.assertTrue(limited["deduplicationLimited"])
        # The top-level count (log lines minus rendered lines) stays exact; sections carry the bound.
        self.assertEqual(limited["omittedLineCountQuality"], "exact")
        failures = next(item for item in limited["sections"] if item["title"] == "Failure highlights")
        exact_failures = next(item for item in exact["sections"] if item["title"] == "Failure highlights")
        self.assertEqual(failures["omittedLineCountQuality"], "upper_bound")
        self.assertFalse(failures["displayedLinesMayRepeat"])  # first-lines sections never evict
        self.assertEqual(failures["lines"], exact_failures["lines"])
        self.assertGreaterEqual(failures["omittedLineCount"], exact_failures["omittedLineCount"])


class Step3SummarySingleFlightTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.state = timing_state(Path(self.tmp.name), "off")
        self.job = timing_job(self.state, "s")
        self.job.log_path.write_bytes(b"error: boom\n")
        self.job.state = "failed"
        self.job.exit_code = 1

    def test_racing_status_wait_and_completion_scan_once(self) -> None:
        gate = threading.Event()
        calls: list[int] = []
        real = conductor.OutputSummarizer.summarize_file

        def slow(*args: Any) -> dict:
            calls.append(1)
            gate.wait(5)
            return real(*args)

        results: dict = {}
        with mock.patch.object(conductor.OutputSummarizer, "summarize_file", side_effect=slow):
            threads = [threading.Thread(target=lambda: self.state._refresh_output_summary(self.job, complete_telemetry=True))]
            threads[0].start()
            deadline = time.monotonic() + 5
            while not calls and time.monotonic() < deadline:
                time.sleep(0.005)
            self.assertEqual(self.job.summary_state, "running")
            threads.append(threading.Thread(target=lambda: results.__setitem__("status", self.state.job_status("s", None))))
            threads.append(threading.Thread(target=lambda: results.__setitem__("wait", self.state.job_wait("s", None, None))))
            for thread in threads[1:]:
                thread.start()
            started = time.monotonic()
            self.state._refresh_output_summary(self.job, deadline=conductor.now() + 0.1)
            self.assertLess(time.monotonic() - started, 2.0)  # a joiner honors its own deadline
            self.assertIsNone(self.job.output_summary)
            gate.set()
            for thread in threads:
                thread.join(10)
        self.assertEqual(len(calls), 1)
        self.assertEqual(self.job.summary_state, "complete")
        self.assertTrue(self.job.summary_event.is_set())
        self.assertEqual(results["status"]["outputSummary"], self.job.output_summary)
        self.assertEqual(results["wait"]["outputSummary"], self.job.output_summary)
        self.assertIn("error: boom", section(self.job.output_summary, "Failure highlights"))
        self.state._refresh_output_summary(self.job)
        self.assertEqual(len(calls), 1)

    def test_exception_publishes_a_minimal_error_summary_and_releases_the_claim(self) -> None:
        with mock.patch.object(conductor.OutputSummarizer, "summarize_file", side_effect=RuntimeError("scan broke")):
            payload = self.state.job_wait("s", None, 5.0)
        self.assertEqual(self.job.summary_state, "failed")
        self.assertTrue(self.job.summary_event.is_set())
        self.assertIn("summary failed: RuntimeError: scan broke", json.dumps(payload["outputSummary"]))
        self.assertEqual(payload["outputSummary"]["deduplicationLimited"], False)
        self.assertEqual(payload["outputSummary"]["omittedLineCountQuality"], "exact")


def reference_progress_lines(text: str) -> list[tuple[str, Any]]:
    """The parent's per-line XCTest normalization over one complete decoded line/record."""
    items = []
    for raw_line in text.splitlines():
        line = conductor.XCTEST_ANSI_SGR_RE.sub("", raw_line).strip()
        marker = conductor.XCTEST_PROGRESS_RE.match(line)
        if marker is not None or "Build complete!" in line:
            items.append((line, None if marker is None else marker.groups()))
    return items


def reference_scan(text: str) -> tuple[list[tuple[str, Any]], Optional[str]]:
    """OD16 over one over-cap record: the parent's items, or the bound it fails at.

    A normalized line over ``SEGMENT_MAX_CHARS`` that the parent would match as
    a marker fails with ``"segment"``; more than ``SEGMENT_MAX_PENDING_ITEMS``
    items fail with ``"pending"``. Either way no item survives. Over the bound,
    a non-marker line is only its ``Build complete!`` substring test.
    """
    items: list = []
    for raw_line in text.splitlines():
        line = conductor.XCTEST_ANSI_SGR_RE.sub("", raw_line).strip()
        marker = conductor.XCTEST_PROGRESS_RE.match(line)
        if len(line) > OUT.SEGMENT_MAX_CHARS:
            if marker is not None:
                return [], "segment"
            if "Build complete!" in line:
                items.append(("Build complete!", None))
        elif marker is not None or "Build complete!" in line:
            items.append((line, None if marker is None else marker.groups()))
        if len(items) > OUT.SEGMENT_MAX_PENDING_ITEMS:
            return [], "pending"
    return items, None


def scanned_items(data: bytes, chunk: int) -> tuple[list[tuple[str, Any]], Optional[str]]:
    """Every item one over-cap record yields through the splitter, and its OD16 failure."""
    splitter = OUT.RecordSplitter(segment_scanner=conductor._xctest_segment_scanner)
    items: list = []
    for start in range(0, len(data), chunk):
        for record in splitter.feed(data[start:start + chunk], 0):
            items.extend(record.segment_items)
    for record in splitter.finish(0):
        items.extend(record.segment_items)
    failure = splitter.segment_failure
    if failure is not None:
        assert failure[1] == 0, failure  # the record being scanned
    return (
        [(line, None if marker is None else marker.groups()) for line, marker in items],
        None if failure is None else failure[0],
    )


class Step3OverCapProgressTests(unittest.TestCase):
    """S3-R0-03: XCTest progress in records beyond the 64 KiB cap is classified before truncation."""

    PASS_A = b"Test Case '-[M.S testA]' started.\nTest Case '-[M.S testA]' passed (0.1 seconds).\n"
    START_B = b"Test Case '-[M.S testB]' started."

    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.state = timing_state(Path(self.tmp.name), "off")

    def pump(self, chunks: list[bytes], stamps: Optional[list[int]] = None) -> tuple[conductor.Job, bytes, list[tuple]]:
        job = xctest_job(self.state)
        applied: list[tuple] = []
        original = self.state._apply_xctest_progress_line_locked

        def record(target: Any, line: str, marker: Any, timestamp: float, observed_at: float) -> bool:
            result = original(target, line, marker, timestamp, observed_at)
            applied.append((line, target.xctest_progress_sequence, timestamp))
            return result

        sink = io.BytesIO()
        reads = iter(chunks + [b""])
        with mock.patch.object(self.state, "_apply_xctest_progress_line_locked", side_effect=record):
            if stamps is None:
                self.state._pump_output(job.ticket, reads.__next__, sink)
            else:
                clock = iter(stamps)
                with mock.patch.object(conductor.time, "monotonic_ns", side_effect=lambda: next(clock)):
                    self.state._pump_output(job.ticket, reads.__next__, sink)
        return job, sink.getvalue(), applied

    def assert_b_active(self, job: conductor.Job, applied: list[tuple], read_time: Optional[float] = None) -> None:
        self.assertEqual(job.xctest_current_test, "-[M.S testB]")
        self.assertEqual(job.xctest_previous_test, "-[M.S testA]")
        self.assertEqual(job.xctest_deadline_phase, "active-method")
        self.assertEqual(job.xctest_started_count, 2)
        self.assertEqual(job.xctest_progress_sequence, 3)
        self.assertEqual([line for line, _seq, _ts in applied if "testB" in line], [self.START_B.decode()])
        if read_time is not None:
            self.assertEqual(job.xctest_progress_deadline, read_time + job.xctest_active_method_budget_seconds)

    def test_over_cap_whitespace_ansi_and_separators_keep_the_transition(self) -> None:
        cases = {
            "spaces": b" " * 65536 + self.START_B + b"\n",
            "tabs-and-unicode-spaces": ("\t\u3000\xa0" * 30000).encode() + self.START_B + b"   \n",
            "ansi": b"\x1b[0m" * 20000 + self.START_B + b"\n",
            "ansi-between-spaces": b" \x1b[1;32m " * 12000 + self.START_B + b"\x1b[0m" * 9000 + b"\n",
            "long-sgr-parameters": b"\x1b[" + b"1" * 70000 + b"m" + self.START_B + b"\n",
            "trailing-spaces": self.START_B + b" " * 70000 + b"\n",
        }
        for separator in ("\x0b", "\x0c", "\x1c", "\x1d", "\x1e", "\x85", "\u2028", "\u2029"):
            cases[f"after-{ord(separator):#x}"] = b"x" * 70000 + separator.encode() + self.START_B + b"\n"
        for name, data in cases.items():
            for chunk in (13, 1021, 4096, 65536):
                chunks = [data[index:index + chunk] for index in range(0, len(data), chunk)]
                with self.subTest(case=name, chunk=chunk):
                    job, raw, applied = self.pump([self.PASS_A] + chunks)
                    self.assertEqual(raw, self.PASS_A + data)  # raw bytes unchanged
                    self.assert_b_active(job, applied)
                    # The tail entry is the OD7 entry of the whole record, not of its kept bytes.
                    self.assertEqual(job.tail[-1], OUT.tail_entry(data[:-1].decode("utf-8", errors="replace"))[0])

    def test_segment_of_an_over_cap_record_takes_the_completing_reads_time_in_order(self) -> None:
        # A long record whose B marker ends at an embedded separator while the record
        # itself stays pending: like the parent's per-line application at the LF, B
        # applies when the record completes, with that read's time, after A.
        data = b"y" * 70000 + b"\x0b" + self.START_B + b"\x0bz"
        reads = [self.PASS_A, data[:65000], data[65000:], b"" + b"w" * 10, b"\nTest Case '-[M.S testB]' passed (1 seconds).\n"]
        stamps = [1_000_000_000, 2_000_000_000, 3_000_000_000, 4_000_000_000, 5_000_000_000, 6_000_000_000]
        job, raw, applied = self.pump(reads, stamps=stamps)
        self.assertEqual(raw, b"".join(reads))
        self.assertEqual([(line, seq) for line, seq, _ts in applied], [
            ("Test Case '-[M.S testA]' started.", 1),
            ("Test Case '-[M.S testA]' passed (0.1 seconds).", 2),
            ("Test Case '-[M.S testB]' started.", 3),
            ("Test Case '-[M.S testB]' passed (1 seconds).", 4),
        ])
        self.assertEqual([ts for _line, _seq, ts in applied], [1.0, 1.0, 5.0, 5.0])
        self.assertEqual((job.xctest_current_test, job.xctest_deadline_phase), (None, "between-method"))

    def test_segment_started_before_the_cap_applies_when_the_record_completes(self) -> None:
        data = self.START_B + b"\x0b" + b"q" * 70000
        job, _raw, applied = self.pump([self.PASS_A, data[:2000], data[2000:], b"\n"],
                                       stamps=[1_000_000_000, 2_000_000_000, 3_000_000_000, 4_000_000_000, 5_000_000_000])
        self.assert_b_active(job, applied, read_time=4.0)

    def assert_od16_failure(self, job: conductor.Job, boundary: str, record_seq: int) -> None:
        """The job is failed visibly with a bounded reason that echoes no output."""
        reason = job.xctest_output_failure or ""
        self.assertTrue(reason.startswith("XCTest output contract failure (OD16): "), reason)
        self.assertLess(len(reason), 300)
        for echoed in ("nnnn", "9999", "qqqq", "-[M.S t"):
            self.assertNotIn(echoed, reason)
        self.assertTrue(job.measurement_invalid)
        self.assertEqual(job.error, reason)
        self.assertIn(reason + "\n", list(job.tail))
        diagnostic = job.diagnostics[-1]
        self.assertEqual(
            {key: diagnostic[key] for key in ("kind", "boundary", "recordSeq", "limit")},
            {
                "kind": "xctest-output-contract",
                "boundary": boundary,
                "recordSeq": record_seq,
                "limit": OUT.SEGMENT_MAX_CHARS if boundary == "segment" else OUT.SEGMENT_MAX_PENDING_ITEMS,
            },
        )
        # It finalizes as failed even when the child exits 0.
        with self.state.condition:
            self.state._finalize_process_exit_locked(job, 0)
        self.assertEqual((job.state, job.exit_code), ("failed", conductor.XCTEST_STALL_FAILURE_EXIT_CODE))
        self.assertEqual(job.result_summary, reason)

    def assert_no_od16_failure(self, job: conductor.Job) -> None:
        self.assertIsNone(job.xctest_output_failure)
        self.assertFalse(job.measurement_invalid)
        self.assertEqual(job.diagnostics, [])

    def test_pending_items_up_to_the_bound_wait_for_the_record_and_one_more_fails_the_job(self) -> None:
        # D2b (16 items) keeps normal semantics; D2c (17) fails visibly, applying none early.
        bound = OUT.SEGMENT_MAX_PENDING_ITEMS
        start_a = b"Test Case '-[M.S testA]' started.\n"
        for count in (bound, bound + 1):
            for terminator in (b"\n", b""):
                with self.subTest(count=count, eof_without_newline=not terminator):
                    markers = b"".join(b"\x0bTest Case '-[M.S t%d]' started." % index for index in range(count))
                    data = b"q" * 70000 + markers + b"\x0b"
                    stamps = [1_000_000_000, 2_000_000_000, 3_000_000_000, 4_000_000_000, 5_000_000_000]
                    reads = [start_a, data, b"tail" + terminator]
                    job, raw, applied = self.pump(reads, stamps=stamps)
                    self.assertEqual(raw, b"".join(reads))
                    started = [(line, ts) for line, _seq, ts in applied if "testA" not in line]
                    if count == bound:
                        self.assert_no_od16_failure(job)
                        self.assertEqual([line for line, _ts in started],
                                         [f"Test Case '-[M.S t{index}]' started." for index in range(count)])
                        # Every item takes the completing read's time (3.0), or EOF's (4.0).
                        self.assertEqual({ts for _line, ts in started}, {3.0 if terminator else 4.0})
                        self.assertEqual(job.xctest_current_test, f"-[M.S t{count - 1}]")
                        self.assertEqual(job.xctest_progress_sequence, 1 + count)
                    else:
                        self.assertEqual(started, [])
                        self.assertEqual((job.xctest_current_test, job.xctest_progress_sequence), ("-[M.S testA]", 1))
                        self.assert_od16_failure(job, "pending", 1)

    def test_over_cap_tail_entries_equal_the_whole_record_entry(self) -> None:
        import random

        rng = random.Random(41)
        pieces = [
            b"\x1b[0m", b"\x1b[1;31m", b"\x1b[", b"1;", b"!", b"m", b"\x1b", b"\x1bA", b"\x1b[", b"[31m", b"Z",
            b"\xe2\x9c\x93", b"\xe2\x9c", b"\xff", b"text ", b"\xc3\xa9" * 7, b"\x1b[" + b"2;" * 900,
        ]
        for trial in range(40):
            body = bytearray()
            target = 66000 + trial * 977
            while len(body) < target:
                body += rng.choice(pieces) if rng.random() < 0.97 else b"v" * rng.randrange(1, 6000)
            body = bytes(body).replace(b"\r", b"").replace(b"\n", b"")
            for terminator in (b"\n", b""):
                data = body + terminator
                expected = OUT.tail_entry(body.decode("utf-8", errors="replace"), terminated=bool(terminator))
                for chunk in (509, 4096, 65536):
                    with self.subTest(trial=trial, terminated=bool(terminator), chunk=chunk):
                        records = split_all([data[i:i + chunk] for i in range(0, len(data), chunk)])
                        self.assertEqual(len(records), 1)
                        self.assertTrue(records[0].truncated)
                        self.assertEqual(OUT.tail_entries(records), [expected])

    def test_build_complete_in_an_over_bound_segment_starts_the_startup_deadline(self) -> None:
        data = b"z" * 40000 + b"Build complete! (3s)" + b"z" * 40000 + b"\n"
        job, _raw, applied = self.pump([data[:30000], data[30000:]], stamps=[1_000_000_000, 2_000_000_000, 3_000_000_000])
        self.assertEqual(job.xctest_deadline_phase, "startup")
        self.assertEqual(job.xctest_progress_deadline, 2.0 + conductor.XCTEST_STARTUP_DEADLINE_SECONDS)
        self.assertEqual(job.xctest_progress_sequence, 0)
        self.assertEqual([line for line, _seq, _ts in applied], ["Build complete!"])

    def test_build_complete_split_across_reads_in_an_over_bound_segment(self) -> None:
        data = b"z" * 70000 + b"Build complete! (3s)" + b"z" * 10 + b"\n"
        for split in range(70000, 70016):
            with self.subTest(split=split):
                job, _raw, applied = self.pump([data[:split], data[split:]])
                self.assertEqual(job.xctest_deadline_phase, "startup")
                self.assertEqual([line for line, _seq, _ts in applied], ["Build complete!"])

    @staticmethod
    def bounded_marker(kind: str, chars: int) -> str:
        """A marker whose normalized line has ``chars`` characters (D1b name / D1a parenthetical)."""
        if kind == "name":
            line = "Test Case '-[M.S t" + "n" * (chars - 29) + "]' started."
        else:
            line = "Test Case '-[M.S testA]' passed (" + "9" * (chars - 35) + ")."
        assert len(line) == chars
        return line

    def test_marker_lines_at_the_segment_bound_apply_and_beyond_it_fail_the_job(self) -> None:
        bound = OUT.SEGMENT_MAX_CHARS
        start_a = b"Test Case '-[M.S testA]' started.\n"
        for kind in ("name", "parenthetical"):
            for chars in (bound, bound + 1):
                for decoration, terminator in (((b"", b""), b"\n"), ((b"\x1b[1m  ", b"\x1b[0m \t"), b""), ((b"", b""), b"")):
                    line = self.bounded_marker(kind, chars).encode()
                    data = decoration[0] + line + decoration[1] + terminator
                    for chunk in (977, 4093, 65536):
                        with self.subTest(kind=kind, chars=chars, decorated=bool(decoration[0]),
                                          eof_without_newline=not terminator, chunk=chunk):
                            chunks = [data[i:i + chunk] for i in range(0, len(data), chunk)]
                            job, raw, applied = self.pump([start_a] + chunks)
                            self.assertEqual(raw, start_a + data)
                            # The tail entry is still the whole-record entry.
                            self.assertEqual(job.tail[-1], OUT.tail_entry(
                                (data[:-1] if terminator else data).decode(), terminated=bool(terminator))[0])
                            if chars == bound:
                                self.assert_no_od16_failure(job)
                                self.assertEqual(job.xctest_progress_sequence, 2)
                                self.assertEqual(applied[-1][0], line.decode())
                                self.assertEqual(job.xctest_current_test,
                                                 line.decode()[11:-10] if kind == "name" else None)
                            else:
                                self.assertEqual([entry[1] for entry in applied], [1])  # testA only
                                self.assertEqual(job.xctest_current_test, "-[M.S testA]")
                                self.assert_od16_failure(job, "segment", 1)

    def test_over_bound_marker_shape_equals_the_parent_regex(self) -> None:
        # OD16 D1 trigger precision: a stripped line over the bound fails exactly when
        # the parent's ``XCTEST_PROGRESS_RE`` would match it, never for other text.
        import random

        rng = random.Random(16)
        big = 70000
        lines = [
            "Test Case '" + "x" * big + "' started.",
            "Test Case '" + "x" * big + "' skipped.",
            "Test Case '-[M.S t]' failed (" + "9" * big + ").",
            "Test Case 'a' started (" + "9" * big + ").",
            "Test Case '" + "x" * big + "' started ().",
            "Test Case '" + "x" * big + "' passed (1) x' failed (2).",
            "Test Case '" + "(" * big + "' started.",
            "Test Case '" + ")" * big + "' started (x).",
            "Test Case '" + "' started (" * 9000 + "x).",
            "Test Case 'x' passed (" + "((" * (big // 2) + ").",
            "Test Case '" + "x" * big + "' started.\x1b[0m",
            "\x1b[1mTest \x1b[0mCase '" + "x" * big + "' passed\x1b[32m (1s).",
            "Test Case '" + " " * big + "x' started.",
            "Test Case '" + "x" * big,
            "Test Case 'x' started" + " y" * (big // 2),
            "x" * big + "' started.",
            "Test Case '" + "x" * big + "' started",
            "Test Case '" + "x" * big + "' started. done",
            "Test Case '-[M.S t]' passed (" + "9" * big + ")",
            "Test Case '-[M.S t]' passed (" + "9" * big + ") x).",
            "Test Case '-[M.S t]' passed (" + "9" * big + "x.",
            "Test Case '' started (" + "9" * big + ").",
            "Test Case '' started." + " " * big,
            "Test case '" + "x" * big + "' started.",
            "xTest Case '" + "x" * big + "' started.",
            "Test Case '" + "x" * big + "' Started.",
            "Test Case '" + "x" * big + "'  started.",
            "Test Case '" + "x" * big + "' started (1) (2).",
            "Test Case '" + "x" * big + "' started (1)).",
            "Test Case '\x1b[" + "1" * big + "' started.",
            "Test Case 'q\x1b[" + "1" * big + "' started.",
            "Test Case 'q' started (\x1b[" + "1" * big + ").",
            "\x1b[" + "1" * big + "Test Case 'q' started.",
        ]
        tokens = ["'", " ", "(", ")", ".", "x", "' started", "' passed", " (", ").", "Test Case '", "\x1b[1m", "\t"]
        for _ in range(160):
            parts = [rng.choice(["Test Case '", "Test Case '", " Test Case '", "Test Case "])]
            parts += [rng.choice(tokens) for _ in range(rng.randrange(0, 8))]
            parts.append(rng.choice(["' started", "' passed", "' failed", "' skipped", "' start"]))
            parts += [rng.choice(["", " (", " (1s)", " (", "("])]
            parts += [rng.choice(tokens) for _ in range(rng.randrange(0, 4))]
            parts.append(rng.choice([".", ").", "", ". ", ".x"]))
            filler = rng.choice(["x", "9", " ", "(", ")", "'"]) * big
            parts.insert(rng.randrange(1, len(parts) + 1), filler)
            lines.append("".join(parts))
        outcomes = {True: 0, False: 0}
        for index, line in enumerate(lines):
            normalized = conductor.XCTEST_ANSI_SGR_RE.sub("", line).strip()
            expected = len(normalized) > OUT.SEGMENT_MAX_CHARS and conductor.XCTEST_PROGRESS_RE.match(normalized) is not None
            outcomes[expected] += 1
            data = ("q\x0b" + line + "\x0bq").encode()
            for chunk in ((7, 4093, 65536) if index < 33 else (4093,)):
                with self.subTest(index=index, chunk=chunk):
                    items, failure = scanned_items(data, chunk)
                    self.assertEqual(failure, "segment" if expected else None)
                    if not expected:
                        self.assertEqual((items, failure), reference_scan(data.decode()))
        self.assertGreater(outcomes[True], 20, outcomes)
        self.assertGreater(outcomes[False], 20, outcomes)

    def test_large_non_marker_records_never_fail_the_job(self) -> None:
        records = [
            b"Test Case '" + b"x" * 200000 + b"\n",
            b"Test Case '-[M.S t]' passed (" + b"9" * 200000 + b") x).\n",
            b"y" * 70000 + (b"Test Case '" * 2000) + b"\n",
            b"\x1b[31m" * 30000 + b"error: " + b"z" * 70000 + b"\n",
            b"x" * 100000 + b"' started.\n",
        ]
        for chunk in (4093, 65536):
            with self.subTest(chunk=chunk):
                data = b"".join(records) + b"Test Case '-[M.S testZ]' started.\n"
                job, raw, applied = self.pump([data[i:i + chunk] for i in range(0, len(data), chunk)])
                self.assertEqual(raw, data)
                self.assert_no_od16_failure(job)
                self.assertEqual([line for line, _seq, _ts in applied], ["Test Case '-[M.S testZ]' started."])
                self.assertEqual(job.xctest_current_test, "-[M.S testZ]")

    def test_records_before_the_failure_keep_transitions_and_later_records_feed_only_the_tail(self) -> None:
        markers = b"".join(b"\x0bTest Case '-[M.S t%d]' started." % index for index in range(17))
        later = b"Test Case '-[M.S testZ]' started.\n"
        data = b"Test Case '-[M.S testA]' started.\n" + b"q" * 70000 + markers + b"\n" + later
        for chunk in (len(data), 4096):
            with self.subTest(chunk=chunk):
                job, raw, applied = self.pump([data[i:i + chunk] for i in range(0, len(data), chunk)])
                self.assertEqual(raw, data)
                self.assertEqual([line for line, _seq, _ts in applied], ["Test Case '-[M.S testA]' started."])
                self.assertEqual(job.tail[-1], later.decode())  # classification stopped; the tail did not
                self.assert_od16_failure(job, "pending", 1)

    def test_marker_shape_and_failed_scanners_stay_bounded(self) -> None:
        scanner = conductor._xctest_segment_scanner()
        piece = ("' started (" + "x" * 4000 + ") " + " " * 3000).encode()
        scanner.feed(b"Test Case '")
        for _ in range(300):  # about 2 MiB in one segment
            scanner.feed(piece)
            self.assertLessEqual(len(scanner._shape_end), 16)
            self.assertLessEqual(len(scanner._shape_spaces), 16)
            self.assertLessEqual(len(scanner._run_tail), 10)
            self.assertEqual(len(scanner._shape_head), 12)
            self.assertLessEqual(sum(map(len, scanner._content)), OUT.SEGMENT_MAX_CHARS)
        self.assertEqual(scanner._content, [])  # over the bound: no content kept
        self.assertEqual(scanner.finish(), [])
        self.assertIsNone(scanner.failure)  # ends with ") " stripped to ")": no final dot
        # A failed splitter scans no further record and keeps no items.
        splitter = OUT.RecordSplitter(segment_scanner=conductor._xctest_segment_scanner)
        markers = b"".join(b"\x0bTest Case '-[M.S t%d]' started." % index for index in range(17))
        records = splitter.feed(b"q" * 70000 + markers, 0)
        self.assertEqual((records, splitter.segment_failure), ([], None))  # the 17th segment has not ended
        records = splitter.feed(b"\x0b", 0)
        self.assertEqual((records, splitter.segment_failure), ([], ("pending", 0)))
        self.assertIsNone(splitter._scanner)
        self.assertIsNone(splitter._scanner_factory)
        records = splitter.feed(b"\n" + b"q" * 70000 + b"\x0bTest Case '-[M.S t]' started.\n", 0)
        self.assertEqual([(record.truncated, record.segment_items) for record in records], [(True, ()), (True, ())])
        self.assertEqual(splitter.segment_failure, ("pending", 0))

    def test_summaries_never_classify_or_fail(self) -> None:
        # Summary-only reading has no scanner: OD16 inputs summarize like any text.
        log = Path(self.tmp.name) / "od16.log"
        markers = b"".join(b"\x0bTest Case '-[M.S t%d]' started." % index for index in range(17))
        log.write_bytes(
            self.bounded_marker("parenthetical", OUT.SEGMENT_MAX_CHARS + 1).encode() + b"\n"
            + b"q" * 70000 + markers + b"\nerror: boom\n"
        )
        for state, exit_code in (("completed", 0), ("failed", 1)):
            with self.subTest(state=state):
                summary = conductor.OutputSummarizer.summarize_file("test", {}, state, exit_code, False, log)
                self.assertNotIn("OD16", json.dumps(summary))
                with contextlib.redirect_stdout(io.StringIO()):
                    conductor.render_output_summary(summary)
        self.assertEqual(len(list(OUT.iter_file_texts(log, over_cap=str, visible_chars=10))), 3)

    def test_scanner_items_equal_the_parent_normalization_of_the_whole_record(self) -> None:
        import random

        rng = random.Random(29)
        pieces = [
            b" ", b"\t", b"\x0b", b"\x0c", b"\x1c", b"\xc2\x85", b"\xe2\x80\xa8", b"\x1b[", b"\x1b[0m", b"\x1b[1;3",
            b"m", b"\x1b", b"12", b";", b"\xe3\x80\x80", b"\xff", b"\xe2\x9c", b"x" * 997, b" " * 3001,
            b"Test Case '-[M.S t1]' started.", b"Test Case '-[M.S t2]' passed (0.2 seconds).", b"Build complete!",
            b"Test Case '", b"' failed (1 seconds).", b"Build ", b"complete!", b"\x1b[32mTest\x1b[0m Case '-[A b]' skipped.",
        ]
        item_pieces = [piece for piece in pieces if b"Test Case '" in piece or b"Build complete!" in piece]
        other_pieces = [piece for piece in pieces if piece not in item_pieces]
        outcomes: dict = {}
        for trial in range(60):
            # Item density varies, so trials stay within the pending bound or exceed it.
            density = (0.0, 0.01, 0.2, 0.5)[trial % 4]
            body = bytearray()
            while len(body) < 66000 + trial * 1000:
                body += rng.choice(item_pieces if rng.random() < density else other_pieces)
            data = bytes(body)
            reference = reference_scan(data.decode("utf-8", errors="replace"))
            outcomes.setdefault(reference[1], 0)
            outcomes[reference[1]] += 1
            for chunk in (1023, 4093, 65536):
                with self.subTest(trial=trial, chunk=chunk):
                    self.assertEqual(scanned_items(data, chunk), reference)
        self.assertGreater(outcomes.get(None, 0), 10, outcomes)
        self.assertGreater(outcomes.get("pending", 0), 10, outcomes)

    def test_records_within_the_cap_do_not_use_the_scanner(self) -> None:
        created: list[int] = []

        def factory() -> Any:
            created.append(1)
            return conductor._xctest_segment_scanner()

        splitter = OUT.RecordSplitter(segment_scanner=factory)
        records = splitter.feed(b"a" * 65536 + b"\n" + self.START_B + b"\n", 0)
        self.assertEqual(created, [])
        self.assertEqual([record.segment_items for record in records], [(), ()])
        self.assertFalse(any(record.truncated for record in records))

    def test_without_the_scanner_the_transition_would_be_lost(self) -> None:
        # Guards the regression test itself: the truncated text alone has no marker.
        records = split_all([b" " * 65536 + self.START_B + b"\n"])
        self.assertTrue(records[0].truncated)
        self.assertEqual(self.state._xctest_progress_transitions([records[0]._replace(segment_items=())]), [])

    def test_prefilter_equals_the_per_line_regex(self) -> None:
        # OracleB S3R0-EQ-01: the record-level literal prefilter never hides a match.
        lines = [
            "Test Case '-[A b]' started.", "  Test Case '-[A b]' passed (0.1 seconds).  ", "\x1b[1mTest Case '-[A b]' failed.\x1b[0m",
            "Test\x1b[0m Case '-[A b]' skipped.", "Test \x1b[32mCase\x1b[0m '-[A b]' started.", "Test Case \x1b[1m'-[A b]' started.",
            "test case '-[A b]' started.", "Test Suite 'All tests' started.", "Build complete! (1s)", "x\x0bTest Case '-[A b]' started.",
            "Test Case '-[A b]' started.\u2028Build complete!", "Test Case '-[A b]' started (0.1 seconds).", "Build\x1b[0m complete!",
        ]
        for line in lines:
            with self.subTest(line=line):
                record = conductor.CONDUCTOR_OUTPUT.OutputRecord(0, 5, line, "lf")
                got = [(text, None if marker is None else marker.groups())
                       for _ts, text, marker in self.state._xctest_progress_transitions([record])]
                self.assertEqual(got, reference_progress_lines(line))


class Step3OverCapVisibleTextTests(unittest.TestCase):
    """D3/D4: over-cap tail entries and summary lines equal those of the whole record."""

    PIECES = [
        b"\x1b", b"\x1b[", b"[", b"0", b"1;", b";", b"?", b" ", b"!", b"/", b"m", b"K", b"A", b"\\", b"_", b"~",
        b"\x7f", b"x", b"\xe2\x9c\x93", b"\xe2", b"\x9c", b"\xff", b"\xc3\xa9", b"\x1b[0m", b"\x1b[38;5;1m",
    ]

    def test_visible_prefix_equals_one_pass_substitution_of_the_whole_text(self) -> None:
        import random

        rng = random.Random(7)
        for pattern in (OUT.ANSI_RE, OUT.CSI_RE):
            for trial in range(300):
                data = b"".join(rng.choice(self.PIECES) for _ in range(rng.randrange(0, 160)))
                if rng.random() < 0.2:
                    data = b"\x1b[" + b"1" * rng.randrange(0, 40) + b" " * rng.randrange(0, 5) + data
                whole = pattern.sub("", data.decode("utf-8", errors="replace"))
                for max_chars in (1, 2, 3, 7, 40, 1000):
                    chunk = rng.choice((1, 2, 3, 5, 64))
                    with self.subTest(pattern=pattern.pattern, trial=trial, max_chars=max_chars, chunk=chunk):
                        prefix = OUT.VisiblePrefix(max_chars, pattern)
                        for start in range(0, len(data), chunk):
                            prefix.feed(data[start:start + chunk])
                        self.assertEqual(prefix.finish(), whole[:max_chars])

    def test_visible_prefix_carry_stays_bounded(self) -> None:
        prefix = OUT.VisiblePrefix(10)
        prefix.feed(b"ab\x1b[")
        for _ in range(200):
            prefix.feed(b"1;" * 500)
            self.assertLessEqual(len(prefix._carry), 10 + 2)
        prefix.feed(b"\x07tail")  # BEL is no final byte: the whole candidate is literal
        self.assertEqual(prefix.finish(), "ab\x1b[1;1;1;")
        completed = OUT.VisiblePrefix(10)
        completed.feed(b"ab\x1b[" + b"1;" * 50000 + b"mcd")
        self.assertEqual(completed.finish(), "abcd")

    def test_ansi_only_input_retains_no_fragments(self) -> None:
        # S3-R1-01: an unterminated over-cap record of complete ANSI sequences must
        # not grow the collector, whatever the read sizes.
        for pieces in ((b"\x1b[0m",), (b"\x1b[0m" * 1000,), (b"\x1b[1;3", b"1m"), (b"\x1b", b"[0", b"m")):
            with self.subTest(pieces=pieces):
                prefix = OUT.VisiblePrefix(OUT.TAIL_VISIBLE_CHARS)
                for _ in range(5000):
                    for piece in pieces:
                        prefix.feed(piece)
                    self.assertEqual(len(prefix._parts), 0)
                prefix.feed(b"\x1b[0mabc")
                self.assertEqual(len(prefix._parts), 1)
                self.assertEqual(prefix.finish(), "abc")
        splitter = OUT.RecordSplitter()
        for _ in range(2000):
            splitter.feed(b"\x1b[0m" * 256, 0)
        self.assertEqual(splitter._visible._parts, [])
        self.assertEqual(splitter.finish(0)[0].visible, "")

    def test_records_within_the_cap_have_no_visible_prefix(self) -> None:
        records = split_all([b"\x1b[0mshort\n", b"x" * 70000 + b"\n"])
        self.assertEqual([record.visible for record in records], [None, "x" * OUT.TAIL_VISIBLE_CHARS])
        self.assertEqual([record.visible for record in split_all([b"x" * 70000 + b"\n"], visible_chars=0)], [None])

    def summaries(self, data: bytes) -> tuple[dict, dict]:
        with tempfile.TemporaryDirectory() as tmp:
            log = Path(tmp) / "o.log"
            log.write_bytes(data)
            got = conductor.OutputSummarizer.summarize_file("test", {}, "failed", 1, False, log)
            # The parent's reader: universal-newline text lines, cleaned line by line.
            with log.open("r", encoding="utf-8", errors="replace") as handle:
                want = conductor.OutputSummarizer.summarize_lines("test", {}, "failed", 1, False, handle)
        return got, want

    def test_over_cap_summary_lines_equal_the_whole_line_classification(self) -> None:
        cases = {
            "ansi-then-error": b"\x1b[31m" * 15000 + b"ERROR: boom\n",
            "ansi-then-long-error": b"\x1b[2K" * 20000 + b"Sources/A.swift:1:2: error: bad " + b"z" * 500 + b"\n",
            "long-csi-then-test-failure": b"\x1b[" + b"0;" * 40000 + b"mTest Case '-[M.S t]' failed (1.0 seconds).\r\n",
            "unterminated-candidate": b"\x1b[" + b"1;" * 40000 + b"\x07 FAILED here\r",
            "escape-escape": b"\x1b" + b"\x1b[0m" * 17000 + b"[31m==> phase\n",
            "non-csi-escape-stays": b"\x1b[0m" * 17000 + b"\x1bMERROR: kept escape\n",
            "multibyte-at-cut": b"\x1b[0m" * 16383 + b"abc" + "é".encode() * 300 + b" timed out after 3s",
        }
        for name, line in cases.items():
            with self.subTest(case=name):
                got, want = self.summaries(b"start\n" + line + b"\nok\n")
                self.assertEqual(got, want)

    def test_visible_summary_line_is_only_cut_never_cleaned_again(self) -> None:
        # A literal ESC left by the whole-record pass stays in the classified line:
        # cleaning it again would expose an anchored phase marker.
        def phases(line: str) -> Optional[dict]:
            summary = conductor.OutputSummarizer.summarize_lines("build", {}, "failed", 1, False, [line])
            return next((s for s in summary["sections"] if s["title"] == "Phases"), None)

        self.assertIsNone(phases(conductor.VisibleSummaryLine("\x1b[0m==> phase")))
        self.assertIsNotNone(phases("\x1b[0m==> phase"))
        summary = conductor.OutputSummarizer.summarize_lines(
            "build", {}, "failed", 1, False, [conductor.VisibleSummaryLine("==> " + "r" * 500)]
        )
        phase = next(s for s in summary["sections"] if s["title"] == "Phases")
        self.assertEqual(phase["lines"], [("==> " + "r" * 500)[: conductor.SUMMARY_LINE_MAX_CHARS - 1] + "…"])


class Step3BatchAndCancellationTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.state = timing_state(Path(self.tmp.name), "off")

    def test_batches_count_utf8_bytes_exactly(self) -> None:
        ascii_records = OUT.RecordSplitter().feed(b"".join(b"%05d" % index + b"x" * 250 + b"\n" for index in range(255)), 0)
        self.assertEqual(len(list(OUT.record_batches(ascii_records))), 1)  # one 64 KiB read, one lock
        wide = OUT.RecordSplitter().feed(("\U0001f600" * 1000 + "\n").encode() * 40, 0)
        batches = list(OUT.record_batches(wide))
        self.assertEqual([record for batch in batches for record in batch], wide)
        for batch in batches:
            self.assertLessEqual(sum(OUT.utf8_size(record.text) for record in batch), OUT.BATCH_MAX_BYTES)
        self.assertEqual([len(batch) for batch in batches], [16, 16, 8])

    def test_cancellation_mid_record_flushes_the_pending_record(self) -> None:
        # Cancellation closes the reader: the next read returns EOF (or raises) with a
        # partial record pending. It is flushed through tail and progress; raw is exact.
        for ending in ("eof", "error"):
            with self.subTest(ending=ending):
                job = xctest_job(self.state, f"c-{ending}")
                chunks = [b"\x1b[1mfirst\x1b[0m\r\nTest Case '-[M.S testC]' sta", b"rted."]
                reads = iter(chunks)

                def read_chunk() -> bytes:
                    try:
                        return next(reads)
                    except StopIteration:
                        if ending == "error":
                            raise OSError(errno.EBADF, "closed by cancellation")
                        return b""

                sink = io.BytesIO()
                if ending == "error":
                    with self.assertRaises(OSError):
                        self.state._pump_output(job.ticket, read_chunk, sink)
                else:
                    self.state._pump_output(job.ticket, read_chunk, sink)
                self.assertEqual(sink.getvalue(), b"".join(chunks))
                self.assertEqual(list(job.tail)[:2], ["first\n", "Test Case '-[M.S testC]' started."])
                self.assertEqual(job.xctest_current_test, "-[M.S testC]")


class FlushCountingSink(io.BytesIO):
    def __init__(self, fail_on_write: Optional[int] = None) -> None:
        super().__init__()
        self.flushes = 0
        self.writes = 0
        self.fail_on_write = fail_on_write

    def write(self, data: Any) -> int:
        self.writes += 1
        if self.fail_on_write is not None and self.writes == self.fail_on_write:
            raise OSError(errno.ENOSPC, "fixture write failure")
        return super().write(data)

    def flush(self) -> None:
        self.flushes += 1
        super().flush()


class Step3PtyCoalescingTests(unittest.TestCase):
    """OD14: bounded available-read coalescing keeps per-read times, raw bytes and order."""

    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.state = timing_state(Path(self.tmp.name), "off")

    def run_pump(
        self,
        blocking: list[bytes],
        available: Any,
        *,
        step_ns: int = 1_000,
        sink: Optional[io.BytesIO] = None,
        ticket: str = "co",
    ) -> dict:
        """Pump with fake per-read clocks; returns the event log and job state.

        ``available`` is a list (``None`` entries mean "nothing available now") or a
        callable. Each successful read is stamped by exactly one ``monotonic_ns`` /
        ``time.time`` call, recorded with the read it follows.
        """
        job = xctest_job(self.state, ticket)
        events: list[tuple] = []
        allowances: list[int] = []
        clock = {"ns": 1_000_000_000, "wall": 5_000.0}
        stamps: list[tuple[int, float]] = []
        blocking_reads = iter(blocking + [b""])
        available_reads = iter(available) if isinstance(available, list) else None

        def read_chunk() -> bytes:
            chunk = held.pop() if held else next(blocking_reads)
            events.append(("read", chunk))
            return chunk

        held: list[bytes] = []  # the unread rest of a chunk longer than the allowance

        def read_available(max_bytes: int) -> Optional[bytes]:
            allowances.append(max_bytes)
            if held:
                chunk: Optional[bytes] = held.pop()
            elif available_reads is None:
                chunk = available()
            else:
                chunk = next(available_reads, None)
            if chunk and len(chunk) > max_bytes:  # like os.read(fd, max_bytes)
                chunk, rest = chunk[:max_bytes], chunk[max_bytes:]
                held.append(rest)
            events.append(("available", chunk))
            return chunk

        def monotonic_ns() -> int:
            clock["ns"] += step_ns
            return clock["ns"]

        def wall() -> float:
            clock["wall"] += 1.0
            stamps.append((clock["ns"], clock["wall"]))
            return clock["wall"]

        original_apply = self.state._apply_xctest_progress_line_locked
        original_records = self.state._submit_output_records
        original_fail = self.state._fail_xctest_output_contract
        classify_flags: list[bool] = []

        def apply(target: Any, line: str, marker: Any, timestamp: float, observed_at: float) -> bool:
            events.append(("apply", line, timestamp, observed_at))
            return original_apply(target, line, marker, timestamp, observed_at)

        def submit_records(*args: Any) -> None:
            events.append(("records", [record.text for record in args[1]]))
            classify_flags.append(args[3])
            return original_records(*args)

        def fail(ticket_: str, kind: str, record_seq: int, line_open: bool = False) -> None:
            events.append(("fail", kind, record_seq))
            return original_fail(ticket_, kind, record_seq, line_open)

        sink = sink if sink is not None else FlushCountingSink()
        sink_flush = sink.flush

        def flush() -> None:
            events.append(("flush",))
            sink_flush()

        sink.flush = flush  # type: ignore[method-assign]
        error: Optional[BaseException] = None
        with contextlib.ExitStack() as stack:
            stack.enter_context(mock.patch.object(conductor.time, "monotonic_ns", side_effect=monotonic_ns))
            stack.enter_context(mock.patch.object(conductor.time, "time", side_effect=wall))
            stack.enter_context(mock.patch.object(self.state, "_apply_xctest_progress_line_locked", side_effect=apply))
            stack.enter_context(mock.patch.object(self.state, "_submit_output_records", side_effect=submit_records))
            stack.enter_context(mock.patch.object(self.state, "_fail_xctest_output_contract", side_effect=fail))
            try:
                self.state._pump_output(job.ticket, read_chunk, sink, None, read_available)
            except OSError as exc:
                error = exc
        read_stamps = iter(stamps)
        reads = []
        for event in events:
            if event[0] in {"read", "available"} and event[1]:
                reads.append((event[1], next(read_stamps)))
        if error is None:
            # Every read's raw bytes are written and flushed before anything else happens.
            for index, event in enumerate(events):
                if event[0] in {"read", "available"} and event[1]:
                    self.assertEqual(events[index + 1], ("flush",), f"read {index} not flushed first")
        return {"job": job, "events": events, "sink": sink, "error": error, "reads": reads, "allowances": allowances,
                "classify": classify_flags}

    @staticmethod
    def kinds(events: list[tuple]) -> list[str]:
        return [event[0] for event in events if event[0] != "flush"]

    def test_each_coalesced_read_keeps_its_receive_time_wall_time_and_bytes(self) -> None:
        blocking = [b"Test Case '-[M.S testA]' started.\nTest Case '-[M.S testA]' pas"]
        available = [b"sed (0.1 seconds).\nTest Case '-[M.S testB]' st", b"arted.\n", None]
        result = self.run_pump(blocking, available)
        (_r1, (ns1, wall1)), (_r2, (ns2, wall2)), (_r3, (ns3, wall3)) = result["reads"]
        applied = [event[1:] for event in result["events"] if event[0] == "apply"]
        self.assertEqual(applied, [
            ("Test Case '-[M.S testA]' started.", ns1 / 1e9, wall1),
            ("Test Case '-[M.S testA]' passed (0.1 seconds).", ns2 / 1e9, wall2),
            ("Test Case '-[M.S testB]' started.", ns3 / 1e9, wall3),
        ])
        self.assertTrue(ns1 < ns2 < ns3 and wall1 < wall2 < wall3)
        # One group: one flush and one submission, exact raw bytes in read order.
        self.assertEqual([event for event in result["events"] if event[0] == "records"], [("records", [
            "Test Case '-[M.S testA]' started.",
            "Test Case '-[M.S testA]' passed (0.1 seconds).",
            "Test Case '-[M.S testB]' started.",
        ])])
        self.assertEqual(result["sink"].getvalue(), blocking[0] + available[0] + available[1])
        self.assertEqual(result["sink"].flushes, 3)
        self.assertEqual(result["job"].xctest_progress_deadline, ns3 / 1e9 + result["job"].xctest_active_method_budget_seconds)
        self.assertEqual(result["job"].xctest_last_progress_observed_at, wall3)

    def test_groups_end_at_the_read_byte_and_time_bounds(self) -> None:
        line = b"x" * 99 + b"\n"
        for name, chunk, step_ns, expected in (
            ("reads", line, 1_000, OUT.COALESCE_MAX_READS),
            ("bytes", b"y" * 4095 + b"\n", 1_000, OUT.COALESCE_MAX_BYTES // 4096),
            # The clock advances 1 ms per call, and each further read costs two calls
            # (the budget check before it, its receive time after it); the k-th
            # check sees (2k - 1) ms, so reads stop at the first k with 2k - 1 >= 5.
            ("time", line, 1_000_000, next(k for k in itertools.count(1) if (2 * k - 1) * 1_000_000 >= OUT.COALESCE_MAX_NS)),
        ):
            with self.subTest(bound=name):
                remaining = {"count": 500}

                def available() -> Optional[bytes]:
                    if remaining["count"] == 0:
                        return None
                    remaining["count"] -= 1
                    return chunk

                result = self.run_pump([chunk] * 3, available, step_ns=step_ns, ticket=f"b-{name}")
                sizes = [len(event[1]) for event in result["events"] if event[0] == "records"]
                self.assertEqual(sizes, [expected] * 3)
                self.assertEqual(remaining["count"], 500 - 3 * (expected - 1))
                self.assertEqual(result["sink"].getvalue(), chunk * (3 * expected))
                self.assertEqual(result["sink"].flushes, 3 * expected)

    def test_uneven_reads_never_exceed_the_group_byte_budget(self) -> None:
        # 60 KiB first, then 8 KiB chunks: the next read may take only the 4 KiB
        # left in the group, and the rest of that chunk opens the next group.
        first = b"f" * (60 * 1024 - 1) + b"\n"
        chunk = b"e" * (8 * 1024 - 1) + b"\n"
        stream = [chunk] * 20
        result = self.run_pump([first, b"g\n"], lambda: stream.pop() if stream else None)
        self.assertEqual(result["allowances"][0], 4 * 1024)
        self.assertTrue(all(0 < allowance <= OUT.COALESCE_MAX_BYTES for allowance in result["allowances"]))
        groups: list[int] = []
        for event in result["events"]:
            if event[0] == "read" and event[1]:
                groups.append(len(event[1]))
            elif event[0] == "available" and event[1]:
                groups[-1] += len(event[1])
        self.assertEqual(groups[0], OUT.COALESCE_MAX_BYTES)
        self.assertTrue(all(size <= OUT.COALESCE_MAX_BYTES for size in groups), groups)
        taken = b"".join(event[1] for event in result["events"] if event[0] in {"read", "available"} and event[1])
        self.assertEqual(result["sink"].getvalue(), taken)  # every byte taken is relayed, in order
        self.assertEqual(taken, first + chunk * 20 + b"g\n")

    def test_no_further_read_starts_after_the_time_budget(self) -> None:
        # The first read's own processing already used the budget (6 ms per clock
        # call): no available read is even attempted, so nothing is consumed early.
        result = self.run_pump([b"one\n", b"two\n"], lambda: b"never\n", step_ns=6_000_000)
        self.assertNotIn("available", self.kinds(result["events"]))
        self.assertEqual(result["allowances"], [])
        self.assertEqual(list(result["job"].tail)[:2], ["one\n", "two\n"])

    def test_unavailable_data_ends_a_group_without_waiting(self) -> None:
        result = self.run_pump([b"one\n", b"two\n"], [None, b"three\n", None])
        self.assertEqual(self.kinds(result["events"]), [
            "read", "available", "records", "read", "available", "available", "records", "read",
        ])
        self.assertEqual(list(result["job"].tail)[:3], ["one\n", "two\n", "three\n"])

    @staticmethod
    def pending_markers(last: str) -> tuple[bytes, list[str]]:
        """One more VT-separated marker than an over-cap record may hold pending (OD16 D2)."""
        names = [f"-[M.S t{index}]" for index in range(OUT.SEGMENT_MAX_PENDING_ITEMS)] + [last]
        lines = [f"Test Case '{name}' started." for name in names]
        return "".join(line + "\x0b" for line in lines).encode(), lines

    def test_a_scanner_failure_ends_a_group_after_exactly_the_preceding_records(self) -> None:
        markers, _lines = self.pending_markers("-[M.S testX]")
        # Within one group the byte budget keeps a record started in that group under
        # the 64 KiB cap, so the record overflows in a later group: group 2 starts with
        # a small blocking read and overflows on an available read, whose OD16 failure
        # ends it although more data ("w" * 10) is available.
        first = b"Test Case '-[M.S testA]' started.\n" + markers + b"y" * 60000
        overflow = b"y" * 10000
        result = self.run_pump([first, b"y" * 100, b"\n"], [None, overflow, b"w" * 10, None, None])
        events = [event for event in result["events"] if event[0] in {"records", "fail", "available", "read"}]
        self.assertEqual(self.kinds(events), [
            "read", "available", "records", "read", "available", "fail",
            "read", "available", "available", "records", "read", "records",
        ])
        self.assertEqual(events[2][1], ["Test Case '-[M.S testA]' started."])
        self.assertEqual(events[5], ("fail", "pending", 1))
        # Nothing pending is applied, early or later; later records feed only the tail.
        self.assertEqual([event[1] for event in result["events"] if event[0] == "apply"],
                         ["Test Case '-[M.S testA]' started."])
        self.assertEqual(result["classify"], [True, False, False])
        job = result["job"]
        self.assertEqual(job.xctest_current_test, "-[M.S testA]")
        self.assertTrue(job.measurement_invalid)
        self.assertTrue((job.error or "").startswith("XCTest output contract failure (OD16): "))
        self.assertEqual(result["sink"].getvalue(), first + b"y" * 100 + overflow + b"\n" + b"w" * 10)

    def test_segment_items_within_the_bound_ride_on_the_record_through_a_group(self) -> None:
        # The record overflows in the second group and completes in a coalesced read.
        first = b"Test Case '-[M.S testA]' started.\n" + b"Test Case '-[M.S testX]' started.\x0b" + b"y" * 60000
        result = self.run_pump([first, b"y" * 10000], [None, b"w\n", None])
        self.assertEqual(self.kinds(result["events"]).count("fail"), 0)
        self.assertEqual(self.kinds([e for e in result["events"] if e[0] != "apply"])[:7],
                         ["read", "available", "records", "read", "available", "available", "records"])
        _r3, (ns3, wall3) = result["reads"][2]
        applied = [event[1:] for event in result["events"] if event[0] == "apply"]
        self.assertEqual(applied[-1], ("Test Case '-[M.S testX]' started.", ns3 / 1e9, wall3))
        self.assertEqual(result["job"].xctest_current_test, "-[M.S testX]")

    def test_a_scanner_failure_in_a_groups_first_read_skips_coalescing(self) -> None:
        # The record pends in group 1; group 2's first (blocking) read overflows it and
        # fails, so group 2 takes no available read although "z\n" is there.
        markers, _lines = self.pending_markers("-[M.S testX]")
        result = self.run_pump([b"y" * 60000, b"\x0b" + markers + b"y" * 6000], [None, b"z\n", None])
        self.assertEqual(self.kinds([e for e in result["events"] if e[0] != "apply"]),
                         ["read", "available", "read", "fail", "read", "records"])
        self.assertEqual(result["allowances"], [OUT.COALESCE_MAX_BYTES - 60000])  # group 1 only
        self.assertEqual(result["classify"], [False])
        self.assertEqual(result["sink"].getvalue(), b"y" * 60000 + b"\x0b" + markers + b"y" * 6000)

    def test_a_failure_mid_group_still_delivers_the_earlier_reads(self) -> None:
        sink = FlushCountingSink(fail_on_write=3)
        result = self.run_pump([b"one\n"], [b"two\n", b"three\n", b"four\n"], sink=sink)
        self.assertIsInstance(result["error"], OSError)
        self.assertEqual(list(result["job"].tail), ["one\n", "two\n"])
        self.assertEqual(sink.getvalue(), b"one\ntwo\n")
        self.assertEqual(sink.flushes, 2)

    def test_transport_read_available_never_waits_and_tolerates_closure(self) -> None:
        transport = conductor.ProcessOutputTransport.create("pty")
        self.addCleanup(transport.close_all)
        self.assertIsNone(conductor.ProcessOutputTransport.create("pipe").read_available())
        started = time.monotonic()
        self.assertIsNone(transport.read_available())
        self.assertLess(time.monotonic() - started, 0.5)
        os.write(transport.slave_fd, b"hello")
        received = b""
        deadline = time.monotonic() + 5
        while received != b"hello" and time.monotonic() < deadline:
            received += transport.read_available() or b""
        self.assertEqual(received, b"hello")
        # The byte allowance bounds a real read (S3-R1-02).
        os.write(transport.slave_fd, b"abcdefgh")
        pieces: list[bytes] = []
        deadline = time.monotonic() + 5
        while b"".join(pieces) != b"abcdefgh" and time.monotonic() < deadline:
            piece = transport.read_available(3)
            if piece:
                self.assertLessEqual(len(piece), 3)
                pieces.append(piece)
        self.assertEqual(b"".join(pieces), b"abcdefgh")
        with mock.patch.object(conductor.select, "select", side_effect=ValueError("filedescriptor out of range")):
            self.assertIsNone(transport.read_available())
        with mock.patch.object(conductor.select, "select", return_value=([transport.master_fd], [], [])), \
                mock.patch.object(conductor.os, "read", side_effect=OSError(errno.EIO, "eof")):
            self.assertIsNone(transport.read_available())
        transport.close_reader()
        self.assertIsNone(transport.read_available())

    def test_read_process_output_coalesces_only_real_pty_transports(self) -> None:
        for kind in ("pty", "pipe"):
            with self.subTest(kind=kind):
                job = xctest_job(self.state, f"wire-{kind}")
                transport = mock.Mock(kind=kind)
                transport.read_chunk.side_effect = [b"a\n", b"b\n", b""]
                transport.read_available.return_value = None
                self.state._read_process_output(job.ticket, mock.Mock(), io.BytesIO(), transport)
                if kind == "pty":
                    self.assertEqual(transport.read_available.call_count, 2)
                else:
                    transport.read_available.assert_not_called()
                self.assertEqual(list(job.tail)[:2], ["a\n", "b\n"])
                transport.close_reader.assert_called_once()


class Step3SummaryDisclosureTests(unittest.TestCase):
    """S3-R0-01 (OD15) and S3-R0-06: saturated deduplication is disclosed in payload and terminal."""

    def test_keep_last_repeat_after_saturation_is_disclosed(self) -> None:
        lines = ["a", "b", "c", "d", "b"]
        limited = conductor.SummarySectionBuilder("Phases", 2, keep_last=True, max_seen=1)
        exact = conductor.SummarySectionBuilder("Phases", 2, keep_last=True, max_seen=10**9)
        limited.extend(lines)
        exact.extend(lines)
        self.assertEqual(exact.lines, ["c", "d"])
        self.assertEqual(limited.lines, ["d", "b"])  # the repeated older line OD15 permits
        payload = limited.payload()
        self.assertEqual(
            (payload["deduplicationLimited"], payload["omittedLineCountQuality"], payload["displayedLinesMayRepeat"]),
            (True, "upper_bound", True),
        )
        self.assertFalse(exact.payload()["displayedLinesMayRepeat"])

    def test_keep_last_without_eviction_and_first_lines_sections_stay_exact(self) -> None:
        roomy = conductor.SummarySectionBuilder("Phases", 10, keep_last=True, max_seen=1)
        roomy.extend(["a", "b", "c", "b", "c"])
        self.assertEqual(roomy.lines, ["a", "b", "c"])
        self.assertFalse(roomy.payload()["displayedLinesMayRepeat"])
        first = conductor.SummarySectionBuilder("Failure highlights", 2, max_seen=1)
        first.extend(["a", "b", "c", "d", "b"])
        self.assertEqual(first.lines, ["a", "b"])
        self.assertFalse(first.payload()["displayedLinesMayRepeat"])

    def test_production_limit_phase_repeat_is_disclosed_in_payload_and_terminal(self) -> None:
        lines = [f"+ step {index}" for index in range(conductor.SUMMARY_SEEN_MAX_ENTRIES + 50)] + ["+ step 4100"]
        summary = summarize("build", "failed", 1, lines)
        phases = next(item for item in summary["sections"] if item["title"] == "Phases")
        self.assertEqual(phases["lines"][-1], "+ step 4100")
        self.assertTrue(phases["displayedLinesMayRepeat"])
        self.assertTrue(summary["displayedLinesMayRepeat"])
        self.assertEqual(summary["omittedLineCountQuality"], "exact")
        with contextlib.redirect_stdout(io.StringIO()) as out:
            conductor.render_output_summary(summary)
        text = out.getvalue()
        self.assertIn("omitted at most ", text)
        self.assertIn("the count is an upper bound", text)
        self.assertIn("these lines may repeat older lines of this section", text)

    def test_exact_counts_render_unqualified(self) -> None:
        summary = summarize("build", "failed", 1, [f"+ step {index}" for index in range(40)])
        with contextlib.redirect_stdout(io.StringIO()) as out:
            conductor.render_output_summary(summary)
        self.assertIn("... omitted 20 matching line(s); see full log path above", out.getvalue())
        self.assertNotIn("at most", out.getvalue())
        self.assertNotIn("may repeat", out.getvalue())

    def test_artifact_scope_section_carries_the_v2_fields(self) -> None:
        payload = {"artifactScope": "current", "artifactScopeMessage": "artifact_scope: current", "state": "completed"}
        enriched = conductor._with_artifact_scope_summary(payload, summarize("build", "completed", 0, ["x"]))
        scope = enriched["sections"][0]
        self.assertEqual(scope["title"], "Artifact scope")
        self.assertEqual(
            {key: scope[key] for key in ("deduplicationLimited", "omittedLineCountQuality", "displayedLinesMayRepeat")},
            {"deduplicationLimited": False, "omittedLineCountQuality": "exact", "displayedLinesMayRepeat": False},
        )


class Step3SummaryPendingAndPinTests(unittest.TestCase):
    """S3-R0-02 (pending summary, one scan) and S3-R0-04 (retention pins)."""

    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.state = timing_state(Path(self.tmp.name), "off")
        self.job = timing_job(self.state, "s")
        self.job.log_path.write_bytes(b"error: boom\n")
        self.job.state = "failed"
        self.job.exit_code = 1
        self.job.finished_at = conductor.now()
        self.calls: list[str] = []
        self.gate = threading.Event()
        self.real = conductor.OutputSummarizer.summarize_file

    def slow(self, *args: Any) -> dict:
        self.calls.append(threading.current_thread().name)
        if threading.current_thread().name == "claimant":
            self.gate.wait(10)
        return self.real(*args)

    def start_claimant(self) -> threading.Thread:
        claimant = threading.Thread(target=self.state._refresh_output_summary, args=(self.job,), name="claimant")
        claimant.start()
        deadline = time.monotonic() + 5
        while not self.calls and time.monotonic() < deadline:
            time.sleep(0.005)
        self.assertEqual(self.calls, ["claimant"])
        return claimant

    def test_deadline_limited_wait_marks_the_summary_pending_and_clients_never_rescan(self) -> None:
        with mock.patch.object(conductor.OutputSummarizer, "summarize_file", side_effect=self.slow):
            claimant = self.start_claimant()
            payload = self.state.job_wait("s", None, 0.05)
            self.assertEqual((payload["waitTimedOut"], payload.get("summaryPending")), (False, True))
            self.assertNotIn("outputSummary", payload)
            enriched = conductor.payload_with_output_summary(payload)
            summary = conductor.output_summary_for_payload(payload)
            with contextlib.redirect_stdout(io.StringIO()) as out:
                conductor.print_terminal_job_output(payload)
                conductor.render_job(payload)
            self.assertEqual(self.calls, ["claimant"])  # no client-side scan anywhere
            self.assertIn(conductor.SUMMARY_PENDING_NOTE, json.dumps(enriched["outputSummary"]))
            self.assertIn("logTail", enriched)  # the live tail stays while the summary is pending
            self.assertIn(conductor.SUMMARY_PENDING_NOTE, json.dumps(summary))
            self.assertIn("still being generated", out.getvalue())
            self.gate.set()
            claimant.join(10)
            final = self.state.job_wait("s", None, 0.05)
        self.assertEqual(self.calls, ["claimant"])
        self.assertNotIn("summaryPending", final)
        self.assertIn("error: boom", section(final["outputSummary"], "Failure highlights"))

    def test_legacy_payload_without_the_pending_flag_still_scans_client_side(self) -> None:
        payload = {"ticket": "s", "operation": "build", "state": "failed", "exitCode": 1, "logPath": str(self.job.log_path)}
        with mock.patch.object(conductor.OutputSummarizer, "summarize_file", side_effect=self.slow):
            summary = conductor.output_summary_for_payload(payload)
        self.assertEqual(len(self.calls), 1)
        self.assertIn("error: boom", section(summary, "Failure highlights"))

    def test_wait_for_terminal_rewaits_a_pending_summary_within_its_bound(self) -> None:
        pending = {"ticket": "s", "state": "failed", "exitCode": 1, "summaryPending": True, "waitTimedOut": False}
        done = dict(pending, summaryPending=None, outputSummary={"headline": "x", "sections": []})
        done.pop("summaryPending")
        replies = iter([pending, pending, done])
        with mock.patch.object(conductor, "request_daemon", side_effect=lambda *a, **k: next(replies)) as request:
            final = conductor.wait_for_terminal(Path("/nonexistent"), "s", None, json_mode=True)
        self.assertEqual(final, done)
        self.assertEqual(request.call_count, 3)
        clock = iter([0.0, 0.0, 0.0, 10.0, 70.0, 70.0, 70.0])
        bounded_replies = iter([pending] * 20)  # an unbounded re-wait exhausts these and errors
        with mock.patch.object(conductor, "request_daemon", side_effect=lambda *a, **k: next(bounded_replies)) as request, \
                mock.patch.object(conductor, "now", side_effect=lambda: next(clock)):
            final = conductor.wait_for_terminal(Path("/nonexistent"), "s", None, json_mode=True)
        self.assertTrue(final["summaryPending"])  # bounded: returned without a summary, never scanned
        self.assertEqual(request.call_count, 3)

    def prune_conditions(self) -> dict:
        return {
            "age": lambda: setattr(self.job, "finished_at", conductor.now() - conductor.TERMINAL_RETENTION_SECONDS - 5),
            "count": lambda: mock.patch.object(conductor, "MAX_TERMINAL_JOBS", 0).start(),
        }

    def test_retention_never_prunes_a_job_during_summary_or_its_payload(self) -> None:
        for boundary in ("age", "count"):
            for consumer in ("status", "wait"):
                with self.subTest(boundary=boundary, consumer=consumer):
                    self.setUp()
                    self.addCleanup(mock.patch.stopall)
                    self.prune_conditions()[boundary]()
                    results: dict = {}

                    def run() -> None:
                        try:
                            if consumer == "status":
                                results["payload"] = self.state.job_status("s", None)
                            else:
                                results["payload"] = self.state.job_wait("s", None, 30.0)
                        except Exception as exc:  # noqa: BLE001
                            results["error"] = exc

                    with mock.patch.object(conductor.OutputSummarizer, "summarize_file", side_effect=self.slow):
                        claimant = self.start_claimant()
                        consumer_thread = threading.Thread(target=run)
                        consumer_thread.start()
                        deadline = time.monotonic() + 5
                        while self.job.summary_pins < 2 and time.monotonic() < deadline:
                            time.sleep(0.005)
                        with self.state.condition:
                            self.state._retention_pass_locked()
                        self.assertIn("s", self.state.jobs)
                        self.assertTrue(self.job.log_path.exists())
                        self.assertTrue(self.job.retention_deferred)
                        self.gate.set()
                        claimant.join(10)
                        consumer_thread.join(10)
                    mock.patch.stopall()
                    self.assertNotIn("error", results)
                    self.assertIn("error: boom", section(results["payload"]["outputSummary"], "Failure highlights"))
                    self.assertEqual(self.calls, ["claimant"])
                    self.assertEqual(self.job.summary_pins, 0)
                    self.assertNotIn("s", self.state.jobs)  # the last unpin reran the deferred retention
                    self.assertTrue(self.state._await_maintenance(10.0))  # Step 5: deletion is off-lock
                    self.assertFalse(self.job.log_path.exists())

    def test_pins_are_released_on_failure_and_base_exception_paths(self) -> None:
        class Abort(BaseException):
            pass

        with mock.patch.object(conductor.OutputSummarizer, "summarize_file", side_effect=RuntimeError("scan broke")):
            payload = self.state.job_status("s", None)
        self.assertIn("summary failed: RuntimeError", json.dumps(payload["outputSummary"]))
        self.assertEqual(self.job.summary_pins, 0)
        other = timing_job(self.state, "t")
        other.state, other.exit_code = "failed", 1
        with mock.patch.object(conductor.OutputSummarizer, "summarize_file", side_effect=Abort()):
            with self.assertRaises(Abort):
                self.state.job_wait("t", None, 5.0)
        self.assertEqual(other.summary_state, "failed")
        self.assertTrue(other.summary_event.is_set())
        self.assertIn("summary failed: Abort", json.dumps(other.output_summary))
        self.assertEqual(other.summary_pins, 0)



class Step5RetentionMaintenanceTests(unittest.TestCase):
    """Step 5: retention decides under the scheduler lock; one worker does the file work."""

    T1 = "0d6f2c1e-5a7b-4c3d-9e8f-000000000001"
    T2 = "0d6f2c1e-5a7b-4c3d-9e8f-000000000002"
    T3 = "0d6f2c1e-5a7b-4c3d-9e8f-000000000003"
    ORPHAN = "0d6f2c1e-5a7b-4c3d-9e8f-0000000000aa"
    FRESH_ORPHAN = "0d6f2c1e-5a7b-4c3d-9e8f-0000000000bb"

    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.old = time.time() - conductor.TERMINAL_RETENTION_SECONDS - 60

    def make_state(self, name: str, timing: str = "off") -> conductor.DaemonState:
        state = timing_state(self.root / name, timing)
        self.addCleanup(state._await_maintenance, 10.0)
        self.addCleanup(state._await_job_telemetry, 10.0)
        return state

    def write_family(self, state: conductor.DaemonState, ticket: str, aged: bool = True) -> list[Path]:
        paths = [state.paths.jobs_dir / f"{ticket}{suffix}" for suffix in conductor.GENERATED_JOB_FILE_SUFFIXES]
        for path in paths:
            path.write_text("x")
            if aged:
                os.utime(path, (self.old, self.old))
        return paths

    def terminal_job(
        self, state: conductor.DaemonState, ticket: str, expired: bool = True, aged: bool = True
    ) -> conductor.Job:
        job = timing_job(state, ticket)
        job.state, job.exit_code = "completed", 0
        job.finished_at = conductor.now() - (conductor.TERMINAL_RETENTION_SECONDS + 10 if expired else 0)
        paths = self.write_family(state, ticket, aged=aged)
        job.diagnostic_paths = [path for path in paths if ".xctest-stall." in path.name]
        return job

    def names(self, state: conductor.DaemonState) -> list[str]:
        return sorted(path.name for path in state.paths.jobs_dir.iterdir())

    def generated_names(self, ticket: str) -> list[str]:
        return sorted(f"{ticket}{suffix}" for suffix in conductor.GENERATED_JOB_FILE_SUFFIXES)

    def run_pass(self, state: conductor.DaemonState) -> None:
        with state.condition:
            state._retention_pass_locked()

    def rewind_sweep_interval(self, state: conductor.DaemonState) -> None:
        with state._maintenance_cv:
            state._last_orphan_sweep -= conductor.ORPHAN_SWEEP_INTERVAL_SECONDS

    def io_guard(self, state: conductor.DaemonState, block_unlink: Optional[threading.Event] = None):
        """Record jobs-dir scans/stats/unlinks and whether the caller held the scheduler lock."""
        jobs_dir = str(state.paths.jobs_dir)
        calls: list[tuple[str, bool]] = []
        entered = threading.Event()
        real = {
            "os.scandir": os.scandir, "os.unlink": os.unlink, "os.stat": os.stat, "os.lstat": os.lstat,
            "Path.unlink": Path.unlink, "Path.stat": Path.stat, "Path.glob": Path.glob, "Path.iterdir": Path.iterdir,
        }

        def wrap(name: str, fn: Any) -> Any:
            def guarded(target: Any, *args: Any, **kwargs: Any) -> Any:
                if str(target).startswith(jobs_dir):
                    calls.append((name, state.lock._is_owned()))
                    if block_unlink is not None and "unlink" in name and not entered.is_set():
                        entered.set()
                        block_unlink.wait(10.0)
                return fn(target, *args, **kwargs)

            return guarded

        stack = contextlib.ExitStack()
        for name, fn in real.items():
            owner, attr = (os, name[3:]) if name.startswith("os.") else (Path, name[5:])
            stack.enter_context(mock.patch.object(owner, attr, wrap(name, fn)))
        return stack, calls, entered

    def test_generated_name_predicate_accepts_only_exact_families_of_uuid_tickets(self) -> None:
        t = self.T1
        accepted = [f"{t}{suffix}" for suffix in conductor.GENERATED_JOB_FILE_SUFFIXES]
        self.assertEqual(
            sorted(accepted),
            sorted(f"{t}{s}" for s in (".log", ".xctest-stall.json", ".xctest-stall.sample.txt", ".timing-events.jsonl", ".timings.json", ".runner-timings.json")),
        )
        for name in accepted:
            self.assertEqual(conductor.generated_job_file_ticket(name), t, name)
        for name in (
            f"{t}.log.bak", f"{t}.xctest-stall.extra", f"{t}.timings.json.tmp", f"{t}.json", f"{t}",
            f"{t.upper()}.log", f"x{t}.log", f"{t}x.log", "notes.log", "kept.log", "build-ticket-root.json",
            "daemon.log", ".log", f"{t[:-1]}.timings.json",
        ):
            self.assertIsNone(conductor.generated_job_file_ticket(name), name)

    def test_cleanup_runs_off_the_scheduler_lock_and_deletes_only_exact_generated_families(self) -> None:
        state = self.make_state("offlock")
        jobs_dir = state.paths.jobs_dir
        for ticket in (self.T1, self.T2):
            self.terminal_job(state, ticket)
        # A recorded path that is not this ticket's generated file is never deleted.
        state.jobs[self.T2].diagnostic_paths.append(jobs_dir / "build-ticket-root.json")
        self.terminal_job(state, self.T3, expired=False)
        self.write_family(state, self.ORPHAN)
        self.write_family(state, self.FRESH_ORPHAN, aged=False)
        foreign = [f"{self.ORPHAN}.log.bak", f"{self.ORPHAN}.xctest-stall.extra", "notes.log", "build-ticket-root.json"]
        for name in foreign:
            (jobs_dir / name).write_text("keep")
            os.utime(jobs_dir / name, (self.old, self.old))
        (jobs_dir / f"{self.T1[:-1]}9.log").mkdir()  # a directory with a generated name is never removed
        stack, calls, _entered = self.io_guard(state)
        with stack:
            self.run_pass(state)
            self.assertTrue(state._await_maintenance(10.0))
        self.assertEqual([call for call in calls if call[1]], [])  # nothing under the scheduler lock
        self.assertIn("os.scandir", {name for name, _ in calls})  # the guard observed the sweep
        self.assertTrue(any("unlink" in name for name, _ in calls))
        self.assertEqual(sorted(state.jobs), [self.T3])
        self.assertEqual(
            self.names(state),
            sorted([*self.generated_names(self.T3), *self.generated_names(self.FRESH_ORPHAN), *foreign, f"{self.T1[:-1]}9.log"]),
        )

    def test_status_and_enqueue_stay_within_50ms_while_cleanup_is_blocked(self) -> None:
        state = self.make_state("blocked")
        self.terminal_job(state, self.T1)
        state.active_lanes["style"] = "occupied"  # enqueued jobs stay queued; no child process runs
        release = threading.Event()
        self.addCleanup(release.set)
        request = {"operation": "build", "args": {}, "env": {}}
        prepared = ([sys.executable, "-c", "pass"], ["style"], state.paths.repo_root, {}, 30.0)
        stack, _calls, entered = self.io_guard(state, block_unlink=release)
        with stack, mock.patch.object(state.registry, "prepare", return_value=prepared):
            trigger = threading.Thread(target=state.enqueue, args=(request,), daemon=True)
            trigger.start()
            self.assertTrue(entered.wait(5.0), "the worker never started the blocked unlink")
            latencies: dict[str, float] = {}

            def measure(label: str, call: Any) -> None:
                start = time.perf_counter()
                call()
                latencies[label] = time.perf_counter() - start

            for label, call in (
                ("status", state.status_payload),
                ("enqueue", lambda: state.enqueue(request)),
                ("list", lambda: state.list_jobs(None)),
            ):
                probe = threading.Thread(target=measure, args=(label, call), daemon=True)
                probe.start()
                probe.join(1.0)
                self.assertFalse(probe.is_alive(), f"{label} blocked behind cleanup")
                self.assertLessEqual(latencies[label], 0.05, latencies)
            trigger.join(1.0)
            self.assertFalse(trigger.is_alive())
            self.assertNotIn(self.T1, state.jobs)  # evicted before its files are gone
            self.assertTrue((state.paths.jobs_dir / f"{self.T1}.log").exists())
            self.assertFalse(state._await_maintenance(0.05))  # bounded drain reports the stuck cleanup
            release.set()
            self.assertTrue(state._await_maintenance(10.0))
        self.assertFalse(any(name.startswith(self.T1) for name in self.names(state)))

    def test_orphan_sweeps_coalesce_to_one_per_interval_without_delaying_exact_removals(self) -> None:
        state = self.make_state("coalesce")
        scans: list[str] = []
        real_scandir = os.scandir

        def counting_scandir(path: Any) -> Any:
            if str(path) == str(state.paths.jobs_dir) and threading.current_thread().name == "conductor-maintenance":
                scans.append(threading.current_thread().name)
            return real_scandir(path)

        with mock.patch.object(os, "scandir", counting_scandir):
            self.run_pass(state)
            self.assertTrue(state._await_maintenance(10.0))
            self.assertEqual(scans, ["conductor-maintenance"])
            self.write_family(state, self.ORPHAN)
            self.terminal_job(state, self.T1)
            for _ in range(5):
                self.run_pass(state)
                self.assertTrue(state._await_maintenance(10.0))
            self.assertEqual(len(scans), 1)  # coalesced: one sweep in the interval
            self.assertFalse(any(name.startswith(self.T1) for name in self.names(state)))  # not delayed
            self.assertEqual(self.names(state), self.generated_names(self.ORPHAN))
            with state._maintenance_cv:
                self.assertTrue(state._orphan_sweep_requested)
                self.assertIsNone(state._maintenance_thread)  # idle: no worker waits for the interval
            self.rewind_sweep_interval(state)
            self.run_pass(state)
            self.assertTrue(state._await_maintenance(10.0))
        self.assertEqual(len(scans), 2)
        self.assertEqual(self.names(state), [])

    def test_failed_cleanup_is_retried_by_a_later_sweep_and_never_changes_jobs(self) -> None:
        state = self.make_state("retry")
        # Fresh files of an evicted ticket (as after a 200-job eviction): only the
        # exact retry can remove them; the age-gated orphan sweep never would.
        self.terminal_job(state, self.T1, aged=False)
        survivor = self.terminal_job(state, self.T2, expired=False)
        stuck = state.paths.jobs_dir / f"{self.T1}.log"
        real_unlink = Path.unlink
        failures: list[Path] = []

        def failing_unlink(path: Path, *args: Any, **kwargs: Any) -> None:
            if path == stuck and not failures:
                failures.append(path)
                raise PermissionError(errno.EACCES, "denied", str(path))
            real_unlink(path, *args, **kwargs)

        with mock.patch.object(Path, "unlink", failing_unlink):
            self.run_pass(state)
            self.assertTrue(state._await_maintenance(10.0))
        self.assertEqual(failures, [stuck])
        self.assertEqual(self.names(state), sorted([stuck.name, *self.generated_names(self.T2)]))
        with self.assertRaisesRegex(conductor.ConductorError, "unknown job"):
            state.job_status(self.T1, None)  # evicted ticket stays unknown
        self.assertEqual((survivor.state, survivor.exit_code), ("completed", 0))
        with state._maintenance_cv:
            self.assertEqual(state._maintenance_retry, {stuck: self.T1})
            self.assertIn("retried", state._maintenance_error)
        self.run_pass(state)  # within the interval: no retry yet
        self.assertTrue(state._await_maintenance(10.0))
        self.assertTrue(stuck.exists())
        self.rewind_sweep_interval(state)
        self.run_pass(state)
        self.assertTrue(state._await_maintenance(10.0))
        self.assertFalse(stuck.exists())
        with state._maintenance_cv:
            self.assertEqual(state._maintenance_retry, {})
        self.assertEqual((survivor.state, survivor.exit_code), ("completed", 0))

    def test_worker_start_failure_keeps_removals_queued_for_the_next_signal(self) -> None:
        state = self.make_state("start")
        self.terminal_job(state, self.T1)
        real_start = threading.Thread.start
        refused: list[str] = []

        def refusing_start(thread: threading.Thread) -> None:
            if thread.name == "conductor-maintenance" and not refused:
                refused.append(thread.name)
                raise RuntimeError("can't start new thread")
            real_start(thread)

        with mock.patch.object(threading.Thread, "start", refusing_start):
            self.run_pass(state)  # never raises into the transition
        self.assertEqual(refused, ["conductor-maintenance"])
        self.assertNotIn(self.T1, state.jobs)
        self.assertIn("not started", state._maintenance_error)
        self.assertFalse(state._await_maintenance(0.05))  # queued work, no worker
        self.assertTrue((state.paths.jobs_dir / f"{self.T1}.log").exists())
        self.run_pass(state)
        self.assertTrue(state._await_maintenance(10.0))
        self.assertEqual(self.names(state), [])

    def gate_persistence(self, state: conductor.DaemonState) -> tuple[threading.Event, threading.Event]:
        entered, release = threading.Event(), threading.Event()
        self.addCleanup(release.set)
        real_persist = state._persist_job_telemetry

        def gated(*args: Any) -> Any:
            entered.set()
            release.wait(10.0)
            return real_persist(*args)

        state._persist_job_telemetry = gated  # type: ignore[method-assign]
        return entered, release

    def assert_pinned_then_pruned_without_recreation(
        self, state: conductor.DaemonState, ticket: str, entered: threading.Event, release: threading.Event
    ) -> None:
        self.assertTrue(entered.wait(10.0))
        with mock.patch.object(conductor, "MAX_TERMINAL_JOBS", 0):
            self.run_pass(state)
            job = state.jobs.get(ticket)
            self.assertIsNotNone(job)  # finalization still owns the job
            self.assertTrue(job.retention_deferred)
            release.set()
            deadline = time.monotonic() + 10.0
            while ticket in state.jobs and time.monotonic() < deadline:
                time.sleep(0.005)
            self.assertNotIn(ticket, state.jobs)  # the finalizer's last unpin reran retention
        self.assertTrue(job.telemetry_persisted)
        self.assertIsNone(job.telemetry_persist_error)
        self.assertTrue(state._await_maintenance(10.0))
        self.assertEqual([name for name in self.names(state) if name.startswith(ticket)], [])

    def test_dispatched_job_finalization_pins_until_timing_is_persisted(self) -> None:
        state = self.make_state("dispatched", timing="on")
        entered, release = self.gate_persistence(state)
        argv = [sys.executable, "-c", "print('done')"]
        with mock.patch.object(
            state.registry, "prepare",
            side_effect=lambda _request: (argv, ["style"], state.paths.repo_root, {"PATH": os.environ.get("PATH", "")}, 30.0),
        ), mock.patch.object(conductor, "operation_requires_global_heavy_slot", return_value=False):
            enqueued = state.enqueue({"operation": "build", "args": {}, "env": {}})
            waited = state.job_wait(enqueued["ticket"], None, 30.0)
        self.assertEqual(waited["state"], "completed")
        self.assertIsNotNone(waited.get("outputSummary"))  # the summary pin is already released
        self.assert_pinned_then_pruned_without_recreation(state, enqueued["ticket"], entered, release)

    def test_job_owned_reader_that_outlives_run_job_keeps_the_job_pinned(self) -> None:
        state = self.make_state("reader")
        entered, release = threading.Event(), threading.Event()
        self.addCleanup(release.set)
        real_reader = conductor.DaemonState._read_process_output

        def held_reader(state_self: conductor.DaemonState, *args: Any) -> None:
            entered.set()
            release.wait(10.0)
            real_reader(state_self, *args)

        argv = [sys.executable, "-c", "print('done')"]
        with mock.patch.object(conductor.DaemonState, "_read_process_output", held_reader), mock.patch.object(
            conductor, "OUTPUT_READER_JOIN_SECONDS", 0.05
        ), mock.patch.object(
            state.registry, "prepare",
            side_effect=lambda _request: (argv, ["style"], state.paths.repo_root, {"PATH": os.environ.get("PATH", "")}, 30.0),
        ), mock.patch.object(conductor, "operation_requires_global_heavy_slot", return_value=False):
            ticket = state.enqueue({"operation": "build", "args": {}, "env": {}})["ticket"]
            waited = state.job_wait(ticket, None, 30.0)
            self.assertTrue(entered.is_set())
            self.assertIn(waited["state"], conductor.TERMINAL_STATES)
            job = state.jobs[ticket]
            deadline = time.monotonic() + 10.0
            while job.summary_pins > 1 and time.monotonic() < deadline:  # _run_job finished; only the reader holds one
                time.sleep(0.005)
            self.assertEqual(job.summary_pins, 1)
            with mock.patch.object(conductor, "MAX_TERMINAL_JOBS", 0):
                self.run_pass(state)
                self.assertIn(ticket, state.jobs)
                self.assertTrue(job.retention_deferred)
                release.set()
                while ticket in state.jobs and time.monotonic() < deadline:
                    time.sleep(0.005)
                self.assertNotIn(ticket, state.jobs)
        self.assertTrue(state._await_maintenance(10.0))
        self.assertEqual([name for name in self.names(state) if name.startswith(ticket)], [])

    def test_undispatched_timing_completion_pins_until_persisted(self) -> None:
        state = self.make_state("undispatched", timing="on")
        state.active_lanes["style"] = "occupied"
        entered, release = self.gate_persistence(state)
        prepared = ([sys.executable, "-c", "pass"], ["style"], state.paths.repo_root, {}, 30.0)
        with mock.patch.object(state.registry, "prepare", return_value=prepared):
            ticket = state.enqueue({"operation": "build", "args": {}, "env": {}})["ticket"]
        canceled = state.job_cancel(ticket, None)
        self.assertEqual((canceled["state"], canceled["exitCode"]), ("canceled", 130))
        self.assert_pinned_then_pruned_without_recreation(state, ticket, entered, release)



class Step5OwnershipPinTests(unittest.TestCase):
    """Step 5 r1: every owner that can still write a job's files keeps it pinned (S5-R0-OWNERSHIP / S5-R0-01/02)."""

    CANCEL_OWNERS = ("owner-cancel", "_escalate_canceled_job_after_grace", "_force_shutdown_when_canceled")
    SLEEPER = "import time; print('ready', flush=True); time.sleep(60)"

    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)

    def make_state(self, name: str, timing: str) -> conductor.DaemonState:
        state = timing_state(self.root / name, timing)
        self.addCleanup(state._await_maintenance, 10.0)
        self.addCleanup(state._await_job_telemetry, 10.0)
        return state

    def names(self, state: conductor.DaemonState, ticket: str) -> list[str]:
        return sorted(path.name for path in state.paths.jobs_dir.iterdir() if path.name.startswith(ticket))

    def track_run_job(self) -> dict:
        """Patch ``_run_job`` so each ticket's real runner signals when it has fully returned."""
        done: dict = {}
        real = conductor.DaemonState._run_job

        def tracked_run_job(state_self: conductor.DaemonState, ticket: str) -> None:
            event = done.setdefault(ticket, threading.Event())
            try:
                real(state_self, ticket)
            finally:
                event.set()

        patcher = mock.patch.object(conductor.DaemonState, "_run_job", tracked_run_job)
        patcher.start()
        self.addCleanup(patcher.stop)
        return done

    def prepare_patches(self, state: conductor.DaemonState, child_lanes: list[str]) -> contextlib.ExitStack:
        def prepare(request: dict) -> tuple:
            env = {"PATH": os.environ.get("PATH", "")}
            if request.get("operation") == "app":  # the superseding job stays queued behind "release"
                return ([sys.executable, "-c", "pass"], ["liveApp", "release"], state.paths.repo_root, env, 30.0)
            return ([sys.executable, "-u", "-c", self.SLEEPER], child_lanes, state.paths.repo_root, env, 60.0)

        stack = contextlib.ExitStack()
        stack.enter_context(mock.patch.object(state.registry, "prepare", side_effect=prepare))
        stack.enter_context(mock.patch.object(conductor, "operation_requires_global_heavy_slot", return_value=False))
        return stack

    def suspend_cancellation_wait(self, state: conductor.DaemonState) -> tuple[threading.Event, threading.Event]:
        """Suspend the cancellation owner at its first process-tree wait, releasing the condition like the real wait."""
        entered, resume = threading.Event(), threading.Event()
        self.addCleanup(resume.set)
        real = state._wait_for_process_tree_exit_locked

        def wait(job: conductor.Job, deadline: float, signal_for_new: Any) -> bool:
            name = threading.current_thread().name
            if not entered.is_set() and any(owner in name for owner in self.CANCEL_OWNERS):
                entered.set()
                while not resume.is_set():
                    state.condition.wait(0.01)
                return True  # still "alive": the owner escalates and writes its SIGKILL lines
            return real(job, deadline, signal_for_new)

        state._wait_for_process_tree_exit_locked = wait  # type: ignore[method-assign]
        return entered, resume

    def wait_until(self, predicate: Any, timeout: float = 15.0) -> bool:
        deadline = time.monotonic() + timeout
        while not predicate() and time.monotonic() < deadline:
            time.sleep(0.005)
        return bool(predicate())

    def run_cancellation_owner(self, owner: str) -> None:
        state = self.make_state(owner, timing="on")
        done = self.track_run_job()
        entered, resume = self.suspend_cancellation_wait(state)
        lanes = ["liveApp"] if owner == "supersede" else ["style"]
        with self.prepare_patches(state, lanes):
            ticket = state.enqueue({"operation": "build", "args": {}, "env": {}})["ticket"]
            job = state.jobs[ticket]
            self.assertTrue(self.wait_until(lambda: job.process_pid and "ready\n" in "".join(job.tail)))
            owner_thread = None
            if owner == "cancel":
                owner_thread = threading.Thread(target=state.job_cancel, args=(ticket, None), name="owner-cancel")
                owner_thread.start()
            elif owner == "supersede":
                state.active_lanes["release"] = "occupied"
                superseded = state.enqueue({"operation": "app", "args": {"subcommand": "stop"}, "env": {}})
                self.assertEqual([item["ticket"] for item in superseded["supersededJobs"]], [ticket])
            else:
                state.stop(force=True)
            self.assertTrue(entered.wait(15.0), "the cancellation owner never reached its wait")
            # The real runner finishes and releases its own pin while the owner is suspended.
            self.assertTrue(done.setdefault(ticket, threading.Event()).wait(15.0))
            self.assertTrue(self.wait_until(lambda: job.summary_pins <= 1))
            self.assertEqual(job.summary_pins, 1)  # only the cancellation owner's pin remains
            self.assertEqual((job.state, job.exit_code), ("canceled", 130))
            with mock.patch.object(conductor, "MAX_TERMINAL_JOBS", 0):
                with state.condition:
                    state._retention_pass_locked()
                self.assertIn(ticket, state.jobs)
                self.assertTrue(job.retention_deferred)
                self.assertTrue(state._await_maintenance(10.0))
                self.assertTrue(job.log_path.exists())
                resume.set()
                self.assertTrue(self.wait_until(lambda: ticket not in state.jobs))  # released after the last write
                if owner_thread is not None:
                    owner_thread.join(15.0)
                    self.assertFalse(owner_thread.is_alive())
                self.assertTrue(state._await_maintenance(10.0))
        self.assertIn("SIGKILL after grace period", "".join(job.tail))  # the late write happened while pinned
        self.assertEqual(self.names(state, ticket), [])  # pruned afterwards and never recreated
        self.assertEqual((job.state, job.exit_code), ("canceled", 130))

    def test_job_cancel_pins_until_its_last_escalation_write(self) -> None:
        self.run_cancellation_owner("cancel")

    def test_supersession_escalation_pins_until_its_last_write(self) -> None:
        self.run_cancellation_owner("supersede")

    def test_force_stop_cleanup_pins_until_its_last_write(self) -> None:
        self.run_cancellation_owner("force")

    def run_held_owned_thread(self, method: str, timing: str, extra: contextlib.ExitStack) -> conductor.Job:
        """Hold one job-owned thread past ``_run_job``; it alone must keep the job pinned."""
        state = self.make_state(method, timing=timing)
        done = self.track_run_job()
        entered, release = threading.Event(), threading.Event()
        self.addCleanup(release.set)
        real = getattr(conductor.DaemonState, method)

        def held(state_self: conductor.DaemonState, *args: Any, **kwargs: Any) -> Any:
            if not entered.is_set():
                entered.set()
                release.wait(15.0)
                if method == "_monitor_xctest_stall":
                    return None  # the watchdog's own work is not under test
            return real(state_self, *args, **kwargs)

        with extra, mock.patch.object(conductor.DaemonState, method, held), self.prepare_patches(state, ["style"]):
            state.registry.prepare.side_effect = lambda _request: (
                [sys.executable, "-c", "print('done')"], ["style"], state.paths.repo_root,
                {"PATH": os.environ.get("PATH", "")}, 30.0,
            )
            ticket = state.enqueue({"operation": "build", "args": {}, "env": {}})["ticket"]
            job = state.jobs[ticket]
            self.assertTrue(entered.wait(15.0))
            self.assertTrue(done.setdefault(ticket, threading.Event()).wait(15.0))
            self.assertTrue(self.wait_until(lambda: job.summary_pins <= 1))
            self.assertEqual(job.summary_pins, 1)  # only the held thread's pin remains
            with mock.patch.object(conductor, "MAX_TERMINAL_JOBS", 0):
                with state.condition:
                    state._retention_pass_locked()
                self.assertIn(ticket, state.jobs)
                self.assertTrue(job.retention_deferred)
                release.set()
                self.assertTrue(self.wait_until(lambda: ticket not in state.jobs))
                self.assertTrue(state._await_maintenance(10.0))
        self.assertEqual(self.names(state, ticket), [])
        return job

    def test_watchdog_thread_pins_until_it_returns(self) -> None:
        extra = contextlib.ExitStack()
        extra.enter_context(mock.patch.object(conductor.DaemonState, "_xctest_watchdog_enabled", return_value=True))
        extra.enter_context(mock.patch.object(conductor, "XCTEST_WATCHDOG_JOIN_SECONDS", 0.05))
        job = self.run_held_owned_thread("_monitor_xctest_stall", "on", extra)
        # The runner's bounded join gave up; the existing visible outcome is unchanged.
        self.assertEqual(job.error, "XCTest progress stall watchdog did not finish bounded diagnostics")

    def test_timing_off_summary_thread_pins_until_it_returns(self) -> None:
        job = self.run_held_owned_thread("_refresh_output_summary", "off", contextlib.ExitStack())
        self.assertIsNotNone(job.output_summary)
        self.assertEqual((job.state, job.exit_code), ("completed", 0))

    def test_predicate_accepts_real_minted_tickets_and_watchdog_diagnostic_names(self) -> None:
        state = self.make_state("names", timing="off")
        state.active_lanes["style"] = "occupied"  # stays queued: names only, no child
        with self.prepare_patches(state, ["style"]):
            payload = state.enqueue({"operation": "build", "args": {}, "env": {}})
        ticket = payload["ticket"]
        job = state.jobs[ticket]
        self.assertEqual(conductor.generated_job_file_ticket(Path(payload["logPath"]).name), ticket)
        self.assertEqual(job.log_path.parent, state.paths.jobs_dir)

        def fake_sample(argv: list, **_kwargs: Any) -> subprocess.CompletedProcess:
            Path(argv[argv.index("-file") + 1]).write_text("sample")
            return subprocess.CompletedProcess(argv, 0, "", "")

        with mock.patch.object(conductor.subprocess, "run", side_effect=fake_sample):
            state._capture_xctest_stall_diagnostics(job, {}, (os.getpid(), "token"))
        self.assertEqual(
            sorted(path.name for path in job.diagnostic_paths),
            sorted([f"{ticket}.xctest-stall.json", f"{ticket}.xctest-stall.sample.txt"]),
        )
        for path in job.diagnostic_paths:
            self.assertEqual(path.parent, state.paths.jobs_dir)
            self.assertEqual(conductor.generated_job_file_ticket(path.name), ticket)
            self.assertTrue(path.exists())


class InjectedSetupFault(BaseException):
    """A non-``Exception`` fault: rollback must not depend on ``except Exception``."""


class Step5PinHandoffRollbackTests(unittest.TestCase):
    """Step 5 r2: a pin acquired for a cancellation thread is released if setup fails before handoff (S5-R1-STOP-PIN-ROLLBACK / S5-R1-01)."""

    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.state = timing_state(Path(self.tmp.name) / "state", "off")
        self.addCleanup(self.state._await_maintenance, 10.0)
        self.real_thread = threading.Thread

    def job(self, n: int, job_state: str, lanes: tuple = ("style",)) -> conductor.Job:
        ticket = f"5e7f0000-0000-4000-8000-{n:012d}"
        job = conductor.Job(
            ticket=ticket, request_key=None, fingerprint="f", operation="build", args={}, lanes=list(lanes),
            timeout=None, verbose=False, env={}, created_at=conductor.now(),
            log_path=self.state.paths.jobs_dir / f"{ticket}.log", state=job_state,
        )
        self.state.jobs[ticket] = job
        if job_state == "queued":
            self.state.queue.append(ticket)
        return job

    def failing_thread_factory(self, target_name: str, mode: str, on_fault: Any) -> Any:
        """``threading.Thread`` replacement failing construction or ``start()`` for one target only."""
        real_thread = self.real_thread

        def factory(*args: Any, **kwargs: Any) -> threading.Thread:
            target = kwargs.get("target")
            if getattr(target, "__name__", "") != target_name:
                return real_thread(*args, **kwargs)
            if mode == "construct":
                on_fault()
                raise InjectedSetupFault("thread construction")
            thread = real_thread(*args, **kwargs)

            def refuse_start() -> None:
                on_fault()
                raise InjectedSetupFault("thread start")

            thread.start = refuse_start  # type: ignore[method-assign]
            return thread

        return factory

    def run_failing_stop(self, fault: str) -> tuple[list[int], list[int], list[conductor.Job]]:
        """Force-stop with running R1, queued Q, running R2 (already pinned by another holder), running R3.

        Returns (pins at the fault, pins afterwards, [R1, Q, R2, R3]).
        """
        r1, q, r2, r3 = self.job(1, "running"), self.job(2, "queued"), self.job(3, "running"), self.job(4, "running")
        r2.summary_pins = 1  # e.g. a status/wait pin: must survive the rollback
        running = (r1, r2, r3)
        at_fault: list[int] = []
        terminated: list[str] = []

        def snapshot() -> None:
            at_fault.extend(job.summary_pins for job in running)

        def terminate(job: conductor.Job, reason: str) -> None:
            terminated.append(job.ticket)
            if (fault == "terminate-first" and job is r1) or (fault == "terminate-later" and job is r2):
                snapshot()
                raise InjectedSetupFault(fault)

        def raising(*_args: Any, **_kwargs: Any) -> Any:
            snapshot()
            raise InjectedSetupFault(fault)

        with contextlib.ExitStack() as stack:
            stack.enter_context(mock.patch.object(self.state, "_terminate_process_group_locked", side_effect=terminate))
            if fault == "queued":
                stack.enter_context(
                    mock.patch.object(self.state, "_complete_undispatched_telemetry_locked", side_effect=raising)
                )
            elif fault == "ledger":
                stack.enter_context(mock.patch.object(self.state, "_write_running_processes_locked", side_effect=raising))
            elif fault == "payload":
                stack.enter_context(mock.patch.object(self.state, "status_payload", side_effect=raising))
            elif fault in {"thread-construct", "thread-start"}:
                mode = "construct" if fault == "thread-construct" else "start"
                stack.enter_context(
                    mock.patch.object(
                        conductor.threading, "Thread",
                        self.failing_thread_factory("_force_shutdown_when_canceled", mode, snapshot),
                    )
                )
            with self.assertRaises(InjectedSetupFault) as raised:
                self.state.stop(force=True)
        self.assertEqual(str(raised.exception), {"thread-construct": "thread construction", "thread-start": "thread start"}.get(fault, fault))
        self.assertTrue(self.state.shutdown_requested)
        return at_fault, [job.summary_pins for job in running], [r1, q, r2, r3]

    def assert_rolled_back(self, fault: str, expected_at_fault: list[int]) -> list[conductor.Job]:
        at_fault, after, jobs = self.run_failing_stop(fault)
        self.assertEqual(at_fault, expected_at_fault)  # the pins really were acquired before the fault
        self.assertEqual(after, [0, 1, 0])  # every acquired pin released; the other holder's pin kept
        for job in jobs:
            self.assertFalse(job.retention_deferred)
        return jobs

    def test_stop_rolls_back_the_pin_when_terminating_the_first_running_job_fails(self) -> None:
        r1, q, r2, r3 = self.assert_rolled_back("terminate-first", [1, 1, 0])
        self.assertEqual((r1.state, r1.cancel_requested), ("running", True))  # no outcome is rewritten
        self.assertEqual((q.state, r3.cancel_requested), ("queued", False))

    def test_stop_rolls_back_every_pin_of_a_partial_multi_job_acquisition(self) -> None:
        r1, q, r2, r3 = self.assert_rolled_back("terminate-later", [1, 2, 0])
        self.assertEqual((q.state, q.exit_code), ("canceled", 130))  # processed before the fault, unchanged
        self.assertEqual(r3.cancel_requested, False)

    def test_stop_rolls_back_pins_when_queued_job_processing_fails(self) -> None:
        self.assert_rolled_back("queued", [1, 1, 0])

    def test_stop_rolls_back_pins_when_the_running_ledger_write_fails(self) -> None:
        self.assert_rolled_back("ledger", [1, 2, 1])

    def test_stop_rolls_back_pins_when_payload_construction_fails(self) -> None:
        self.assert_rolled_back("payload", [1, 2, 1])

    def test_stop_rolls_back_pins_when_the_cleanup_thread_cannot_be_constructed(self) -> None:
        self.assert_rolled_back("thread-construct", [1, 2, 1])

    def test_stop_rolls_back_pins_when_the_cleanup_thread_cannot_start(self) -> None:
        self.assert_rolled_back("thread-start", [1, 2, 1])

    def test_supersession_rolls_back_its_pin_when_the_escalation_thread_cannot_start(self) -> None:
        for mode in ("construct", "start"):
            with self.subTest(mode=mode):
                old = self.job(10 + (mode == "start"), "running", lanes=("liveApp",))
                old.summary_pins = 1  # another holder's pin
                new = self.job(20 + (mode == "start"), "queued", lanes=("liveApp", "release"))
                self.state.queue.remove(new.ticket)
                del self.state.jobs[new.ticket]  # the superseding job is not yet registered
                at_fault: list[int] = []
                factory = self.failing_thread_factory(
                    "_escalate_canceled_job_after_grace", mode, lambda: at_fault.append(old.summary_pins)
                )
                with mock.patch.object(conductor.threading, "Thread", factory):
                    with self.state.condition, self.assertRaises(InjectedSetupFault):
                        self.state._supersede_live_app_jobs_locked(new, "stop")
                self.assertEqual(at_fault, [2])
                self.assertEqual(old.summary_pins, 1)
                self.assertEqual((old.state, old.cancel_requested), ("running", True))
                del self.state.jobs[old.ticket]  # isolate the next mode

    def test_job_owned_thread_rolls_back_its_pin_when_it_cannot_be_constructed_or_started(self) -> None:
        for mode in ("construct", "start"):
            with self.subTest(mode=mode):
                job = self.job(30 + (mode == "start"), "running")
                job.summary_pins = 1
                ran: list[bool] = []
                at_fault: list[int] = []
                factory = self.failing_thread_factory("run", mode, lambda: at_fault.append(job.summary_pins))
                with mock.patch.object(conductor.threading, "Thread", factory), self.assertRaises(InjectedSetupFault):
                    self.state._start_job_owned_thread(job, lambda: ran.append(True), ())
                self.assertEqual(at_fault, [2])
                self.assertEqual(job.summary_pins, 1)
                self.assertEqual(ran, [])


# ---------------------------------------------------------------------------
# Step 6: cached-import entry with checked-hash bytecode.

ENTRY_SOURCES = ("conductor.py", "conductor_entry.py", "debug_app_process.py", "swift_pipeline_metrics.py", "conductor_output.py")
CACHED_SOURCES = ("conductor.py", "debug_app_process.py", "swift_pipeline_metrics.py", "conductor_output.py")
HELP_TITLE = "conductor — RepoPrompt CE developer daemon"
EDITED_HELP_TITLE = "conductor — RepoPrompt CE DEVELOPER daemon"  # same encoded size


class Step6ConductorEntryTests(unittest.TestCase):
    def setUp(self) -> None:
        self.fresh_copy()

    def fresh_copy(self) -> None:
        """A private checkout copy with no ``__pycache__`` and an isolated TMPDIR."""
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.root = Path(tmp.name).resolve()
        self.repo = self.root / "repo"
        self.scripts = self.repo / "Scripts"
        self.scripts.mkdir(parents=True)
        for name in ENTRY_SOURCES:
            (self.scripts / name).write_bytes((SCRIPT_DIR / name).read_bytes())
        launcher = self.repo / "conductor"
        launcher.write_bytes((SCRIPT_DIR.parent / "conductor").read_bytes())
        launcher.chmod(0o755)
        self.tmpdir = self.root / "tmpdir"
        self.tmpdir.mkdir()
        socket_dir = self.root / "sock"
        socket_dir.mkdir(mode=0o700)
        self.env = {
            key: value
            for key, value in os.environ.items()
            if key not in {"PYTHONDONTWRITEBYTECODE", "PYTHONPYCACHEPREFIX", "PYTHONPATH"}
        }
        self.env.update(
            REPOPROMPT_DEV_DAEMON_STATE_DIR=str(self.root / "state"),
            REPOPROMPT_DEV_DAEMON_SOCKET=str(socket_dir / "c.sock"),
            TMPDIR=str(self.tmpdir),
        )

    def cfile(self, name: str = "conductor.py") -> Path:
        return Path(importlib.util.cache_from_source(str(self.scripts / name)))

    def header(self, name: str = "conductor.py") -> tuple[bool, int]:
        data = self.cfile(name).read_bytes()[:16]
        return data[:4] == importlib.util.MAGIC_NUMBER, int.from_bytes(data[4:8], "little")

    def run_entry(self, *args: str, env: Optional[dict] = None) -> subprocess.CompletedProcess:
        return subprocess.run(
            [sys.executable, str(self.scripts / "conductor_entry.py"), *args],
            cwd=str(self.repo), env=env or self.env, capture_output=True, text=True, timeout=60,
        )

    def run_probe(self, code: str, env: Optional[dict] = None) -> subprocess.CompletedProcess:
        prelude = (
            "import json, runpy, sys\n"
            f"scripts = {str(self.scripts)!r}\n"
            "sys.path.insert(0, scripts)\n"
            "entry = runpy.run_path(scripts + '/conductor_entry.py', run_name='rpce_entry_probe')\n"
        )
        return subprocess.run(
            [sys.executable, "-c", prelude + code], cwd=str(self.repo), env=env or self.env,
            capture_output=True, text=True, timeout=60,
        )

    def edit_help_preserving_size_and_mtime(self) -> None:
        path = self.scripts / "conductor.py"
        before = path.stat()
        source = path.read_bytes()
        self.assertEqual(source.count(HELP_TITLE.encode()), 1)
        edited = source.replace(HELP_TITLE.encode(), EDITED_HELP_TITLE.encode())
        self.assertEqual(len(edited), len(source))
        path.write_bytes(edited)
        os.utime(path, ns=(before.st_atime_ns, before.st_mtime_ns))
        after = path.stat()
        self.assertEqual((after.st_size, after.st_mtime_ns), (before.st_size, before.st_mtime_ns))

    def timestamp_compile_all(self) -> None:
        import py_compile

        for name in CACHED_SOURCES:
            py_compile.compile(
                str(self.scripts / name), doraise=True, invalidation_mode=py_compile.PycInvalidationMode.TIMESTAMP
            )
            self.assertEqual(self.header(name), (True, 0))

    def test_entry_imports_rpce_conductor_and_matches_direct_execution(self) -> None:
        probe = self.run_probe(
            "m = entry['load_conductor'](scripts)\n"
            "import importlib.machinery\n"
            "print(json.dumps([m.__name__, sys.modules['rpce_conductor'] is m, m.__file__, m.__cached__,\n"
            "    type(m.__spec__.loader) is importlib.machinery.SourceFileLoader,\n"
            "    m.Job.__module__, m.conductor_entry_script() == m.Path(scripts, 'conductor_entry.py').resolve()]))\n"
        )
        self.assertEqual(probe.returncode, 0, probe.stderr)
        name, registered, module_file, cached, source_loader, dataclass_module, entry_path = json.loads(probe.stdout)
        self.assertEqual((name, registered, source_loader, dataclass_module, entry_path), ("rpce_conductor", True, True, "rpce_conductor", True))
        self.assertEqual(Path(module_file), self.scripts / "conductor.py")
        self.assertEqual(Path(cached), self.cfile())
        # The CLI (help, a ConductorError exit and argparse usage) is identical either way.
        for args in (["--help"], ["job", "status", "--request-key", "missing"], ["build", "--timeout", "x"]):
            with self.subTest(args=args):
                via_entry = self.run_entry(*args)
                direct = subprocess.run(
                    [sys.executable, str(self.scripts / "conductor.py"), *args],
                    cwd=str(self.repo), env=self.env, capture_output=True, text=True, timeout=60,
                )
                self.assertEqual(
                    (via_entry.returncode, via_entry.stdout, via_entry.stderr),
                    (direct.returncode, direct.stdout, direct.stderr),
                )
        self.assertEqual(self.run_entry("--help").returncode, 0)
        failure = self.run_entry("job", "status", "--request-key", "missing")
        self.assertEqual(failure.returncode, 1)
        self.assertTrue(failure.stderr.startswith("conductor: "), failure.stderr)
        usage = self.run_entry("build", "--timeout", "x")
        self.assertEqual(usage.returncode, 2)
        self.assertIn("usage: conductor.py", usage.stderr)

    def test_root_launcher_bootstraps_checked_hash_bytecode_once(self) -> None:
        self.assertFalse((self.scripts / "__pycache__").exists())
        first = subprocess.run([str(self.repo / "conductor"), "--help"], cwd=str(self.repo), env=self.env, capture_output=True, text=True, timeout=60)
        self.assertEqual(first.returncode, 0, first.stderr)
        self.assertIn(HELP_TITLE, first.stdout)
        # Running conductor.py as __main__ never caches it, so a conductor pyc proves the launcher used the entry.
        for name in CACHED_SOURCES:
            with self.subTest(name=name):
                self.assertEqual(self.header(name), (True, 0b11))
        self.assertFalse(list((self.scripts / "__pycache__").glob("conductor_entry.*")))
        written = {name: self.cfile(name).stat().st_mtime_ns for name in CACHED_SOURCES}
        second = subprocess.run([str(self.repo / "conductor"), "--help"], cwd=str(self.repo), env=self.env, capture_output=True, text=True, timeout=60)
        self.assertEqual(second.returncode, 0, second.stderr)
        self.assertEqual({name: self.cfile(name).stat().st_mtime_ns for name in CACHED_SOURCES}, written)

    def test_same_size_same_mtime_edit_runs_new_code(self) -> None:
        for prior in ("timestamp", "checked-hash"):
            with self.subTest(prior=prior):
                self.fresh_copy()
                if prior == "timestamp":
                    self.timestamp_compile_all()  # as an ordinary `import conductor` caches it
                else:
                    self.assertEqual(self.run_entry("--help").returncode, 0)
                    self.assertEqual(self.header(), (True, 0b11))
                self.edit_help_preserving_size_and_mtime()
                if prior == "timestamp":
                    # Control: an ordinary import trusts the timestamp pyc and runs the old code.
                    stale = subprocess.run(
                        [sys.executable, "-c", f"import sys; sys.path.insert(0, {str(self.scripts)!r}); import conductor; print(conductor.HELP)"],
                        cwd=str(self.repo), env=self.env, capture_output=True, text=True, timeout=60,
                    )
                    self.assertIn(HELP_TITLE, stale.stdout, stale.stderr)
                result = self.run_entry("--help")
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn(EDITED_HELP_TITLE, result.stdout)
                self.assertNotIn(HELP_TITLE, result.stdout)
                self.assertEqual(self.header(), (True, 0b11))

    def test_missing_malformed_or_foreign_bytecode_is_recompiled(self) -> None:
        magic = importlib.util.MAGIC_NUMBER
        foreign = bytes([magic[0] ^ 0xFF]) + magic[1:]
        # Header-field cases keep the real hash and loadable body, so only that field is wrong.
        cases = {
            "empty": lambda data: b"",
            "truncated header": lambda data: magic[:3],
            "garbage": lambda data: b"\x00not bytecode\x00" * 8,
            "other interpreter": lambda data: foreign + data[4:],
            "unchecked hash": lambda data: data[:4] + (0b01).to_bytes(4, "little") + data[8:],
            "timestamp": lambda data: data[:4] + (0).to_bytes(4, "little") + data[8:],
            "missing": None,
        }
        for label, content in cases.items():
            with self.subTest(case=label):
                self.fresh_copy()
                self.assertEqual(self.run_entry("--help").returncode, 0)
                cfile = self.cfile()
                data = cfile.read_bytes()
                cfile.unlink()
                if content is None:
                    self.assertEqual(self.run_entry("--help").returncode, 0)  # missing: rebuilt
                    self.assertEqual(self.header(), (True, 0b11))
                    continue
                cfile.write_bytes(content(data))
                result = self.run_entry("--help")
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn(HELP_TITLE, result.stdout)
                self.assertEqual(self.header(), (True, 0b11))

    def test_valid_checked_hash_header_with_corrupt_body_is_recompiled(self) -> None:
        import marshal

        def loadable(name: str) -> bool:
            try:
                return isinstance(marshal.loads(self.cfile(name).read_bytes()[16:]), type(loadable.__code__))
            except (EOFError, ValueError, TypeError):
                return False

        bodies = {
            "truncated body": lambda body: body[: len(body) // 2],
            "garbage body": lambda body: b"\xff" * 64,
            "non-code body": lambda body: marshal.dumps(42),
        }
        # The entry loads conductor.py; debug_app_process is a plain import; conductor_output loads by explicit path.
        for name in ("conductor.py", "debug_app_process.py", "conductor_output.py"):
            for label, corrupt in bodies.items():
                with self.subTest(source=name, case=label):
                    self.fresh_copy()
                    self.assertEqual(self.run_entry("--help").returncode, 0)
                    cfile = self.cfile(name)
                    data = cfile.read_bytes()
                    corrupted = data[:16] + corrupt(data[16:])  # the header still matches the source hash
                    cfile.write_bytes(corrupted)
                    self.assertFalse(loadable(name))
                    # Control: an ordinary import fails on this cache.
                    plain = subprocess.run(
                        [sys.executable, "-c", f"import sys; sys.path.insert(0, {str(self.scripts)!r}); import conductor"],
                        cwd=str(self.repo), env=self.env, capture_output=True, text=True, timeout=60,
                    )
                    self.assertNotEqual(plain.returncode, 0)
                    cfile.write_bytes(corrupted)  # unchanged by the failed import, but restore regardless
                    result = self.run_entry("--help")
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertIn(HELP_TITLE, result.stdout)
                    self.assertEqual(self.header(name), (True, 0b11))
                    self.assertTrue(loadable(name))
        # Unwritable: the corrupt cache is bypassed through the fresh private prefix, never loaded.
        self.fresh_copy()
        self.assertEqual(self.run_entry("--help").returncode, 0)
        data = self.cfile().read_bytes()
        corrupted = data[:16] + data[16 : 16 + (len(data) - 16) // 2]
        self.cfile().write_bytes(corrupted)
        pycache = self.scripts / "__pycache__"
        pycache.chmod(0o555)
        self.addCleanup(pycache.chmod, 0o755)
        result = self.run_entry("--help")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(HELP_TITLE, result.stdout)
        self.assertEqual(self.cfile().read_bytes(), corrupted)
        self.assertEqual(list(self.tmpdir.iterdir()), [])

    def test_unwritable_cache_uses_a_fresh_empty_private_prefix_removed_at_exit(self) -> None:
        self.timestamp_compile_all()
        self.edit_help_preserving_size_and_mtime()  # the old cache would now run stale code
        stale_bytes = self.cfile().read_bytes()
        pycache = self.scripts / "__pycache__"
        pycache.chmod(0o555)
        self.addCleanup(pycache.chmod, 0o755)
        probe = self.run_probe(
            "import os\n"
            "ok = entry['ensure_checked_hash_bytecode'](scripts)\n"
            "prefix = sys.pycache_prefix\n"
            "state = [ok, prefix, sorted(os.listdir(prefix)), sys.dont_write_bytecode]\n"
            "m = entry['load_conductor'](scripts)\n"
            "print(json.dumps(state + [m.HELP.splitlines()[0], sorted(os.listdir(prefix))]))\n"
        )
        self.assertEqual(probe.returncode, 0, probe.stderr)
        ok, prefix, listed_before, no_writes, title, listed_after = json.loads(probe.stdout)
        self.assertFalse(ok)
        self.assertEqual(Path(prefix).parent, self.tmpdir)
        self.assertTrue(Path(prefix).name.startswith("rpce-conductor-pycache-"))
        self.assertEqual((listed_before, no_writes, listed_after), ([], True, []))
        self.assertEqual(title, EDITED_HELP_TITLE)
        self.assertFalse(Path(prefix).exists())  # removed at exit
        self.assertEqual(self.cfile().read_bytes(), stale_bytes)
        # The real launcher path behaves the same and leaves nothing behind.
        result = self.run_entry("--help")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(EDITED_HELP_TITLE, result.stdout)
        self.assertEqual(list(self.tmpdir.iterdir()), [])

    def test_disabled_bytecode_writes_never_use_a_stale_cache(self) -> None:
        env = dict(self.env, PYTHONDONTWRITEBYTECODE="1")
        self.timestamp_compile_all()
        self.edit_help_preserving_size_and_mtime()
        stale_bytes = self.cfile().read_bytes()
        result = self.run_entry("--help", env=env)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(EDITED_HELP_TITLE, result.stdout)
        self.assertEqual(self.cfile().read_bytes(), stale_bytes)
        self.assertEqual(list(self.tmpdir.iterdir()), [])
        # Valid checked-hash caches are still used when writes are disabled.
        self.assertEqual(self.run_entry("--help").returncode, 0)
        probe = self.run_probe("print(json.dumps([entry['ensure_checked_hash_bytecode'](scripts), sys.pycache_prefix]))", env=env)
        self.assertEqual(json.loads(probe.stdout), [True, None], probe.stderr)

    def test_concurrent_first_imports_each_run_and_leave_valid_bytecode(self) -> None:
        gate = (
            "import runpy, sys\n"
            "sys.stdin.read(1)\n"
            f"scripts = {str(self.scripts)!r}\n"
            "sys.path.insert(0, scripts)\n"
            "sys.argv = [scripts + '/conductor_entry.py', '--help']\n"
            "runpy.run_path(sys.argv[0], run_name='__main__')\n"
        )
        processes = [
            subprocess.Popen(
                [sys.executable, "-c", gate], cwd=str(self.repo), env=self.env,
                stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            )
            for _ in range(8)
        ]
        for process in processes:  # release every child only once all are waiting
            assert process.stdin is not None
            process.stdin.write(b"x")
            process.stdin.close()
        for process in processes:
            stdout, stderr = process.communicate(timeout=60)
            self.assertEqual(process.returncode, 0, stderr.decode())
            self.assertIn(HELP_TITLE, stdout.decode())
        for name in CACHED_SOURCES:
            self.assertEqual(self.header(name), (True, 0b11))
        leftovers = [path.name for path in (self.scripts / "__pycache__").iterdir() if not path.name.endswith(".pyc")]
        self.assertEqual(leftovers, [])

    def test_runners_and_daemon_starts_use_the_entry_with_sys_executable(self) -> None:
        entry = conductor.conductor_entry_script()
        self.assertEqual(entry, (SCRIPT_DIR / "conductor_entry.py").resolve())
        registry = conductor.OperationRegistry(self.repo, self.root / "jobs")
        self.assertEqual(registry._internal_argv("app_status", {})[:4], [sys.executable, "-u", str(entry), "__operation_runner"])
        paths = timing_paths(self.root / "daemon")
        plist = conductor.plistlib.loads(conductor.write_daemon_launchd_plist(paths, entry).read_bytes())
        self.assertEqual(plist["ProgramArguments"], [sys.executable, str(entry), "__daemon", "--repo-root", str(paths.repo_root)])
        with mock.patch.object(conductor.subprocess, "Popen") as popen:
            conductor.spawn_daemon_direct(paths, entry)
        self.assertEqual(popen.call_args.args[0], [sys.executable, str(entry), "__daemon", "--repo-root", str(paths.repo_root)])

        class Spawned(Exception):
            pass

        with mock.patch.object(conductor, "spawn_daemon", side_effect=Spawned) as spawn:
            with self.assertRaises(Spawned):
                conductor.ensure_daemon(paths)  # start and every replacement path
        spawn.assert_called_once_with(paths, entry)

    def test_daemon_identity_requires_exact_entry_arguments_or_legacy_direct_daemon(self) -> None:
        paths = timing_paths(self.root / "identity")
        root = paths.repo_root
        entry = conductor.conductor_entry_script()
        framework = "/opt/homebrew/Frameworks/Python.framework/Versions/3.14/Resources/Python.app/Contents/MacOS/Python"
        cases = {
            f"{framework} {entry} __daemon --repo-root {root}": True,
            f"/usr/bin/python3 {entry} __daemon --repo-root {root}": True,
            f"/usr/bin/python3 /x/Scripts/conductor.py __daemon --repo-root {root}": True,  # legacy direct daemon
            f"/usr/bin/python3 {entry} __daemon --repo-root {root}/other": False,
            f"/usr/bin/python3 /elsewhere/Scripts/conductor_entry.py __daemon --repo-root {root}": False,
            f"/usr/bin/python3 {entry} __daemon --repo-root {root} --extra": False,
            f"/usr/bin/python3 {entry} __operation_runner --repo-root {root}": False,
            f"/usr/bin/python3 {entry} status {root}": False,
            "": False,
        }
        for command, expected in cases.items():
            with self.subTest(command=command):
                self.assertIs(conductor.daemon_command_matches(command, paths), expected)
        paths.daemon_meta_path.write_text(
            json.dumps({"pid": 4242, "repoRoot": str(root), "repoHash": paths.repo_hash}), encoding="utf-8"
        )
        for command, expected in ((f"{framework} {entry} __daemon --repo-root {root}", True), (f"python3 {entry} status", False)):
            with self.subTest(verify=command), mock.patch.object(conductor, "process_command", return_value=command):
                self.assertIs(conductor.verify_daemon_pid_identity(paths, 4242), expected)



if __name__ == "__main__":
    unittest.main()
