#!/usr/bin/env python3
"""Focused tests for conductor interactive app lifecycle intent."""

from __future__ import annotations

import contextlib
import errno
import fcntl
import hashlib
import io
import json
import os
import shutil
import signal
import stat
import subprocess
import sys
import tempfile
import textwrap
import threading
import time
import unittest
import uuid
from pathlib import Path
from unittest import mock

SCRIPT_DIR = Path(__file__).resolve().parent
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))

import conductor  # noqa: E402
import parallel_xctest_runner as parallel_runner  # noqa: E402


class LifecycleTestCase(unittest.TestCase):
    def setUp(self) -> None:
        super().setUp()
        launchd_opt_out = mock.patch.dict(
            os.environ,
            {"REPOPROMPT_DEV_DAEMON_LAUNCHD": "0"},
        )
        launchd_opt_out.start()
        self.addCleanup(launchd_opt_out.stop)

    def make_state(self) -> tuple[tempfile.TemporaryDirectory[str], conductor.DaemonState]:
        tmp = tempfile.TemporaryDirectory()
        root = Path(tmp.name)
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
        return tmp, conductor.DaemonState(paths)

    def make_job(
        self,
        state: conductor.DaemonState,
        ticket: str,
        operation: str,
        args: dict,
        lanes: list[str],
        job_state: str = "queued",
        request_key: str | None = None,
        fingerprint: str = "fingerprint",
    ) -> conductor.Job:
        return conductor.Job(
            ticket=ticket,
            request_key=request_key,
            fingerprint=fingerprint,
            operation=operation,
            args=args,
            lanes=lanes,
            timeout=None,
            verbose=False,
            env={},
            created_at=conductor.now(),
            log_path=state.paths.jobs_dir / f"{ticket}.log",
            state=job_state,
        )


class LifecycleQueueTests(LifecycleTestCase):
    def test_protocol_version_bump_replaces_older_daemons(self) -> None:
        # 16: Step 10 adds the `dsym` operation and forwards RPCE_DEBUG_DSYM; an
        # idle protocol-15 daemon would reject one and silently drop the other.
        # 17: forwards RPCE_INDEX_STORE, which an idle protocol-16 daemon would drop.
        # 18: forwards REPOPROMPT_DEBUG_PACKAGE_CACHE, which an idle protocol-17 daemon would drop.
        # 19: `build --optimized` (args.optimized); an idle protocol-18 daemon would drop it and build debug.
        # 20: `--optimized-incremental` (args.optimizedIncremental); an idle protocol-19 daemon would drop it
        # and build debug.
        self.assertEqual(conductor.PROTOCOL_VERSION, 20)

    def test_ensure_daemon_stops_and_replaces_idle_protocol_15_daemon(self) -> None:
        tmp, state = self.make_state()
        self.addCleanup(tmp.cleanup)
        fake_proc = mock.Mock()
        fake_proc.poll.return_value = None
        old_payload = {
            "protocolVersion": 15,
            "runningJobs": [],
            "queuedJobs": [],
        }
        new_payload = {"protocolVersion": conductor.PROTOCOL_VERSION}
        requests: list[dict] = []

        def fake_request(_paths: conductor.Paths, message: dict, timeout: float = 1.0) -> dict:
            requests.append(message)
            if message["type"] == "status" and len(requests) == 1:
                return old_payload
            if message["type"] == "stop":
                return {}
            if message["type"] == "status" and len(requests) == 3:
                raise conductor.ConductorError("old daemon is stopped")
            if message["type"] == "status":
                return new_payload
            raise AssertionError(f"unexpected daemon request: {message}")

        with mock.patch.object(conductor, "request_daemon", side_effect=fake_request), mock.patch.object(
            conductor, "wait_until_stopped", return_value=True
        ) as wait, mock.patch.object(conductor.subprocess, "Popen", return_value=fake_proc) as popen:
            payload = conductor.ensure_daemon(state.paths)

        self.assertEqual(payload, new_payload)
        self.assertEqual(requests[0], {"type": "status"})
        self.assertEqual(requests[1], {"type": "stop", "force": False})
        wait.assert_called_once_with(state.paths, timeout=conductor.TERMINATE_GRACE_SECONDS + 5.0)
        self.assertEqual(popen.call_args.kwargs["stdin"], subprocess.DEVNULL)

    def test_ensure_daemon_refuses_mismatched_replacement_when_work_appears_before_stop(self) -> None:
        tmp, state = self.make_state()
        self.addCleanup(tmp.cleanup)
        requests: list[dict] = []

        def fake_request(_paths: conductor.Paths, message: dict, timeout: float = 1.0) -> dict:
            requests.append(message)
            if message["type"] == "status":
                return {
                    "protocolVersion": 15,
                    "runningJobs": [],
                    "queuedJobs": [],
                }
            if message["type"] == "stop":
                raise conductor.ConductorError("daemon has active or queued jobs")
            raise AssertionError(f"unexpected daemon request: {message}")

        with mock.patch.object(conductor, "request_daemon", side_effect=fake_request), mock.patch.object(
            conductor, "wait_until_stopped"
        ) as wait, mock.patch.object(conductor.subprocess, "Popen") as popen:
            with self.assertRaisesRegex(conductor.ConductorError, "jobs may have become active"):
                conductor.ensure_daemon(state.paths)

        self.assertEqual(
            requests,
            [
                {"type": "status"},
                {"type": "stop", "force": False},
            ],
        )
        wait.assert_not_called()
        popen.assert_not_called()

    def test_ensure_daemon_raises_for_locked_protocol_mismatch_with_active_jobs(self) -> None:
        tmp, state = self.make_state()
        self.addCleanup(tmp.cleanup)
        requests: list[dict] = []

        def fake_request(_paths: conductor.Paths, message: dict, timeout: float = 1.0) -> dict:
            requests.append(message)
            if len(requests) == 1:
                raise conductor.ConductorError("down before start lock")
            return {
                "protocolVersion": 15,
                "runningJobs": [{"ticket": "active"}],
                "queuedJobs": [],
            }

        with mock.patch.object(conductor, "request_daemon", side_effect=fake_request), mock.patch.object(
            conductor, "wait_until_stopped"
        ) as wait, mock.patch.object(conductor.subprocess, "Popen") as popen:
            with self.assertRaisesRegex(conductor.ConductorError, "protocol mismatch"):
                conductor.ensure_daemon(state.paths)

        self.assertEqual(requests, [{"type": "status"}, {"type": "status"}])
        wait.assert_not_called()
        popen.assert_not_called()

    def test_app_relaunch_cli_requires_delimiter_and_forwards_arguments(self) -> None:
        tmp, state = self.make_state()
        self.addCleanup(tmp.cleanup)
        with mock.patch.object(conductor, "enqueue_and_maybe_wait", return_value=0) as enqueue:
            code = conductor.handle_real_operation(state.paths, "app", ["relaunch", "--", "--demo"])

        self.assertEqual(code, 0)
        self.assertEqual(enqueue.call_args.args[1], "app")
        self.assertEqual(enqueue.call_args.args[2], {"subcommand": "relaunch", "appArgs": ["--demo"]})
        with self.assertRaises(conductor.ConductorError):
            conductor.handle_real_operation(state.paths, "app", ["relaunch", "--demo"])
        with mock.patch.object(conductor, "enqueue_and_maybe_wait", return_value=0) as enqueue_launch:
            code = conductor.handle_real_operation(state.paths, "app", ["launch-existing", "--", "--demo"])
        self.assertEqual(code, 0)
        self.assertEqual(enqueue_launch.call_args.args[2], {"subcommand": "launch-existing", "appArgs": ["--demo"]})

    def test_app_relaunch_delegates_split_internal_runner_with_live_lane_and_timeout(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            registry = conductor.OperationRegistry(Path(tmp))
            argv, lanes, _cwd, _env, timeout = registry.prepare(
                {"operation": "app", "args": {"subcommand": "relaunch", "appArgs": ["--demo"]}}
            )
            launch_existing_argv, launch_existing_lanes, _cwd, _env, _timeout = registry.prepare(
                {"operation": "app", "args": {"subcommand": "launch-existing", "appArgs": ["--demo"]}}
            )

        self.assertIn("__operation_runner", argv)
        self.assertIn("debug_app_build_then_launch", argv[-1])
        self.assertEqual(lanes, ["liveApp"])
        self.assertEqual(timeout, conductor.MEDIUM_TIMEOUT_SECONDS)
        self.assertIn("app_launch_existing", launch_existing_argv[-1])
        self.assertEqual(launch_existing_lanes, ["liveApp"])
        self.assertEqual(conductor.operation_display_name("app", {"subcommand": "relaunch"}), "app relaunch")

    def test_build_fast_cli_explicitly_forwards_package_marker(self) -> None:
        tmp, state = self.make_state()
        self.addCleanup(tmp.cleanup)
        with mock.patch.object(conductor, "enqueue_and_maybe_wait", return_value=0) as enqueue:
            code = conductor.handle_real_operation(state.paths, "build", ["--fast"])

        self.assertEqual(code, 0)
        self.assertEqual(enqueue.call_args.args[2], {"fastPackage": True})
        registry = conductor.OperationRegistry(state.paths.repo_root)
        fast_argv, fast_lanes, _cwd, _env, _timeout = registry.prepare(
            {"operation": "build", "args": {"fastPackage": True}}
        )
        default_argv, _lanes, _cwd, _env, _timeout = registry.prepare(
            {"operation": "build", "args": {}}
        )
        self.assertEqual(fast_argv[-2:], ["debug", "fast"])
        self.assertEqual(default_argv[-1:], ["debug"])
        self.assertEqual(fast_lanes, ["build", "debugArtifact"])

    def test_build_forwards_debug_package_cache_escape_verbatim_to_package_child_env(self) -> None:
        # Client snapshot -> daemon request filter -> package_app.sh child env, verbatim; package_app.sh
        # (not conductor) rejects values other than on/off before any build or mutation.
        key = "REPOPROMPT_DEBUG_PACKAGE_CACHE"
        self.assertIn(key, conductor.OperationRegistry.PASSTHROUGH_ENV_KEYS)
        self.assertNotIn("CODESIGN_ALLOCATE", conductor.OperationRegistry.PASSTHROUGH_ENV_KEYS)
        with tempfile.TemporaryDirectory() as tmp:
            registry = conductor.OperationRegistry(Path(tmp))
            for value in ("off", "on", "bogus", ""):
                with self.subTest(value=value), mock.patch.dict(os.environ, {key: value}):
                    snapshot = conductor.OperationRegistry.client_env_snapshot()
                    self.assertEqual(snapshot[key], value)
                    for args in ({}, {"fastPackage": True}):
                        argv, _lanes, _cwd, env, _timeout = registry.prepare(
                            {"operation": "build", "args": args, "env": snapshot}
                        )
                        self.assertTrue(argv[0].endswith("package_app.sh"), argv)
                        self.assertEqual(env[key], value)
                    # `run` packages through the internal build-then-launch job; its env carries the
                    # escape to the staged package child the same way (prepared only, never launched).
                    argv, _lanes, _cwd, env, _timeout = registry.prepare(
                        {"operation": "run", "args": {"appArgs": []}, "env": snapshot}
                    )
                    self.assertEqual(json.loads(argv[-1])["kind"], "debug_app_build_then_launch")
                    self.assertEqual(env[key], value)
            argv, _lanes, _cwd, env, _timeout = registry.prepare({"operation": "build", "args": {}, "env": {}})
            self.assertNotIn(key, env)

    def test_build_optimized_cli_sets_the_lane_key_only_when_true(self) -> None:
        tmp, state = self.make_state()
        self.addCleanup(tmp.cleanup)
        cases = {
            (): ({}, None),
            ("--fast",): ({"fastPackage": True}, None),
            ("--optimized",): ({"optimized": True}, None),
            ("--optimized", "--fast"): ({"fastPackage": True, "optimized": True}, None),
            ("--optimized", "--timeout", "600"): ({"optimized": True}, 600.0),
            ("--timeout", "9000", "--optimized"): ({"optimized": True}, 9000.0),
        }
        for argv, (expected_args, expected_timeout) in cases.items():
            with self.subTest(argv=argv), mock.patch.object(conductor, "enqueue_and_maybe_wait", return_value=0) as enqueue:
                code = conductor.handle_real_operation(state.paths, "build", list(argv))
                self.assertEqual(code, 0)
                self.assertEqual(enqueue.call_args.args[1], "build")
                self.assertEqual(enqueue.call_args.args[2], expected_args)
                self.assertEqual(enqueue.call_args.args[3].timeout, expected_timeout)
                if "--optimized" not in argv:
                    self.assertNotIn("optimized", enqueue.call_args.args[2])
        with mock.patch.object(conductor, "enqueue_and_maybe_wait", return_value=0), \
                contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
            conductor.handle_real_operation(state.paths, "build", ["--optimized=yes"])

    def test_build_optimized_maps_to_the_lane_package_config_and_timeout_floor(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            registry = conductor.OperationRegistry(Path(tmp))
            default = registry.prepare({"operation": "build", "args": {}, "env": {}})
            fast = registry.prepare({"operation": "build", "args": {"fastPackage": True}, "env": {}})
            lane = registry.prepare({"operation": "build", "args": {"optimized": True}, "env": {}})
            lane_fast = registry.prepare(
                {"operation": "build", "args": {"optimized": True, "fastPackage": True}, "env": {}}
            )
            # Default lane: today's argv, lanes and timeout, byte for byte.
            self.assertEqual(default[0], [str(Path(tmp) / "Scripts" / "package_app.sh"), "debug"])
            self.assertEqual(fast[0], [str(Path(tmp) / "Scripts" / "package_app.sh"), "debug", "fast"])
            self.assertEqual(default[4], conductor.MEDIUM_TIMEOUT_SECONDS)
            self.assertEqual(fast[4], conductor.MEDIUM_TIMEOUT_SECONDS)
            # Lane: same script, the debug-optimized config, the same lanes, and the timeout floor.
            self.assertEqual(lane[0], [str(Path(tmp) / "Scripts" / "package_app.sh"), "debug-optimized"])
            self.assertEqual(lane_fast[0][-2:], ["debug-optimized", "fast"])
            for prepared in (default, fast, lane, lane_fast):
                self.assertEqual(prepared[1], ["build", "debugArtifact"])
                self.assertEqual(prepared[2], Path(tmp))
            floor = max(conductor.MEDIUM_TIMEOUT_SECONDS, conductor.OPTIMIZED_LANE_TIMEOUT_FLOOR_SECONDS)
            self.assertEqual(lane[4], floor)
            self.assertEqual(lane_fast[4], floor)
            # Never below the ordinary build default, whatever the measured floor.
            self.assertGreaterEqual(lane[4], conductor.MEDIUM_TIMEOUT_SECONDS)
            # The floor applies to the lane only, whatever its measured value; the default keeps its timeout.
            with mock.patch.object(conductor, "OPTIMIZED_LANE_TIMEOUT_FLOOR_SECONDS", conductor.MEDIUM_TIMEOUT_SECONDS * 3):
                self.assertEqual(
                    registry.prepare({"operation": "build", "args": {"optimized": True}, "env": {}})[4],
                    conductor.MEDIUM_TIMEOUT_SECONDS * 3,
                )
                self.assertEqual(
                    registry.prepare({"operation": "build", "args": {}, "env": {}})[4],
                    conductor.MEDIUM_TIMEOUT_SECONDS,
                )
            with mock.patch.object(conductor, "OPTIMIZED_LANE_TIMEOUT_FLOOR_SECONDS", 60):
                self.assertEqual(
                    registry.prepare({"operation": "build", "args": {"optimized": True}, "env": {}})[4],
                    conductor.MEDIUM_TIMEOUT_SECONDS,
                )
            # An explicit --timeout always wins, below or above the floor.
            for explicit in (5.0, 600.0, floor + 1.0):
                with self.subTest(explicit=explicit):
                    _argv, _lanes, _cwd, _env, timeout = registry.prepare(
                        {"operation": "build", "args": {"optimized": True}, "env": {}, "timeout": explicit}
                    )
                    self.assertEqual(timeout, explicit)
            # Only `true` is a lane request; every other present value is malformed, never debug.
            for bad in (False, "true", 1, None, "1"):
                with self.subTest(bad=bad), self.assertRaisesRegex(conductor.ConductorError, "must be true"):
                    registry.prepare({"operation": "build", "args": {"optimized": bad}, "env": {}})
            # Other operations are untouched by the key (run/app relaunch support is Step 5).
            package = registry.prepare({"operation": "package", "args": {"config": "debug"}, "env": {}})
            self.assertEqual(package[0][-1], "debug")

    def test_build_optimized_request_identity_is_distinct_and_default_identity_unchanged(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            registry = conductor.OperationRegistry(Path(tmp))
            default = {"operation": "build", "args": {}, "env": {}}
            lane = {"operation": "build", "args": {"optimized": True}, "env": {}}
            # The default fingerprint is exactly the pre-lane material: no `optimized` key appears.
            material = {
                "operation": "build",
                "args": {},
                "timeout": None,
                "verbose": False,
                "env": {
                    key: ("off" if key == conductor.DEBUG_DSYM_POLICY_ENV_KEY else None)
                    for key in conductor.OperationRegistry.PASSTHROUGH_ENV_KEYS
                },
            }
            expected = hashlib.sha256(conductor.json_dumps(material).encode("utf-8")).hexdigest()
            self.assertEqual(registry.fingerprint(default), expected)
            self.assertNotEqual(registry.fingerprint(lane), registry.fingerprint(default))
            self.assertNotEqual(
                registry.fingerprint({"operation": "build", "args": {"optimized": True, "fastPackage": True}}),
                registry.fingerprint({"operation": "build", "args": {"fastPackage": True}}),
            )

    def test_build_optimized_forwards_caller_signing_without_injecting_absent_identity_or_sentry(self) -> None:
        # The lane preconditions in package_app.sh require an explicit Apple Development SIGN_IDENTITY and
        # *unset* Sentry variables and BUNDLE_ID; conductor must forward the first verbatim and never inject
        # the others, even when the daemon's own environment has them.
        self.assertNotIn("RPCE_OPTIMIZED_DIAGNOSTICS", conductor.OperationRegistry.PASSTHROUGH_ENV_KEYS)
        identity = "Apple Development: Stub Person (TEAMID1234)"
        absent = ("REPOPROMPT_ENABLE_SENTRY", "REPOPROMPT_UPLOAD_SENTRY_SYMBOLS", "BUNDLE_ID", "DEBUG_BUNDLE_ID")
        bundle = "/tmp/rpce-opt-probe-test/RepoPrompt.app"
        caller = {key: value for key, value in os.environ.items() if key not in absent}
        caller.update({
            "SIGN_IDENTITY": identity,
            "REPOPROMPT_DEBUG_APP_BUNDLE": bundle,
            "RPCE_OPTIMIZED_DIAGNOSTICS": "1",
        })
        with tempfile.TemporaryDirectory() as tmp, mock.patch.dict(os.environ, caller, clear=True):
            snapshot = conductor.OperationRegistry.client_env_snapshot()
            registry = conductor.OperationRegistry(Path(tmp))
            daemon_env = {"REPOPROMPT_ENABLE_SENTRY": "1", "REPOPROMPT_UPLOAD_SENTRY_SYMBOLS": "1", "BUNDLE_ID": "x.y"}
            with mock.patch.dict(os.environ, daemon_env):
                for args in ({"optimized": True}, {"optimized": True, "fastPackage": True}):
                    with self.subTest(args=args):
                        argv, _lanes, _cwd, env, _timeout = registry.prepare(
                            {"operation": "build", "args": args, "env": snapshot}
                        )
                        self.assertEqual(argv[1], "debug-optimized")
                        self.assertEqual(env["SIGN_IDENTITY"], identity)
                        self.assertEqual(env["REPOPROMPT_DEBUG_APP_BUNDLE"], bundle)
                        for key in absent + ("RPCE_OPTIMIZED_DIAGNOSTICS", "ALLOW_ADHOC_SIGNING"):
                            self.assertNotIn(key, env)
                # A forged request env carrying the gate is filtered by the daemon too.
                forged = dict(snapshot, RPCE_OPTIMIZED_DIAGNOSTICS="1")
                _argv, _lanes, _cwd, env, _timeout = registry.prepare(
                    {"operation": "build", "args": {"optimized": True}, "env": forged}
                )
                self.assertNotIn("RPCE_OPTIMIZED_DIAGNOSTICS", env)

    def run_build_until_timeout(
        self, args: dict, *, request_timeout: float | None = None, operation: str = "build"
    ) -> tuple[conductor.DaemonState, dict, list[float]]:
        tmp, state = self.make_state()
        self.addCleanup(tmp.cleanup)
        # Persistence and maintenance finish after ``job_wait``; drain before the tempdir goes (LIFO).
        self.addCleanup(state._await_maintenance, 10.0)
        self.addCleanup(state._await_job_telemetry, 10.0)
        sleeper = [sys.executable, "-u", "-c", "import time; time.sleep(30)"]
        prepared_timeouts: list[float] = []

        def fake_prepare(request: dict) -> tuple:
            real = conductor.OperationRegistry.prepare(state.registry, request)
            prepared_timeouts.append(real[4])
            return (sleeper, ["style"], state.paths.repo_root, {"PATH": os.environ.get("PATH", "")}, 0.5)

        with mock.patch.object(state.registry, "prepare", side_effect=fake_prepare), mock.patch.object(
            conductor, "operation_requires_global_heavy_slot", return_value=False
        ):
            request = {"operation": operation, "args": args, "env": {}}
            if request_timeout is not None:
                request["timeout"] = request_timeout
            ticket = state.enqueue(request)["ticket"]
            waited = state.job_wait(ticket, None, 30.0)
        return state, waited, prepared_timeouts

    def test_optimized_build_timeout_failure_names_the_timeout_flag(self) -> None:
        _state, waited, prepared = self.run_build_until_timeout({"optimized": True})
        self.assertEqual(waited["state"], "failed")
        self.assertEqual(waited["exitCode"], 124)
        error = waited.get("error") or ""
        self.assertTrue(error.startswith("timed out after 0.5s; "), error)
        self.assertIn("./conductor build --optimized --timeout <seconds>", error)
        self.assertIn("(this run allowed 0s)", error)  # 0.5 rounds to 0 in the whole-second hint
        self.assertIn("hint: optimized-lane builds", "".join(waited.get("logTail") or []))
        self.assertEqual(waited["resultSummary"], error)
        # The enqueue-time preparation applies the floor; the run-time one sees the job's stored timeout.
        floor = max(conductor.MEDIUM_TIMEOUT_SECONDS, conductor.OPTIMIZED_LANE_TIMEOUT_FLOOR_SECONDS)
        self.assertEqual(float(prepared[0]), float(floor))

    def test_default_build_timeout_failure_message_is_unchanged(self) -> None:
        _state, waited, _prepared = self.run_build_until_timeout({})
        self.assertEqual(waited["state"], "failed")
        self.assertEqual(waited.get("error"), "timed out after 0.5s")
        self.assertTrue(waited.get("logTail"))
        self.assertNotIn("--timeout", "".join(waited.get("logTail") or []))
        self.assertIsNone(conductor.optimized_lane_timeout_hint("build", {}, 10.0))
        # Step 5 extends the hint to run/app relaunch; non-packaging operations never get it.
        for operation, args in (
            ("run", {"appArgs": []}),
            ("app", {"subcommand": "relaunch", "appArgs": []}),
            ("app", {"subcommand": "launch-existing", "optimized": True}),
            ("app", {"subcommand": "stop", "optimized": True}),
            ("package", {"config": "debug", "optimized": True}),
        ):
            with self.subTest(operation=operation, args=args):
                self.assertIsNone(conductor.optimized_lane_timeout_hint(operation, args, 10.0))

    def test_optimized_and_default_build_requests_never_share_a_request_key(self) -> None:
        tmp, state = self.make_state()
        self.addCleanup(tmp.cleanup)
        self.addCleanup(state._await_maintenance, 10.0)
        self.addCleanup(state._await_job_telemetry, 10.0)
        sleeper = [sys.executable, "-u", "-c", "import time; time.sleep(30)"]
        with mock.patch.object(
            state.registry, "prepare",
            side_effect=lambda _request: (sleeper, ["style"], state.paths.repo_root, {"PATH": os.environ.get("PATH", "")}, 1.0),
        ), mock.patch.object(conductor, "operation_requires_global_heavy_slot", return_value=False):
            first = state.enqueue({"operation": "build", "args": {"optimized": True}, "env": {}, "requestKey": "k"})
            with self.assertRaisesRegex(conductor.ConductorError, "request-key mismatch"):
                state.enqueue({"operation": "build", "args": {}, "env": {}, "requestKey": "k"})
            again = state.enqueue({"operation": "build", "args": {"optimized": True}, "env": {}, "requestKey": "k"})
            self.assertTrue(again.get("reused"))
            self.assertEqual(again["ticket"], first["ticket"])
            waited = state.job_wait(first["ticket"], None, 30.0)
        self.assertEqual(waited["state"], "failed")

    # Step 5: `run --optimized` / `app relaunch --optimized`. Every lifecycle case below is a stubbed
    # enqueue or a prepared request; nothing builds, stops or launches an app.

    def test_run_optimized_cli_consumes_only_a_leading_flag_and_keeps_pass_through(self) -> None:
        tmp, state = self.make_state()
        self.addCleanup(tmp.cleanup)
        cases = {
            # Today's rule, unchanged: an optional leading '--', everything else is an app argument.
            (): ({"appArgs": []}, None),
            ("--", "--demo"): ({"appArgs": ["--demo"]}, None),
            ("--demo",): ({"appArgs": ["--demo"]}, None),
            ("--", "--optimized"): ({"appArgs": ["--optimized"]}, None),
            ("--demo", "--optimized"): ({"appArgs": ["--demo", "--optimized"]}, None),
            # A leading --optimized is consumed once; the rest follows today's rule.
            ("--optimized",): ({"optimized": True, "appArgs": []}, None),
            ("--optimized", "--", "--demo"): ({"optimized": True, "appArgs": ["--demo"]}, None),
            ("--optimized", "--demo"): ({"optimized": True, "appArgs": ["--demo"]}, None),
            ("--optimized", "--optimized"): ({"optimized": True, "appArgs": ["--optimized"]}, None),
            ("--optimized", "--", "--optimized"): ({"optimized": True, "appArgs": ["--optimized"]}, None),
            ("--optimized", "--timeout", "900", "--", "--x"): ({"optimized": True, "appArgs": ["--x"]}, 900.0),
            ("--timeout", "900", "--optimized"): ({"optimized": True, "appArgs": []}, 900.0),
        }
        for argv, (expected_args, expected_timeout) in cases.items():
            with self.subTest(argv=argv), mock.patch.object(conductor, "enqueue_and_maybe_wait", return_value=0) as enqueue:
                code = conductor.handle_real_operation(state.paths, "run", list(argv))
                self.assertEqual(code, 0)
                self.assertEqual(enqueue.call_args.args[1], "run")
                self.assertEqual(enqueue.call_args.args[2], expected_args)
                self.assertEqual(enqueue.call_args.args[3].timeout, expected_timeout)
                if "optimized" not in expected_args:
                    self.assertNotIn("optimized", enqueue.call_args.args[2])

    def test_app_relaunch_optimized_cli_is_leading_only_and_launch_existing_rejects_it(self) -> None:
        tmp, state = self.make_state()
        self.addCleanup(tmp.cleanup)
        accepted = {
            ("relaunch",): {"subcommand": "relaunch", "appArgs": []},
            ("relaunch", "--optimized"): {"subcommand": "relaunch", "optimized": True, "appArgs": []},
            ("relaunch", "--optimized", "--", "--demo"): {
                "subcommand": "relaunch", "optimized": True, "appArgs": ["--demo"]
            },
            ("relaunch", "--optimized", "--", "--optimized"): {
                "subcommand": "relaunch", "optimized": True, "appArgs": ["--optimized"]
            },
            # After '--' it is an application argument, never the lane.
            ("relaunch", "--", "--optimized"): {"subcommand": "relaunch", "appArgs": ["--optimized"]},
            ("launch-existing", "--", "--optimized"): {"subcommand": "launch-existing", "appArgs": ["--optimized"]},
        }
        for argv, expected in accepted.items():
            with self.subTest(argv=argv), mock.patch.object(conductor, "enqueue_and_maybe_wait", return_value=0) as enqueue:
                self.assertEqual(conductor.handle_real_operation(state.paths, "app", list(argv)), 0)
                self.assertEqual(enqueue.call_args.args[1], "app")
                self.assertEqual(enqueue.call_args.args[2], expected)
        rejected = {
            # Leading-only: a non-leading flag or app arguments without '--' keep today's error.
            ("relaunch", "--optimized", "--demo"): "must follow '--'",
            ("relaunch", "--optimized", "--optimized"): "must follow '--'",
            ("relaunch", "--demo", "--optimized"): "must follow '--'",
            ("launch-existing", "--optimized"): "launch-existing does not build",
            ("launch-existing", "--optimized", "--", "--demo"): "launch-existing does not build",
            ("status", "--optimized"): "does not accept application arguments",
            ("stop", "--optimized"): "does not accept application arguments",
        }
        for argv, message in rejected.items():
            with self.subTest(argv=argv), mock.patch.object(conductor, "enqueue_and_maybe_wait", return_value=0) as enqueue:
                with self.assertRaisesRegex(conductor.ConductorError, message):
                    conductor.handle_real_operation(state.paths, "app", list(argv))
                enqueue.assert_not_called()
        with mock.patch.object(conductor, "enqueue_and_maybe_wait", return_value=0), self.assertRaises(
            conductor.ConductorError
        ) as usage:
            conductor.handle_real_operation(state.paths, "app", ["--optimized", "relaunch"])
        # The usage error offers the lane flags for relaunch only.
        self.assertIn("relaunch [--optimized | --optimized-incremental] [-- <app args...>]", str(usage.exception))
        self.assertIn("launch-existing [-- <app args...>]", str(usage.exception))
        self.assertEqual(str(usage.exception).count("--optimized "), 1)
        self.assertEqual(str(usage.exception).count("--optimized-incremental"), 1)
        with mock.patch.object(conductor, "enqueue_and_maybe_wait", return_value=0), self.assertRaises(
            conductor.ConductorError
        ) as raised:
            conductor.handle_real_operation(state.paths, "app", ["launch-existing", "--optimized"])
        self.assertEqual(
            str(raised.exception),
            "launch-existing does not build; its lane is whatever the bundle was packaged with "
            "(see RepoPromptDebugProvenance.json).",
        )

    def test_run_and_relaunch_optimized_prepare_forwards_lane_with_timeout_floor(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            registry = conductor.OperationRegistry(Path(tmp))
            floor = max(conductor.MEDIUM_TIMEOUT_SECONDS, conductor.OPTIMIZED_LANE_TIMEOUT_FLOOR_SECONDS)
            plain_requests = {
                "run": {"operation": "run", "args": {"appArgs": ["--demo"]}, "env": {}},
                "app relaunch": {"operation": "app", "args": {"subcommand": "relaunch", "appArgs": ["--demo"]}, "env": {}},
            }
            for label, plain in plain_requests.items():
                lane = dict(plain, args=dict(plain["args"], optimized=True))
                with self.subTest(label=label):
                    plain_argv, plain_lanes, _cwd, _env, plain_timeout = registry.prepare(plain)
                    lane_argv, lane_lanes, _cwd, _env, lane_timeout = registry.prepare(lane)
                    plain_payload = json.loads(plain_argv[-1])
                    lane_payload = json.loads(lane_argv[-1])
                    # Same internal build-then-launch job and lane; only the forwarded key differs.
                    self.assertEqual(plain_payload["kind"], "debug_app_build_then_launch")
                    self.assertEqual(lane_payload["kind"], "debug_app_build_then_launch")
                    self.assertEqual(plain_payload["args"], plain["args"])
                    self.assertNotIn("optimized", plain_payload["args"])
                    self.assertIs(lane_payload["args"]["optimized"], True)
                    self.assertEqual(plain_lanes, ["liveApp"])
                    self.assertEqual(lane_lanes, ["liveApp"])
                    self.assertEqual(plain_timeout, conductor.MEDIUM_TIMEOUT_SECONDS)
                    self.assertEqual(lane_timeout, floor)
                    with mock.patch.object(
                        conductor, "OPTIMIZED_LANE_TIMEOUT_FLOOR_SECONDS", conductor.MEDIUM_TIMEOUT_SECONDS * 3
                    ):
                        self.assertEqual(registry.prepare(lane)[4], conductor.MEDIUM_TIMEOUT_SECONDS * 3)
                        self.assertEqual(registry.prepare(plain)[4], conductor.MEDIUM_TIMEOUT_SECONDS)
                    for explicit in (5.0, floor + 1.0):
                        self.assertEqual(registry.prepare(dict(lane, timeout=explicit))[4], explicit)
                    for bad in (False, "true", 1, None):
                        forged = dict(plain, args=dict(plain["args"], optimized=bad))
                        with self.assertRaisesRegex(conductor.ConductorError, "must be true"):
                            registry.prepare(forged)
                        with self.assertRaisesRegex(conductor.ConductorError, "must be true"):
                            registry.prepare(dict(forged, timeout=600.0))
                        # Validation does not depend on the default-timeout path.
                        with mock.patch.object(
                            registry, "_default_timeout", return_value=conductor.MEDIUM_TIMEOUT_SECONDS
                        ), self.assertRaisesRegex(conductor.ConductorError, "must be true"):
                            registry.prepare(dict(forged, timeout=600.0))
            # A forged launch-existing lane request is refused by the daemon too, with the same explanation.
            with self.assertRaisesRegex(conductor.ConductorError, "launch-existing does not build"):
                registry.prepare(
                    {"operation": "app", "args": {"subcommand": "launch-existing", "optimized": True, "appArgs": []}}
                )
            launch_existing = registry.prepare({"operation": "app", "args": {"subcommand": "launch-existing", "appArgs": []}})
            self.assertIn("app_launch_existing", launch_existing[0][-1])
            self.assertEqual(launch_existing[4], conductor.MEDIUM_TIMEOUT_SECONDS)
            # Gate never forwarded for the launch commands either.
            with mock.patch.dict(os.environ, {"RPCE_OPTIMIZED_DIAGNOSTICS": "1"}):
                snapshot = conductor.OperationRegistry.client_env_snapshot()
                for plain in plain_requests.values():
                    lane = dict(plain, args=dict(plain["args"], optimized=True), env=snapshot)
                    self.assertNotIn("RPCE_OPTIMIZED_DIAGNOSTICS", registry.prepare(lane)[3])

    def test_optimized_run_and_relaunch_timeout_failures_name_their_own_command(self) -> None:
        cases = {
            "run": ({"optimized": True, "appArgs": []}, "./conductor run --optimized --timeout <seconds>"),
            "app": (
                {"subcommand": "relaunch", "optimized": True, "appArgs": []},
                "./conductor app relaunch --optimized --timeout <seconds>",
            ),
        }
        for operation, (args, command) in cases.items():
            with self.subTest(operation=operation):
                _state, waited, prepared = self.run_build_until_timeout(args, operation=operation)
                self.assertEqual(waited["state"], "failed")
                self.assertEqual(waited["exitCode"], 124)
                error = waited.get("error") or ""
                self.assertTrue(error.startswith("timed out after 0.5s; "), error)
                self.assertIn(command, error)
                self.assertIn("hint: optimized-lane builds", "".join(waited.get("logTail") or []))
                floor = max(conductor.MEDIUM_TIMEOUT_SECONDS, conductor.OPTIMIZED_LANE_TIMEOUT_FLOOR_SECONDS)
                self.assertEqual(float(prepared[0]), float(floor))
        _state, waited, _prepared = self.run_build_until_timeout({"appArgs": []}, operation="run")
        self.assertEqual(waited.get("error"), "timed out after 0.5s")

    def test_optimized_and_plain_launch_requests_never_share_a_request_key(self) -> None:
        for operation, plain_args in (
            ("run", {"appArgs": []}),
            ("app", {"subcommand": "relaunch", "appArgs": []}),
        ):
            with self.subTest(operation=operation):
                tmp, state = self.make_state()
                self.addCleanup(tmp.cleanup)
                lane_args = dict(plain_args, optimized=True)
                self.assertNotEqual(
                    state.registry.fingerprint({"operation": operation, "args": lane_args}),
                    state.registry.fingerprint({"operation": operation, "args": plain_args}),
                )
                with mock.patch.object(state, "_schedule_locked"):
                    first = state.enqueue({"operation": operation, "args": lane_args, "env": {}, "requestKey": "k"})
                    with self.assertRaisesRegex(conductor.ConductorError, "request-key mismatch"):
                        state.enqueue({"operation": operation, "args": plain_args, "env": {}, "requestKey": "k"})
                    again = state.enqueue({"operation": operation, "args": lane_args, "env": {}, "requestKey": "k"})
                self.assertTrue(again.get("reused"))
                self.assertEqual(again["ticket"], first["ticket"])
                self.assertIs(state.jobs[first["ticket"]].args["optimized"], True)

    def test_newest_relaunch_intent_supersedes_across_lanes(self) -> None:
        # The newest relaunch wins whatever either lane is; a superseded queued lane job never builds.
        cases = (
            ("run", {"optimized": True, "appArgs": []}, {"subcommand": "relaunch", "appArgs": []}),
            ("app", {"subcommand": "relaunch", "optimized": True, "appArgs": []}, {"subcommand": "relaunch", "appArgs": []}),
            ("app", {"subcommand": "relaunch", "appArgs": []}, {"subcommand": "relaunch", "optimized": True, "appArgs": []}),
            ("run", {"appArgs": []}, {"subcommand": "relaunch", "optimized": True, "appArgs": []}),
            ("app", {"subcommand": "relaunch", "optimized": True, "appArgs": []}, {"subcommand": "stop"}),
        )
        for old_operation, old_args, new_args in cases:
            with self.subTest(old=(old_operation, old_args), new=new_args):
                tmp, state = self.make_state()
                self.addCleanup(tmp.cleanup)
                old = self.make_job(state, "old", old_operation, dict(old_args), ["liveApp"])
                state.jobs[old.ticket] = old
                state.queue.append(old.ticket)
                with mock.patch.object(state, "_schedule_locked"):
                    payload = state.enqueue({"operation": "app", "args": dict(new_args)})
                self.assertEqual(old.state, "canceled")
                self.assertEqual(old.superseded_by_operation, f"app {new_args['subcommand']}")
                self.assertEqual(payload["supersededJobs"][0]["ticket"], old.ticket)
                newest = state.jobs[payload["ticket"]]
                self.assertEqual(newest.args.get("optimized"), new_args.get("optimized"))
        # `run --optimized` stays an ordinary FIFO run: it supersedes nothing.
        tmp, state = self.make_state()
        self.addCleanup(tmp.cleanup)
        prior = self.make_job(state, "prior", "app", {"subcommand": "relaunch", "appArgs": []}, ["liveApp"])
        state.jobs[prior.ticket] = prior
        state.queue.append(prior.ticket)
        with mock.patch.object(state, "_schedule_locked"):
            payload = state.enqueue({"operation": "run", "args": {"optimized": True, "appArgs": []}})
        self.assertEqual(prior.state, "queued")
        self.assertEqual(payload.get("supersededJobs"), [])

    # Optimized-incremental App lane (`--optimized-incremental`): a separate, mutually exclusive selector
    # that maps to package_app.sh debug-optimized-incremental. Nothing below builds, stops or launches.

    INCREMENTAL = "optimizedIncremental"

    def test_build_optimized_incremental_cli_sets_its_own_key_and_rejects_mixed_lanes(self) -> None:
        tmp, state = self.make_state()
        self.addCleanup(tmp.cleanup)
        cases = {
            ("--optimized-incremental",): ({self.INCREMENTAL: True}, None),
            ("--optimized-incremental", "--fast"): ({"fastPackage": True, self.INCREMENTAL: True}, None),
            ("--timeout", "900", "--optimized-incremental"): ({self.INCREMENTAL: True}, 900.0),
            ("--optimized",): ({"optimized": True}, None),
            (): ({}, None),
        }
        for argv, (expected_args, expected_timeout) in cases.items():
            with self.subTest(argv=argv), mock.patch.object(conductor, "enqueue_and_maybe_wait", return_value=0) as enqueue:
                self.assertEqual(conductor.handle_real_operation(state.paths, "build", list(argv)), 0)
                self.assertEqual(enqueue.call_args.args[2], expected_args)
                self.assertEqual(enqueue.call_args.args[3].timeout, expected_timeout)
        for argv in (("--optimized", "--optimized-incremental"), ("--optimized-incremental", "--fast", "--optimized")):
            with self.subTest(argv=argv), mock.patch.object(conductor, "enqueue_and_maybe_wait", return_value=0) as enqueue:
                with self.assertRaisesRegex(conductor.ConductorError, "mutually exclusive"):
                    conductor.handle_real_operation(state.paths, "build", list(argv))
                enqueue.assert_not_called()
        with mock.patch.object(conductor, "enqueue_and_maybe_wait", return_value=0), \
                contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
            conductor.handle_real_operation(state.paths, "build", ["--optimized-incremental=yes"])

    def test_build_optimized_incremental_prepare_maps_config_lanes_floor_and_rejects_malformed(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            registry = conductor.OperationRegistry(Path(tmp))
            script = str(Path(tmp) / "Scripts" / "package_app.sh")
            lane = registry.prepare({"operation": "build", "args": {self.INCREMENTAL: True}, "env": {}})
            lane_fast = registry.prepare(
                {"operation": "build", "args": {self.INCREMENTAL: True, "fastPackage": True}, "env": {}}
            )
            self.assertEqual(lane[0], [script, "debug-optimized-incremental"])
            self.assertEqual(lane_fast[0], [script, "debug-optimized-incremental", "fast"])
            floor = max(conductor.MEDIUM_TIMEOUT_SECONDS, conductor.OPTIMIZED_LANE_TIMEOUT_FLOOR_SECONDS)
            for prepared in (lane, lane_fast):
                self.assertEqual(prepared[1], ["build", "debugArtifact"])
                self.assertEqual(prepared[4], floor)
            with mock.patch.object(conductor, "OPTIMIZED_LANE_TIMEOUT_FLOOR_SECONDS", conductor.MEDIUM_TIMEOUT_SECONDS * 3):
                self.assertEqual(
                    registry.prepare({"operation": "build", "args": {self.INCREMENTAL: True}, "env": {}})[4],
                    conductor.MEDIUM_TIMEOUT_SECONDS * 3,
                )
            self.assertEqual(
                registry.prepare({"operation": "build", "args": {self.INCREMENTAL: True}, "env": {}, "timeout": 5.0})[4], 5.0
            )
            # Default and old-lane requests keep their argv byte for byte.
            self.assertEqual(registry.prepare({"operation": "build", "args": {}, "env": {}})[0], [script, "debug"])
            self.assertEqual(
                registry.prepare({"operation": "build", "args": {"optimized": True}, "env": {}})[0], [script, "debug-optimized"]
            )
            for bad in (False, "true", 1, None, "1"):
                with self.subTest(bad=bad), self.assertRaisesRegex(conductor.ConductorError, "optimizedIncremental' must be true"):
                    registry.prepare({"operation": "build", "args": {self.INCREMENTAL: bad}, "env": {}})
            # Both lane keys is a malformed request on every path, with or without an explicit timeout.
            both = {"optimized": True, self.INCREMENTAL: True}
            for request in (
                {"operation": "build", "args": dict(both), "env": {}},
                {"operation": "build", "args": dict(both), "env": {}, "timeout": 600.0},
                {"operation": "run", "args": dict(both, appArgs=[]), "env": {}, "timeout": 600.0},
                {"operation": "app", "args": dict(both, subcommand="relaunch", appArgs=[]), "env": {}, "timeout": 600.0},
            ):
                with self.subTest(request=request), self.assertRaisesRegex(conductor.ConductorError, "mutually exclusive"):
                    registry.prepare(request)
            with self.assertRaisesRegex(conductor.ConductorError, "mutually exclusive"):
                conductor.debug_package_config_for_request(both)
            self.assertEqual(conductor.debug_package_config_for_request({}), "debug")
            # Other operations are untouched by the key.
            self.assertEqual(registry.prepare({"operation": "package", "args": {"config": "debug"}, "env": {}})[0][-1], "debug")
            # Distinct request identity from both the default and the WMO lane.
            fingerprints = {
                registry.fingerprint({"operation": "build", "args": args})
                for args in ({}, {"optimized": True}, {self.INCREMENTAL: True})
            }
            self.assertEqual(len(fingerprints), 3)

    def test_optimized_incremental_gate_is_never_forwarded(self) -> None:
        self.assertNotIn("RPCE_OPTIMIZED_INCREMENTAL", conductor.OperationRegistry.PASSTHROUGH_ENV_KEYS)
        with tempfile.TemporaryDirectory() as tmp, mock.patch.dict(
            os.environ, {"RPCE_OPTIMIZED_INCREMENTAL": "1", "RPCE_OPTIMIZED_DIAGNOSTICS": "1"}
        ):
            snapshot = conductor.OperationRegistry.client_env_snapshot()
            registry = conductor.OperationRegistry(Path(tmp))
            forged = dict(snapshot, RPCE_OPTIMIZED_INCREMENTAL="1", RPCE_OPTIMIZED_DIAGNOSTICS="1")
            for request in (
                {"operation": "build", "args": {self.INCREMENTAL: True}, "env": forged},
                {"operation": "run", "args": {self.INCREMENTAL: True, "appArgs": []}, "env": forged},
                {"operation": "app", "args": {"subcommand": "relaunch", self.INCREMENTAL: True, "appArgs": []}, "env": forged},
            ):
                with self.subTest(operation=request["operation"]):
                    env = registry.prepare(request)[3]
                    self.assertNotIn("RPCE_OPTIMIZED_INCREMENTAL", env)
                    self.assertNotIn("RPCE_OPTIMIZED_DIAGNOSTICS", env)

    def test_run_and_relaunch_optimized_incremental_cli(self) -> None:
        tmp, state = self.make_state()
        self.addCleanup(tmp.cleanup)
        run_cases = {
            ("--optimized-incremental",): {self.INCREMENTAL: True, "appArgs": []},
            ("--optimized-incremental", "--", "--demo"): {self.INCREMENTAL: True, "appArgs": ["--demo"]},
            # A repeat of the same flag keeps today's pass-through rule; after '--' it is an app argument.
            ("--optimized-incremental", "--optimized-incremental"): {
                self.INCREMENTAL: True, "appArgs": ["--optimized-incremental"]
            },
            ("--", "--optimized-incremental"): {"appArgs": ["--optimized-incremental"]},
            ("--optimized", "--", "--optimized-incremental"): {"optimized": True, "appArgs": ["--optimized-incremental"]},
        }
        for argv, expected in run_cases.items():
            with self.subTest(argv=argv), mock.patch.object(conductor, "enqueue_and_maybe_wait", return_value=0) as enqueue:
                self.assertEqual(conductor.handle_real_operation(state.paths, "run", list(argv)), 0)
                self.assertEqual(enqueue.call_args.args[2], expected)
        relaunch_cases = {
            ("relaunch", "--optimized-incremental"): {"subcommand": "relaunch", self.INCREMENTAL: True, "appArgs": []},
            ("relaunch", "--optimized-incremental", "--", "--demo"): {
                "subcommand": "relaunch", self.INCREMENTAL: True, "appArgs": ["--demo"]
            },
            ("relaunch", "--", "--optimized-incremental"): {"subcommand": "relaunch", "appArgs": ["--optimized-incremental"]},
        }
        for argv, expected in relaunch_cases.items():
            with self.subTest(argv=argv), mock.patch.object(conductor, "enqueue_and_maybe_wait", return_value=0) as enqueue:
                self.assertEqual(conductor.handle_real_operation(state.paths, "app", list(argv)), 0)
                self.assertEqual(enqueue.call_args.args[2], expected)
        rejected = {
            ("run", "--optimized", "--optimized-incremental"): "mutually exclusive",
            ("run", "--optimized-incremental", "--optimized"): "mutually exclusive",
            ("app", "relaunch", "--optimized", "--optimized-incremental"): "mutually exclusive",
            ("app", "relaunch", "--optimized-incremental", "--optimized"): "mutually exclusive",
            ("app", "relaunch", "--optimized-incremental", "--demo"): "must follow '--'",
            ("app", "launch-existing", "--optimized-incremental"): "launch-existing does not build",
            ("app", "status", "--optimized-incremental"): "does not accept application arguments",
        }
        for (operation, *argv), message in rejected.items():
            with self.subTest(argv=argv), mock.patch.object(conductor, "enqueue_and_maybe_wait", return_value=0) as enqueue:
                with self.assertRaisesRegex(conductor.ConductorError, message):
                    conductor.handle_real_operation(state.paths, operation, list(argv))
                enqueue.assert_not_called()

    def test_run_and_relaunch_optimized_incremental_prepare_and_launch_existing_refusal(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            registry = conductor.OperationRegistry(Path(tmp))
            floor = max(conductor.MEDIUM_TIMEOUT_SECONDS, conductor.OPTIMIZED_LANE_TIMEOUT_FLOOR_SECONDS)
            for request in (
                {"operation": "run", "args": {self.INCREMENTAL: True, "appArgs": ["--demo"]}, "env": {}},
                {"operation": "app", "args": {"subcommand": "relaunch", self.INCREMENTAL: True, "appArgs": []}, "env": {}},
            ):
                with self.subTest(operation=request["operation"]):
                    argv, lanes, _cwd, _env, timeout = registry.prepare(request)
                    payload = json.loads(argv[-1])
                    self.assertEqual(payload["kind"], "debug_app_build_then_launch")
                    self.assertIs(payload["args"][self.INCREMENTAL], True)
                    self.assertNotIn("optimized", payload["args"])
                    self.assertEqual((lanes, timeout), (["liveApp"], floor))
                    with self.assertRaisesRegex(conductor.ConductorError, "must be true"):
                        registry.prepare(dict(request, args=dict(request["args"], **{self.INCREMENTAL: "true"}), timeout=1.0))
            with self.assertRaisesRegex(conductor.ConductorError, "launch-existing does not build"):
                registry.prepare(
                    {"operation": "app", "args": {"subcommand": "launch-existing", self.INCREMENTAL: True, "appArgs": []}}
                )

    def test_optimized_incremental_timeout_hint_names_its_own_flag(self) -> None:
        for operation, args, command in (
            ("build", {self.INCREMENTAL: True}, "./conductor build --optimized-incremental --timeout <seconds>"),
            ("run", {self.INCREMENTAL: True, "appArgs": []}, "./conductor run --optimized-incremental --timeout <seconds>"),
            ("app", {"subcommand": "relaunch", self.INCREMENTAL: True, "appArgs": []},
             "./conductor app relaunch --optimized-incremental --timeout <seconds>"),
        ):
            with self.subTest(operation=operation):
                hint = conductor.optimized_lane_timeout_hint(operation, args, 10.0) or ""
                self.assertIn(command, hint)
                self.assertIn("every module except RepoPromptApp", hint)
        for operation, args in (
            ("app", {"subcommand": "launch-existing", self.INCREMENTAL: True}),
            ("package", {"config": "debug", self.INCREMENTAL: True}),
        ):
            self.assertIsNone(conductor.optimized_lane_timeout_hint(operation, args, 10.0))
        # The WMO lane's hint is unchanged.
        self.assertIn("./conductor build --optimized --timeout", conductor.optimized_lane_timeout_hint("build", {"optimized": True}, 1.0))
        _state, waited, prepared = self.run_build_until_timeout({self.INCREMENTAL: True})
        self.assertEqual((waited["state"], waited["exitCode"]), ("failed", 124))
        self.assertIn("./conductor build --optimized-incremental --timeout <seconds>", waited.get("error") or "")
        self.assertIn("hint: optimized-incremental builds", "".join(waited.get("logTail") or []))
        floor = max(conductor.MEDIUM_TIMEOUT_SECONDS, conductor.OPTIMIZED_LANE_TIMEOUT_FLOOR_SECONDS)
        self.assertEqual(float(prepared[0]), float(floor))

    def test_optimized_incremental_requests_never_share_a_request_key_with_other_lanes(self) -> None:
        for operation, plain_args in (("build", {}), ("run", {"appArgs": []}), ("app", {"subcommand": "relaunch", "appArgs": []})):
            with self.subTest(operation=operation):
                tmp, state = self.make_state()
                self.addCleanup(tmp.cleanup)
                lane_args = dict(plain_args, **{self.INCREMENTAL: True})
                with mock.patch.object(state, "_schedule_locked"):
                    first = state.enqueue({"operation": operation, "args": lane_args, "env": {}, "requestKey": "k"})
                    for other in (plain_args, dict(plain_args, optimized=True)):
                        with self.assertRaisesRegex(conductor.ConductorError, "request-key mismatch"):
                            state.enqueue({"operation": operation, "args": dict(other), "env": {}, "requestKey": "k"})
                    again = state.enqueue({"operation": operation, "args": dict(lane_args), "env": {}, "requestKey": "k"})
                self.assertEqual(again["ticket"], first["ticket"])
                self.assertIs(state.jobs[first["ticket"]].args[self.INCREMENTAL], True)

    def test_newest_relaunch_intent_supersedes_the_incremental_lane_too(self) -> None:
        for old_operation, old_args, new_args in (
            ("run", {self.INCREMENTAL: True, "appArgs": []}, {"subcommand": "relaunch", "optimized": True, "appArgs": []}),
            ("app", {"subcommand": "relaunch", "optimized": True, "appArgs": []},
             {"subcommand": "relaunch", self.INCREMENTAL: True, "appArgs": []}),
        ):
            with self.subTest(old=old_args, new=new_args):
                tmp, state = self.make_state()
                self.addCleanup(tmp.cleanup)
                old = self.make_job(state, "old", old_operation, dict(old_args), ["liveApp"])
                state.jobs[old.ticket] = old
                state.queue.append(old.ticket)
                with mock.patch.object(state, "_schedule_locked"):
                    payload = state.enqueue({"operation": "app", "args": dict(new_args)})
                self.assertEqual(old.state, "canceled")
                newest = state.jobs[payload["ticket"]]
                self.assertEqual(newest.args.get(self.INCREMENTAL), new_args.get(self.INCREMENTAL))
                self.assertEqual(newest.args.get("optimized"), new_args.get("optimized"))

    def test_guardrails_delegates_aggregator_without_lanes(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            repo_root = Path(tmp)
            registry = conductor.OperationRegistry(repo_root)
            argv, lanes, cwd, _env, _timeout = registry.prepare({"operation": "guardrails", "args": {}})

        self.assertEqual(Path(argv[0]).name, "guardrails.sh")
        self.assertEqual(Path(argv[0]).parent.name, "Scripts")
        self.assertEqual(lanes, [])
        self.assertEqual(cwd, repo_root)

    def test_release_artifact_delegates_release_script_with_release_lanes_and_timeout(self) -> None:
        tmp, state = self.make_state()
        self.addCleanup(tmp.cleanup)
        with mock.patch.object(conductor, "enqueue_and_maybe_wait", return_value=0) as enqueue:
            code = conductor.handle_real_operation(state.paths, "release", ["artifact"])

        registry = conductor.OperationRegistry(state.paths.repo_root)
        argv, lanes, _cwd, _env, timeout = registry.prepare({"operation": "release", "args": {"subcommand": "artifact"}})

        self.assertEqual(code, 0)
        self.assertEqual(enqueue.call_args.args[2], {"subcommand": "artifact"})
        self.assertEqual(Path(argv[0]).name, "release.sh")
        self.assertEqual(argv[1], "artifact")
        self.assertEqual(lanes, ["build", "debugArtifact", "release"])
        self.assertEqual(timeout, conductor.RELEASE_TIMEOUT_SECONDS)

    def test_packaged_smoke_uses_only_live_app_lane(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            registry = conductor.OperationRegistry(Path(tmp))
            argv, lanes, _cwd, _env, _timeout = registry.prepare(
                {"operation": "smoke", "args": {"packagedApp": "/tmp/RepoPrompt CE.app"}}
            )

        self.assertEqual(lanes, ["liveApp"])
        self.assertTrue(Path(argv[0]).name.startswith("python3"))
        self.assertIn('"kind":"smoke"', argv[-1].replace(" ", ""))

    def test_diagnostics_build_cache_delegates_read_only_without_lanes(self) -> None:
        tmp, state = self.make_state()
        self.addCleanup(tmp.cleanup)
        with mock.patch.object(conductor, "enqueue_and_maybe_wait", return_value=0) as enqueue:
            code = conductor.handle_real_operation(state.paths, "diagnostics", ["build-cache", "--limit", "3"])

        registry = conductor.OperationRegistry(state.paths.repo_root)
        argv, lanes, cwd, _env, timeout = registry.prepare(
            {"operation": "diagnostics", "args": {"subcommand": "build-cache", "limit": 3}}
        )

        self.assertEqual(code, 0)
        self.assertEqual(enqueue.call_args.args[1], "diagnostics")
        self.assertEqual(enqueue.call_args.args[2], {"subcommand": "build-cache", "limit": 3})
        self.assertEqual(lanes, [])
        self.assertEqual(cwd, state.paths.repo_root)
        self.assertEqual(timeout, conductor.SHORT_TIMEOUT_SECONDS)
        self.assertTrue(Path(argv[0]).name.startswith("python3"))
        self.assertIn('"kind":"diagnostics_build_cache"', argv[-1].replace(" ", ""))

    def test_diagnostics_build_cache_reports_managed_worktree_build_sizes(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            container = Path(tmp) / ".repoprompt-worktrees" / "repoprompt-ce-upstream"
            repo_root = container / "wt-a"
            sibling = container / "wt-b"
            (repo_root / ".build").mkdir(parents=True)
            (sibling / ".build").mkdir(parents=True)
            (repo_root / ".build" / "a.bin").write_bytes(b"a" * 1024)
            (sibling / ".build" / "b.bin").write_bytes(b"b" * 2 * 1024 * 1024)

            output = io.StringIO()
            with contextlib.redirect_stdout(output):
                code = conductor.operation_diagnostics_build_cache(repo_root, {"limit": 1})

        text = output.getvalue()
        self.assertEqual(code, 0)
        self.assertIn("Build cache diagnostics", text)
        self.assertIn("Current .build:", text)
        self.assertIn("Worktree .build total:", text)
        self.assertIn("across 2 build directories", text)
        self.assertIn("Top .build directories:", text)
        self.assertIn("wt-b", text)

    def test_release_local_install_delegates_installer_with_release_lanes_and_confirmation(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            registry = conductor.OperationRegistry(Path(tmp))
            argv, lanes, _cwd, env, timeout = registry.prepare(
                {
                    "operation": "release",
                    "args": {"subcommand": "local-install"},
                    "env": {
                        "CONFIRM_LOCAL_PRODUCTION_INSTALL": "1",
                        "LOCAL_SELF_SIGNED_CERTIFICATE_NAME": "divergent override",
                    },
                }
            )

        self.assertEqual(Path(argv[0]).name, "install_local_production.sh")
        self.assertEqual(lanes, ["build", "debugArtifact", "release"])
        self.assertEqual(env["CONFIRM_LOCAL_PRODUCTION_INSTALL"], "1")
        self.assertNotIn("LOCAL_SELF_SIGNED_CERTIFICATE_NAME", env)
        self.assertEqual(timeout, conductor.RELEASE_TIMEOUT_SECONDS)

    def test_ensure_daemon_launchd_opt_out_uses_direct_spawn_with_devnull_stdin(self) -> None:
        tmp, state = self.make_state()
        self.addCleanup(tmp.cleanup)
        fake_proc = mock.Mock()
        fake_proc.poll.return_value = None
        down_before_start = conductor.ConductorError("down before start")
        down_before_spawn = conductor.ConductorError("down before spawn")

        with mock.patch.object(
            conductor,
            "request_daemon",
            side_effect=[down_before_start, down_before_spawn, {"protocolVersion": conductor.PROTOCOL_VERSION}],
        ), mock.patch.object(conductor, "run_launchctl") as launchctl, mock.patch.object(
            conductor.subprocess, "Popen", return_value=fake_proc
        ) as popen:
            payload = conductor.ensure_daemon(state.paths)

        self.assertEqual(payload["protocolVersion"], conductor.PROTOCOL_VERSION)
        launchctl.assert_not_called()
        self.assertEqual(popen.call_args.kwargs["stdin"], subprocess.DEVNULL)
        self.assertEqual(popen.call_args.kwargs["stdout"].name, str(state.paths.daemon_log_path))
        self.assertEqual(popen.call_args.kwargs["stderr"], subprocess.STDOUT)
        self.assertIn(
            "possibly QoS-clamped context",
            state.paths.daemon_log_path.read_text(encoding="utf-8"),
        )

    def test_daemon_run_job_launches_process_with_devnull_stdin(self) -> None:
        tmp, state = self.make_state()
        self.addCleanup(tmp.cleanup)
        job = self.make_job(state, "job-devnull", "build", {}, ["build"], job_state="running")
        state.jobs[job.ticket] = job
        fake_stdout = mock.Mock()
        fake_stdout.read1.side_effect = [b""]
        fake_process = mock.Mock()
        fake_process.pid = os.getpid()
        fake_process.stdout = fake_stdout
        fake_process.wait.return_value = 0

        with mock.patch.object(conductor, "operation_requires_global_heavy_slot", return_value=False), mock.patch.object(
            conductor.subprocess, "Popen", return_value=fake_process
        ) as popen, mock.patch.object(
            conductor, "process_table_snapshot", return_value={os.getpid(): (os.getppid(), "fixture-start")}
        ), mock.patch.object(state, "_schedule_locked"), mock.patch.object(state, "_refresh_output_summary"):
            state._run_job(job.ticket)

        job_launch = next(call for call in popen.call_args_list if call.kwargs.get("stdin") == subprocess.DEVNULL)
        self.assertEqual(job_launch.kwargs["stdout"], subprocess.PIPE)
        self.assertEqual(job_launch.kwargs["stderr"], subprocess.STDOUT)
        self.assertEqual(state.jobs[job.ticket].state, "completed")

    def test_daemon_timeout_preserves_timeout_result_when_root_resists_sigkill(self) -> None:
        tmp, state = self.make_state()
        self.addCleanup(tmp.cleanup)
        job = self.make_job(state, "job-timeout-sigkill", "build", {}, ["build"], job_state="running")
        state.jobs[job.ticket] = job
        fake_stdout = mock.Mock()
        fake_stdout.read1.side_effect = [b""]
        fake_process = mock.Mock()
        fake_process.pid = os.getpid()
        fake_process.stdout = fake_stdout
        fake_process.wait.side_effect = [
            subprocess.TimeoutExpired(["fixture"], 1.0),
            subprocess.TimeoutExpired(["fixture"], conductor.TERMINATE_GRACE_SECONDS),
            subprocess.TimeoutExpired(["fixture"], conductor.KILL_GRACE_SECONDS),
        ]

        with mock.patch.object(conductor, "operation_requires_global_heavy_slot", return_value=False), mock.patch.object(
            conductor.subprocess, "Popen", return_value=fake_process
        ), mock.patch.object(
            conductor, "process_table_snapshot", return_value={os.getpid(): (os.getppid(), "fixture-start")}
        ), mock.patch.object(state, "_terminate_process_group_locked"), mock.patch.object(
            state, "_kill_process_group_locked"
        ), mock.patch.object(
            state, "_wait_for_process_tree_exit_locked", side_effect=[False, True]
        ), mock.patch.object(
            state, "_schedule_locked"
        ), mock.patch.object(
            state, "_refresh_output_summary"
        ):
            state._run_job(job.ticket)

        self.assertEqual(job.state, "failed")
        self.assertEqual(job.exit_code, 124)
        self.assertTrue(job.timed_out)
        self.assertIn("job processes remained alive after SIGKILL escalation", job.error or "")
        self.assertNotIn("daemon runner error", job.result_summary or "")

    def test_process_group_signal_requires_verified_job_identity(self) -> None:
        tmp, state = self.make_state()
        self.addCleanup(tmp.cleanup)
        job = self.make_job(state, "job-pgid-unverified", "fixture", {}, ["build"], job_state="running")
        job.process_pgid = 123456
        state.jobs[job.ticket] = job

        with mock.patch.object(conductor.os, "killpg") as killpg:
            with state.condition:
                state._terminate_process_group_locked(job, reason="unverified group")

        killpg.assert_not_called()
        self.assertFalse(job.process_group_identity_confirmed)
        self.assertIn("terminating process tree: unverified group", "".join(job.tail))
        self.assertNotIn("terminating process group: unverified group", "".join(job.tail))

    def test_process_group_signal_refuses_reused_root_pid_identity(self) -> None:
        tmp, state = self.make_state()
        self.addCleanup(tmp.cleanup)
        job = self.make_job(state, "job-pgid-reused", "fixture", {}, ["build"], job_state="running")
        job.process_pid = 12345
        job.process_pgid = 12345
        job.process_start = "expected-start"
        job.tracked_processes[12345] = "expected-start"
        state.jobs[job.ticket] = job

        with mock.patch.object(
            conductor,
            "process_group_snapshot",
            return_value={12345: (1, "expected-start")},
        ), mock.patch.object(
            conductor,
            "process_table_snapshot",
            return_value={12345: (1, "reused-start")},
        ), mock.patch.object(conductor.os, "killpg") as killpg:
            with state.condition:
                state._terminate_process_group_locked(job, reason="reused root")

        killpg.assert_not_called()
        self.assertIn("recorded child identity no longer matches", "".join(job.tail))

    def test_cancel_signals_process_group_for_reparented_descendant(self) -> None:
        tmp, state = self.make_state()
        self.addCleanup(tmp.cleanup)
        root = Path(tmp.name)
        grandchild_pid_path = root / "grandchild.pid"
        grandchild_ready_path = root / "grandchild.ready"
        job = self.make_job(state, "job-pgid-orphan", "fixture", {}, ["build"], job_state="running")
        state.jobs[job.ticket] = job
        state.active_lanes = {"build": job.ticket}

        grandchild_code = textwrap.dedent(
            """
            import os
            import signal
            import sys
            import time

            signal.signal(signal.SIGTERM, signal.SIG_IGN)
            pid_path = sys.argv[1]
            ready_path = sys.argv[2]
            with open(pid_path, "w", encoding="utf-8") as handle:
                handle.write(str(os.getpid()))
            with open(ready_path, "w", encoding="utf-8") as handle:
                handle.write(f"{os.getpid()} {os.getppid()} {os.getpgid(0)}")
            while True:
                time.sleep(1)
            """
        )
        intermediate_code = textwrap.dedent(
            """
            import subprocess
            import sys

            subprocess.Popen(
                [sys.executable, "-u", "-c", sys.argv[1], sys.argv[2], sys.argv[3]],
                stdin=subprocess.DEVNULL,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                start_new_session=False,
            )
            """
        )
        root_code = textwrap.dedent(
            """
            import os
            import subprocess
            import sys
            import time

            grandchild_code = sys.argv[1]
            pid_path = sys.argv[2]
            ready_path = sys.argv[3]
            subprocess.run(
                [sys.executable, "-u", "-c", sys.argv[4], grandchild_code, pid_path, ready_path],
                check=True,
            )
            deadline = time.time() + 5.0
            while not os.path.exists(ready_path) and time.time() < deadline:
                time.sleep(0.05)
            print("ROOT_READY", flush=True)
            while True:
                time.sleep(1)
            """
        )
        argv = [
            sys.executable,
            "-u",
            "-c",
            root_code,
            grandchild_code,
            str(grandchild_pid_path),
            str(grandchild_ready_path),
            intermediate_code,
        ]
        state.registry.prepare = lambda _request: (argv, ["build"], root, os.environ.copy(), 30.0)  # type: ignore[method-assign]

        def cleanup_grandchild() -> None:
            if not grandchild_pid_path.exists() or not grandchild_ready_path.exists():
                return
            with contextlib.suppress(ValueError, ProcessLookupError, PermissionError, OSError):
                grandchild_pid = int(grandchild_pid_path.read_text(encoding="utf-8"))
                grandchild_pgid = int(grandchild_ready_path.read_text(encoding="utf-8").split()[2])
                if os.getpgid(grandchild_pid) == grandchild_pgid:
                    os.kill(grandchild_pid, signal.SIGKILL)

        self.addCleanup(cleanup_grandchild)
        with mock.patch.object(conductor, "operation_requires_global_heavy_slot", return_value=False):
            worker = threading.Thread(target=state._run_job, args=(job.ticket,), daemon=True)
            worker.start()
            deadline = time.time() + 5.0
            while time.time() < deadline:
                with state.condition:
                    process_pgid = job.process_pgid
                if grandchild_ready_path.exists() and process_pgid:
                    break
                time.sleep(0.05)
            self.assertTrue(grandchild_ready_path.exists())
            grandchild_pid = int(grandchild_pid_path.read_text(encoding="utf-8"))
            with state.condition:
                self.assertEqual(os.getpgid(grandchild_pid), job.process_pgid)

            with mock.patch.multiple(
                conductor,
                TERMINATE_GRACE_SECONDS=0.2,
                KILL_GRACE_SECONDS=1.0,
                PROCESS_TREE_POLL_SECONDS=0.02,
            ):
                state.job_cancel(job.ticket, None)
            worker.join(timeout=5.0)

        self.assertFalse(worker.is_alive())
        self.assertEqual(job.state, "canceled")
        deadline = time.time() + 3.0
        while time.time() < deadline and conductor.pid_alive(grandchild_pid):
            time.sleep(0.05)
        self.assertFalse(conductor.pid_alive(grandchild_pid))

    def test_run_operation_command_uses_devnull_stdin(self) -> None:
        completed = subprocess.CompletedProcess(["echo", "ok"], 0, "ok\n", "")
        with mock.patch.object(conductor.subprocess, "run", return_value=completed) as run, contextlib.redirect_stdout(io.StringIO()):
            code, stdout, stderr = conductor.run_operation_command("fixture", ["echo", "ok"], Path.cwd())

        self.assertEqual((code, stdout, stderr), (0, "ok\n", ""))
        self.assertEqual(run.call_args.kwargs["stdin"], subprocess.DEVNULL)
        self.assertTrue(run.call_args.kwargs["capture_output"])
        self.assertTrue(run.call_args.kwargs["text"])

    def test_release_local_install_job_succeeds_with_closed_parent_fd0(self) -> None:
        child_code = textwrap.dedent(
            f"""
            import os
            import sys
            import tempfile
            from pathlib import Path

            sys.path.insert(0, {str(SCRIPT_DIR)!r})
            import conductor

            tmp = tempfile.TemporaryDirectory()
            root = Path(tmp.name)
            conductor.machine_lock_dir = lambda: root / "machine-locks"
            jobs_dir = root / "jobs"
            scripts_dir = root / "Scripts"
            jobs_dir.mkdir()
            scripts_dir.mkdir()
            installer = scripts_dir / "install_local_production.sh"
            installer.write_text(
                "#!" + {sys.executable!r} + "\\n"
                "import os, sys\\n"
                "fd_stat = os.fstat(0)\\n"
                "devnull_stat = os.stat(os.devnull)\\n"
                "if (fd_stat.st_dev, fd_stat.st_ino) != (devnull_stat.st_dev, devnull_stat.st_ino):\\n"
                "    print('STDIN_NOT_DEVNULL')\\n"
                "    sys.exit(44)\\n"
                "print('STDIN_DEVNULL_OK')\\n",
                encoding="utf-8",
            )
            installer.chmod(0o755)
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
            state._schedule_locked = lambda: None
            payload = state.enqueue(
                {{
                    "operation": "release",
                    "args": {{"subcommand": "local-install"}},
                    "env": {{"CONFIRM_LOCAL_PRODUCTION_INSTALL": "1"}},
                }}
            )
            ticket = payload["ticket"]
            job = state.jobs[ticket]
            job.state = "running"
            job.started_at = conductor.now()
            for lane in job.lanes:
                state.active_lanes[lane] = ticket
            os.close(0)
            state._run_job(ticket)
            log = job.log_path.read_text(encoding="utf-8")
            if job.state != "completed" or "STDIN_DEVNULL_OK" not in log:
                print(f"job_state={{job.state}} exit={{job.exit_code}}")
                print(log)
                sys.exit(1)
            print("CLOSED_FD_REGRESSION_OK")
            tmp.cleanup()
            """
        )

        result = subprocess.run(
            [sys.executable, "-c", child_code],
            stdin=subprocess.DEVNULL,
            text=True,
            capture_output=True,
            timeout=10,
        )

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("CLOSED_FD_REGRESSION_OK", result.stdout)

    def test_app_stop_supersedes_queued_live_app_but_not_build_only_work(self) -> None:
        tmp, state = self.make_state()
        self.addCleanup(tmp.cleanup)
        old_run = self.make_job(state, "old-run", "run", {}, ["build", "debugArtifact", "liveApp"])
        build = self.make_job(state, "build", "build", {}, ["build"])
        state.jobs = {old_run.ticket: old_run, build.ticket: build}
        state.queue = [old_run.ticket, build.ticket]

        with mock.patch.object(state, "_schedule_locked"):
            payload = state.enqueue({"operation": "app", "args": {"subcommand": "stop"}})

        self.assertEqual(old_run.state, "canceled")
        self.assertEqual(old_run.exit_code, 130)
        self.assertEqual(old_run.superseded_by_operation, "app stop")
        self.assertEqual(build.state, "queued")
        self.assertEqual(payload["supersededJobs"][0]["ticket"], old_run.ticket)

    def test_app_relaunch_supersedes_queued_run(self) -> None:
        tmp, state = self.make_state()
        self.addCleanup(tmp.cleanup)
        old_run = self.make_job(state, "old-run", "run", {}, ["build", "debugArtifact", "liveApp"])
        state.jobs[old_run.ticket] = old_run
        state.queue.append(old_run.ticket)

        with mock.patch.object(state, "_schedule_locked"):
            payload = state.enqueue({"operation": "app", "args": {"subcommand": "relaunch", "appArgs": []}})

        self.assertEqual(old_run.state, "canceled")
        self.assertEqual(old_run.superseded_by_operation, "app relaunch")
        self.assertEqual(payload["operationLabel"], "app relaunch")

    def test_running_launch_is_cancellation_requested_and_retains_lane_for_stop(self) -> None:
        tmp, state = self.make_state()
        self.addCleanup(tmp.cleanup)
        old_run = self.make_job(state, "running-run", "run", {}, ["build", "debugArtifact", "liveApp"], "running")
        old_run.process_pid = 123
        state.jobs[old_run.ticket] = old_run
        state.active_lanes = {lane: old_run.ticket for lane in old_run.lanes}

        with mock.patch.object(state, "_terminate_process_group_locked") as terminate, mock.patch.object(
            state, "_schedule_locked"
        ), mock.patch.object(conductor.threading, "Thread"):
            payload = state.enqueue({"operation": "app", "args": {"subcommand": "stop"}})

        stop = state.jobs[payload["ticket"]]
        self.assertTrue(old_run.cancel_requested)
        self.assertEqual(old_run.state, "running")
        self.assertEqual(state.active_lanes["liveApp"], old_run.ticket)
        self.assertTrue(stop.args["guardDelayedLaunch"])
        terminate.assert_called_once()

    def test_superseded_job_without_pid_is_signaled_after_delayed_assignment_then_escalated(self) -> None:
        tmp, state = self.make_state()
        self.addCleanup(tmp.cleanup)
        old_run = self.make_job(state, "delayed-pid-run", "run", {}, ["build", "debugArtifact", "liveApp"], "running")
        state.jobs[old_run.ticket] = old_run
        state.active_lanes = {lane: old_run.ticket for lane in old_run.lanes}
        real_thread = threading.Thread

        with mock.patch.object(state, "_terminate_process_group_locked") as terminate, mock.patch.object(
            state, "_kill_process_group_locked"
        ) as kill, mock.patch.object(
            state, "_wait_for_process_tree_exit_locked", side_effect=[True, False]
        ), mock.patch.object(state, "_schedule_locked"), mock.patch.object(
            conductor, "TERMINATE_GRACE_SECONDS", 0.01
        ), mock.patch.object(conductor.threading, "Thread") as thread_factory:
            state.enqueue({"operation": "app", "args": {"subcommand": "stop"}})
            terminate.assert_not_called()
            # Step 5: the enqueue's retention pass may also construct the maintenance worker.
            escalations = [
                call for call in thread_factory.call_args_list
                if call.kwargs.get("target") == state._escalate_canceled_job_after_grace
            ]
            self.assertEqual(len(escalations), 1)
            target = escalations[0].kwargs["target"]
            args = escalations[0].kwargs["args"]
            self.assertFalse(args[2])
            worker = real_thread(target=target, args=args)
            worker.start()
            time.sleep(0.03)
            terminate.assert_not_called()
            kill.assert_not_called()
            with state.condition:
                old_run.process_pid = 456
                state.condition.notify_all()
            worker.join(timeout=1.0)

        self.assertFalse(worker.is_alive())
        terminate.assert_called_once()
        self.assertIs(terminate.call_args.args[0], old_run)
        kill.assert_called_once()
        self.assertIs(kill.call_args.args[0], old_run)

    def test_outstanding_launch_guard_propagates_to_newer_lifecycle_intents(self) -> None:
        for subcommand in ["stop", "relaunch"]:
            with self.subTest(subcommand=subcommand):
                tmp, state = self.make_state()
                self.addCleanup(tmp.cleanup)
                guarded = self.make_job(
                    state,
                    "guarded-stop",
                    "app",
                    {"subcommand": "stop", "guardDelayedLaunch": True},
                    ["liveApp"],
                )
                state.jobs[guarded.ticket] = guarded
                state.queue.append(guarded.ticket)
                args = {"subcommand": subcommand}
                if subcommand == "relaunch":
                    args["appArgs"] = []

                with mock.patch.object(state, "_schedule_locked"):
                    payload = state.enqueue({"operation": "app", "args": args})

                self.assertTrue(state.jobs[payload["ticket"]].args["guardDelayedLaunch"])

    def test_ordinary_run_remains_fifo_and_does_not_supersede(self) -> None:
        tmp, state = self.make_state()
        self.addCleanup(tmp.cleanup)
        prior = self.make_job(state, "prior", "run", {}, ["build", "debugArtifact", "liveApp"])
        state.jobs[prior.ticket] = prior
        state.queue.append(prior.ticket)

        with mock.patch.object(state, "_schedule_locked"):
            payload = state.enqueue({"operation": "run", "args": {"appArgs": []}})

        self.assertEqual(prior.state, "queued")
        self.assertFalse(prior.cancel_requested)
        self.assertEqual(payload.get("supersededJobs"), [])

    def test_request_key_reuse_is_checked_before_supersession(self) -> None:
        tmp, state = self.make_state()
        self.addCleanup(tmp.cleanup)
        request = {"operation": "app", "args": {"subcommand": "relaunch", "appArgs": []}, "requestKey": "interactive"}
        fingerprint = state.registry.fingerprint(request)
        existing = self.make_job(
            state,
            "existing",
            "app",
            {"subcommand": "relaunch", "appArgs": []},
            ["build", "debugArtifact", "liveApp"],
            request_key="interactive",
            fingerprint=fingerprint,
        )
        victim = self.make_job(state, "victim", "run", {}, ["build", "debugArtifact", "liveApp"])
        state.jobs = {existing.ticket: existing, victim.ticket: victim}
        state.queue = [existing.ticket, victim.ticket]
        state.request_keys["interactive"] = existing.ticket

        payload = state.enqueue(request)

        self.assertTrue(payload["reused"])
        self.assertFalse(victim.cancel_requested)

    def test_request_key_mismatch_has_no_supersession_side_effect(self) -> None:
        tmp, state = self.make_state()
        self.addCleanup(tmp.cleanup)
        existing = self.make_job(state, "keyed", "build", {}, ["build"], request_key="interactive", fingerprint="other")
        victim = self.make_job(state, "victim", "run", {}, ["build", "debugArtifact", "liveApp"])
        state.jobs = {existing.ticket: existing, victim.ticket: victim}
        state.queue = [existing.ticket, victim.ticket]
        state.request_keys["interactive"] = existing.ticket

        with self.assertRaises(conductor.ConductorError):
            state.enqueue({"operation": "app", "args": {"subcommand": "stop"}, "requestKey": "interactive"})

        self.assertFalse(victim.cancel_requested)
        self.assertEqual(victim.state, "queued")

    def test_queued_payload_identifies_active_lane_blocker(self) -> None:
        tmp, state = self.make_state()
        self.addCleanup(tmp.cleanup)
        active = self.make_job(state, "build-active", "build", {}, ["build"], "running")
        waiting = self.make_job(state, "relaunch", "app", {"subcommand": "relaunch"}, ["build", "debugArtifact", "liveApp"])
        state.jobs = {active.ticket: active, waiting.ticket: waiting}
        state.active_lanes = {"build": active.ticket}
        state.queue = [waiting.ticket]

        payload = state.job_status(waiting.ticket, None)

        self.assertEqual(payload["blockedBy"][0]["ticket"], active.ticket)
        self.assertEqual(payload["blockedBy"][0]["conflictingLanes"], ["build"])

    def wait_for_terminal_job(self, state: conductor.DaemonState, ticket: str, timeout: float = 5.0) -> conductor.Job:
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            with state.condition:
                job = state.jobs[ticket]
                # Step 2 timing publishes, then persists, after the terminal
                # transition; wait for publication here. Persistence is drained by
                # the state's fixture cleanup before its temporary directory goes.
                if job.state in conductor.TERMINAL_STATES and (
                    job.telemetry is None or job.phase_metrics is not None
                ):
                    return job
            time.sleep(0.01)
        with state.condition:
            return state.jobs[ticket]

    def make_state_for_global_slot(
        self,
        root: Path,
        name: str,
        shared_socket_parent: Path,
    ) -> conductor.DaemonState:
        state_dir = root / name
        jobs_dir = state_dir / "jobs"
        jobs_dir.mkdir(parents=True)
        paths = conductor.Paths(
            repo_root=state_dir,
            repo_hash=name,
            state_dir=state_dir,
            socket_path=shared_socket_parent / f"{name}.sock",
            pid_path=state_dir / "conductor.pid",
            lock_path=state_dir / "conductor.lock",
            jobs_dir=jobs_dir,
            daemon_log_path=state_dir / "daemon.log",
            daemon_meta_path=state_dir / "daemon.json",
            running_processes_path=state_dir / "running.json",
        )
        state = conductor.DaemonState(paths)
        # Callers register ``tmp.cleanup`` first; cleanups run LIFO, so this
        # drains timing persistence into ``state_dir`` before it is removed.
        self.addCleanup(self.drain_job_telemetry, state)
        return state

    def drain_job_telemetry(self, state: conductor.DaemonState) -> None:
        self.assertTrue(state._await_job_telemetry(10.0), "job timing persistence did not drain")

    def test_global_slot_fixture_cleanup_waits_for_timing_persistence(self) -> None:
        observed: dict[str, object] = {}
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)

        def assert_persisted_before_removal() -> None:
            # Cleanups run LIFO: after the fixture drain, before ``tmp.cleanup``.
            if "job" not in observed:
                return  # the test body already failed before its job existed
            state, job = observed["state"], observed["job"]
            with state.condition:
                self.assertTrue(job.telemetry_persisted)
                self.assertIsNone(job.telemetry_persist_error)
            self.assertTrue((state.paths.jobs_dir / f"{job.ticket}.timings.json").is_file())

        self.addCleanup(assert_persisted_before_removal)
        root = Path(tmp.name)
        state = self.make_state_for_global_slot(root, "daemon", root / "shared")
        observed["state"] = state
        release = threading.Event()
        persist = state._persist_job_telemetry

        def gated_persist(*args, **kwargs):
            self.assertTrue(release.wait(10.0))
            return persist(*args, **kwargs)

        state._persist_job_telemetry = gated_persist
        lock_root = root / "machine-locks"
        with mock.patch.object(conductor, "GLOBAL_HEAVY_SLOT_POLL_SECONDS", 0.01), mock.patch.object(
            conductor, "machine_lock_dir", return_value=lock_root
        ):
            payload = state.enqueue(
                {"operation": "fake-sleep", "args": {"seconds": 0.01, "lanes": ["build"], "message": "gated"}}
            )
            job = self.wait_for_terminal_job(state, payload["ticket"])
        observed["job"] = job

        with state.condition:
            self.assertEqual(job.state, "completed", job.result_summary)
            self.assertIsNotNone(job.phase_metrics)
            self.assertTrue(job.telemetry_persist_claimed)
            self.assertFalse(job.telemetry_persisted)
        # Runs first among cleanups: persistence is still gated when the drain starts.
        self.addCleanup(threading.Timer(0.2, release.set).start)

    def test_global_heavy_slot_serializes_build_lane_jobs_across_daemons(self) -> None:
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        root = Path(tmp.name)
        shared_socket_parent = root / "shared"
        shared_socket_parent.mkdir()
        state_a = self.make_state_for_global_slot(root, "daemon-a", shared_socket_parent)
        state_b = self.make_state_for_global_slot(root, "daemon-b", shared_socket_parent)

        lock_root = root / "machine-locks"
        with mock.patch.object(conductor, "GLOBAL_HEAVY_SLOT_POLL_SECONDS", 0.01), mock.patch.object(
            conductor, "machine_lock_dir", return_value=lock_root
        ):
            payload_a = state_a.enqueue(
                {
                    "operation": "fake-sleep",
                    "args": {"seconds": 0.25, "lanes": ["build"], "message": "daemon-a"},
                }
            )
            payload_b = state_b.enqueue(
                {
                    "operation": "fake-sleep",
                    "args": {"seconds": 0.25, "lanes": ["build"], "message": "daemon-b"},
                }
            )
            job_a = self.wait_for_terminal_job(state_a, payload_a["ticket"])
            job_b = self.wait_for_terminal_job(state_b, payload_b["ticket"])

        self.assertEqual(job_a.state, "completed", job_a.result_summary)
        self.assertEqual(job_b.state, "completed", job_b.result_summary)
        self.assertEqual(job_a.global_heavy_slot_path, str(lock_root / "global-heavy-0.lock"))
        self.assertEqual(job_b.global_heavy_slot_path, str(lock_root / "global-heavy-0.lock"))
        self.assertIsNotNone(job_a.process_started_at)
        self.assertIsNotNone(job_a.process_finished_at)
        self.assertIsNotNone(job_b.process_started_at)
        self.assertIsNotNone(job_b.process_finished_at)

        first, second = sorted([job_a, job_b], key=lambda job: job.process_started_at or 0)
        self.assertGreaterEqual(second.process_started_at or 0, first.process_finished_at or 0)
        self.assertGreater(max(job_a.global_heavy_slot_wait_seconds or 0, job_b.global_heavy_slot_wait_seconds or 0), 0.05)

    def test_cancel_waiting_for_global_heavy_slot_does_not_spawn_process(self) -> None:
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        root = Path(tmp.name)
        shared_socket_parent = root / "shared"
        shared_socket_parent.mkdir()
        state = self.make_state_for_global_slot(root, "daemon", shared_socket_parent)
        lock_root = root / "machine-locks"
        with mock.patch.object(conductor, "GLOBAL_HEAVY_SLOT_POLL_SECONDS", 0.01), mock.patch.object(
            conductor, "machine_lock_dir", return_value=lock_root
        ):
            lock_path = lock_root / "global-heavy-0.lock"
            lock_root.mkdir(mode=0o700, parents=True, exist_ok=True)
            lock_file = lock_path.open("a+", encoding="utf-8")
            self.addCleanup(lock_file.close)
            fcntl.flock(lock_file.fileno(), fcntl.LOCK_EX)
            self.addCleanup(lambda: fcntl.flock(lock_file.fileno(), fcntl.LOCK_UN))
            payload = state.enqueue(
                {
                    "operation": "fake-sleep",
                    "args": {"seconds": 0.5, "lanes": ["build"], "message": "blocked"},
                }
            )
            ticket = payload["ticket"]
            deadline = time.monotonic() + 2.0
            while time.monotonic() < deadline:
                with state.condition:
                    job = state.jobs[ticket]
                    if job.global_heavy_slot_path and job.process_started_at is None:
                        break
                time.sleep(0.01)
            with state.condition:
                self.assertEqual(state.jobs[ticket].state, "running")
                self.assertIsNone(state.jobs[ticket].process_started_at)
                status_payload = state._job_payload_locked(state.jobs[ticket], include_tail=False)
                self.assertEqual(status_payload["state"], "waiting-heavy-slot")
                self.assertIsNotNone(status_payload["globalHeavySlotWaitSeconds"])
            state.job_cancel(ticket, None)
            job = self.wait_for_terminal_job(state, ticket)

        self.assertEqual(job.state, "canceled")
        self.assertEqual(job.exit_code, 130)
        self.assertEqual(job.result_summary, "canceled before global heavy slot")
        self.assertIsNone(job.process_pid)
        self.assertIsNone(job.process_started_at)
        self.assertIn("job canceled before global heavy slot", "".join(job.tail))

    def test_xctest_slot_wait_uses_derived_state_and_renders_holder(self) -> None:
        tmp, state = self.make_state()
        self.addCleanup(tmp.cleanup)
        job = self.make_job(
            state,
            "xctest-wait",
            "test-artifact",
            {"filter": "AlphaTests"},
            ["build"],
            job_state="running",
        )
        job.global_xctest_slot_path = "/tmp/global-xctest-0.lock"
        job.global_xctest_slot_holder = "pid=123 ticket=holder"
        state.jobs[job.ticket] = job

        with state.lock:
            payload = state._job_payload_locked(job, include_tail=False)
        listed = state.list_jobs("waiting-xctest-slot")
        with contextlib.redirect_stdout(io.StringIO()) as output:
            conductor.render_job(payload, include_tail=False)

        self.assertEqual(payload["state"], "waiting-xctest-slot")
        self.assertEqual([item["ticket"] for item in listed["jobs"]], [job.ticket])
        self.assertIn("xctest:    /tmp/global-xctest-0.lock", output.getvalue())
        self.assertIn("holder:    pid=123 ticket=holder", output.getvalue())

    def test_socket_parent_does_not_shard_global_heavy_slots(self) -> None:
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        root = Path(tmp.name)
        state_a = self.make_state_for_global_slot(root, "daemon-a", root / "socket-a")
        state_b = self.make_state_for_global_slot(root, "daemon-b", root / "socket-b")
        lock_root = root / "machine-locks"

        with mock.patch.object(conductor, "machine_lock_dir", return_value=lock_root):
            self.assertEqual(state_a._global_heavy_slot_paths(), [lock_root / "global-heavy-0.lock"])
            self.assertEqual(state_b._global_heavy_slot_paths(), [lock_root / "global-heavy-0.lock"])

    def test_configured_global_heavy_slots_allow_two_cross_daemon_builds(self) -> None:
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        root = Path(tmp.name)
        state_a = self.make_state_for_global_slot(root, "daemon-a", root / "socket-a")
        state_b = self.make_state_for_global_slot(root, "daemon-b", root / "socket-b")
        lock_root = root / "machine-locks"

        with mock.patch.object(conductor, "machine_lock_dir", return_value=lock_root), mock.patch.dict(
            os.environ,
            {"REPOPROMPT_DEV_HEAVY_SLOTS": "2"},
        ):
            payload_a = state_a.enqueue(
                {
                    "operation": "fake-sleep",
                    "args": {"seconds": 0.25, "lanes": ["build"], "message": "daemon-a"},
                    "env": {"REPOPROMPT_DEV_HEAVY_SLOTS": "2"},
                }
            )
            payload_b = state_b.enqueue(
                {
                    "operation": "fake-sleep",
                    "args": {"seconds": 0.25, "lanes": ["build"], "message": "daemon-b"},
                    "env": {"REPOPROMPT_DEV_HEAVY_SLOTS": "2"},
                }
            )
            job_a = self.wait_for_terminal_job(state_a, payload_a["ticket"])
            job_b = self.wait_for_terminal_job(state_b, payload_b["ticket"])

        self.assertEqual(job_a.state, "completed", job_a.result_summary)
        self.assertEqual(job_b.state, "completed", job_b.result_summary)
        self.assertNotEqual(job_a.global_heavy_slot_path, job_b.global_heavy_slot_path)
        latest_start = max(job_a.process_started_at or 0, job_b.process_started_at or 0)
        earliest_finish = min(job_a.process_finished_at or 0, job_b.process_finished_at or 0)
        self.assertLess(latest_start, earliest_finish)

    def test_live_app_lock_serializes_across_processes_without_gui_launch(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            lock_root = root / "machine-locks"
            events = root / "events.log"
            ready = root / "ready-a"
            child = textwrap.dedent(
                """\
                import sys, time
                from pathlib import Path
                sys.path.insert(0, sys.argv[1])
                import conductor
                conductor.MACHINE_LOCK_POLL_SECONDS = 0.01
                conductor.machine_lock_dir = lambda: Path(sys.argv[2])
                label = sys.argv[3]
                events = Path(sys.argv[4])
                ready = Path(sys.argv[5]) if sys.argv[5] != '-' else None
                metadata = conductor.display_lock_metadata(
                    lock_kind='live-app',
                    ticket=label,
                    operation='test-live-app',
                    operation_label='test live app',
                    repo_root=Path(sys.argv[2]),
                )
                with conductor.machine_exclusive_lock(conductor.live_app_lock_path(), metadata, 'live-app lock'):
                    with events.open('a', encoding='utf-8') as handle:
                        handle.write(f'start {label} {time.time()}\\n')
                    if ready is not None:
                        ready.write_text('ready', encoding='utf-8')
                    time.sleep(0.25)
                    with events.open('a', encoding='utf-8') as handle:
                        handle.write(f'end {label} {time.time()}\\n')
                """
            )
            proc_a = subprocess.Popen(
                [sys.executable, "-c", child, str(SCRIPT_DIR), str(lock_root), "a", str(events), str(ready)],
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
            )
            deadline = time.monotonic() + 2.0
            while time.monotonic() < deadline and not ready.exists():
                time.sleep(0.01)
            self.assertTrue(ready.exists())
            proc_b = subprocess.Popen(
                [sys.executable, "-c", child, str(SCRIPT_DIR), str(lock_root), "b", str(events), "-"],
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
            )
            stdout_a, stderr_a = proc_a.communicate(timeout=5)
            stdout_b, stderr_b = proc_b.communicate(timeout=5)
            self.assertEqual(proc_a.returncode, 0, stdout_a + stderr_a)
            self.assertEqual(proc_b.returncode, 0, stdout_b + stderr_b)
            rows = events.read_text(encoding="utf-8").splitlines()

        self.assertEqual([row.split()[0:2] for row in rows], [["start", "a"], ["end", "a"], ["start", "b"], ["end", "b"]])


class ConductorTestContractTests(LifecycleTestCase):
    LEDGER_HEADER = "method_id\ttarget\tsuite\tmethod\n"

    def write_ledger(self, root: Path) -> None:
        ledger = root / "Scripts" / "Fixtures" / "test-suite-contract-ledger.tsv"
        ledger.parent.mkdir(parents=True, exist_ok=True)
        ledger.write_text(
            self.LEDGER_HEADER
            + "root/RepoPromptTests.AlphaTests/testOne\troot\tRepoPromptTests.AlphaTests\ttestOne\n"
            + "root/RepoPromptTests.BetaTests/testTwo\troot\tRepoPromptTests.BetaTests\ttestTwo\n"
            + "root/RepoPromptTests.GammaTests/testThree\troot\tRepoPromptTests.GammaTests\ttestThree\n"
            + "core/RepoPromptCoreTests.CoreTests/testCore\tcore\tRepoPromptCoreTests.CoreTests\ttestCore\n",
            encoding="utf-8",
        )

    def test_filter_preflight_accepts_suite_and_method_forms(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            self.write_ledger(root)
            for filter_value in [
                "AlphaTests",
                "RepoPromptTests.AlphaTests",
                "AlphaTests/testOne",
                "RepoPromptTests.AlphaTests/testOne",
                "Alpha.*testOne",
            ]:
                with self.subTest(filter=filter_value):
                    conductor.preflight_test_filter(root, "test", filter_value)
            conductor.preflight_test_filter(root, "core-test", "CoreTests/testCore")

    def test_filter_preflight_garbage_exits_64_fast_with_three_suggestions(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            env = os.environ.copy()
            env["REPOPROMPT_DEV_DAEMON_STATE_DIR"] = str(Path(tmp) / "state")
            started = time.monotonic()
            completed = subprocess.run(
                [sys.executable, str(Path(conductor.__file__)), "test", "--filter", "DefinitelyNoSuchSuite"],
                text=True,
                capture_output=True,
                env=env,
                timeout=10.0,
            )
            elapsed = time.monotonic() - started

        self.assertEqual(completed.returncode, 64, completed.stdout + completed.stderr)
        self.assertLess(elapsed, 5.0)
        self.assertIn("Closest ledger suites:", completed.stderr)
        suggestion_text = completed.stderr.split("Closest ledger suites:", 1)[1].split(". Set", 1)[0]
        self.assertEqual(len(suggestion_text.split(",")), 3)
        self.assertIn("RPCE_ALLOW_UNKNOWN_FILTER=1", completed.stderr)

    def test_filter_preflight_override_bypasses_unknown_filter(self) -> None:
        with tempfile.TemporaryDirectory() as tmp, mock.patch.dict(
            os.environ, {"RPCE_ALLOW_UNKNOWN_FILTER": "1"}, clear=False
        ), contextlib.redirect_stderr(io.StringIO()) as stderr:
            conductor.preflight_test_filter(Path(tmp), "test", "UnknownTests")

        self.assertIn("skipping curated test filter preflight", stderr.getvalue())

    def test_filter_preflight_source_fallback_warns_and_allows(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            self.write_ledger(root)
            source = root / "Tests" / "RepoPromptTests" / "UncuratedTests.swift"
            source.parent.mkdir(parents=True)
            source.write_text("final class UncuratedTests: XCTestCase {}\n", encoding="utf-8")
            with contextlib.redirect_stderr(io.StringIO()) as stderr:
                conductor.preflight_test_filter(root, "test", "RepoPromptTests.UncuratedTests")

        self.assertIn("Suite 'UncuratedTests' found in sources but not in the curated ledger", stderr.getvalue())
        self.assertIn("the ledger is frozen; running with default deadlines", stderr.getvalue())

    def test_filtered_test_timeout_defaults_to_twenty_minutes(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            registry = conductor.OperationRegistry(Path(tmp))
            filtered = registry.prepare({"operation": "test", "args": {"filter": "AlphaTests"}})
            unfiltered = registry.prepare({"operation": "test", "args": {}})
            overridden = registry.prepare(
                {"operation": "provider-test", "args": {"filter": "AlphaTests"}, "timeout": 7.0}
            )
            core_filtered = registry.prepare({"operation": "core-test", "args": {"filter": "AlphaTests"}})

        self.assertEqual(filtered[-1], conductor.FILTERED_TEST_TIMEOUT_SECONDS)
        self.assertEqual(unfiltered[-1], conductor.MEDIUM_TIMEOUT_SECONDS)
        self.assertEqual(overridden[-1], 7.0)
        self.assertEqual(core_filtered[-1], conductor.FILTERED_TEST_TIMEOUT_SECONDS)

    # Step 9 (OD23): fixed benchmark driver-diagnostics route for the root debug test.

    def test_benchmark_driver_diagnostics_cli_registers_only_for_root_test(self) -> None:
        tmp, state = self.make_state()
        self.addCleanup(tmp.cleanup)
        with mock.patch.object(conductor, "enqueue_and_maybe_wait", return_value=0) as enqueue, mock.patch.object(
            conductor, "preflight_test_filter"
        ):
            code = conductor.handle_real_operation(
                state.paths, "test", ["--filter", "AlphaTests", "--benchmark-driver-diagnostics"]
            )
            plain = conductor.handle_real_operation(state.paths, "test", ["--filter", "AlphaTests"])
        self.assertEqual((code, plain), (0, 0))
        self.assertEqual(
            enqueue.call_args_list[0].args[2], {"filter": "AlphaTests", "benchmarkDriverDiagnostics": True}
        )
        # Legacy/default requests never carry the key.
        self.assertEqual(enqueue.call_args_list[1].args[2], {"filter": "AlphaTests"})
        rejected = [
            ("provider-test", ["--filter", "AlphaTests", "--benchmark-driver-diagnostics"], "root debug test"),
            ("core-test", ["--benchmark-driver-diagnostics"], "root debug test"),
            ("test", ["--list", "--benchmark-driver-diagnostics"], "--list"),
            ("test", ["--test-product", "X", "--benchmark-driver-diagnostics"], "--test-product"),
        ]
        for operation, argv, text in rejected:
            with self.subTest(operation=operation, argv=argv):
                with mock.patch.object(conductor, "enqueue_and_maybe_wait") as never, mock.patch.object(
                    conductor, "preflight_test_filter"
                ):
                    with self.assertRaisesRegex(conductor.ConductorError, text):
                        conductor.handle_real_operation(state.paths, operation, argv)
                never.assert_not_called()
        for operation in ("test-artifact", "build", "swift-build", "test-parallel"):
            with self.subTest(operation=operation):
                with mock.patch.object(conductor, "enqueue_and_maybe_wait") as never, self.assertRaises(SystemExit), \
                        contextlib.redirect_stderr(io.StringIO()):
                    conductor.handle_real_operation(state.paths, operation, ["--benchmark-driver-diagnostics"])
                never.assert_not_called()

    def test_benchmark_driver_diagnostics_command_construction_is_fixed(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            registry = conductor.OperationRegistry(Path(tmp))
            diag = registry.prepare(
                {"operation": "test", "args": {"filter": "AlphaTests", "benchmarkDriverDiagnostics": True}}
            )
            plain = registry.prepare({"operation": "test", "args": {"filter": "AlphaTests"}})
        canonical = str(Path(tmp) / "Scripts" / "canonical_swift.sh")
        self.assertEqual(
            diag[0],
            [canonical, "test", "--filter", "AlphaTests", "-Xswiftc", "-driver-show-incremental", "-Xswiftc",
             "-driver-time-compilation"],
        )
        self.assertEqual(plain[0], [canonical, "test", "--filter", "AlphaTests"])
        self.assertEqual(diag[1:2], plain[1:2])
        self.assertEqual(diag[-1], plain[-1])

    def test_benchmark_driver_diagnostics_is_validated_daemon_side_before_enqueue(self) -> None:
        tmp, state = self.make_state()
        self.addCleanup(tmp.cleanup)
        cases = [
            ({"operation": "test", "args": {"benchmarkDriverDiagnostics": False}}, "must be true"),
            ({"operation": "test", "args": {"benchmarkDriverDiagnostics": "-Xfoo"}}, "must be true"),
            ({"operation": "provider-test", "args": {"benchmarkDriverDiagnostics": True}}, "root debug test"),
            ({"operation": "core-test", "args": {"benchmarkDriverDiagnostics": True}}, "root debug test"),
            ({"operation": "build", "args": {"benchmarkDriverDiagnostics": True}}, "root debug test"),
            ({"operation": "test-artifact", "args": {"filter": "A", "benchmarkDriverDiagnostics": True}}, "root debug test"),
            ({"operation": "test", "args": {"list": True, "benchmarkDriverDiagnostics": True}}, "--list"),
            ({"operation": "test", "args": {"testProduct": "X", "benchmarkDriverDiagnostics": True}}, "--test-product"),
        ]
        for request, text in cases:
            with self.subTest(request=request):
                with mock.patch.object(state, "_schedule_locked"):
                    with self.assertRaisesRegex(conductor.ConductorError, text):
                        state.enqueue(dict(request))
                self.assertEqual(state.jobs, {})
                self.assertEqual(state.queue, [])

    def test_benchmark_driver_diagnostics_is_part_of_request_identity_and_dedup(self) -> None:
        tmp, state = self.make_state()
        self.addCleanup(tmp.cleanup)
        plain = {"operation": "test", "args": {"filter": "AlphaTests"}, "requestKey": "bench-key"}
        diag = {"operation": "test", "args": {"filter": "AlphaTests", "benchmarkDriverDiagnostics": True},
                "requestKey": "bench-key"}
        self.assertNotEqual(state.registry.fingerprint(plain), state.registry.fingerprint(diag))
        with mock.patch.object(state, "_schedule_locked"), mock.patch.object(
            conductor, "admit_test_artifact", return_value=None
        ):
            first = state.enqueue(dict(plain))
            # An active job with the same key but different identity is never reused.
            with self.assertRaisesRegex(conductor.ConductorError, "request-key mismatch"):
                state.enqueue(dict(diag))
            again = state.enqueue(dict(plain))
        self.assertTrue(again["reused"])
        self.assertEqual(again["ticket"], first["ticket"])
        self.assertNotIn("benchmarkDriverDiagnostics", state.jobs[first["ticket"]].args)

    def test_benchmark_harness_pins_conductor_error_strings(self) -> None:
        import swift_build_benchmark as bench

        tmp, state = self.make_state()
        self.addCleanup(tmp.cleanup)
        with self.assertRaises(conductor.ConductorError) as missing:
            state.resolve_job_locked(None, "unknown-key")
        self.assertIn(bench.REQUEST_KEY_NOT_FOUND_TEXT, str(missing.exception))
        job = self.make_job(state, "busy", "test", {}, ["build"], job_state="running")
        state.jobs[job.ticket] = job
        with self.assertRaises(conductor.ConductorError) as refused:
            state.stop(force=False)
        self.assertIn(bench.STOP_REFUSED_ACTIVE_TEXT, str(refused.exception))
        self.assertFalse(state.shutdown_requested)
        self.assertEqual(bench.ARTIFACT_DERIVED_ARG_KEYS, conductor.TEST_ARTIFACT_DERIVED_ARG_KEYS)
        self.assertEqual(bench.DIAG_ROUTE_MARKER, "BENCHMARK_DRIVER_DIAGNOSTIC_SWIFT_ARGS")
        self.assertEqual(bench.DIAG_ARG_KEY, conductor.BENCHMARK_DRIVER_DIAGNOSTICS_ARG)

    def initialize_git_repo(self, root: Path) -> Path:
        source = root / "Tracked.swift"
        subprocess.run(["git", "init", "-q"], cwd=root, check=True)
        source.write_text("let value = 1\n", encoding="utf-8")
        (root / ".gitignore").write_text(
            ".build/\njobs/\nmachine-locks/\nrunning.json\n", encoding="utf-8"
        )
        subprocess.run(["git", "add", "Tracked.swift", ".gitignore"], cwd=root, check=True)
        subprocess.run(
            [
                "git",
                "-c",
                "user.name=Conductor Tests",
                "-c",
                "user.email=conductor-tests@example.invalid",
                "-c",
                "commit.gpgsign=false",
                "commit",
                "-q",
                "-m",
                "fixture",
            ],
            cwd=root,
            check=True,
        )
        return source

    def create_test_artifact(self, root: Path, arch: str = "testarch", contents: bytes = b"test executable") -> Path:
        artifact = root / ".build" / f"{arch}-apple-macosx" / "debug" / "RepoPromptCEPackageTests.xctest"
        executable = artifact / "Contents" / "MacOS" / "RepoPromptCEPackageTests"
        executable.parent.mkdir(parents=True)
        executable.write_bytes(contents)
        return executable

    def create_test_resource_bundle(self, root: Path, arch: str = "testarch") -> Path:
        resource = (
            root
            / ".build"
            / f"{arch}-apple-macosx"
            / "debug"
            / "RepoPromptCE_RepoPromptTests.bundle"
            / "fixture.txt"
        )
        resource.parent.mkdir(parents=True)
        resource.write_text("resource version one\n", encoding="utf-8")
        return resource

    # Step 7 helpers: the daemon evaluates the artifact itself, after slot admission.
    ARTIFACT_TOOLCHAIN = {"swift_version": "Swift test", "arch": "testarch", "config": "debug"}
    PASSING_ARTIFACT_RUN = (
        "print(\"Test Case '-[RepoPromptTests.AlphaTests testOne]' started.\", flush=True); "
        "print(\"Test Case '-[RepoPromptTests.AlphaTests testOne]' passed (0.001 seconds).\", flush=True)"
    )

    def artifact_host(self) -> contextlib.ExitStack:
        stack = contextlib.ExitStack()
        stack.enter_context(
            mock.patch.object(conductor, "artifact_toolchain_snapshot", return_value=dict(self.ARTIFACT_TOOLCHAIN))
        )
        stack.enter_context(mock.patch.object(conductor, "host_artifact_arch", return_value="testarch"))
        return stack

    def mint_artifact_ticket(self, state: conductor.DaemonState) -> dict:
        ticket_job = self.make_job(state, f"built-{uuid.uuid4().hex[:8]}", "test", {}, ["build"])
        with self.artifact_host():
            ticket = conductor.build_ticket_payload(state.paths.repo_root, ticket_job, os.environ.copy())
        self.assertIsNotNone(ticket)
        conductor.write_build_ticket(state.paths.jobs_dir / "build-ticket-root.json", ticket or {})
        return ticket or {}

    def artifact_fixture(self, resource: bool = True) -> tuple[conductor.DaemonState, Path, Path | None]:
        tmp, state = self.make_state()
        self.addCleanup(tmp.cleanup)
        self.initialize_git_repo(state.paths.repo_root)
        executable = self.create_test_artifact(state.paths.repo_root)
        resource_path = self.create_test_resource_bundle(state.paths.repo_root) if resource else None
        if resource_path is not None:
            nested = resource_path.parent / "nested" / "inner.txt"
            nested.parent.mkdir()
            nested.write_text("inner\n", encoding="utf-8")
        self.mint_artifact_ticket(state)
        return state, executable, resource_path

    def run_artifact_job(
        self,
        state: conductor.DaemonState,
        command: list[str],
        *,
        args: dict | None = None,
        timeout: float = 30.0,
        extra: contextlib.ExitStack | None = None,
    ) -> conductor.Job:
        job = self.make_job(
            state,
            f"artifact-{uuid.uuid4().hex[:8]}",
            "test-artifact",
            dict(args or {"filter": "AlphaTests"}),
            ["build"],
            job_state="running",
        )
        state.jobs[job.ticket] = job
        with self.artifact_host(), (extra or contextlib.ExitStack()):
            with (
                mock.patch.object(
                    state.registry,
                    "prepare",
                    return_value=(command, ["build"], state.paths.repo_root, os.environ.copy(), timeout),
                ),
                mock.patch.object(state, "_xctest_watchdog_enabled", return_value=False),
                mock.patch.object(conductor, "machine_lock_dir", return_value=state.paths.repo_root / "machine-locks"),
            ):
                state._run_job(job.ticket)
        return job

    @staticmethod
    def mutate_same_size_preserving_mtime(path: Path) -> None:
        original = path.read_bytes()
        original_stat = path.stat()
        mutated = bytearray(original)
        mutated[0] = (mutated[0] + 1) % 256
        path.write_bytes(bytes(mutated))
        os.utime(path, ns=(original_stat.st_atime_ns, original_stat.st_mtime_ns))

    @staticmethod
    def job_launch_probe(launch: object = None) -> mock.Mock:
        """A Popen stand-in recording only job launches (``start_new_session``);
        snapshot helpers such as git run for real. Without ``launch`` a job launch fails."""
        real_popen = conductor.subprocess.Popen
        launches: list[list[str]] = []

        def popen(argv: object, *args: object, **kwargs: object) -> object:
            if not kwargs.get("start_new_session"):
                return real_popen(argv, *args, **kwargs)
            launches.append(list(argv))  # type: ignore[call-overload]
            if launch is None:
                raise RuntimeError("job process must not be created")
            return launch(argv, *args, **kwargs)  # type: ignore[operator]

        probe = mock.Mock(side_effect=popen)
        probe.launches = launches
        return probe

    def test_parallel_runner_uses_absolute_xcrun_and_explicit_environment(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            logs_dir = root / "logs"
            logs_dir.mkdir()
            suite = parallel_runner.SuiteWork(
                name="FirstModule.ExampleTests",
                methods=("testExample",),
                expected_count=1,
                weight=1.0,
                ledger_runtime_s=1.0,
                deadline_s=10.0,
                serial_tags=(),
                exclusive=False,
            )
            process = mock.Mock()
            process.communicate.return_value = (
                "Executed 1 test, with 0 failures in 0.001 seconds\n",
                None,
            )
            process.returncode = 0
            poisoned = {
                "PATH": "/poisoned/bin",
                "GH_TOKEN": "gh-secret",
                "GITHUB_TOKEN": "github-secret",
                "SOURCE_TOKEN": "source-secret",
                "DYLD_INSERT_LIBRARIES": "/tmp/poison.dylib",
                "REPOPROMPT_CONDUCTOR_JOB_TICKET": "ticket-secret",
                "UNRELATED_METADATA": "metadata",
                "DEVELOPER_DIR": "/Applications/Xcode.app/Contents/Developer",
                "RPCE_RUN_SCALE_TESTS": "1",
            }

            with mock.patch.dict(os.environ, poisoned, clear=True), mock.patch.object(
                parallel_runner.subprocess, "Popen", return_value=process
            ) as popen:
                attempt = parallel_runner.run_attempt(
                    suite,
                    attempt_number=1,
                    worker="w1",
                    tmpdir=root / "tmp",
                    bundle=root / "Tests.xctest",
                    logs_dir=logs_dir,
                    registry=parallel_runner.ProcessRegistry(),
                )

            self.assertEqual(attempt.status, "PASS")
            command = popen.call_args.args[0]
            environment = popen.call_args.kwargs["env"]
            self.assertEqual(command[0], "/usr/bin/xcrun")
            self.assertEqual(environment["PATH"], parallel_runner.RUNTIME_PATH)
            self.assertEqual(environment["TMPDIR"], str(root / "tmp"))
            self.assertEqual(
                environment["DEVELOPER_DIR"],
                "/Applications/Xcode.app/Contents/Developer",
            )
            self.assertEqual(environment["RPCE_RUN_SCALE_TESTS"], "1")
            self.assertEqual(
                set(environment),
                {
                    "PATH",
                    "TMPDIR",
                    "DEVELOPER_DIR",
                    "RPCE_RUN_SCALE_TESTS",
                },
            )

    def test_parallel_runner_census_includes_multiple_modules_and_rejects_bad_test_lines(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            test_list = Path(tmp) / "tests.txt"
            test_list.write_text(
                "[1/1] Planning build\n"
                "FirstModule.FirstSuite/testOne\n"
                "SecondModule.SecondSuite/testTwo\n",
                encoding="utf-8",
            )

            expected = parallel_runner.parse_test_list(test_list)
            work = parallel_runner.build_work_list(
                expected,
                {},
                {},
                parallel_runner.CROSS_PROCESS_UNSAFE_TAGS,
                None,
                (),
            )

            self.assertEqual(
                {suite.name: suite.methods for suite in work},
                {
                    "FirstModule.FirstSuite": ("testOne",),
                    "SecondModule.SecondSuite": ("testTwo",),
                },
            )

            test_list.write_text(
                "FirstModule.FirstSuite/testOne\n"
                "SecondModule.Bad-Suite/testTwo\n",
                encoding="utf-8",
            )
            with self.assertRaisesRegex(
                parallel_runner.RunnerError, "unrecognized test identifier"
            ):
                parallel_runner.parse_test_list(test_list)

    def test_parallel_runner_signals_reap_fake_xcrun_process_group(self) -> None:
        fake_source = """\
#!/usr/bin/env python3
import json
import signal
import subprocess
import sys
from pathlib import Path

ready = Path(sys.argv[-1])
child = subprocess.Popen(
    [sys.executable, "-c", "import time; time.sleep(600)"]
)

def stop(signum, _frame):
    try:
        child.terminate()
    except ProcessLookupError:
        pass
    try:
        child.wait(timeout=2)
    except subprocess.TimeoutExpired:
        child.kill()
        child.wait(timeout=2)
    raise SystemExit(128 + signum)

signal.signal(signal.SIGTERM, stop)
ready.write_text(
    json.dumps({"worker": __import__("os").getpid(), "child": child.pid}),
    encoding="utf-8",
)
child.wait()
"""
        harness_source = """\
import sys
from pathlib import Path

sys.path.insert(0, sys.argv[4])
import parallel_xctest_runner as runner

runner.XCRUN_PATH = Path(sys.argv[1])
suite = runner.SuiteWork(
    name="FakeModule.FakeSuite",
    methods=("testLongRunning",),
    expected_count=1,
    weight=1.0,
    ledger_runtime_s=1.0,
    deadline_s=30.0,
    serial_tags=(),
    exclusive=False,
)
raise SystemExit(
    runner.run_suites(
        [suite],
        workers=1,
        bundle=Path(sys.argv[2]),
        workdir=Path(sys.argv[3]),
        retry_failed=False,
    )
)
"""

        def pid_exists(pid: int) -> bool:
            try:
                os.kill(pid, 0)
            except ProcessLookupError:
                return False
            return True

        for cancellation_signal in (signal.SIGTERM, signal.SIGHUP):
            with self.subTest(signal=signal.Signals(cancellation_signal).name):
                with tempfile.TemporaryDirectory() as tmp:
                    root = Path(tmp)
                    fake_xcrun = root / "fake-xcrun"
                    fake_xcrun.write_text(
                        fake_source.replace(
                            "#!/usr/bin/env python3",
                            f"#!{sys.executable}",
                            1,
                        ),
                        encoding="utf-8",
                    )
                    fake_xcrun.chmod(0o755)
                    ready = root / "ready.json"
                    process = subprocess.Popen(
                        [
                            sys.executable,
                            "-c",
                            harness_source,
                            str(fake_xcrun),
                            str(ready),
                            str(root / "work"),
                            str(SCRIPT_DIR),
                        ],
                        stdout=subprocess.PIPE,
                        stderr=subprocess.STDOUT,
                        text=True,
                    )
                    deadline = time.monotonic() + 5.0
                    payload = None
                    while time.monotonic() < deadline:
                        try:
                            payload = json.loads(ready.read_text(encoding="utf-8"))
                            break
                        except (FileNotFoundError, json.JSONDecodeError):
                            time.sleep(0.01)
                    if payload is None:
                        process.kill()
                        output, _ = process.communicate(timeout=5)
                        self.fail(f"fake xcrun did not become ready:\n{output}")

                    process.send_signal(cancellation_signal)
                    output, _ = process.communicate(timeout=8)
                    self.assertNotEqual(process.returncode, 0, output)

                    for name in ("worker", "child"):
                        pid = int(payload[name])
                        reap_deadline = time.monotonic() + 3.0
                        while pid_exists(pid) and time.monotonic() < reap_deadline:
                            time.sleep(0.01)
                        self.assertFalse(
                            pid_exists(pid),
                            f"{name} pid {pid} survived cancellation:\n{output}",
                        )

    def write_parallel_candidate(
        self,
        state: conductor.DaemonState,
        job: conductor.Job,
        run_id: str,
        toolchain: dict[str, str],
        filter_value: str | None = None,
    ) -> tuple[Path, dict]:
        snapshot = conductor.source_snapshot(state.paths.repo_root)
        self.assertIsNotNone(snapshot)
        artifact_path = conductor.discover_root_test_artifact(
            state.paths.repo_root, toolchain["arch"]
        )
        self.assertIsNotNone(artifact_path)
        candidate_path = (
            state.paths.jobs_dir
            / f"parallel-xctest-{run_id}-candidate.json"
        )
        candidate = {
            "schema_version": conductor.PARALLEL_TEST_CANDIDATE_SCHEMA_VERSION,
            "fingerprint_version": conductor.ARTIFACT_FINGERPRINT_VERSION,
            "kind": conductor.PARALLEL_TEST_CANDIDATE_KIND,
            "run_id": run_id,
            "ticket_id": job.ticket,
            "filter": filter_value,
            "evidence_scope": conductor.parallel_test_evidence_scope(filter_value),
            "source_snapshot": snapshot,
            "env_gates": conductor.artifact_env_gates(os.environ),
            "worker_runtime_gates": conductor.parallel_xctest_runtime_gates(os.environ),
            "toolchain": toolchain,
            "artifact_path": str((artifact_path or Path()).resolve()),
            "artifact_fingerprint": conductor.test_artifact_fingerprint(
                artifact_path or Path()
            ),
            "build_duration_seconds": 1.25,
            "runner_started_at": conductor.now(),
        }
        conductor.write_build_ticket(candidate_path, candidate)
        return candidate_path, candidate

    def test_source_snapshot_hashes_untracked_file_contents(self) -> None:
        tmp, state = self.make_state()
        self.addCleanup(tmp.cleanup)
        self.initialize_git_repo(state.paths.repo_root)
        untracked = state.paths.repo_root / "Sources" / "New.swift"
        untracked.parent.mkdir(parents=True)
        untracked.write_text("let value = 1\n", encoding="utf-8")

        first = conductor.source_snapshot(state.paths.repo_root)
        untracked.write_text("let value = 2\n", encoding="utf-8")
        second = conductor.source_snapshot(state.paths.repo_root)

        self.assertIsNotNone(first)
        self.assertIsNotNone(second)
        self.assertEqual(first["porcelain_sha256"], second["porcelain_sha256"])
        self.assertNotEqual(
            first["dirty_file_sha256"]["Sources/New.swift"],
            second["dirty_file_sha256"]["Sources/New.swift"],
        )

    def test_source_snapshot_changes_when_dirty_symlink_is_retargeted(self) -> None:
        tmp, state = self.make_state()
        self.addCleanup(tmp.cleanup)
        self.initialize_git_repo(state.paths.repo_root)
        link = state.paths.repo_root / "Sources" / "Current.swift"
        link.parent.mkdir(parents=True)
        link.symlink_to("First.swift")

        first = conductor.source_snapshot(state.paths.repo_root)
        link.unlink()
        link.symlink_to("Second.swift")
        second = conductor.source_snapshot(state.paths.repo_root)

        self.assertIsNotNone(first)
        self.assertIsNotNone(second)
        self.assertEqual(first["porcelain_sha256"], second["porcelain_sha256"])
        self.assertNotEqual(
            first["dirty_file_sha256"]["Sources/Current.swift"],
            second["dirty_file_sha256"]["Sources/Current.swift"],
        )

    def test_successful_root_test_job_records_latest_build_ticket(self) -> None:
        tmp, state = self.make_state()
        self.addCleanup(tmp.cleanup)
        self.initialize_git_repo(state.paths.repo_root)
        self.create_test_artifact(state.paths.repo_root)
        job = self.make_job(state, "root-test-ticket", "test", {}, ["build"], job_state="running")
        state.jobs[job.ticket] = job
        command = [sys.executable, "-u", "-c", "print('root tests passed', flush=True)"]

        with (
            mock.patch.object(
                state.registry,
                "prepare",
                return_value=(command, ["build"], state.paths.repo_root, os.environ.copy(), 5.0),
            ),
            mock.patch.object(conductor, "operation_requires_global_heavy_slot", return_value=False),
            mock.patch.object(state, "_xctest_watchdog_enabled", return_value=False),
            mock.patch.object(
                conductor,
                "artifact_toolchain_snapshot",
                return_value={"swift_version": "Swift test", "arch": "testarch", "config": "debug"},
            ),
        ):
            state._run_job(job.ticket)

        ticket_path = state.paths.jobs_dir / "build-ticket-root.json"
        self.assertEqual(job.state, "completed", job.result_summary)
        self.assertTrue(ticket_path.is_file())
        ticket = json.loads(ticket_path.read_text(encoding="utf-8"))
        self.assertEqual(ticket["ticket_id"], job.ticket)
        self.assertEqual(ticket["source_snapshot"]["dirty_file_sha256"], {})
        self.assertEqual(ticket["env_gates"]["REPOPROMPT_ENABLE_SENTRY"], None)
        self.assertEqual(ticket["toolchain"]["config"], "debug")
        self.assertEqual(ticket["artifact_fingerprint"]["size"], len(b"test executable"))
        self.assertIn("closure_manifest_sha256", ticket["artifact_fingerprint"])
        self.assertEqual(ticket["artifact_fingerprint"]["closure_file_count"], 0)
        # Step 8: root schema 2 with top-level fingerprint v2; six nested keys unchanged.
        self.assertEqual((ticket["schema_version"], ticket["fingerprint_version"]), (2, 2))
        self.assertEqual(len(ticket["artifact_fingerprint"]), 6)

    def test_root_test_withholds_ticket_when_source_changes_during_successful_run(self) -> None:
        tmp, state = self.make_state()
        self.addCleanup(tmp.cleanup)
        source = self.initialize_git_repo(state.paths.repo_root)
        self.create_test_artifact(state.paths.repo_root)
        ticket_path = state.paths.jobs_dir / "build-ticket-root.json"
        ticket_path.write_text('{"ticket_id":"old"}\n', encoding="utf-8")
        job = self.make_job(state, "source-race", "test", {}, ["build"], job_state="running")
        state.jobs[job.ticket] = job
        command = [
            sys.executable,
            "-u",
            "-c",
            "from pathlib import Path; import sys; Path(sys.argv[1]).write_text('let value = 2\\n')",
            str(source),
        ]

        with (
            mock.patch.object(
                state.registry,
                "prepare",
                return_value=(command, ["build"], state.paths.repo_root, os.environ.copy(), 5.0),
            ),
            mock.patch.object(conductor, "operation_requires_global_heavy_slot", return_value=False),
            mock.patch.object(state, "_xctest_watchdog_enabled", return_value=False),
            mock.patch.object(
                conductor,
                "artifact_toolchain_snapshot",
                return_value={"swift_version": "Swift test", "arch": "testarch", "config": "debug"},
            ),
        ):
            state._run_job(job.ticket)

        self.assertEqual(job.state, "completed", job.result_summary)
        self.assertFalse(ticket_path.exists())
        self.assertIn("ticket withheld: source changed during run", "".join(job.tail))

    def test_benchmark_driver_diagnostics_test_never_mints_the_root_ticket(self) -> None:
        tmp, state = self.make_state()
        self.addCleanup(tmp.cleanup)
        self.initialize_git_repo(state.paths.repo_root)
        self.create_test_artifact(state.paths.repo_root)
        ticket_path = state.paths.jobs_dir / "build-ticket-root.json"
        ticket_path.write_text('{"ticket_id":"old"}\n', encoding="utf-8")
        job = self.make_job(
            state, "driver-diag", "test", {"benchmarkDriverDiagnostics": True}, ["build"],
            job_state="running",
        )
        state.jobs[job.ticket] = job
        command = [sys.executable, "-u", "-c", "pass"]

        with (
            mock.patch.object(
                state.registry,
                "prepare",
                return_value=(command, ["build"], state.paths.repo_root, os.environ.copy(), 5.0),
            ),
            mock.patch.object(conductor, "operation_requires_global_heavy_slot", return_value=False),
            mock.patch.object(state, "_xctest_watchdog_enabled", return_value=False),
            mock.patch.object(
                conductor,
                "artifact_toolchain_snapshot",
                return_value={"swift_version": "Swift test", "arch": "testarch", "config": "debug"},
            ),
        ):
            state._run_job(job.ticket)

        self.assertEqual(job.state, "completed", job.result_summary)
        # The prior ticket is invalidated at start and no new ticket is minted.
        self.assertFalse(ticket_path.exists())
        self.assertIn("ticket withheld: benchmark driver diagnostics build", "".join(job.tail))

    def test_failed_root_test_invalidates_prior_build_ticket_at_start(self) -> None:
        tmp, state = self.make_state()
        self.addCleanup(tmp.cleanup)
        self.initialize_git_repo(state.paths.repo_root)
        ticket_path = state.paths.jobs_dir / "build-ticket-root.json"
        ticket_path.write_text('{"ticket_id":"old"}\n', encoding="utf-8")
        job = self.make_job(state, "failed-root", "test", {}, ["build"], job_state="running")
        state.jobs[job.ticket] = job
        command = [sys.executable, "-u", "-c", "raise SystemExit(1)"]

        with (
            mock.patch.object(
                state.registry,
                "prepare",
                return_value=(command, ["build"], state.paths.repo_root, os.environ.copy(), 5.0),
            ),
            mock.patch.object(conductor, "operation_requires_global_heavy_slot", return_value=False),
            mock.patch.object(state, "_xctest_watchdog_enabled", return_value=False),
        ):
            state._run_job(job.ticket)

        self.assertEqual(job.state, "failed")
        self.assertFalse(ticket_path.exists())

    def test_swift_build_invalidates_prior_build_ticket_at_start(self) -> None:
        tmp, state = self.make_state()
        self.addCleanup(tmp.cleanup)
        ticket_path = state.paths.jobs_dir / "build-ticket-root.json"
        ticket_path.write_text('{"ticket_id":"old"}\n', encoding="utf-8")
        job = self.make_job(state, "swift-build", "swift-build", {"product": "RepoPrompt"}, ["build"], job_state="running")
        state.jobs[job.ticket] = job
        command = [sys.executable, "-u", "-c", "raise SystemExit(1)"]

        with (
            mock.patch.object(
                state.registry,
                "prepare",
                return_value=(command, ["build"], state.paths.repo_root, os.environ.copy(), 5.0),
            ),
            mock.patch.object(conductor, "operation_requires_global_heavy_slot", return_value=False),
            mock.patch.object(state, "_xctest_watchdog_enabled", return_value=False),
        ):
            state._run_job(job.ticket)

        self.assertEqual(job.state, "failed")
        self.assertFalse(ticket_path.exists())

    def test_ineligible_swift_child_drops_inherited_job_ticket(self) -> None:
        tmp, state = self.make_state()
        self.addCleanup(tmp.cleanup)
        observed = state.paths.repo_root / "observed-ticket.txt"
        swift = state.paths.repo_root / "swift"
        swift.write_text(
            "#!/usr/bin/env python3\n"
            "import os, sys\n"
            "from pathlib import Path\n"
            "Path(sys.argv[1]).write_text(os.environ.get('REPOPROMPT_CONDUCTOR_JOB_TICKET', '<missing>'))\n",
            encoding="utf-8",
        )
        swift.chmod(0o755)
        inherited_env = os.environ.copy()
        inherited_env["REPOPROMPT_CONDUCTOR_JOB_TICKET"] = "inherited-daemon-value"
        job = self.make_job(state, "env-pop", "core-test", {}, ["build"], job_state="running")
        state.jobs[job.ticket] = job

        with (
            mock.patch.object(
                state.registry,
                "prepare",
                return_value=([str(swift), str(observed)], ["build"], state.paths.repo_root, inherited_env, 5.0),
            ),
            mock.patch.object(conductor, "operation_requires_global_heavy_slot", return_value=False),
            mock.patch.object(state, "_xctest_watchdog_enabled", return_value=False),
        ):
            state._run_job(job.ticket)

        self.assertEqual(job.state, "completed", job.result_summary)
        self.assertEqual(observed.read_text(encoding="utf-8"), "<missing>")

    def test_test_artifact_refuses_without_ticket_with_exit_65(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / "repo"
            scripts = root / "Scripts"
            scripts.mkdir(parents=True)
            shutil.copy2(Path(conductor.__file__), scripts / "conductor.py")
            shutil.copy2(SCRIPT_DIR / "debug_app_process.py", scripts / "debug_app_process.py")
            shutil.copy2(SCRIPT_DIR / "conductor_output.py", scripts / "conductor_output.py")
            ledger = scripts / "Fixtures" / "test-suite-contract-ledger.tsv"
            ledger.parent.mkdir(parents=True)
            ledger.write_text(
                self.LEDGER_HEADER
                + "root/RepoPromptTests.SyntheticTests/testMissingArtifact\troot\t"
                "RepoPromptTests.SyntheticTests\ttestMissingArtifact\n",
                encoding="utf-8",
            )
            env = os.environ.copy()
            env["REPOPROMPT_DEV_DAEMON_STATE_DIR"] = str(Path(tmp) / "state")
            completed = subprocess.run(
                [
                    sys.executable,
                    str(scripts / "conductor.py"),
                    "test-artifact",
                    "--filter",
                    "RepoPromptTests.SyntheticTests/testMissingArtifact",
                ],
                text=True,
                capture_output=True,
                env=env,
                timeout=2.0,
            )

        self.assertEqual(completed.returncode, 65, completed.stdout + completed.stderr)
        self.assertIn("run `make dev-test` first", completed.stderr)

    def test_test_artifact_resource_bundle_swap_is_unavailable(self) -> None:
        tmp, state = self.make_state()
        self.addCleanup(tmp.cleanup)
        self.initialize_git_repo(state.paths.repo_root)
        self.create_test_artifact(state.paths.repo_root)
        resource = self.create_test_resource_bundle(state.paths.repo_root)
        toolchain = {"swift_version": "Swift test", "arch": "testarch", "config": "debug"}
        env = os.environ.copy()
        ticket_job = self.make_job(state, "built", "test", {}, ["build"])

        with mock.patch.object(conductor, "artifact_toolchain_snapshot", return_value=toolchain):
            ticket = conductor.build_ticket_payload(state.paths.repo_root, ticket_job, env)
            self.assertEqual((ticket or {})["artifact_fingerprint"]["closure_file_count"], 1)
            conductor.write_build_ticket(state.paths.jobs_dir / "build-ticket-root.json", ticket or {})
            replacement = resource.with_suffix(".replacement")
            replacement.write_text("resource version two\n", encoding="utf-8")
            os.replace(replacement, resource)
            with self.assertRaisesRegex(conductor.ArtifactUnavailableError, "artifact closure"):
                conductor.evaluate_test_artifact(state.paths.repo_root, state.paths.jobs_dir, env)

    def test_test_artifact_same_size_mtime_preserving_resource_swap_is_unavailable(self) -> None:
        tmp, state = self.make_state()
        self.addCleanup(tmp.cleanup)
        self.initialize_git_repo(state.paths.repo_root)
        self.create_test_artifact(state.paths.repo_root)
        resource = self.create_test_resource_bundle(state.paths.repo_root)
        toolchain = {"swift_version": "Swift test", "arch": "testarch", "config": "debug"}
        env = os.environ.copy()
        ticket_job = self.make_job(state, "built-mtime", "test", {}, ["build"])

        with mock.patch.object(conductor, "artifact_toolchain_snapshot", return_value=toolchain):
            ticket = conductor.build_ticket_payload(state.paths.repo_root, ticket_job, env)
            conductor.write_build_ticket(state.paths.jobs_dir / "build-ticket-root.json", ticket or {})
            original = resource.read_bytes()
            original_stat = resource.stat()
            mutated = bytearray(original)
            mutated[0] = (mutated[0] + 1) % 256
            self.assertEqual(len(mutated), len(original))
            resource.write_bytes(bytes(mutated))
            os.utime(resource, ns=(original_stat.st_atime_ns, original_stat.st_mtime_ns))
            self.assertEqual(resource.stat().st_size, original_stat.st_size)
            self.assertEqual(resource.stat().st_mtime_ns, original_stat.st_mtime_ns)
            with self.assertRaisesRegex(conductor.ArtifactUnavailableError, "artifact closure"):
                conductor.evaluate_test_artifact(state.paths.repo_root, state.paths.jobs_dir, env)

    def hooked_fingerprint(self, artifact_path: Path, hook: object, observations: object) -> dict:
        """Fingerprint with ``hook(n)`` run on the n-th digest update (after that chunk was read)."""
        real_hashlib = conductor.hashlib
        updates = [0]

        class Digest:
            def __init__(self, data: bytes = b"") -> None:
                self.real = real_hashlib.sha256(data)

            def update(self, chunk: bytes) -> None:
                updates[0] += 1
                hook(updates[0])  # type: ignore[operator]
                self.real.update(chunk)

            def hexdigest(self) -> str:
                return self.real.hexdigest()

        fake = mock.Mock(wraps=real_hashlib)
        fake.sha256 = Digest
        with mock.patch.object(conductor, "hashlib", fake):
            return conductor.test_artifact_fingerprint(artifact_path, observations=observations)

    def test_fingerprint_observations_reject_mutation_during_hashing(self) -> None:
        # Digest update 1 is the executable, 2 the bundle's fixture.txt, 3 nested/inner.txt.
        def during_read(executable: Path, resource: Path) -> None:
            self.mutate_same_size_preserving_mtime(resource)

        def hashed_executable_changed_later(executable: Path, resource: Path) -> None:
            self.mutate_same_size_preserving_mtime(executable)

        def path_replaced_with_open_descriptor(executable: Path, resource: Path) -> None:
            replacement = resource.with_name("replacement")
            shutil.copy2(resource, replacement)
            os.replace(replacement, resource)

        def sibling_bundle_added(executable: Path, resource: Path) -> None:
            (resource.parent.parent / "Late_Resources.bundle").mkdir()

        def member_added_after_enumeration(executable: Path, resource: Path) -> None:
            (resource.parent / "late.txt").write_text("late\n", encoding="utf-8")

        def nested_member_added_after_enumeration(executable: Path, resource: Path) -> None:
            (resource.parent / "nested" / "late.txt").write_text("late\n", encoding="utf-8")

        cases = (
            (during_read, 2, "fixture.txt"),
            (hashed_executable_changed_later, 2, "RepoPromptCEPackageTests"),
            (path_replaced_with_open_descriptor, 2, "fixture.txt"),
            (sibling_bundle_added, 2, "debug"),
            (member_added_after_enumeration, 3, "RepoPromptCE_RepoPromptTests.bundle"),
            (nested_member_added_after_enumeration, 3, "nested"),
        )
        for mutate, at_update, named in cases:
            with self.subTest(mutation=mutate.__name__):
                tmp, state = self.make_state()
                self.addCleanup(tmp.cleanup)
                executable = self.create_test_artifact(state.paths.repo_root)
                resource = self.create_test_resource_bundle(state.paths.repo_root)
                nested = resource.parent / "nested" / "inner.txt"
                nested.parent.mkdir()
                nested.write_text("inner\n", encoding="utf-8")
                artifact_path = executable.parents[2]
                baseline = conductor.test_artifact_fingerprint(artifact_path)

                def hook(update: int, m=mutate, n=at_update, e=executable, r=resource) -> None:
                    if update == n:
                        m(e, r)

                with self.assertRaisesRegex(conductor.ArtifactUnavailableError, "while it was being fingerprinted") as raised:
                    self.hooked_fingerprint(artifact_path, hook, conductor.ArtifactObservations())
                self.assertIn(named, str(raised.exception))
                if mutate is path_replaced_with_open_descriptor:
                    # Same bytes and mtime: only the identity fence can see the swap.
                    self.assertEqual(conductor.test_artifact_fingerprint(artifact_path), baseline)

    def test_fingerprint_observations_keep_payload_and_symlink_exclusions(self) -> None:
        tmp, state = self.make_state()
        self.addCleanup(tmp.cleanup)
        executable = self.create_test_artifact(state.paths.repo_root)
        resource = self.create_test_resource_bundle(state.paths.repo_root)
        nested = resource.parent / "nested" / "inner.txt"
        nested.parent.mkdir()
        nested.write_text("inner\n", encoding="utf-8")
        (resource.parent / "link.txt").symlink_to(resource)
        (resource.parent / "linkdir").symlink_to(nested.parent, target_is_directory=True)
        dsym = executable.with_name(executable.name + ".dSYM") / "Contents" / "Info.plist"
        dsym.parent.mkdir(parents=True)
        dsym.write_text("<plist/>\n", encoding="utf-8")
        artifact_path = executable.parents[2]
        observations = conductor.ArtifactObservations()

        plain = conductor.test_artifact_fingerprint(artifact_path)
        observed = conductor.test_artifact_fingerprint(artifact_path, observations=observations)

        self.assertEqual(observed, plain)
        self.assertEqual(
            set(plain),
            {"executable_path", "size", "mtime_ns", "sha256", "closure_manifest_sha256", "closure_file_count"},
        )
        # fixture.txt and nested/inner.txt; Step 8 prunes the executable's own adjacent dSYM.
        self.assertEqual(plain["closure_file_count"], 2)
        self.assertGreater(len(observations), 2)
        observations.verify("in test")

    # Step 8 (fingerprint v2) helpers and tests.
    LEGACY_V2_MESSAGE = "ticket predates fingerprint v2 — re-mint with a source-validating run"

    def sink_fingerprint(
        self, artifact_path: Path, observations: object = None
    ) -> tuple[dict, dict]:
        """Fingerprint through the production sink; returns (fingerprint, content counters)."""
        events: list[tuple[str, dict]] = []
        fingerprint = conductor.test_artifact_fingerprint(
            artifact_path,
            sink=lambda name, _duration, counters: events.append((name, dict(counters or {}))),
            observations=observations,  # type: ignore[arg-type]
        )
        self.assertEqual([name for name, _ in events], ["artifact_fingerprint"])
        return fingerprint, events[0][1]

    @staticmethod
    def regular_file_bytes(root: Path) -> tuple[int, int]:
        """Independent no-follow enumeration: (content bytes, files) of regular files."""
        total = files = 0
        for directory, _names, file_names in os.walk(root, followlinks=False):
            for name in file_names:
                metadata = os.lstat(Path(directory) / name)
                if stat.S_ISREG(metadata.st_mode):
                    total += metadata.st_size
                    files += 1
        return total, files

    def fingerprint_fixture(self) -> tuple[conductor.DaemonState, Path, Path, Path]:
        tmp, state = self.make_state()
        self.addCleanup(tmp.cleanup)
        executable = self.create_test_artifact(state.paths.repo_root)
        resource = self.create_test_resource_bundle(state.paths.repo_root)
        return state, executable, resource, executable.parents[2]

    @staticmethod
    def write_dsym(directory: Path, name: str, payload: bytes) -> Path:
        dwarf = directory / name / "Contents" / "Resources" / "DWARF" / name.removesuffix(".dSYM")
        dwarf.parent.mkdir(parents=True, exist_ok=True)
        dwarf.write_bytes(payload)
        (directory / name / "Contents" / "Info.plist").write_text("<plist/>\n", encoding="utf-8")
        return dwarf

    def test_fingerprint_v2_excludes_only_the_exact_real_adjacent_dsym(self) -> None:
        _state, executable, _resource, artifact_path = self.fingerprint_fixture()
        baseline, baseline_counters = self.sink_fingerprint(artifact_path)
        baseline_observations = conductor.ArtifactObservations()
        conductor.test_artifact_fingerprint(artifact_path, observations=baseline_observations)
        dsym = executable.with_name(executable.name + ".dSYM")

        def create() -> None:
            self.write_dsym(executable.parent, dsym.name, b"dwarf one " * 4096)

        def regenerate() -> None:
            self.write_dsym(executable.parent, dsym.name, b"regenerated dwarf, longer " * 8192)
            relocations = dsym / "Contents" / "Resources" / "Relocations" / "aarch64" / "x.yml"
            relocations.parent.mkdir(parents=True)
            relocations.write_text("relocations\n", encoding="utf-8")

        def delete() -> None:
            shutil.rmtree(dsym)

        for step in (create, regenerate, delete):
            with self.subTest(step=step.__name__):
                step()
                plain, counters = self.sink_fingerprint(artifact_path)
                observations = conductor.ArtifactObservations()
                observed = conductor.test_artifact_fingerprint(artifact_path, observations=observations)
                self.assertEqual(plain, baseline)
                self.assertEqual(observed, baseline)
                # Same content bytes and files: nothing beneath the dSYM is read or observed.
                self.assertEqual(counters, baseline_counters)
                self.assertEqual(len(observations), len(baseline_observations))
                observations.verify("in test")

    def test_fingerprint_v2_content_bytes_drop_by_exactly_the_excluded_subtree(self) -> None:
        _state, executable, resource, artifact_path = self.fingerprint_fixture()
        dsym = executable.with_name(executable.name + ".dSYM")
        self.write_dsym(executable.parent, dsym.name, b"d" * 300_001)
        (dsym / "Contents" / "Resources" / "empty").mkdir()
        (dsym / "Contents" / "link.txt").symlink_to(resource)
        other = self.write_dsym(resource.parent, "Other.dSYM", b"o" * 70_003)

        _fingerprint, counters = self.sink_fingerprint(artifact_path)

        roots = [artifact_path, resource.parent]
        inclusive_bytes = sum(self.regular_file_bytes(root)[0] for root in roots)
        inclusive_files = sum(self.regular_file_bytes(root)[1] for root in roots)
        excluded_bytes, excluded_files = self.regular_file_bytes(dsym)
        self.assertEqual(excluded_files, 2)
        self.assertEqual(inclusive_bytes - counters["bytesHashed"], excluded_bytes)
        self.assertEqual(inclusive_files - counters["filesHashed"], excluded_files)
        # The other dSYM's content is still read.
        self.assertGreaterEqual(counters["bytesHashed"], other.stat().st_size + executable.stat().st_size)

    def test_fingerprint_v2_keeps_other_dsyms_regular_file_and_symlink_rules(self) -> None:
        def adjacent(executable: Path) -> str:
            return executable.name + ".dSYM"

        included = {
            "bundle-dsym": lambda e, r: self.write_dsym(r.parent, "Other.dSYM", b"other\n"),
            "other-dsym-next-to-executable": lambda e, r: self.write_dsym(e.parent, "Helper.dSYM", b"helper\n"),
            "same-name-dsym-not-adjacent": lambda e, r: self.write_dsym(e.parents[1], adjacent(e), b"moved\n"),
            "same-name-dsym-in-bundle": lambda e, r: self.write_dsym(r.parent, adjacent(e), b"bundle\n"),
            "regular-file-at-exact-name": lambda e, r: (
                e.with_name(adjacent(e)).write_text("plain file\n", encoding="utf-8"),
                e.with_name(adjacent(e)),
            )[1],
        }
        for name, create in included.items():
            with self.subTest(included=name):
                _state, executable, resource, artifact_path = self.fingerprint_fixture()
                before = conductor.test_artifact_fingerprint(artifact_path)
                member = create(executable, resource)
                after = conductor.test_artifact_fingerprint(artifact_path)
                self.assertGreater(after["closure_file_count"], before["closure_file_count"])
                self.assertNotEqual(after["closure_manifest_sha256"], before["closure_manifest_sha256"])
                self.mutate_same_size_preserving_mtime(member)
                mutated = conductor.test_artifact_fingerprint(artifact_path)
                self.assertNotEqual(mutated["closure_manifest_sha256"], after["closure_manifest_sha256"])
                for key in ("executable_path", "size", "mtime_ns", "sha256"):
                    self.assertEqual(mutated[key], before[key])

        for name in ("symlink-directory-at-exact-name", "symlink-file-at-exact-name"):
            with self.subTest(excluded=name):
                state, executable, resource, artifact_path = self.fingerprint_fixture()
                baseline = conductor.test_artifact_fingerprint(artifact_path)
                outside = state.paths.repo_root / "outside"
                target = self.write_dsym(outside, adjacent(executable), b"outside dwarf\n")
                link = executable.with_name(adjacent(executable))
                if name == "symlink-directory-at-exact-name":
                    link.symlink_to(outside / adjacent(executable), target_is_directory=True)
                else:
                    link.symlink_to(target)
                self.assertEqual(conductor.test_artifact_fingerprint(artifact_path), baseline)
                self.mutate_same_size_preserving_mtime(target)
                observations = conductor.ArtifactObservations()
                self.assertEqual(
                    conductor.test_artifact_fingerprint(artifact_path, observations=observations), baseline
                )

    def test_fingerprint_v2_keeps_executable_and_retained_file_sensitivity(self) -> None:
        def executable_bytes(e: Path, r: Path) -> None:
            self.mutate_same_size_preserving_mtime(e)

        def renamed(e: Path, r: Path) -> None:
            r.rename(r.with_name("renamed.txt"))

        def resized(e: Path, r: Path) -> None:
            r.write_text("resource version one, longer\n", encoding="utf-8")

        def touched(e: Path, r: Path) -> None:
            metadata = r.stat()
            os.utime(r, ns=(metadata.st_atime_ns, metadata.st_mtime_ns + 1_000_000_000))

        def same_size_content(e: Path, r: Path) -> None:
            self.mutate_same_size_preserving_mtime(r)

        expected = {
            executable_bytes: ("sha256",),
            renamed: ("closure_manifest_sha256",),
            resized: ("closure_manifest_sha256",),
            touched: ("closure_manifest_sha256",),
            same_size_content: ("closure_manifest_sha256",),
        }
        for mutate, changed in expected.items():
            with self.subTest(mutation=mutate.__name__):
                _state, executable, resource, artifact_path = self.fingerprint_fixture()
                self.write_dsym(executable.parent, executable.name + ".dSYM", b"dwarf\n")
                before = conductor.test_artifact_fingerprint(artifact_path)
                mutate(executable, resource)
                after = conductor.test_artifact_fingerprint(artifact_path)
                self.assertEqual(
                    {key for key in before if before[key] != after[key]}, set(changed)
                )

    def test_fingerprint_v2_closure_digest_is_domain_separated(self) -> None:
        prefix = b"rpce-runtime-closure-v2\0"
        self.assertEqual(conductor.ARTIFACT_CLOSURE_DIGEST_PREFIX, prefix)
        tmp, state = self.make_state()
        self.addCleanup(tmp.cleanup)
        executable = self.create_test_artifact(state.paths.repo_root)
        self.write_dsym(executable.parent, executable.name + ".dSYM", b"dwarf\n")
        # Empty manifest (the only member is the excluded dSYM): the prefix still applies.
        empty = conductor.test_artifact_fingerprint(executable.parents[2])
        self.assertEqual(empty["closure_file_count"], 0)
        self.assertEqual(empty["closure_manifest_sha256"], hashlib.sha256(prefix).hexdigest())
        self.assertNotEqual(empty["closure_manifest_sha256"], hashlib.sha256(b"").hexdigest())

        resource = self.create_test_resource_bundle(state.paths.repo_root)
        metadata = resource.stat()
        manifest = (
            f"RepoPromptCE_RepoPromptTests.bundle/fixture.txt\0{metadata.st_size}\0{metadata.st_mtime_ns}\0"
            f"{hashlib.sha256(resource.read_bytes()).hexdigest()}\n"
        ).encode("utf-8")
        current = conductor.test_artifact_fingerprint(executable.parents[2])
        self.assertEqual(current["closure_file_count"], 1)
        self.assertEqual(current["closure_manifest_sha256"], hashlib.sha256(prefix + manifest).hexdigest())
        self.assertNotEqual(current["closure_manifest_sha256"], hashlib.sha256(manifest).hexdigest())
        self.assertEqual(current["sha256"], hashlib.sha256(b"test executable").hexdigest())

    @staticmethod
    def with_envelope(document: dict, changes: dict) -> dict:
        updated = dict(document)
        for key, value in changes.items():
            if value is Ellipsis:
                updated.pop(key, None)
            else:
                updated[key] = value
        return updated

    S, F = "schema_version", "fingerprint_version"
    ROOT_ENVELOPE_CASES = {
        "unversioned-legacy": ({S: ..., F: ...}, LEGACY_V2_MESSAGE),
        "schema-1": ({S: 1, F: ...}, LEGACY_V2_MESSAGE),
        "schema-1-fingerprint-1": ({S: 1, F: 1}, LEGACY_V2_MESSAGE),
        "fingerprint-1-only": ({S: ..., F: 1}, LEGACY_V2_MESSAGE),
        "bool-schema": ({S: True}, "schema_version is malformed"),
        "float-fingerprint": ({F: 2.0}, "fingerprint_version is malformed"),
        "string-schema": ({S: "2"}, "schema_version is malformed"),
        "null-fingerprint": ({F: None}, "fingerprint_version is malformed"),
        "zero-schema": ({S: 0}, "schema_version is malformed"),
        "negative-fingerprint": ({F: -2}, "fingerprint_version is malformed"),
        "future-schema": ({S: 3}, "version is unsupported"),
        "future-fingerprint": ({F: 3}, "version is unsupported"),
        "current-schema-missing-fingerprint": ({F: ...}, "version combination is invalid"),
        "legacy-schema-with-fingerprint-2": ({S: 1}, "version combination is invalid"),
        "unversioned-with-fingerprint-2": ({S: ...}, "version combination is invalid"),
    }
    CANDIDATE_ENVELOPE_CASES = {
        "step7-schema-2": ({S: 2, F: ...}, LEGACY_V2_MESSAGE),
        "schema-1": ({S: 1, F: ...}, LEGACY_V2_MESSAGE),
        "schema-2-fingerprint-1": ({S: 2, F: 1}, LEGACY_V2_MESSAGE),
        "missing-schema": ({S: ...}, "version combination is invalid"),
        "missing-both": ({S: ..., F: ...}, "version combination is invalid"),
        "current-schema-missing-fingerprint": ({F: ...}, "version combination is invalid"),
        "schema-2-fingerprint-2": ({S: 2}, "version combination is invalid"),
        "future-schema": ({S: 4}, "version is unsupported"),
        "bool-fingerprint": ({F: True}, "fingerprint_version is malformed"),
        "string-schema": ({S: "3"}, "schema_version is malformed"),
    }

    def test_root_ticket_versions_are_judged_before_any_artifact_work(self) -> None:
        state, _executable, _resource = self.artifact_fixture()
        ticket_path = state.paths.jobs_dir / "build-ticket-root.json"
        ticket = json.loads(ticket_path.read_text(encoding="utf-8"))
        self.assertEqual((ticket["schema_version"], ticket["fingerprint_version"]), (2, 2))
        self.assertEqual(len(ticket["artifact_fingerprint"]), 6)
        forbidden = AssertionError("version rejection must precede hashing, snapshots and toolchain probes")
        guards = contextlib.ExitStack()
        guards.enter_context(mock.patch.object(conductor, "host_artifact_arch", return_value="testarch"))
        for name in ("_hash_artifact_file", "test_artifact_fingerprint", "source_snapshot", "artifact_toolchain_snapshot"):
            guards.enter_context(mock.patch.object(conductor, name, side_effect=forbidden))
        with guards:
            conductor.admit_test_artifact(state.paths.repo_root, state.paths.jobs_dir)
            for name, (changes, message) in self.ROOT_ENVELOPE_CASES.items():
                with self.subTest(envelope=name):
                    ticket_path.write_text(json.dumps(self.with_envelope(ticket, changes)), encoding="utf-8")
                    for check in (
                        lambda: conductor.admit_test_artifact(state.paths.repo_root, state.paths.jobs_dir),
                        lambda: conductor.evaluate_test_artifact(
                            state.paths.repo_root, state.paths.jobs_dir, os.environ.copy()
                        ),
                    ):
                        with self.assertRaises(conductor.ArtifactUnavailableError) as raised:
                            check()
                        self.assertIn(message, str(raised.exception))
                        self.assertIn("run `make dev-test` first", str(raised.exception))

    def test_legacy_root_ticket_fails_65_before_hashing_or_launch(self) -> None:
        state, _executable, _resource = self.artifact_fixture()
        ticket_path = state.paths.jobs_dir / "build-ticket-root.json"
        ticket = json.loads(ticket_path.read_text(encoding="utf-8"))
        legacy = self.with_envelope(ticket, {self.S: ..., self.F: ...})
        ticket_path.write_text(json.dumps(legacy), encoding="utf-8")
        real_hash = conductor._hash_artifact_file
        hashed: list[Path] = []

        def counted_hash(path: Path, *args: object, **kwargs: object) -> object:
            hashed.append(path)
            return real_hash(path, *args, **kwargs)

        # Enqueue admission rejects it (cheaply) ...
        with (
            self.artifact_host(),
            mock.patch.object(conductor, "_hash_artifact_file", side_effect=counted_hash),
            mock.patch.object(state, "_schedule_locked"),
        ):
            with self.assertRaisesRegex(conductor.ArtifactUnavailableError, self.LEGACY_V2_MESSAGE):
                state.enqueue({"operation": "test-artifact", "args": {"filter": "AlphaTests"}})
        # ... and a legacy ticket written after a current one was admitted at enqueue is
        # rejected at execution, before hashing or launch; scope stays a neutral pending.
        ticket_path.write_text(json.dumps(ticket), encoding="utf-8")
        popen = self.fake_swift_popen(state)
        with mock.patch.object(conductor, "_hash_artifact_file", side_effect=counted_hash):
            job = self.enqueue_and_run_artifact(
                state,
                {"filter": "AlphaTests"},
                between=lambda _job: ticket_path.write_text(json.dumps(legacy), encoding="utf-8"),
                popen=popen,
            )

        self.assertEqual(job.state, "failed")
        self.assertEqual(job.exit_code, 65)
        self.assertIn(self.LEGACY_V2_MESSAGE, job.error or "")
        self.assertEqual(popen.launches, [])
        self.assertEqual(hashed, [])
        self.assertEqual(job.artifact_scope, "pending")
        self.assertNotIn("validated", job.artifact_scope_message or "")
        self.assertIn("not validation evidence", job.artifact_scope_message or "")

    def test_parallel_candidate_versions_precede_strict_keys_and_all_consumers(self) -> None:
        tmp, state = self.make_state()
        self.addCleanup(tmp.cleanup)
        self.initialize_git_repo(state.paths.repo_root)
        self.create_test_artifact(state.paths.repo_root)
        run_id = str(uuid.uuid4())
        job = self.make_job(state, "parallel-versions", "test-parallel", {"parallelRunId": run_id}, ["build"])
        candidate_path, candidate = self.write_parallel_candidate(state, job, run_id, dict(self.ARTIFACT_TOOLCHAIN))
        self.assertEqual((candidate["schema_version"], candidate["fingerprint_version"]), (3, 2))

        def read() -> dict:
            return conductor.read_parallel_test_candidate(
                candidate_path, expected_run_id=run_id, expected_ticket_id=job.ticket, expected_filter=None
            )

        self.assertEqual(read(), candidate)
        projected = conductor.parallel_build_ticket_payload(candidate)
        self.assertEqual((projected["schema_version"], projected["fingerprint_version"]), (2, 2))
        self.assertEqual(projected["artifact_fingerprint"], candidate["artifact_fingerprint"])
        self.assertEqual(len(projected["artifact_fingerprint"]), 6)
        self.assertNotIn("kind", projected)
        self.assertIsNone(conductor.root_build_ticket_version_problem(projected))

        forbidden = AssertionError("candidate version rejection must precede snapshots, probes and hashing")
        for name, (changes, message) in self.CANDIDATE_ENVELOPE_CASES.items():
            with self.subTest(envelope=name):
                changed = self.with_envelope(candidate, changes)
                conductor.write_build_ticket(candidate_path, changed)
                with self.assertRaises(conductor.ParallelTestIntegrityError) as raised:
                    read()
                self.assertIn(message, str(raised.exception))
                self.assertNotIn("schema mismatch", str(raised.exception))
                with contextlib.ExitStack() as guards:
                    for spy in ("source_snapshot", "artifact_toolchain_snapshot", "test_artifact_fingerprint"):
                        guards.enter_context(mock.patch.object(conductor, spy, side_effect=forbidden))
                    with self.assertRaisesRegex(conductor.ParallelTestIntegrityError, message):
                        conductor.verify_parallel_test_candidate(state.paths.repo_root, changed, os.environ.copy())
                    with self.assertRaisesRegex(conductor.ParallelTestIntegrityError, message):
                        conductor.parallel_build_ticket_payload(changed)

        # The strict candidate key set still applies to current envelopes.
        conductor.write_build_ticket(candidate_path, {**candidate, "extra": True})
        with self.assertRaisesRegex(conductor.ParallelTestIntegrityError, r"schema mismatch; missing=\[\]; extra=\['extra'\]"):
            read()

    def test_parallel_job_with_legacy_candidate_fails_67_without_ticket(self) -> None:
        tmp, state = self.make_state()
        self.addCleanup(tmp.cleanup)
        self.initialize_git_repo(state.paths.repo_root)
        self.create_test_artifact(state.paths.repo_root)
        run_id = str(uuid.uuid4())
        job = self.make_job(
            state, "parallel-legacy", "test-parallel", {"workers": 2, "parallelRunId": run_id}, ["build"],
            job_state="running",
        )
        candidate_path, candidate = self.write_parallel_candidate(state, job, run_id, dict(self.ARTIFACT_TOOLCHAIN))
        conductor.write_build_ticket(candidate_path, self.with_envelope(candidate, {self.S: 2, self.F: ...}))
        job.args["parallelCandidate"] = str(candidate_path)
        state.jobs[job.ticket] = job
        ticket_path = state.paths.jobs_dir / "build-ticket-root.json"
        ticket_path.write_text('{"ticket_id":"old"}\n', encoding="utf-8")
        with (
            mock.patch.object(
                state.registry,
                "prepare",
                return_value=(
                    [sys.executable, "-c", "raise SystemExit(0)"], ["build"], state.paths.repo_root,
                    os.environ.copy(), 5.0,
                ),
            ),
            mock.patch.object(conductor, "operation_requires_global_heavy_slot", return_value=False),
            mock.patch.object(conductor, "operation_requires_global_xctest_slot", return_value=False),
            mock.patch.object(conductor, "artifact_toolchain_snapshot", return_value=dict(self.ARTIFACT_TOOLCHAIN)),
        ):
            state._run_job(job.ticket)

        self.assertEqual(job.state, "failed")
        self.assertEqual(job.exit_code, conductor.XCTEST_SOURCE_ARTIFACT_INTEGRITY_EXIT_CODE)
        self.assertIn(self.LEGACY_V2_MESSAGE, job.error or "")
        self.assertFalse(ticket_path.exists())

    def test_test_artifact_scope_is_current_then_stale_after_source_mutation(self) -> None:
        tmp, state = self.make_state()
        self.addCleanup(tmp.cleanup)
        source = self.initialize_git_repo(state.paths.repo_root)
        toolchain = {"swift_version": "Swift test", "arch": "testarch", "config": "debug"}
        executable = self.create_test_artifact(state.paths.repo_root)
        job = self.make_job(state, "ticket-source", "test", {}, ["build"])
        env = os.environ.copy()

        with mock.patch.object(conductor, "artifact_toolchain_snapshot", return_value=toolchain):
            ticket = conductor.build_ticket_payload(state.paths.repo_root, job, env)
            self.assertIsNotNone(ticket)
            conductor.write_build_ticket(state.paths.jobs_dir / "build-ticket-root.json", ticket or {})
            current = conductor.evaluate_test_artifact(state.paths.repo_root, state.paths.jobs_dir, env)
            source.write_text("let value = 2\n", encoding="utf-8")
            stale = conductor.evaluate_test_artifact(state.paths.repo_root, state.paths.jobs_dir, env)

        self.assertEqual(current["artifactScope"], "current")
        self.assertEqual(current["artifactScopeDifferences"], [])
        self.assertEqual(stale["artifactScope"], "stale")
        self.assertIn("dirty digest", stale["artifactScopeDifferences"])
        self.assertIn("current source was NOT validated", stale["artifactScopeMessage"])
        summary = conductor._with_artifact_scope_summary(
            {
                "artifactScope": stale["artifactScope"],
                "artifactScopeDifferences": stale["artifactScopeDifferences"],
                "artifactScopeMessage": stale["artifactScopeMessage"],
                "state": "completed",
                "exitCode": 0,
            },
            {"headline": "completed successfully", "sections": []},
        )
        self.assertEqual(summary["artifactScope"], "stale")
        self.assertIn("artifact passed", summary["headline"])
        self.assertIn("current source was NOT validated", summary["headline"])
        self.assertIn("dirty digest", summary["sections"][0]["lines"][0])

        executable.write_bytes(b"different executable")
        with mock.patch.object(conductor, "artifact_toolchain_snapshot", return_value=toolchain):
            with self.assertRaisesRegex(conductor.ArtifactUnavailableError, "executable fingerprint"):
                conductor.evaluate_test_artifact(state.paths.repo_root, state.paths.jobs_dir, env)

    def test_daemon_reverifies_artifact_after_xctest_slot_before_popen(self) -> None:
        # Step 7: the one authoritative evaluation runs after the slot, so a change
        # made while waiting for it is caught by the full hash before launch.
        state, _executable, resource = self.artifact_fixture()
        assert resource is not None
        slot_file = (state.paths.repo_root / "xctest-slot.lock").open("a+")
        self.addCleanup(slot_file.close)

        def acquire_after_mutation(_ticket: str) -> object:
            self.mutate_same_size_preserving_mtime(resource)
            return slot_file

        extra = contextlib.ExitStack()
        extra.enter_context(
            mock.patch.object(state, "_acquire_global_xctest_slot", side_effect=acquire_after_mutation)
        )
        popen = self.job_launch_probe()
        extra.enter_context(mock.patch.object(conductor.subprocess, "Popen", popen))
        job = self.run_artifact_job(state, ["swift", "test"], extra=extra)

        self.assertEqual(popen.launches, [])
        self.assertEqual(job.state, "failed")
        self.assertEqual(job.exit_code, 65)
        self.assertIn("artifact closure", job.error or "")

    def test_prelaunch_metadata_fence_rejects_changes_after_evaluation_without_popen(self) -> None:
        def same_size_restored_mtime(executable: Path, resource: Path) -> None:
            self.mutate_same_size_preserving_mtime(resource)

        def replace_executable_path(executable: Path, resource: Path) -> None:
            replacement = executable.with_name("replacement")
            shutil.copy2(executable, replacement)
            os.replace(replacement, executable)

        def add_bundle_member(executable: Path, resource: Path) -> None:
            (resource.parent / "late.txt").write_text("late\n", encoding="utf-8")

        def remove_bundle_member(executable: Path, resource: Path) -> None:
            resource.unlink()

        def add_sibling_bundle(executable: Path, resource: Path) -> None:
            sibling = resource.parent.parent / "Late_Resources.bundle"
            sibling.mkdir()
            (sibling / "late.txt").write_text("late\n", encoding="utf-8")

        def add_nested_member(executable: Path, resource: Path) -> None:
            (resource.parent / "nested" / "late.txt").write_text("late\n", encoding="utf-8")

        for mutate in (
            same_size_restored_mtime,
            replace_executable_path,
            add_bundle_member,
            remove_bundle_member,
            add_sibling_bundle,
            add_nested_member,
        ):
            with self.subTest(mutation=mutate.__name__):
                state, executable, resource = self.artifact_fixture()
                assert resource is not None
                fingerprints: list[object] = []
                real_fingerprint = conductor.test_artifact_fingerprint

                def counted(*args: object, **kwargs: object) -> object:
                    fingerprints.append(args[0])
                    return real_fingerprint(*args, **kwargs)

                extra = contextlib.ExitStack()
                # The pin runs after the start line and evaluation, immediately before Popen.
                extra.enter_context(
                    mock.patch.object(
                        state,
                        "_pin_xctest_method_runtimes",
                        side_effect=lambda _job, e=executable, r=resource, m=mutate: m(e, r),
                    )
                )
                extra.enter_context(mock.patch.object(conductor, "test_artifact_fingerprint", side_effect=counted))
                popen = self.job_launch_probe()
                extra.enter_context(mock.patch.object(conductor.subprocess, "Popen", popen))
                job = self.run_artifact_job(state, ["swift", "test"], extra=extra)

                self.assertEqual(popen.launches, [])
                self.assertEqual(job.state, "failed")
                self.assertEqual(job.exit_code, 65)
                self.assertIn("after validation, before launch", job.error or "")
                # Metadata only: the evaluation's hash is the only pre-launch fingerprint.
                self.assertEqual(len(fingerprints), 1)

    def test_cancel_during_evaluation_finishes_canceled_without_popen(self) -> None:
        state, _executable, _resource = self.artifact_fixture()
        real_evaluate = conductor.evaluate_test_artifact

        def evaluate_then_cancel(*args: object, **kwargs: object) -> dict:
            result = real_evaluate(*args, **kwargs)
            with state.condition:
                for candidate in state.jobs.values():
                    candidate.cancel_requested = True
            return result

        extra = contextlib.ExitStack()
        extra.enter_context(mock.patch.object(conductor, "evaluate_test_artifact", side_effect=evaluate_then_cancel))
        popen = self.job_launch_probe()
        extra.enter_context(mock.patch.object(conductor.subprocess, "Popen", popen))
        job = self.run_artifact_job(state, ["swift", "test"], extra=extra)

        self.assertEqual(popen.launches, [])
        self.assertEqual(job.state, "canceled")
        self.assertEqual(job.exit_code, 130)
        self.assertEqual(job.result_summary, "canceled before process start")

    def test_cancel_before_xctest_slot_runs_no_full_validation(self) -> None:
        state, _executable, _resource = self.artifact_fixture()
        job = self.make_job(state, "cancel-slot", "test-artifact", {"filter": "AlphaTests"}, ["build"], job_state="running")
        state.jobs[job.ticket] = job
        real_prepare = state.registry.prepare

        def prepare_then_cancel(request: dict) -> object:
            result = real_prepare(request)
            with state.condition:
                job.cancel_requested = True
            return result

        forbidden = AssertionError("no full validation before the XCTest slot")
        with (
            self.artifact_host(),
            mock.patch.object(state.registry, "prepare", side_effect=prepare_then_cancel),
            mock.patch.object(conductor, "evaluate_test_artifact", side_effect=forbidden) as evaluate,
            mock.patch.object(conductor, "test_artifact_fingerprint", side_effect=forbidden) as fingerprint,
            mock.patch.object(conductor, "source_snapshot", side_effect=forbidden) as snapshot,
            mock.patch.object(conductor.subprocess, "Popen") as popen,
            mock.patch.object(conductor, "machine_lock_dir", return_value=state.paths.repo_root / "machine-locks"),
        ):
            conductor.artifact_toolchain_snapshot.side_effect = forbidden
            state._run_job(job.ticket)
            toolchain_calls = conductor.artifact_toolchain_snapshot.call_count

        self.assertEqual(job.state, "canceled")
        self.assertEqual(job.exit_code, 130)
        self.assertEqual(job.result_summary, "canceled before global xctest slot")
        for probe in (evaluate, fingerprint, snapshot, popen):
            probe.assert_not_called()
        self.assertEqual(toolchain_calls, 0)

    def test_test_artifact_claims_xctest_slot_not_heavy_and_records_run_duration(self) -> None:
        state, _executable, _resource = self.artifact_fixture(resource=False)
        lock_root = state.paths.repo_root / "machine-locks"
        command = [sys.executable, "-u", "-c", self.PASSING_ARTIFACT_RUN]

        job = self.run_artifact_job(state, command)

        payload = job.to_payload()
        self.assertEqual(job.state, "completed", job.result_summary)
        self.assertIsNone(payload["globalHeavySlotPath"])
        self.assertEqual(payload["xctestSlotPath"], str(lock_root / "global-xctest-0.lock"))
        self.assertIsNotNone(payload["xctestSlotWaitSeconds"])
        self.assertIsNotNone(payload["runPhaseSeconds"])
        self.assertGreaterEqual(payload["runPhaseSeconds"], 0.0)
        self.assertEqual(payload["artifactScope"], "current")
        summarized = conductor.payload_with_output_summary(payload)
        self.assertEqual(summarized["outputSummary"]["artifactScope"], "current")
        self.assertEqual(summarized["outputSummary"]["sections"][0]["title"], "Artifact scope")

    def test_test_artifact_post_run_source_change_marks_final_scope_stale(self) -> None:
        # Source-only drift stays a successful, stale-scoped pass (never 65 or 67).
        state, _executable, _resource = self.artifact_fixture(resource=False)
        source = state.paths.repo_root / "Tracked.swift"
        command = [
            sys.executable,
            "-u",
            "-c",
            "from pathlib import Path; import sys; Path(sys.argv[1]).write_text('let value = 2\\n'); "
            + self.PASSING_ARTIFACT_RUN,
            str(source),
        ]

        job = self.run_artifact_job(state, command)

        self.assertEqual(job.state, "completed", job.result_summary)
        self.assertEqual(job.exit_code, 0)
        self.assertEqual(job.artifact_scope, "stale")
        self.assertIn("post-run dirty digest", job.artifact_scope_differences)
        self.assertNotIn("artifact mutated during run", job.artifact_scope_differences)
        self.assertNotIn("passed", job.artifact_scope_message or "")

    def test_test_artifact_mutated_during_run_fails_65_with_stale_scope(self) -> None:
        # Step 7 deliberately supersedes the earlier completed/0 contract: a post-run
        # byte change invalidates an otherwise successful run.
        mutations = {
            "resource-rewrite": "Path(sys.argv[2]).write_text('mutated during run\\n')",
            "executable-rewrite": "Path(sys.argv[1]).write_bytes(b'other executable')",
            "member-added": "Path(sys.argv[2]).with_name('added.txt').write_text('new\\n')",
            "member-removed": "Path(sys.argv[2]).unlink()",
            # S7-R0-04: same size, mtime restored; only content hashing can see it.
            "same-size-restored-mtime": (
                "import os; p = Path(sys.argv[2]); s = p.stat(); b = bytearray(p.read_bytes()); "
                "b[0] = (b[0] + 1) % 256; p.write_bytes(bytes(b)); "
                "os.utime(p, ns=(s.st_atime_ns, s.st_mtime_ns)); "
                "assert (p.stat().st_size, p.stat().st_mtime_ns) == (s.st_size, s.st_mtime_ns)"
            ),
        }
        for name, statement in mutations.items():
            with self.subTest(mutation=name):
                state, executable, resource = self.artifact_fixture()
                command = [
                    sys.executable,
                    "-u",
                    "-c",
                    f"from pathlib import Path; import sys; {statement}; " + self.PASSING_ARTIFACT_RUN,
                    str(executable),
                    str(resource),
                ]

                job = self.run_artifact_job(state, command)

                self.assertEqual(job.state, "failed", job.result_summary)
                self.assertEqual(job.exit_code, 65)
                self.assertIn("test artifact changed during the run", job.error or "")
                self.assertEqual(
                    job.result_summary,
                    "test artifact integrity failed after execution; run `make dev-test` first",
                )
                self.assertEqual(job.artifact_scope, "stale")
                self.assertIn("artifact mutated during run", job.artifact_scope_differences)
                self.assertIn("current source was NOT validated", job.artifact_scope_message or "")
                self.assertIn("artifact integrity failure:", "".join(job.tail))

    def test_test_artifact_unreadable_after_run_fails_65_as_integrity_unavailable(self) -> None:
        state, _executable, resource = self.artifact_fixture()
        assert resource is not None
        self.addCleanup(lambda: resource.chmod(0o644) if resource.exists() else None)
        command = [
            sys.executable,
            "-u",
            "-c",
            "import os, sys; os.chmod(sys.argv[1], 0); " + self.PASSING_ARTIFACT_RUN,
            str(resource),
        ]

        job = self.run_artifact_job(state, command)

        self.assertEqual(job.state, "failed", job.result_summary)
        self.assertEqual(job.exit_code, 65)
        self.assertIn("post-run artifact integrity unavailable", job.error or "")
        self.assertIn("post-run artifact integrity unavailable", job.artifact_scope_differences)
        self.assertEqual(job.artifact_scope, "stale")

    def test_test_artifact_integrity_failure_keeps_earlier_primary_outcome(self) -> None:
        sleeper = [sys.executable, "-u", "-c", "import time; time.sleep(30)"]
        cases = {
            "process-failure": ([sys.executable, "-u", "-c", "raise SystemExit(3)"], 30.0, False),
            "timeout": (sleeper, 0.5, False),
            "cancellation": ([sys.executable, "-u", "-c", self.PASSING_ARTIFACT_RUN], 30.0, True),
        }
        expected = {
            "process-failure": ("failed", 3, "process exited with status 3"),
            "timeout": ("failed", 124, "timed out after 0.5s"),
            "cancellation": ("canceled", 130, None),
        }
        for name, (command, timeout, cancel) in cases.items():
            with self.subTest(outcome=name):
                state, _executable, resource = self.artifact_fixture()
                assert resource is not None
                real_popen = conductor.subprocess.Popen

                def popen_then_mutate(argv: object, *args: object, c=cancel, r=resource, **kwargs: object) -> object:
                    process = real_popen(argv, *args, **kwargs)
                    r.write_text("mutated during run\n", encoding="utf-8")
                    if c:
                        for job_entry in state.jobs.values():
                            job_entry.cancel_requested = True
                    return process

                popen = self.job_launch_probe(popen_then_mutate)
                extra = contextlib.ExitStack()
                extra.enter_context(mock.patch.object(conductor.subprocess, "Popen", popen))
                job = self.run_artifact_job(state, command, timeout=timeout, extra=extra)

                state_name, exit_code, error = expected[name]
                self.assertEqual(job.state, state_name, job.result_summary)
                self.assertEqual(job.exit_code, exit_code)
                if error is not None:
                    self.assertIn(error, job.error or "")
                    self.assertNotIn("integrity failed after execution", job.result_summary or "")
                else:
                    self.assertEqual(job.result_summary, "canceled")
                self.assertIn("artifact mutated during run", job.artifact_scope_differences)
                self.assertEqual(job.artifact_scope, "stale")
                self.assertIn("artifact integrity failure:", "".join(job.tail))

    def fake_swift_popen(self, state: conductor.DaemonState) -> mock.Mock:
        fake_bin = state.paths.jobs_dir / "fake-bin"
        fake_bin.mkdir(exist_ok=True)
        swift = fake_bin / "swift"
        swift.write_text(
            "#!/usr/bin/env python3\n"
            "print(\"Test Case '-[RepoPromptTests.AlphaTests testOne]' started.\")\n"
            "print(\"Test Case '-[RepoPromptTests.AlphaTests testOne]' passed (0.001 seconds).\")\n",
            encoding="utf-8",
        )
        real_popen = conductor.subprocess.Popen

        def launch_fake_swift(argv: object, *args: object, **kwargs: object) -> subprocess.Popen[bytes]:
            command = list(argv) if isinstance(argv, (list, tuple)) else argv
            if isinstance(command, list) and command and Path(command[0]).name in {"swift", "canonical_swift.sh"}:
                command = [sys.executable, str(swift), *command[1:]]
            return real_popen(command, *args, **kwargs)

        return self.job_launch_probe(launch_fake_swift)

    def enqueue_and_run_artifact(
        self,
        state: conductor.DaemonState,
        args: dict,
        between: object = None,
        popen: mock.Mock | None = None,
    ) -> conductor.Job:
        popen = popen or self.fake_swift_popen(state)
        with (
            self.artifact_host(),
            mock.patch.object(conductor.subprocess, "Popen", popen),
            mock.patch.object(state, "_schedule_locked"),
            mock.patch.object(state, "_xctest_watchdog_enabled", return_value=False),
            mock.patch.object(conductor, "machine_lock_dir", return_value=state.paths.repo_root / "machine-locks"),
        ):
            payload = state.enqueue({"operation": "test-artifact", "args": args})
            job = state.jobs[payload["ticket"]]
            if callable(between):
                between(job)
            job.state = "running"
            state.queue.remove(job.ticket)
            state._run_job(job.ticket)
        return job

    def test_enqueue_strips_forged_derived_fields_before_identity_and_evaluation(self) -> None:
        state, _executable, _resource = self.artifact_fixture()
        ticket = json.loads((state.paths.jobs_dir / "build-ticket-root.json").read_text(encoding="utf-8"))
        forged = {
            "artifactPath": str(state.paths.repo_root / "forged.xctest"),
            "artifactFingerprint": {"sha256": "forged"},
            "artifactScope": "current",
            "artifactScopeDifferences": ["forged"],
            "artifactScopeMessage": "artifact_scope: current",
            "artifactTicketSourceSnapshot": {"head": "forged"},
            "buildTicketId": "forged-ticket",
        }
        self.assertEqual(set(forged), set(conductor.TEST_ARTIFACT_DERIVED_ARG_KEYS))
        observed: dict[str, object] = {}

        def capture(job: conductor.Job) -> None:
            observed["args"] = dict(job.args)
            observed["fingerprint"] = job.fingerprint
            observed["scope"] = (job.artifact_scope, job.artifact_scope_message)

        job = self.enqueue_and_run_artifact(state, {"filter": "AlphaTests", **forged}, between=capture)

        self.assertEqual(observed["args"], {"filter": "AlphaTests"})
        self.assertEqual(
            observed["fingerprint"],
            state.registry.fingerprint({"operation": "test-artifact", "args": {"filter": "AlphaTests"}}),
        )
        self.assertEqual(observed["scope"], ("pending", conductor.TEST_ARTIFACT_PENDING_SCOPE_MESSAGE))
        self.assertEqual(job.state, "completed", job.result_summary)
        self.assertEqual(job.args["buildTicketId"], ticket["ticket_id"])
        self.assertEqual(job.args["artifactFingerprint"], ticket["artifact_fingerprint"])
        self.assertEqual(Path(job.args["artifactPath"]).name, "RepoPromptCEPackageTests.xctest")
        self.assertEqual(job.artifact_scope, "current")
        self.assertEqual(job.artifact_scope_differences, [])

    def test_queued_artifact_replacement_is_judged_at_execution(self) -> None:
        # Not re-minted: the execution-time hash rejects it before process creation.
        state, executable, _resource = self.artifact_fixture()
        popen = self.fake_swift_popen(state)
        job = self.enqueue_and_run_artifact(
            state,
            {"filter": "AlphaTests"},
            between=lambda _job: executable.write_bytes(b"replaced while queued"),
            popen=popen,
        )
        self.assertEqual(job.state, "failed")
        self.assertEqual(job.exit_code, 65)
        self.assertIn("executable fingerprint", job.error or "")
        self.assertEqual(popen.launches, [])

        # Re-minted while queued: the job runs against the new artifact, never enqueue-time data.
        state, executable, _resource = self.artifact_fixture()
        replacement: dict[str, dict] = {}

        def rebuild(_job: conductor.Job) -> None:
            executable.write_bytes(b"rebuilt while queued")
            replacement["ticket"] = self.mint_artifact_ticket(state)

        job = self.enqueue_and_run_artifact(state, {"filter": "AlphaTests"}, between=rebuild)
        self.assertEqual(job.state, "completed", job.result_summary)
        self.assertEqual(job.args["buildTicketId"], replacement["ticket"]["ticket_id"])
        self.assertEqual(job.args["artifactFingerprint"], replacement["ticket"]["artifact_fingerprint"])

    def test_test_artifact_job_hashes_twice_and_never_at_client_or_enqueue(self) -> None:
        state, executable, resource = self.artifact_fixture()
        assert resource is not None
        artifact_root = executable.parents[2]
        counts = {"executable_hashes": 0, "closure_walks": 0, "source_snapshots": 0, "toolchain": 0}
        real_hash = conductor._hash_artifact_file
        real_walk = os.walk
        real_snapshot = conductor.source_snapshot

        def counted_hash(path: Path, *args: object, **kwargs: object) -> object:
            if path == executable:
                counts["executable_hashes"] += 1
            return real_hash(path, *args, **kwargs)

        def counted_walk(top: object, *args: object, **kwargs: object) -> object:
            if Path(top) == artifact_root:
                counts["closure_walks"] += 1
            return real_walk(top, *args, **kwargs)

        def counted_snapshot(*args: object, **kwargs: object) -> object:
            counts["source_snapshots"] += 1
            return real_snapshot(*args, **kwargs)

        def counted_toolchain(*_args: object, **_kwargs: object) -> dict:
            counts["toolchain"] += 1
            return dict(self.ARTIFACT_TOOLCHAIN)

        def snapshot_counts() -> dict:
            return dict(counts)

        captured: dict[str, dict] = {}
        with (
            mock.patch.object(conductor, "_hash_artifact_file", side_effect=counted_hash),
            mock.patch.object(conductor.os, "walk", side_effect=counted_walk),
            mock.patch.object(conductor, "source_snapshot", side_effect=counted_snapshot),
            mock.patch.object(conductor, "host_artifact_arch", return_value="testarch"),
            mock.patch.object(conductor, "artifact_toolchain_snapshot", side_effect=counted_toolchain),
            mock.patch.object(conductor, "preflight_test_filter"),
            mock.patch.object(
                conductor,
                "enqueue_and_maybe_wait",
                side_effect=lambda _paths, _operation, args, *_rest, **_kw: captured.setdefault("args", dict(args)) and 0,
            ),
        ):
            self.assertEqual(
                conductor.handle_real_operation(state.paths, "test-artifact", ["--filter", "AlphaTests"]), 0
            )
            after_client = snapshot_counts()
            popen = self.fake_swift_popen(state)
            with (
                mock.patch.object(conductor.subprocess, "Popen", popen),
                mock.patch.object(state, "_schedule_locked"),
                mock.patch.object(state, "_xctest_watchdog_enabled", return_value=False),
                mock.patch.object(conductor, "machine_lock_dir", return_value=state.paths.repo_root / "machine-locks"),
            ):
                payload = state.enqueue({"operation": "test-artifact", "args": captured["args"]})
                after_enqueue = snapshot_counts()
                job = state.jobs[payload["ticket"]]
                job.state = "running"
                state.queue.remove(job.ticket)
                state._run_job(job.ticket)

        zero = {"executable_hashes": 0, "closure_walks": 0, "source_snapshots": 0, "toolchain": 0}
        self.assertEqual(captured["args"], {"filter": "AlphaTests"})
        self.assertEqual(after_client, zero)
        self.assertEqual(after_enqueue, zero)
        self.assertEqual(job.state, "completed", job.result_summary)
        self.assertEqual(len(popen.launches), 1)
        self.assertEqual(popen.launches[0][1:], ["test", "--skip-build", "--filter", "AlphaTests"])
        self.assertEqual(
            counts,
            {"executable_hashes": 2, "closure_walks": 2, "source_snapshots": 2, "toolchain": 1},
        )

    def test_artifact_admission_is_cheap_and_accepts_unknown_ticket_extras(self) -> None:
        forbidden = AssertionError("admission must not hash, snapshot or probe the toolchain")
        state, executable, _resource = self.artifact_fixture()
        ticket_path = state.paths.jobs_dir / "build-ticket-root.json"
        ticket = json.loads(ticket_path.read_text(encoding="utf-8"))
        guards = contextlib.ExitStack()
        guards.enter_context(mock.patch.object(conductor, "host_artifact_arch", return_value="testarch"))
        for name in ("_hash_artifact_file", "test_artifact_fingerprint", "source_snapshot", "artifact_toolchain_snapshot"):
            guards.enter_context(mock.patch.object(conductor, name, side_effect=forbidden))
        with guards:
            # Unknown top-level extras are still ignored on the current (schema 2,
            # fingerprint v2) root ticket; source-stale artifacts stay admissible.
            self.assertEqual((ticket["schema_version"], ticket["fingerprint_version"]), (2, 2))
            ticket_path.write_text(json.dumps({**ticket, "extra": True, "policy": {"x": 1}}), encoding="utf-8")
            (state.paths.repo_root / "Tracked.swift").write_text("let value = 99\n", encoding="utf-8")
            conductor.admit_test_artifact(state.paths.repo_root, state.paths.jobs_dir)

            fingerprint = ticket["artifact_fingerprint"]
            rejected = {
                "missing ticket": None,
                "malformed ticket": "{not json",
                "non-object ticket": "[]",
                "missing fingerprint": json.dumps({**ticket, "artifact_fingerprint": None}),
                "missing field": json.dumps(
                    {**ticket, "artifact_fingerprint": {k: v for k, v in fingerprint.items() if k != "sha256"}}
                ),
                "wrong kind": json.dumps({**ticket, "artifact_fingerprint": {**fingerprint, "size": "7"}}),
                "bool size": json.dumps({**ticket, "artifact_fingerprint": {**fingerprint, "size": True}}),
            }
            for name, content in rejected.items():
                with self.subTest(case=name):
                    if content is None:
                        ticket_path.unlink(missing_ok=True)
                    else:
                        ticket_path.write_text(content, encoding="utf-8")
                    with self.assertRaisesRegex(conductor.ArtifactUnavailableError, "run `make dev-test` first"):
                        conductor.admit_test_artifact(state.paths.repo_root, state.paths.jobs_dir)

            ticket_path.write_text(json.dumps(ticket), encoding="utf-8")
            executable.unlink()
            with self.assertRaisesRegex(conductor.ArtifactUnavailableError, "executable is missing"):
                conductor.admit_test_artifact(state.paths.repo_root, state.paths.jobs_dir)
            shutil.rmtree(executable.parents[2])
            with self.assertRaisesRegex(conductor.ArtifactUnavailableError, "root test artifact is missing"):
                conductor.admit_test_artifact(state.paths.repo_root, state.paths.jobs_dir)

    def test_enqueued_artifact_job_real_prepare_copies_stale_scope_to_result(self) -> None:
        # Step 7: enqueue scope is pending; execution decides current/stale.
        state, _executable, _resource = self.artifact_fixture(resource=False)
        source = state.paths.repo_root / "Tracked.swift"
        enqueue_scope: list[object] = []

        def change_source_while_queued(job: conductor.Job) -> None:
            enqueue_scope.append(job.artifact_scope)
            source.write_text("let value = 2\n", encoding="utf-8")

        job = self.enqueue_and_run_artifact(state, {"filter": "AlphaTests"}, between=change_source_while_queued)

        self.assertEqual(enqueue_scope, ["pending"])
        self.assertEqual(job.state, "completed", job.result_summary)
        self.assertEqual(job.artifact_scope, "stale")
        self.assertIn("dirty digest", job.artifact_scope_differences)

    def test_daemon_runner_preserves_artifact_unavailable_exit_65(self) -> None:
        tmp, state = self.make_state()
        self.addCleanup(tmp.cleanup)
        job = self.make_job(
            state,
            "missing-ticket",
            "test-artifact",
            {"filter": "AlphaTests"},
            ["build"],
            job_state="running",
        )
        state.jobs[job.ticket] = job

        state._run_job(job.ticket)

        self.assertEqual(job.state, "failed")
        self.assertEqual(job.exit_code, 65)
        self.assertIn("build ticket is missing", job.error or "")
        self.assertNotIn("daemon runner error", job.result_summary or "")

    def test_parallel_internal_operation_builds_before_runner_without_prior_ticket(self) -> None:
        tmp, state = self.make_state()
        self.addCleanup(tmp.cleanup)
        executable = self.create_test_artifact(state.paths.repo_root)
        artifact_path = executable.parents[2]
        run_id = str(uuid.uuid4())
        args = {
            "workers": 2,
            "parallelRunId": run_id,
            "parallelCandidate": str(
                state.paths.jobs_dir / f"parallel-xctest-{run_id}-candidate.json"
            ),
            "parallelTestList": str(
                state.paths.jobs_dir / f"parallel-xctest-{run_id}-test-list.txt"
            ),
            "parallelWorkdir": str(
                state.paths.jobs_dir / f"parallel-xctest-{run_id}"
            ),
        }
        snapshot = {
            "head": "head",
            "porcelain_sha256": "porcelain",
            "dirty_file_sha256": {},
        }
        toolchain = {
            "swift_version": "Swift test",
            "arch": "testarch",
            "config": "debug",
        }
        completed = mock.Mock(returncode=0)

        with (
            mock.patch.dict(
                os.environ,
                {"REPOPROMPT_CONDUCTOR_JOB_TICKET": "parallel-ticket"},
                clear=False,
            ),
            mock.patch.object(
                conductor, "source_snapshot", side_effect=[snapshot, snapshot]
            ),
            mock.patch.object(
                conductor, "artifact_toolchain_snapshot", return_value=toolchain
            ),
            mock.patch.object(
                conductor.subprocess, "run", side_effect=[completed, completed]
            ) as run,
        ):
            code = conductor.operation_parallel_root_test(
                state.paths.repo_root, args
            )

        self.assertEqual(code, 0)
        self.assertEqual(
            run.call_args_list[0].args[0],
            [
                str(state.paths.repo_root / "Scripts" / "canonical_swift.sh"),
                "build",
                "--build-tests",
            ],
        )
        runner_argv = run.call_args_list[1].args[0]
        self.assertEqual(
            runner_argv[:3],
            [
                sys.executable,
                "-u",
                str(
                    state.paths.repo_root
                    / "Scripts"
                    / "parallel_xctest_runner.py"
                ),
            ],
        )
        self.assertEqual(
            runner_argv[runner_argv.index("--bundle") + 1],
            str(artifact_path.resolve()),
        )
        candidate = json.loads(
            Path(args["parallelCandidate"]).read_text(encoding="utf-8")
        )
        self.assertEqual(candidate["run_id"], run_id)
        self.assertEqual((candidate["schema_version"], candidate["fingerprint_version"]), (3, 2))
        self.assertEqual(len(candidate["artifact_fingerprint"]), 6)
        self.assertEqual(candidate["ticket_id"], "parallel-ticket")
        self.assertEqual(candidate["evidence_scope"], "full-root")
        self.assertEqual(candidate["source_snapshot"], snapshot)
        self.assertEqual(
            candidate["worker_runtime_gates"],
            conductor.parallel_xctest_runtime_gates(os.environ),
        )
        self.assertEqual(candidate["toolchain"], toolchain)
        self.assertEqual(candidate["artifact_path"], str(artifact_path.resolve()))
        self.assertGreaterEqual(candidate["build_duration_seconds"], 0)
        self.assertGreater(candidate["runner_started_at"], 0)

    def test_parallel_internal_operation_fails_67_on_build_source_drift(self) -> None:
        tmp, state = self.make_state()
        self.addCleanup(tmp.cleanup)
        run_id = str(uuid.uuid4())
        args = {
            "parallelRunId": run_id,
            "parallelCandidate": str(
                state.paths.jobs_dir / f"parallel-xctest-{run_id}-candidate.json"
            ),
            "parallelTestList": str(
                state.paths.jobs_dir / f"parallel-xctest-{run_id}-test-list.txt"
            ),
            "parallelWorkdir": str(
                state.paths.jobs_dir / f"parallel-xctest-{run_id}"
            ),
        }
        snapshot_s0 = {
            "head": "head",
            "porcelain_sha256": "before",
            "dirty_file_sha256": {},
        }
        snapshot_s1 = {
            "head": "head",
            "porcelain_sha256": "after",
            "dirty_file_sha256": {},
        }
        completed = mock.Mock(returncode=0)

        with (
            mock.patch.dict(
                os.environ,
                {"REPOPROMPT_CONDUCTOR_JOB_TICKET": "parallel-ticket"},
                clear=False,
            ),
            mock.patch.object(
                conductor,
                "source_snapshot",
                side_effect=[snapshot_s0, snapshot_s1],
            ),
            mock.patch.object(
                conductor.subprocess, "run", return_value=completed
            ) as run,
        ):
            code = conductor.operation_parallel_root_test(
                state.paths.repo_root, args
            )

        self.assertEqual(
            code, conductor.XCTEST_SOURCE_ARTIFACT_INTEGRITY_EXIT_CODE
        )
        self.assertEqual(run.call_count, 1)
        self.assertFalse(Path(args["parallelCandidate"]).exists())

    def test_parallel_missing_candidate_fails_67_and_invalidates_old_ticket(self) -> None:
        tmp, state = self.make_state()
        self.addCleanup(tmp.cleanup)
        run_id = str(uuid.uuid4())
        ticket_path = state.paths.jobs_dir / "build-ticket-root.json"
        ticket_path.write_text('{"ticket_id":"old"}\n', encoding="utf-8")
        job = self.make_job(
            state,
            "parallel-missing-candidate",
            "test-parallel",
            {
                "workers": 2,
                "parallelRunId": run_id,
                "parallelCandidate": str(
                    state.paths.jobs_dir
                    / f"parallel-xctest-{run_id}-candidate.json"
                ),
            },
            ["build"],
            job_state="running",
        )
        state.jobs[job.ticket] = job
        command = [sys.executable, "-c", "raise SystemExit(0)"]

        with (
            mock.patch.object(
                state.registry,
                "prepare",
                return_value=(
                    command,
                    ["build"],
                    state.paths.repo_root,
                    os.environ.copy(),
                    5.0,
                ),
            ),
            mock.patch.object(
                conductor, "operation_requires_global_heavy_slot", return_value=False
            ),
            mock.patch.object(
                conductor, "operation_requires_global_xctest_slot", return_value=False
            ),
        ):
            state._run_job(job.ticket)

        self.assertEqual(job.state, "failed")
        self.assertEqual(
            job.exit_code, conductor.XCTEST_SOURCE_ARTIFACT_INTEGRITY_EXIT_CODE
        )
        self.assertIn("candidate is missing or unreadable", job.error or "")
        self.assertFalse(ticket_path.exists())

    def test_parallel_green_full_and_filtered_runs_create_provenance_tickets(self) -> None:
        for filter_value, expected_scope in [
            (None, "full-root"),
            ("RepoPromptTests.AlphaTests", "filtered"),
        ]:
            with self.subTest(scope=expected_scope):
                tmp, state = self.make_state()
                self.addCleanup(tmp.cleanup)
                self.initialize_git_repo(state.paths.repo_root)
                self.create_test_artifact(state.paths.repo_root)
                toolchain = {
                    "swift_version": "Swift test",
                    "arch": "testarch",
                    "config": "debug",
                }
                run_id = str(uuid.uuid4())
                args: dict[str, object] = {
                    "workers": 2,
                    "parallelRunId": run_id,
                }
                if filter_value is not None:
                    args["filter"] = filter_value
                job = self.make_job(
                    state,
                    f"parallel-{expected_scope}",
                    "test-parallel",
                    args,
                    ["build"],
                    job_state="running",
                )
                candidate_path, candidate = self.write_parallel_candidate(
                    state, job, run_id, toolchain, filter_value
                )
                job.args["parallelCandidate"] = str(candidate_path)
                state.jobs[job.ticket] = job
                ticket_path = state.paths.jobs_dir / "build-ticket-root.json"
                ticket_path.write_text(
                    '{"ticket_id":"old"}\n', encoding="utf-8"
                )
                command = [sys.executable, "-c", "raise SystemExit(0)"]

                with (
                    mock.patch.object(
                        state.registry,
                        "prepare",
                        return_value=(
                            command,
                            ["build"],
                            state.paths.repo_root,
                            os.environ.copy(),
                            5.0,
                        ),
                    ),
                    mock.patch.object(
                        conductor,
                        "operation_requires_global_heavy_slot",
                        return_value=False,
                    ),
                    mock.patch.object(
                        conductor,
                        "operation_requires_global_xctest_slot",
                        return_value=False,
                    ),
                    mock.patch.object(
                        conductor,
                        "artifact_toolchain_snapshot",
                        return_value=toolchain,
                    ),
                ):
                    state._run_job(job.ticket)

                self.assertEqual(job.state, "completed", job.result_summary)
                self.assertEqual(job.build_phase_seconds, 1.25)
                self.assertIsNotNone(job.run_phase_seconds)
                ticket = json.loads(ticket_path.read_text(encoding="utf-8"))
                self.assertEqual(ticket["ticket_id"], job.ticket)
                self.assertEqual((ticket["schema_version"], ticket["fingerprint_version"]), (2, 2))
                self.assertEqual(
                    ticket["artifact_fingerprint"],
                    candidate["artifact_fingerprint"],
                )
                self.assertEqual(
                    ticket["provenance"]["claim"],
                    "artifact-provenance-only",
                )
                self.assertEqual(
                    ticket["provenance"]["completion"], expected_scope
                )
                if expected_scope == "full-root":
                    self.assertIn(
                        "full-root source validation", job.result_summary or ""
                    )
                else:
                    self.assertIn(
                        "not full-root contribution evidence",
                        job.result_summary or "",
                    )

    def test_parallel_bad_candidate_fails_67(self) -> None:
        tmp, state = self.make_state()
        self.addCleanup(tmp.cleanup)
        self.initialize_git_repo(state.paths.repo_root)
        self.create_test_artifact(state.paths.repo_root)
        toolchain = {
            "swift_version": "Swift test",
            "arch": "testarch",
            "config": "debug",
        }
        run_id = str(uuid.uuid4())
        job = self.make_job(
            state,
            "parallel-bad-candidate",
            "test-parallel",
            {"parallelRunId": run_id},
            ["build"],
            job_state="running",
        )
        candidate_path, candidate = self.write_parallel_candidate(
            state, job, run_id, toolchain
        )
        candidate["unexpected"] = True
        conductor.write_build_ticket(candidate_path, candidate)
        job.args["parallelCandidate"] = str(candidate_path)
        state.jobs[job.ticket] = job
        command = [sys.executable, "-c", "raise SystemExit(0)"]

        with (
            mock.patch.object(
                state.registry,
                "prepare",
                return_value=(
                    command,
                    ["build"],
                    state.paths.repo_root,
                    os.environ.copy(),
                    5.0,
                ),
            ),
            mock.patch.object(
                conductor, "operation_requires_global_heavy_slot", return_value=False
            ),
            mock.patch.object(
                conductor, "operation_requires_global_xctest_slot", return_value=False
            ),
        ):
            state._run_job(job.ticket)

        self.assertEqual(
            job.exit_code, conductor.XCTEST_SOURCE_ARTIFACT_INTEGRITY_EXIT_CODE
        )
        self.assertIn("schema mismatch", job.error or "")

    def test_parallel_post_run_source_artifact_and_worker_gate_drift_fail_67(self) -> None:
        for drift in ("source", "artifact", "worker-gate"):
            with self.subTest(drift=drift):
                tmp, state = self.make_state()
                self.addCleanup(tmp.cleanup)
                source = self.initialize_git_repo(state.paths.repo_root)
                executable = self.create_test_artifact(state.paths.repo_root)
                toolchain = {
                    "swift_version": "Swift test",
                    "arch": "testarch",
                    "config": "debug",
                }
                run_id = str(uuid.uuid4())
                job = self.make_job(
                    state,
                    f"parallel-{drift}-drift",
                    "test-parallel",
                    {"parallelRunId": run_id},
                    ["build"],
                    job_state="running",
                )
                candidate_path, candidate = self.write_parallel_candidate(
                    state, job, run_id, toolchain
                )
                job.args["parallelCandidate"] = str(candidate_path)
                state.jobs[job.ticket] = job
                job_env = os.environ.copy()
                if drift == "source":
                    source.write_text("let value = 2\n", encoding="utf-8")
                elif drift == "artifact":
                    executable.write_bytes(b"mutated executable")
                else:
                    prior_gate = candidate["worker_runtime_gates"]["RPCE_RUN_SCALE_TESTS"]
                    job_env["RPCE_RUN_SCALE_TESTS"] = (
                        "post-run-drift" if prior_gate != "post-run-drift" else "other-drift"
                    )
                command = [sys.executable, "-c", "raise SystemExit(0)"]

                with (
                    mock.patch.object(
                        state.registry,
                        "prepare",
                        return_value=(
                            command,
                            ["build"],
                            state.paths.repo_root,
                            job_env,
                            5.0,
                        ),
                    ),
                    mock.patch.object(
                        conductor,
                        "operation_requires_global_heavy_slot",
                        return_value=False,
                    ),
                    mock.patch.object(
                        conductor,
                        "operation_requires_global_xctest_slot",
                        return_value=False,
                    ),
                    mock.patch.object(
                        conductor,
                        "artifact_toolchain_snapshot",
                        return_value=toolchain,
                    ),
                ):
                    state._run_job(job.ticket)

                self.assertEqual(job.state, "failed")
                self.assertEqual(
                    job.exit_code,
                    conductor.XCTEST_SOURCE_ARTIFACT_INTEGRITY_EXIT_CODE,
                )
                self.assertIn(
                    "source/artifact integrity check failed", job.error or ""
                )
                self.assertFalse(
                    (state.paths.jobs_dir / "build-ticket-root.json").exists()
                )

    def test_zero_tests_postcondition_fails_filtered_success(self) -> None:
        tmp, state = self.make_state()
        self.addCleanup(tmp.cleanup)
        job = self.make_job(
            state,
            "zero-tests",
            "test",
            {"filter": "AlphaTests"},
            ["build"],
            job_state="running",
        )
        job.log_path.write_text("Build complete! (0.1s)\nExecuted 0 tests\n", encoding="utf-8")

        with state.condition:
            state._finalize_process_exit_locked(job, 0)

        self.assertEqual(job.state, "failed")
        self.assertEqual(job.exit_code, conductor.XCTEST_ZERO_TESTS_FAILURE_EXIT_CODE)
        self.assertEqual(
            job.error,
            "0 tests executed for filter 'AlphaTests' — filter matched nothing at runtime "
            "(stale ledger entry, regex mismatch, or config-gated suite)",
        )

    def test_zero_tests_postcondition_allows_started_case(self) -> None:
        tmp, state = self.make_state()
        self.addCleanup(tmp.cleanup)
        job = self.make_job(
            state,
            "one-test",
            "test",
            {"filter": "AlphaTests"},
            ["build"],
            job_state="running",
        )
        job.log_path.write_text(
            "Test Case '-[RepoPromptTests.AlphaTests testOne]' started.\n"
            "Test Case '-[RepoPromptTests.AlphaTests testOne]' passed (0.001 seconds).\n",
            encoding="utf-8",
        )

        with state.condition:
            state._finalize_process_exit_locked(job, 0)

        self.assertEqual(job.state, "completed")
        self.assertEqual(job.exit_code, 0)

    def test_zero_tests_postcondition_override_allows_empty_success(self) -> None:
        tmp, state = self.make_state()
        self.addCleanup(tmp.cleanup)
        job = self.make_job(
            state,
            "allowed-zero-tests",
            "provider-test",
            {"filter": "AlphaTests"},
            ["build"],
            job_state="running",
        )
        job.env["RPCE_ALLOW_ZERO_TESTS"] = "1"
        job.log_path.write_text("Executed 0 tests\n", encoding="utf-8")

        with state.condition:
            state._finalize_process_exit_locked(job, 0)

        self.assertEqual(job.state, "completed")
        self.assertEqual(job.exit_code, 0)


class XCTestStallWatchdogTests(LifecycleTestCase):
    def test_active_method_budget_known_small_runtime_uses_floor(self) -> None:
        self.assertEqual(
            conductor.xctest_active_method_budget(1.0, None, None),
            (90.0, "ledger-derived", False),
        )

    def test_active_method_budget_known_large_runtime_uses_formula(self) -> None:
        self.assertEqual(
            conductor.xctest_active_method_budget(40.0, None, None),
            (190.0, "ledger-derived", False),
        )

    def test_active_method_budget_empty_runtime_uses_flat_default(self) -> None:
        self.assertEqual(
            conductor.xctest_active_method_budget(None, None, None),
            (180.0, "default", False),
        )

    def test_active_method_budget_flag_override_wins(self) -> None:
        self.assertEqual(
            conductor.xctest_active_method_budget(40.0, 12.0, None),
            (12.0, "flag-overridden", False),
        )

    def test_active_method_budget_clamps_to_job_timeout(self) -> None:
        self.assertEqual(
            conductor.xctest_active_method_budget(100.0, None, 120.0),
            (120.0, "ledger-derived", True),
        )

    def test_xctest_case_name_parser_supports_nested_module_names(self) -> None:
        self.assertEqual(
            conductor.parse_xctest_case_name(
                "-[Company.Product.Tests.DeeplyNestedTests testDeadlineBudget]"
            ),
            ("Company.Product.Tests.DeeplyNestedTests", "testDeadlineBudget"),
        )

    def test_missing_runtime_ledger_logs_once_and_uses_default(self) -> None:
        tmp, state = self.make_state()
        self.addCleanup(tmp.cleanup)
        job = self.make_job(state, "missing-ledger", "test", {}, ["build"], job_state="running")
        state.jobs[job.ticket] = job

        # Step 4: the ledger is consulted once, at the pre-start pin, not per marker.
        state._pin_xctest_method_runtimes(job)
        self.assertIsNone(job.xctest_method_runtimes)
        for method in ["testOne", "testTwo"]:
            state._record_xctest_progress_locked(
                job,
                f"Test Case '-[RepoPromptTests.MissingLedgerTests {method}]' started.\n",
                observed_at=1.0,
            )

        log = job.log_path.read_text(encoding="utf-8")
        self.assertEqual(log.count("XCTest runtime ledger unavailable"), 1)
        self.assertEqual(job.xctest_active_method_budget_seconds, 180.0)
        self.assertEqual(job.xctest_active_method_budget_source, "default")

    def test_negative_runtime_ledger_entry_is_ignored(self) -> None:
        tmp, state = self.make_state()
        self.addCleanup(tmp.cleanup)
        ledger = state.paths.repo_root / "Scripts" / "Fixtures" / "test-suite-contract-ledger.tsv"
        ledger.parent.mkdir(parents=True)
        ledger.write_text(
            "suite\tmethod\truntime_seconds\ttarget\n"
            "RepoPromptTests.NegativeRuntimeTests\ttestMalformed\t-0.01\troot\n",
            encoding="utf-8",
        )
        job = self.make_job(state, "negative-runtime", "test", {}, ["build"], job_state="running")

        state._pin_xctest_method_runtimes(job)
        runtimes = job.xctest_method_runtimes
        state._record_xctest_progress_locked(
            job,
            "Test Case '-[RepoPromptTests.NegativeRuntimeTests testMalformed]' started.\n",
            observed_at=1.0,
        )

        self.assertEqual(runtimes, {})
        self.assertEqual(job.xctest_active_method_budget_seconds, 180.0)
        self.assertEqual(job.xctest_active_method_budget_source, "default")

    def test_synthetic_runtime_ledger_controls_active_budget_and_unknown_method_survives(self) -> None:
        tmp, state = self.make_state()
        self.addCleanup(tmp.cleanup)
        ledger = state.paths.repo_root / "Scripts" / "Fixtures" / "test-suite-contract-ledger.tsv"
        ledger.parent.mkdir(parents=True)
        suite = "Company.Product.Tests.SyntheticDeadlineTests"
        ledger.write_text(
            "suite\tmethod\truntime_seconds\ttarget\n"
            f"{suite}\ttestLedgerHang\t0.001\tprovider\n",
            encoding="utf-8",
        )

        def run_case(ticket: str, method: str, sleep_seconds: float) -> tuple[conductor.Job, float]:
            test_name = f"-[{suite} {method}]"
            child_code = (
                "import time\n"
                f"print(\"Test Case '{test_name}' started.\", flush=True)\n"
                f"time.sleep({sleep_seconds!r})\n"
            )
            argv = [sys.executable, "-u", "-c", child_code]
            job = self.make_job(state, ticket, "test", {}, ["build"], job_state="running")
            job.timeout = 1.5
            job.env["REPOPROMPT_DEV_XCTEST_ACTIVE_FLOOR_SECONDS"] = "0.1"
            state.jobs[job.ticket] = job
            state.active_lanes = {"build": job.ticket}

            def prepare(_request: dict) -> tuple[list[str], list[str], Path, dict[str, str], float]:
                return argv, ["build"], state.paths.repo_root, os.environ.copy(), 1.5

            started_at = time.monotonic()
            with mock.patch.object(conductor, "operation_requires_global_heavy_slot", return_value=False), mock.patch.object(
                conductor, "XCTEST_ACTIVE_METHOD_RUNTIME_PADDING_SECONDS", 0.0
            ), mock.patch.object(
                conductor, "source_snapshot", return_value=None
            ), mock.patch.object(
                state.registry, "prepare", side_effect=prepare
            ), mock.patch.object(
                state, "_xctest_process_snapshot_locked", return_value=(None, [])
            ), mock.patch.object(
                state,
                "_capture_xctest_stall_diagnostics",
                side_effect=lambda _job, diagnostic, _identity: diagnostic,
            ), mock.patch.multiple(
                conductor,
                TERMINATE_GRACE_SECONDS=0.05,
                KILL_GRACE_SECONDS=0.2,
                PROCESS_TREE_POLL_SECONDS=0.01,
            ):
                state._run_job(job.ticket)
            return job, time.monotonic() - started_at

        ledger_job, ledger_elapsed = run_case("ledger-budget", "testLedgerHang", 5.0)
        unknown_job, unknown_elapsed = run_case("default-budget", "testUnknownMethod", 0.6)

        ledger_method = f"-[{suite} testLedgerHang]"
        self.assertEqual(ledger_job.state, "failed")
        self.assertEqual(ledger_job.exit_code, conductor.XCTEST_STALL_FAILURE_EXIT_CODE)
        self.assertIn(ledger_method, ledger_job.error or "")
        self.assertIn("budget=0.100s", ledger_job.error or "")
        self.assertIn("budget source=ledger-derived", ledger_job.error or "")
        self.assertEqual(ledger_job.diagnostics[0]["budgetSource"], "ledger-derived")
        self.assertGreaterEqual(ledger_elapsed, 0.07)
        self.assertLess(ledger_elapsed, 1.2)

        self.assertEqual(unknown_job.state, "completed")
        self.assertEqual(unknown_job.exit_code, 0)
        self.assertEqual(unknown_job.xctest_active_method_budget_source, "default")
        self.assertGreater(unknown_elapsed, ledger_elapsed)

    def make_watchdog_job(
        self,
        state: conductor.DaemonState,
        *,
        wake_probe: bool = False,
    ) -> conductor.Job:
        args: dict[str, object] = {"xctestStallSeconds": 5.0}
        if wake_probe:
            args["xctestStallWakeProbe"] = True
        job = self.make_job(state, "xctest-watchdog", "test", args, ["build"], job_state="running")
        state.jobs[job.ticket] = job
        return job

    def assert_fds_closed(self, fds: list[int]) -> None:
        for fd in fds:
            with self.assertRaises(OSError):
                os.fstat(fd)

    def run_deadline_hang(
        self,
        ticket: str,
        output_lines: list[str],
        *,
        active_budget: float | None = None,
    ) -> conductor.Job:
        tmp, state = self.make_state()
        self.addCleanup(tmp.cleanup)
        child_code = "import time\n" + "".join(
            f"print({line!r}, flush=True)\n" for line in output_lines
        ) + "time.sleep(30)\n"
        argv = [sys.executable, "-u", "-c", child_code]
        args: dict[str, object] = {}
        if active_budget is not None:
            args["xctestStallSeconds"] = active_budget
        job = self.make_job(state, ticket, "test", args, ["build"], job_state="running")
        job.timeout = 5.0
        state.jobs[job.ticket] = job
        state.active_lanes = {"build": job.ticket}

        def prepare(_request: dict) -> tuple[list[str], list[str], Path, dict[str, str], float]:
            return argv, ["build"], state.paths.repo_root, os.environ.copy(), 5.0

        with mock.patch.object(conductor, "operation_requires_global_heavy_slot", return_value=False), mock.patch.object(
            state.registry, "prepare", side_effect=prepare
        ), mock.patch.object(
            state,
            "_xctest_process_snapshot_locked",
            return_value=(None, []),
        ), mock.patch.object(
            state,
            "_capture_xctest_stall_diagnostics",
            side_effect=lambda _job, diagnostic, _identity: diagnostic,
        ), mock.patch.multiple(
            conductor,
            XCTEST_STARTUP_DEADLINE_SECONDS=0.1,
            XCTEST_BETWEEN_METHOD_DEADLINE_SECONDS=0.1,
            TERMINATE_GRACE_SECONDS=0.1,
            KILL_GRACE_SECONDS=0.5,
            PROCESS_TREE_POLL_SECONDS=0.01,
        ):
            state._run_job(job.ticket)

        return job

    def test_startup_deadline_fires_after_build_complete_without_case_start(self) -> None:
        job = self.run_deadline_hang("startup-deadline", ["Build complete! (0.01s)"])

        self.assertEqual(job.state, "failed")
        self.assertEqual(job.exit_code, conductor.XCTEST_STALL_FAILURE_EXIT_CODE)
        self.assertIn("STARTUP", job.error or "")
        self.assertIn("active test method=<none>", job.error or "")
        self.assertEqual(job.diagnostics[0]["phase"], "startup")

    def test_active_method_deadline_names_active_case(self) -> None:
        test_name = "-[RepoPromptTests.DeadlineTests testActiveHang]"
        job = self.run_deadline_hang(
            "active-method-deadline",
            ["Build complete! (0.01s)", f"Test Case '{test_name}' started."],
            active_budget=0.1,
        )

        self.assertEqual(job.state, "failed")
        self.assertEqual(job.exit_code, conductor.XCTEST_STALL_FAILURE_EXIT_CODE)
        self.assertIn("ACTIVE-METHOD", job.error or "")
        self.assertIn(test_name, job.error or "")
        self.assertEqual(job.diagnostics[0]["phase"], "active-method")

    def test_between_method_deadline_fires_after_case_end(self) -> None:
        test_name = "-[RepoPromptTests.DeadlineTests testBetweenHang]"
        job = self.run_deadline_hang(
            "between-method-deadline",
            [
                "Build complete! (0.01s)",
                f"Test Case '{test_name}' started.",
                f"Test Case '{test_name}' passed (0.001 seconds).",
            ],
            active_budget=1.0,
        )

        self.assertEqual(job.state, "failed")
        self.assertEqual(job.exit_code, conductor.XCTEST_STALL_FAILURE_EXIT_CODE)
        self.assertIn("BETWEEN-METHOD", job.error or "")
        self.assertIn("active test method=<none>", job.error or "")
        self.assertEqual(job.diagnostics[0]["phase"], "between-method")

    def test_output_transport_selection_is_pty_only_for_watchdog_non_list_tests(self) -> None:
        tmp, state = self.make_state()
        self.addCleanup(tmp.cleanup)
        jobs = [
            ("build", {}, "pipe"),
            ("test", {}, "pty"),
            ("provider-test", {}, "pty"),
            ("core-test", {}, "pty"),
            ("test", {"xctestDeadlines": False}, "pipe"),
            ("test", {"list": True, "xctestStallSeconds": 5.0}, "pipe"),
            ("test", {"xctestStallSeconds": 5.0}, "pty"),
            ("provider-test", {"xctestStallSeconds": 5.0}, "pty"),
            ("core-test", {"xctestStallSeconds": 5.0}, "pty"),
            ("test", {"xctestStallSeconds": 5.0, "xctestStallWakeProbe": True}, "pty"),
        ]

        for index, (operation, args, expected) in enumerate(jobs):
            with self.subTest(operation=operation, args=args):
                job = self.make_job(state, f"transport-{index}", operation, args, ["build"], "running")
                transport = state._create_process_output_transport(job)
                try:
                    self.assertEqual(transport.kind, expected)
                finally:
                    transport.close_all()

    def test_process_output_transport_closes_native_pty_descriptors_idempotently(self) -> None:
        transport = conductor.ProcessOutputTransport.create("pty")
        fds = [transport.master_fd, transport.slave_fd]
        self.assertTrue(all(isinstance(fd, int) for fd in fds))
        process = mock.Mock(stdout=None)

        transport.attach_process(process)
        transport.close_reader()
        transport.close_all()

        self.assert_fds_closed([int(fd) for fd in fds if fd is not None])

    def test_pty_eio_is_eof_without_waiting_for_popen_to_reap_child(self) -> None:
        transport = conductor.ProcessOutputTransport(kind="pty", master_fd=123)
        process = mock.Mock()

        with mock.patch.object(conductor.os, "read", side_effect=OSError(errno.EIO, "fixture EIO")):
            self.assertEqual(transport.read_chunk(process), b"")

        process.poll.assert_not_called()
        transport.master_fd = None

    def test_output_relay_frames_split_multiple_crlf_unterminated_and_sgr_markers(self) -> None:
        tmp, state = self.make_state()
        self.addCleanup(tmp.cleanup)
        job = self.make_watchdog_job(state)
        job.progress_transport = "pty"
        first = "-[RepoPromptTests.ExampleTests testOne]"
        second = "-[RepoPromptTests.ExampleTests testTwo]"
        chunks = [
            b"\x1b[32mTest Ca",
            (
                f"se '{first}' started.\x1b[0m\r\n"
                f"Test Case '{first}' passed (0.001 seconds).\n"
                "Test Case '-[RepoPromptTests.ExampleTests test"
            ).encode(),
            (
                "Two]' started.\n"
                f"Test Case '{second}' skipped (0.001 seconds)."
            ).encode(),
            b"",
        ]
        transport = mock.Mock()
        transport.read_chunk.side_effect = chunks
        process = mock.Mock()
        log = io.BytesIO()

        state._read_process_output(job.ticket, process, log, transport)

        self.assertEqual(log.getvalue(), b"".join(chunks[:-1]))
        self.assertEqual(job.xctest_progress_sequence, 4)
        self.assertEqual(job.xctest_last_progress_test, second)
        self.assertEqual(job.xctest_last_progress_action, "skipped")
        self.assertIsNone(job.xctest_current_test)
        self.assertEqual(job.xctest_previous_test, second)
        # Step 3 (OD7) tail: ANSI-stripped records, each "\n"-terminated except the
        # unterminated final record.
        self.assertEqual(
            list(job.tail),
            [
                f"Test Case '{first}' started.\n",
                f"Test Case '{first}' passed (0.001 seconds).\n",
                f"Test Case '{second}' started.\n",
                f"Test Case '{second}' skipped (0.001 seconds).",
            ],
        )
        transport.close_reader.assert_called_once_with()

    def test_watchdog_trigger_snapshot_is_immutable_after_later_progress(self) -> None:
        tmp, state = self.make_state()
        self.addCleanup(tmp.cleanup)
        job = self.make_watchdog_job(state)
        job.progress_transport = "pty"
        test_name = "-[RepoPromptTests.ExampleTests testSnapshot]"
        state._record_xctest_progress_locked(
            job,
            f"Test Case '{test_name}' started.\n",
            observed_at=10.0,
        )
        claim = state._claim_xctest_stall_locked(job, observed_at=15.0)
        self.assertIsNotNone(claim)
        state._record_xctest_progress_locked(
            job,
            f"Test Case '{test_name}' passed (0.001 seconds).\n",
            observed_at=16.0,
        )

        with mock.patch.object(state, "_xctest_process_snapshot_locked", return_value=(None, [])), mock.patch.object(
            state,
            "_capture_xctest_stall_diagnostics",
            side_effect=lambda _job, diagnostic, _identity: diagnostic,
        ), mock.patch.object(state, "_terminate_xctest_stalled_job"):
            state._handle_xctest_stall(job.ticket, claim)

        diagnostic = job.diagnostics[-1]
        self.assertEqual(diagnostic["progressTransport"], "pty")
        self.assertEqual(diagnostic["progressSequence"], 1)
        self.assertEqual(diagnostic["lastProgressTest"], test_name)
        self.assertEqual(diagnostic["lastProgressAction"], "started")
        self.assertEqual(diagnostic["lastProgressObservedAt"], 10.0)
        self.assertEqual(diagnostic["currentTest"], test_name)
        self.assertIsNone(diagnostic["previousTest"])
        self.assertEqual(job.xctest_progress_sequence, 2)
        self.assertEqual(job.xctest_last_progress_action, "passed")
        self.assertIsNone(job.xctest_current_test)

    def test_buffered_xctest_marker_streams_on_pty_before_watchdog_capture(self) -> None:
        tmp, state = self.make_state()
        self.addCleanup(tmp.cleanup)
        root = state.paths.repo_root
        test_name = "-[RepoPromptTests.BufferedTests testStreamsBeforeStall]"
        child_code = textwrap.dedent(
            f"""\
            import time
            print("Test Case {test_name!r} started.")
            time.sleep(30)
            """
        )
        argv = [sys.executable, "-c", child_code]
        job = self.make_job(
            state,
            "buffered-xctest-pty",
            "test",
            {"xctestStallSeconds": 0.1},
            ["build"],
            job_state="running",
        )
        job.timeout = 5.0
        state.jobs[job.ticket] = job
        state.active_lanes = {"build": job.ticket}
        opened_fds: list[int] = []
        real_openpty = os.openpty

        def tracking_openpty() -> tuple[int, int]:
            pair = real_openpty()
            opened_fds.extend(pair)
            return pair

        def prepare(_request: dict) -> tuple[list[str], list[str], Path, dict[str, str], float]:
            return argv, ["build"], root, os.environ.copy(), 5.0

        with mock.patch.object(conductor, "operation_requires_global_heavy_slot", return_value=False), mock.patch.object(
            state.registry, "prepare", side_effect=prepare
        ), mock.patch.object(
            conductor.os, "openpty", side_effect=tracking_openpty
        ), mock.patch.object(
            state,
            "_xctest_process_snapshot_locked",
            return_value=(None, []),
        ), mock.patch.object(
            state,
            "_capture_xctest_stall_diagnostics",
            side_effect=lambda _job, diagnostic, _identity: diagnostic,
        ):
            state._run_job(job.ticket)

        log = job.log_path.read_text(encoding="utf-8")
        marker = f"Test Case '{test_name}' started."
        watchdog_line = "XCTest ACTIVE-METHOD deadline triggered"
        self.assertEqual(job.state, "failed")
        self.assertEqual(job.exit_code, conductor.XCTEST_STALL_FAILURE_EXIT_CODE)
        self.assertEqual(job.progress_transport, "pty")
        self.assertGreater(job.xctest_progress_sequence, 0)
        self.assertEqual(job.diagnostics[0]["lastProgressTest"], test_name)
        self.assertEqual(job.diagnostics[0]["lastProgressAction"], "started")
        self.assertEqual(job.diagnostics[0]["currentTest"], test_name)
        self.assertLess(log.index(marker), log.index(watchdog_line))
        self.assertFalse(state._process_tree_alive_locked(job))
        self.assert_fds_closed(opened_fds)

    def test_pty_descriptors_close_when_process_launch_fails(self) -> None:
        tmp, state = self.make_state()
        self.addCleanup(tmp.cleanup)
        job = self.make_watchdog_job(state)
        opened_fds: list[int] = []
        real_openpty = os.openpty

        def tracking_openpty() -> tuple[int, int]:
            pair = real_openpty()
            opened_fds.extend(pair)
            return pair

        with mock.patch.object(conductor, "operation_requires_global_heavy_slot", return_value=False), mock.patch.object(
            conductor.os, "openpty", side_effect=tracking_openpty
        ), mock.patch.object(
            conductor.subprocess,
            "Popen",
            side_effect=OSError("fixture launch failure"),
        ), mock.patch.object(state, "_schedule_locked"), mock.patch.object(state, "_refresh_output_summary"):
            state._run_job(job.ticket)

        self.assertEqual(job.state, "failed")
        self.assertIn("fixture launch failure", job.error or "")
        self.assert_fds_closed(opened_fds)

    def test_output_transport_cleanup_runs_for_success_timeout_and_cancellation(self) -> None:
        for terminal_path in ["success", "timeout", "cancellation"]:
            with self.subTest(terminal_path=terminal_path):
                tmp, state = self.make_state()
                self.addCleanup(tmp.cleanup)
                job = self.make_watchdog_job(state)
                job.ticket = f"cleanup-{terminal_path}"
                job.log_path = state.paths.jobs_dir / f"{job.ticket}.log"
                state.jobs = {job.ticket: job}
                transport = mock.Mock()
                transport.kind = "pty"
                transport.popen_stdout = 101
                transport.popen_stderr = 101
                transport.read_chunk.return_value = b""
                fake_process = mock.Mock(stdout=None)
                fake_process.pid = os.getpid()
                fake_process.poll.return_value = 0
                if terminal_path == "success":
                    fake_process.wait.return_value = 0
                elif terminal_path == "timeout":
                    fake_process.wait.side_effect = [
                        subprocess.TimeoutExpired(["fixture"], 1.0),
                        0,
                    ]
                else:
                    def cancel_then_exit(*_args: object, **_kwargs: object) -> int:
                        job.cancel_requested = True
                        return 0

                    fake_process.wait.side_effect = cancel_then_exit

                with mock.patch.object(conductor, "operation_requires_global_heavy_slot", return_value=False), mock.patch.object(
                    conductor, "source_snapshot", return_value=None
                ), mock.patch.object(
                    state, "_create_process_output_transport", return_value=transport
                ), mock.patch.object(
                    conductor.subprocess,
                    "Popen",
                    return_value=fake_process,
                ), mock.patch.object(
                    conductor,
                    "process_table_snapshot",
                    return_value={os.getpid(): (os.getppid(), "fixture-start")},
                ), mock.patch.object(
                    state,
                    "_terminate_process_group_locked",
                ), mock.patch.object(
                    state,
                    "_kill_process_group_locked",
                ), mock.patch.object(
                    state,
                    "_process_tree_alive_locked",
                    return_value=False,
                ), mock.patch.object(
                    state,
                    "_wait_for_process_tree_exit_locked",
                    return_value=False,
                ), mock.patch.object(state, "_schedule_locked"), mock.patch.object(
                    state,
                    "_refresh_output_summary",
                ):
                    state._run_job(job.ticket)

                transport.attach_process.assert_called_once_with(fake_process)
                transport.close_reader.assert_called()
                transport.close_all.assert_called_once_with()
                if terminal_path == "success":
                    self.assertEqual(job.state, "completed")
                elif terminal_path == "timeout":
                    self.assertTrue(job.timed_out)
                    self.assertEqual(job.exit_code, 124)
                else:
                    self.assertEqual(job.state, "canceled")

    def test_watchdog_triggers_at_most_once_after_started_marker(self) -> None:
        tmp, state = self.make_state()
        self.addCleanup(tmp.cleanup)
        job = self.make_watchdog_job(state)

        matched = state._record_xctest_progress_locked(
            job,
            "Test Case '-[RepoPromptTests.ExampleTests testStall]' started.\n",
            observed_at=10.0,
        )
        first = state._claim_xctest_stall_locked(job, observed_at=15.0)
        second = state._claim_xctest_stall_locked(job, observed_at=50.0)

        self.assertTrue(matched)
        self.assertIsNotNone(first)
        self.assertIsNone(second)
        self.assertTrue(job.xctest_watchdog_triggered)
        self.assertTrue(job.measurement_invalid)

    def test_watchdog_does_not_signal_or_trigger_before_threshold(self) -> None:
        tmp, state = self.make_state()
        self.addCleanup(tmp.cleanup)
        job = self.make_watchdog_job(state, wake_probe=True)
        state._record_xctest_progress_locked(
            job,
            "Test Case '-[RepoPromptTests.ExampleTests testStillRunning]' started.\n",
            observed_at=20.0,
        )

        with mock.patch.object(conductor.os, "kill") as kill:
            claim = state._claim_xctest_stall_locked(job, observed_at=24.999)

        self.assertIsNone(claim)
        self.assertFalse(job.measurement_invalid)
        kill.assert_not_called()

    def test_only_xctest_progress_markers_reset_after_first_started_marker(self) -> None:
        tmp, state = self.make_state()
        self.addCleanup(tmp.cleanup)
        job = self.make_watchdog_job(state)

        ignored = state._record_xctest_progress_locked(
            job,
            "Test Case '-[RepoPromptTests.ExampleTests testBeforeStart]' passed (0.001 seconds).\n",
            observed_at=1.0,
        )
        self.assertFalse(ignored)
        self.assertIsNone(job.xctest_progress_deadline)

        markers = [
            ("started", "", 2.0),
            ("passed", " (0.001 seconds)", 3.0),
            ("failed", " (0.001 seconds)", 4.0),
            ("skipped", " (0.001 seconds)", 5.0),
        ]
        for action, suffix, observed_at in markers:
            with self.subTest(action=action):
                matched = state._record_xctest_progress_locked(
                    job,
                    f"Test Case '-[RepoPromptTests.ExampleTests testProgress]' {action}{suffix}.\n",
                    observed_at=observed_at,
                )
                self.assertTrue(matched)
                budget = (
                    5.0
                    if action == "started"
                    else conductor.XCTEST_BETWEEN_METHOD_DEADLINE_SECONDS
                )
                self.assertEqual(job.xctest_progress_deadline, observed_at + budget)

    def test_unrelated_output_does_not_reset_xctest_progress_deadline(self) -> None:
        tmp, state = self.make_state()
        self.addCleanup(tmp.cleanup)
        job = self.make_watchdog_job(state)
        state._record_xctest_progress_locked(
            job,
            "Test Case '-[RepoPromptTests.ExampleTests testOutput]' started.\n",
            observed_at=30.0,
        )
        original_deadline = job.xctest_progress_deadline

        matched = state._record_xctest_progress_locked(
            job,
            "arbitrary compiler or test diagnostic output\n",
            observed_at=34.0,
        )
        claim = state._claim_xctest_stall_locked(job, observed_at=35.0)

        self.assertFalse(matched)
        self.assertEqual(job.xctest_progress_deadline, original_deadline)
        self.assertIsNotNone(claim)

    def test_wake_probe_rejects_pid_start_token_mismatch(self) -> None:
        tmp, state = self.make_state()
        self.addCleanup(tmp.cleanup)
        job = self.make_watchdog_job(state, wake_probe=True)
        state._record_xctest_progress_locked(
            job,
            "Test Case '-[RepoPromptTests.ExampleTests testIdentity]' started.\n",
            observed_at=1.0,
        )
        claim = state._claim_xctest_stall_locked(job, observed_at=6.0)
        self.assertIsNotNone(claim)

        with mock.patch.object(
            state,
            "_xctest_process_snapshot_locked",
            return_value=((4321, "expected-token"), []),
        ), mock.patch.object(
            state,
            "_capture_xctest_stall_diagnostics",
            side_effect=lambda _job, diagnostic, _identity: diagnostic,
        ), mock.patch.object(
            conductor,
            "process_table_snapshot",
            return_value={4321: (1, "reused-pid-token")},
        ), mock.patch.object(conductor.os, "kill") as kill, mock.patch.object(
            state,
            "_terminate_xctest_stalled_job",
        ) as terminate:
            state._handle_xctest_stall(job.ticket, claim)

        kill.assert_not_called()
        terminate.assert_called_once_with(job)
        self.assertFalse(job.diagnostics[-1]["stopSent"])
        self.assertFalse(job.diagnostics[-1]["continueSent"])

    def test_resumed_progress_after_wake_probe_still_fails_measurement(self) -> None:
        tmp, state = self.make_state()
        self.addCleanup(tmp.cleanup)
        job = self.make_watchdog_job(state, wake_probe=True)
        state._record_xctest_progress_locked(
            job,
            "Test Case '-[RepoPromptTests.ExampleTests testRecovered]' started.\n",
            observed_at=1.0,
        )
        claim = state._claim_xctest_stall_locked(job, observed_at=6.0)
        self.assertIsNotNone(claim)

        with mock.patch.object(
            state,
            "_xctest_process_snapshot_locked",
            return_value=((5432, "stable-token"), []),
        ), mock.patch.object(
            state,
            "_capture_xctest_stall_diagnostics",
            side_effect=lambda _job, diagnostic, _identity: diagnostic,
        ), mock.patch.object(
            state,
            "_signal_process_identity",
            side_effect=[True, True],
        ) as signal_identity, mock.patch.object(
            state,
            "_wait_for_xctest_progress_after_probe",
            return_value=True,
        ), mock.patch.object(state, "_terminate_xctest_stalled_job") as terminate, mock.patch.object(
            conductor.time,
            "sleep",
        ):
            state._handle_xctest_stall(job.ticket, claim)

        state._finalize_process_exit_locked(job, 0)
        self.assertEqual(signal_identity.call_args_list[0].args[2], conductor.signal.SIGSTOP)
        self.assertEqual(signal_identity.call_args_list[1].args[2], conductor.signal.SIGCONT)
        self.assertEqual(signal_identity.call_count, 2)
        terminate.assert_called_once_with(job)
        self.assertTrue(job.diagnostics[-1]["progressResumed"])
        self.assertEqual(job.state, "failed")
        self.assertEqual(job.exit_code, conductor.XCTEST_STALL_FAILURE_EXIT_CODE)
        self.assertTrue(job.measurement_invalid)

    def test_controlled_wake_probe_progress_still_fails_live_job(self) -> None:
        tmp, state = self.make_state()
        self.addCleanup(tmp.cleanup)
        root = state.paths.repo_root
        fake_xctest = root / "ControlledTests.xctest"
        fake_xctest.symlink_to(sys.executable)
        child_code = textwrap.dedent(
            """\
            import time

            test_name = "-[RepoPromptTests.ControlledTests testWakeProbe]"
            print(f"Test Case '{test_name}' started.", flush=True)
            time.sleep(1)
            print(f"Test Case '{test_name}' passed (0.001 seconds).", flush=True)
            """
        )
        parent_code = textwrap.dedent(
            f"""\
            import subprocess
            import sys
            child = subprocess.Popen(
                [{str(fake_xctest)!r}, "-u", "-c", {child_code!r}],
                stdin=subprocess.DEVNULL,
                stdout=sys.stdout,
                stderr=sys.stderr,
            )
            sys.exit(child.wait())
            """
        )
        argv = [sys.executable, "-u", "-c", parent_code]
        job = self.make_job(
            state,
            "controlled-xctest-watchdog",
            "test",
            {"xctestStallSeconds": 0.05, "xctestStallWakeProbe": True},
            ["build"],
            job_state="running",
        )
        job.timeout = 5.0
        state.jobs[job.ticket] = job
        state.active_lanes = {"build": job.ticket}

        def prepare(_request: dict) -> tuple[list[str], list[str], Path, dict[str, str], float]:
            return argv, ["build"], root, os.environ.copy(), 5.0

        def controlled_commands(pids: object) -> dict[int, str]:
            candidates = sorted(int(pid) for pid in pids)
            return {
                pid: (str(fake_xctest) if pid == candidates[-1] else sys.executable)
                for pid in candidates
            }

        fake_tree = [
            {
                "pid": os.getpid(),
                "ppid": os.getppid(),
                "depth": 0,
                "startToken": "fixture-start",
                "command": str(fake_xctest),
            }
        ]
        with mock.patch.object(conductor, "operation_requires_global_heavy_slot", return_value=False), mock.patch.object(
            state.registry, "prepare", side_effect=prepare
        ), mock.patch.object(
            state,
            "_capture_xctest_stall_diagnostics",
            side_effect=lambda _job, diagnostic, _identity: diagnostic,
        ), mock.patch.object(
            state,
            "_xctest_process_snapshot_locked",
            return_value=((os.getpid(), "fixture-start"), fake_tree),
        ), mock.patch.object(state, "_signal_process_identity", return_value=True), mock.patch.object(
            state, "_wait_for_xctest_progress_after_probe", return_value=True
        ), mock.patch.object(conductor, "process_command_snapshot", side_effect=controlled_commands):
            state._run_job(job.ticket)

        self.assertEqual(job.state, "failed")
        self.assertEqual(job.exit_code, conductor.XCTEST_STALL_FAILURE_EXIT_CODE)
        self.assertTrue(job.measurement_invalid)
        self.assertEqual(len(job.diagnostics), 1)
        self.assertTrue(job.diagnostics[0]["stopSent"], job.diagnostics)
        self.assertTrue(job.diagnostics[0]["continueSent"], job.diagnostics)
        self.assertTrue(job.diagnostics[0]["progressResumed"], job.diagnostics)
        self.assertFalse(state._process_tree_alive_locked(job))

    def test_nonresponsive_watchdog_cleanup_escalates_once(self) -> None:
        tmp, state = self.make_state()
        self.addCleanup(tmp.cleanup)
        job = self.make_watchdog_job(state)

        with mock.patch.object(state, "_terminate_process_group_locked") as terminate, mock.patch.object(
            state,
            "_wait_for_process_tree_exit_locked",
            side_effect=[True, True],
        ) as wait_for_exit, mock.patch.object(state, "_kill_process_group_locked") as kill:
            state._terminate_xctest_stalled_job(job)

        terminate.assert_called_once_with(job, reason="XCTest phase deadline fired")
        kill.assert_called_once()
        self.assertEqual(wait_for_exit.call_count, 2)
        self.assertIn("could not confirm descendant exit", job.log_path.read_text(encoding="utf-8"))

    def test_stall_diagnostic_file_is_bounded(self) -> None:
        tmp, state = self.make_state()
        self.addCleanup(tmp.cleanup)
        path = state.paths.jobs_dir / "bounded.sample.txt"
        path.write_bytes(b"a" * 200)

        state._bound_diagnostic_file(path, max_bytes=80)

        data = path.read_bytes()
        self.assertLessEqual(len(data), 80)
        self.assertIn(b"conductor truncated", data)

    def test_default_test_cli_and_jobs_enable_deadlines(self) -> None:
        tmp, state = self.make_state()
        self.addCleanup(tmp.cleanup)
        with mock.patch.object(conductor, "preflight_test_filter"), mock.patch.object(
            conductor, "enqueue_and_maybe_wait", return_value=0
        ) as enqueue:
            code = conductor.handle_real_operation(state.paths, "test", ["--filter", "ExampleTests"])

        self.assertEqual(code, 0)
        self.assertEqual(enqueue.call_args.args[2], {"filter": "ExampleTests"})
        job = self.make_job(state, "default-test", "test", {}, ["build"], job_state="running")
        self.assertTrue(state._xctest_watchdog_enabled(job))
        self.assertTrue(
            state._record_xctest_progress_locked(
                job,
                "Test Case '-[RepoPromptTests.ExampleTests testDefault]' started.\n",
                observed_at=1.0,
            )
        )
        self.assertEqual(
            job.xctest_progress_deadline,
            1.0 + conductor.XCTEST_ACTIVE_METHOD_DEADLINE_SECONDS,
        )

    def test_test_deadline_opt_out_flag_and_environment_use_pipe(self) -> None:
        tmp, state = self.make_state()
        self.addCleanup(tmp.cleanup)
        with mock.patch.object(conductor, "preflight_test_filter"), mock.patch.object(
            conductor, "enqueue_and_maybe_wait", return_value=0
        ) as enqueue:
            code = conductor.handle_real_operation(
                state.paths,
                "test",
                ["--filter", "ExampleTests", "--no-xctest-deadlines"],
            )

        self.assertEqual(code, 0)
        self.assertEqual(
            enqueue.call_args.args[2],
            {"filter": "ExampleTests", "xctestDeadlines": False},
        )
        flag_job = self.make_job(
            state,
            "flag-opt-out",
            "test",
            {"xctestDeadlines": False},
            ["build"],
            job_state="running",
        )
        env_job = self.make_job(
            state,
            "env-opt-out",
            "test",
            {},
            ["build"],
            job_state="running",
        )
        env_job.env["REPOPROMPT_DEV_XCTEST_DEADLINES"] = "0"
        self.assertFalse(state._xctest_watchdog_enabled(flag_job))
        self.assertFalse(state._xctest_watchdog_enabled(env_job))
        self.assertEqual(state._create_process_output_transport(flag_job).kind, "pipe")

    def test_test_cli_forwards_test_product_for_focused_split_targets(self) -> None:
        tmp, state = self.make_state()
        self.addCleanup(tmp.cleanup)
        with mock.patch.object(conductor, "preflight_test_filter"), mock.patch.object(
            conductor, "enqueue_and_maybe_wait", return_value=0
        ) as enqueue:
            code = conductor.handle_real_operation(
                state.paths,
                "test",
                ["--test-product", "RepoPromptWorkspaceTests", "--filter", "WorkspaceTests"],
            )

        self.assertEqual(code, 0)
        self.assertEqual(
            enqueue.call_args.args[2],
            {"filter": "WorkspaceTests", "testProduct": "RepoPromptWorkspaceTests"},
        )

        registry = conductor.OperationRegistry(state.paths.repo_root)
        root_argv, root_lanes, root_cwd, _env, _timeout = registry.prepare(
            {
                "operation": "test",
                "args": {"filter": "WorkspaceTests", "testProduct": "RepoPromptWorkspaceTests"},
            }
        )

        self.assertEqual(
            root_argv,
            [
                str(state.paths.repo_root / "Scripts" / "canonical_swift.sh"),
                "test",
                "--test-product",
                "RepoPromptWorkspaceTests",
                "--filter",
                "WorkspaceTests",
            ],
        )
        self.assertEqual(root_lanes, ["build"])
        self.assertEqual(root_cwd, state.paths.repo_root)

    def test_parallel_test_cli_and_registry_construct_source_validating_job(self) -> None:
        tmp, state = self.make_state()
        self.addCleanup(tmp.cleanup)
        with (
            mock.patch.object(conductor, "preflight_test_filter") as preflight,
            mock.patch.object(
                conductor, "enqueue_and_maybe_wait", return_value=0
            ) as enqueue,
            mock.patch.object(
                conductor,
                "evaluate_test_artifact",
                side_effect=AssertionError("parallel lane must not require a ticket"),
            ),
        ):
            code = conductor.handle_real_operation(
                state.paths,
                "test-parallel",
                ["--workers", "3", "--filter", "RepoPromptTests.AlphaTests"],
            )

        self.assertEqual(code, 0)
        preflight.assert_called_once_with(
            state.paths.repo_root,
            "test-parallel",
            "RepoPromptTests.AlphaTests",
        )
        cli_args = enqueue.call_args.args[2]
        self.assertEqual(
            cli_args,
            {
                "workers": 3,
                "filter": "RepoPromptTests.AlphaTests",
            },
        )

        registry_args = dict(cli_args)
        argv, lanes, cwd, _env, timeout = state.registry.prepare(
            {"operation": "test-parallel", "args": registry_args}
        )

        self.assertEqual(
            argv[:4],
            [
                sys.executable,
                "-u",
                str(Path(conductor.__file__).resolve().with_name("conductor_entry.py")),
                "__operation_runner",
            ],
        )
        payload = json.loads(argv[4])
        self.assertEqual(payload["kind"], "parallel_root_test")
        internal_args = payload["args"]
        self.assertEqual(internal_args["workers"], 3)
        self.assertEqual(
            internal_args["filter"], "RepoPromptTests.AlphaTests"
        )
        run_id = internal_args["parallelRunId"]
        self.assertEqual(
            Path(internal_args["parallelCandidate"]).name,
            f"parallel-xctest-{run_id}-candidate.json",
        )
        self.assertEqual(
            Path(internal_args["parallelTestList"]).parent,
            state.paths.jobs_dir,
        )
        self.assertEqual(
            Path(internal_args["parallelWorkdir"]).parent,
            state.paths.jobs_dir,
        )
        other_args: dict[str, object] = {"workers": 3}
        state.registry.prepare(
            {"operation": "test-parallel", "args": other_args}
        )
        self.assertNotEqual(
            other_args["parallelRunId"], internal_args["parallelRunId"]
        )
        self.assertEqual(lanes, ["build"])
        self.assertEqual(cwd, state.paths.repo_root)
        self.assertEqual(timeout, conductor.MEDIUM_TIMEOUT_SECONDS)
        self.assertTrue(
            conductor.operation_invalidates_root_build_ticket(
                "test-parallel", registry_args
            )
        )
        self.assertTrue(
            conductor.operation_requires_global_heavy_slot(
                "test-parallel", registry_args
            )
        )
        self.assertTrue(
            conductor.operation_requires_global_xctest_slot(
                "test-parallel", registry_args
            )
        )
        watchdog_job = self.make_job(
            state,
            "parallel-watchdog",
            "test-parallel",
            registry_args,
            ["build"],
            job_state="running",
        )
        self.assertFalse(state._xctest_watchdog_enabled(watchdog_job))

    def test_test_list_cli_preserves_build_lane_and_package_roots(self) -> None:
        tmp, state = self.make_state()
        self.addCleanup(tmp.cleanup)
        with mock.patch.object(conductor, "enqueue_and_maybe_wait", return_value=0) as enqueue:
            code = conductor.handle_real_operation(state.paths, "test", ["--list"])

        self.assertEqual(code, 0)
        self.assertEqual(enqueue.call_args.args[2], {"list": True})

        registry = conductor.OperationRegistry(state.paths.repo_root)
        root_argv, root_lanes, root_cwd, _env, _timeout = registry.prepare(
            {"operation": "test", "args": {"list": True}}
        )
        provider_argv, provider_lanes, provider_cwd, _env, _timeout = registry.prepare(
            {"operation": "provider-test", "args": {"list": True}}
        )
        core_argv, core_lanes, core_cwd, _env, _timeout = registry.prepare(
            {"operation": "core-test", "args": {"list": True}}
        )

        canonical_swift = str(state.paths.repo_root / "Scripts" / "canonical_swift.sh")
        self.assertEqual(root_argv, [canonical_swift, "test", "list"])
        self.assertEqual(root_lanes, ["build"])
        self.assertEqual(root_cwd, state.paths.repo_root)
        self.assertEqual(provider_argv, [canonical_swift, "test", "list"])
        self.assertEqual(provider_lanes, ["build"])
        self.assertEqual(
            provider_cwd,
            state.paths.repo_root / "Packages" / "RepoPromptAgentProviders",
        )
        self.assertEqual(core_argv, [canonical_swift, "test", "list"])
        self.assertEqual(core_lanes, ["build"])
        self.assertEqual(core_cwd, state.paths.repo_root / "Packages" / "RepoPromptCore")

    def test_test_list_rejects_filters_and_stall_diagnostics(self) -> None:
        tmp, state = self.make_state()
        self.addCleanup(tmp.cleanup)
        with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
            conductor.handle_real_operation(state.paths, "test", ["--list", "--filter", "ExampleTests"])
        with self.assertRaisesRegex(conductor.ConductorError, "cannot be combined"):
            conductor.handle_real_operation(
                state.paths,
                "provider-test",
                ["--list", "--xctest-stall-seconds", "10"],
            )
        with self.assertRaisesRegex(conductor.ConductorError, "cannot be combined"):
            conductor.handle_real_operation(
                state.paths,
                "test",
                ["--list", "--test-product", "RepoPromptWorkspaceTests"],
            )

        registry = conductor.OperationRegistry(state.paths.repo_root)
        with self.assertRaisesRegex(conductor.ConductorError, "cannot be combined with a filter"):
            registry.prepare(
                {
                    "operation": "test",
                    "args": {"list": True, "filter": "ExampleTests"},
                }
            )
        with self.assertRaisesRegex(conductor.ConductorError, "cannot be combined with --test-product"):
            registry.prepare(
                {
                    "operation": "test",
                    "args": {"list": True, "testProduct": "RepoPromptWorkspaceTests"},
                }
            )

    def test_test_gate_environment_survives_client_snapshot_and_job_prepare(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            registry = conductor.OperationRegistry(Path(tmp))
            with mock.patch.dict(
                os.environ,
                {
                    "RPCE_ENABLE_BENCHMARK_TESTS": "1",
                    "RPCE_RUN_CODEMAP_E2E": "1",
                    "RPCE_RUN_SCALE_TESTS": "1",
                    "RPCE_UNRELATED_TEST_GATE": "1",
                },
                clear=False,
            ):
                snapshot = conductor.OperationRegistry.client_env_snapshot()

            self.assertEqual(snapshot["RPCE_ENABLE_BENCHMARK_TESTS"], "1")
            self.assertEqual(snapshot["RPCE_RUN_CODEMAP_E2E"], "1")
            self.assertEqual(snapshot["RPCE_RUN_SCALE_TESTS"], "1")
            self.assertNotIn("RPCE_UNRELATED_TEST_GATE", snapshot)

            _argv, _lanes, _cwd, env, _timeout = registry.prepare(
                {
                    "operation": "test",
                    "args": {"filter": "CodemapBindingEngineProjectionTests"},
                    "env": snapshot,
                }
            )

        self.assertEqual(env["RPCE_ENABLE_BENCHMARK_TESTS"], "1")
        self.assertEqual(env["RPCE_RUN_CODEMAP_E2E"], "1")
        self.assertEqual(env["RPCE_RUN_SCALE_TESTS"], "1")
        self.assertNotIn("RPCE_UNRELATED_TEST_GATE", env)

    def test_launchd_plist_keeps_request_gates_out_of_daemon_environment(self) -> None:
        tmp, state = self.make_state()
        self.addCleanup(tmp.cleanup)
        with mock.patch.dict(
            os.environ,
            {
                "RPCE_RUN_SCALE_TESTS": "1",
                "GITHUB_TOKEN": "secret",
            },
            clear=False,
        ):
            plist_path = conductor.write_daemon_launchd_plist(
                state.paths, state.paths.repo_root / "Scripts" / "conductor.py"
            )
            snapshot = conductor.OperationRegistry.client_env_snapshot()

        payload = conductor.plistlib.loads(plist_path.read_bytes())
        self.assertEqual(
            payload["EnvironmentVariables"],
            {
                "REPOPROMPT_DEV_DAEMON_STATE_DIR": str(state.paths.state_dir),
                "REPOPROMPT_DEV_DAEMON_SOCKET": str(state.paths.socket_path),
            },
        )
        self.assertEqual(snapshot["RPCE_RUN_SCALE_TESTS"], "1")
        self.assertNotIn("GITHUB_TOKEN", snapshot)

        registry = conductor.OperationRegistry(state.paths.repo_root)
        _argv, _lanes, _cwd, job_env, _timeout = registry.prepare(
            {
                "operation": "test-parallel",
                "args": {"workers": 2},
                "env": snapshot,
            }
        )
        self.assertEqual(job_env["RPCE_RUN_SCALE_TESTS"], "1")
        self.assertNotIn("GITHUB_TOKEN", job_env)

    def test_test_cli_forwards_watchdog_options_and_requires_threshold(self) -> None:
        tmp, state = self.make_state()
        self.addCleanup(tmp.cleanup)
        with mock.patch.object(conductor, "preflight_test_filter"), mock.patch.object(
            conductor, "enqueue_and_maybe_wait", return_value=0
        ) as enqueue:
            code = conductor.handle_real_operation(
                state.paths,
                "test",
                [
                    "--filter",
                    "ExampleTests",
                    "--xctest-stall-seconds",
                    "12.5",
                    "--xctest-stall-wake-probe",
                ],
            )

        self.assertEqual(code, 0)
        self.assertEqual(
            enqueue.call_args.args[2],
            {
                "filter": "ExampleTests",
                "xctestStallSeconds": 12.5,
                "xctestStallWakeProbe": True,
            },
        )
        with self.assertRaisesRegex(conductor.ConductorError, "requires --xctest-stall-seconds"):
            conductor.handle_real_operation(state.paths, "test", ["--xctest-stall-wake-probe"])


class XCTestOutputContractLifecycleTests(LifecycleTestCase):
    """OD16 through the real job lifecycle: a PTY child, the reader, the monitor and finalization."""

    START_A = b"Test Case '-[M.S testA]' started.\n"
    # argv: payload path, comma-separated flags, go-file path. Flags: exit (no tick
    # loop), ignore-term, spawn (a TERM-ignoring descendant in the job's process
    # group that holds the PTY), wait-go (after the payload, wait up to 15 s for the
    # go file), relay (then write one "after-failure" line).
    CHILD = textwrap.dedent(
        """\
        import os, signal, subprocess, sys, time
        flags = sys.argv[2].split(",")
        if "ignore-term" in flags:
            signal.signal(signal.SIGTERM, signal.SIG_IGN)
        if "spawn" in flags:
            subprocess.Popen([sys.executable, "-c", "import signal, time; signal.signal(signal.SIGTERM, signal.SIG_IGN); time.sleep(60)"])
        data = open(sys.argv[1], "rb").read()
        out = sys.stdout.buffer
        for index in range(0, len(data), 8192):
            out.write(data[index:index + 8192])
            out.flush()
        if "wait-go" in flags:
            deadline = time.monotonic() + 15.0
            while not os.path.exists(sys.argv[3]) and time.monotonic() < deadline:
                time.sleep(0.005)
        if "relay" in flags:
            out.write(b"after-failure\\n")
            out.flush()
        while "exit" not in flags:
            out.write(b"tick\\n")
            out.flush()
            time.sleep(0.01)
        """
    )

    @staticmethod
    def pending(count: int) -> bytes:
        markers = b"".join(b"\x0bTest Case '-[M.S t%d]' started." % index for index in range(count))
        return b"q" * 70000 + markers + b"\x0b\n"

    def run_child(
        self, ticket: str, payload: bytes, mode: str = "exit", ledger: bool = True
    ) -> tuple[conductor.Job, Path, float]:
        tmp, state = self.make_state()
        self.addCleanup(tmp.cleanup)
        self.last_state = state
        root = state.paths.repo_root
        ConductorTestContractTests.initialize_git_repo(self, root)
        ConductorTestContractTests.create_test_artifact(self, root)
        if ledger:
            # A curated ledger exists in real checkouts. No row matches M.S, so budgets stay
            # default-sourced. Without it, Step 4's pre-start "ledger unavailable" diagnostic
            # (a FAILURE_RE line) precedes the child's output; see the missing-ledger test.
            ledger_path = conductor._test_ledger_path(root)
            ledger_path.parent.mkdir(parents=True, exist_ok=True)
            ledger_path.write_text(
                "suite\tmethod\truntime_seconds\ttarget\nOther.Suite\ttestOther\t1.0\troot\n", encoding="utf-8"
            )
        payload_path = state.paths.jobs_dir / f"{ticket}.payload"
        payload_path.write_bytes(payload)
        go_path = state.paths.jobs_dir / f"{ticket}.go"
        argv = [sys.executable, "-u", "-c", self.CHILD, str(payload_path), mode, str(go_path)]
        job = self.make_job(state, ticket, "test", {}, ["build"], job_state="running")
        job.timeout = 20.0
        state.jobs[job.ticket] = job
        state.active_lanes = {"build": job.ticket}

        def prepare(_request: dict) -> tuple[list[str], list[str], Path, dict[str, str], float]:
            return argv, ["build"], root, os.environ.copy(), 20.0

        started = time.monotonic()
        with mock.patch.object(conductor, "operation_requires_global_heavy_slot", return_value=False), mock.patch.object(
            state.registry, "prepare", side_effect=prepare
        ), mock.patch.object(
            conductor,
            "artifact_toolchain_snapshot",
            return_value={"swift_version": "Swift test", "arch": "testarch", "config": "debug"},
        ), mock.patch.multiple(
            conductor,
            TERMINATE_GRACE_SECONDS=0.2,
            KILL_GRACE_SECONDS=1.0,
            PROCESS_TREE_POLL_SECONDS=0.01,
        ):
            state._run_job(job.ticket)
        elapsed = time.monotonic() - started
        self.assertFalse(state._process_tree_alive_locked(job))
        self.assertEqual(job.progress_transport, "pty")
        return job, state.paths.jobs_dir / "build-ticket-root.json", elapsed

    def assert_failed_visibly(self, job: conductor.Job, ticket_path: Path, boundary: str) -> str:
        rendered, log = self.assert_failed_visibly_contract(job, ticket_path, boundary)
        # With no FAILURE_RE line before the oversized record, no summary section holds it.
        self.assertNotIn("9" * 200, rendered)
        return log

    def assert_failed_visibly_contract(self, job: conductor.Job, ticket_path: Path, boundary: str) -> tuple[str, str]:
        """OD16's visible failure: state, exit, bounded output-free reason, no artifact, own log line."""
        reason = job.error or ""
        self.assertEqual(job.state, "failed")
        self.assertEqual(job.exit_code, conductor.XCTEST_STALL_FAILURE_EXIT_CODE)
        self.assertTrue(reason.startswith("XCTest output contract failure (OD16): "), reason)
        self.assertLess(len(reason), 300)
        self.assertNotIn("9999", reason)
        self.assertNotIn("nnnn", reason)
        self.assertEqual(job.result_summary, reason)
        self.assertEqual(job.xctest_output_failure, reason)
        self.assertTrue(job.measurement_invalid)
        self.assertFalse(job.timed_out)
        self.assertEqual([d["boundary"] for d in job.diagnostics if d.get("kind") == "xctest-output-contract"], [boundary])
        self.assertFalse(ticket_path.exists(), "no success artifact from a failed job")
        payload = job.to_payload()
        self.assertEqual((payload["state"], payload["error"], payload["measurementInvalid"]), ("failed", reason, True))
        # The client renders the bounded reason without echoing the oversized output.
        with contextlib.redirect_stdout(io.StringIO()) as rendered:
            conductor.print_terminal_job_output(payload)
        self.assertIn(f"Error:    {reason}\n", rendered.getvalue())
        log = job.log_path.read_bytes()
        # The reason is its own log line, even after an unterminated oversized line.
        self.assertIn(b"\n" + reason.encode() + b"\n", log)
        return rendered.getvalue(), log.decode("utf-8", errors="replace")

    def test_missing_ledger_d1_failure_keeps_the_od16_contract_and_bounds_summary_context(self) -> None:
        payload = self.START_A + b"Test Case '-[M.S testA]' passed (" + b"9" * 70000 + b").\n"
        writes: list[tuple[bytes, bool]] = []
        with record_log_writes(lambda: self.last_state, writes):
            job, ticket_path, _elapsed = self.run_child("od16-d1-no-ledger", payload, ledger=False)
        rendered, log = self.assert_failed_visibly_contract(job, ticket_path, "segment")
        # Fallback: one diagnostic, default budget (clamped to the 20 s job timeout).
        self.assertEqual(log.count("XCTest runtime ledger unavailable"), 1)
        self.assertEqual(job.xctest_active_method_budget_source, "default")
        self.assertEqual(job.xctest_active_method_budget_seconds, 20.0)
        self.assertEqual(log.count("XCTest active-method budget clamped from 180.000s to job timeout 20.000s"), 1)
        # Order: start line, diagnostic, then the child's output.
        start = log.index("$ ")
        diagnostic = log.index("XCTest runtime ledger unavailable")
        self.assertLess(start, diagnostic)
        self.assertLess(diagnostic, log.index("Test Case '-[M.S testA]' started."))
        # Both system lines are written to the log outside the condition.
        for needle in (b"XCTest runtime ledger unavailable", b"budget clamped"):
            owners = [owned for data, owned in writes if needle in data]
            self.assertEqual(owners, [False], needle)
        # The diagnostic is a FAILURE_RE line, so ordinary summary context may show the
        # oversized record, but only as a bounded display line; the reason stays output-free.
        self.assertIn("XCTest runtime ledger unavailable", rendered)
        longest = max(len(line) for line in rendered.splitlines())
        self.assertLessEqual(longest, conductor.SUMMARY_LINE_MAX_CHARS + 8)
        self.assertNotIn("9" * conductor.SUMMARY_LINE_MAX_CHARS, rendered)
        self.assertLessEqual(len(rendered), conductor.SUMMARY_MAX_CHARS + 4096)

    def test_d1_and_d2_fail_the_job_although_the_child_exits_zero(self) -> None:
        cases = {
            "d1a-huge-parenthetical": (self.START_A + b"Test Case '-[M.S testA]' passed (" + b"9" * 70000 + b").\n", "segment"),
            "d1b-huge-name": (b"Test Case '-[M.S t" + b"n" * 70000 + b"]' started.\n", "segment"),
            "d1-eof-without-newline": (self.START_A + b"Test Case '-[M.S testA]' passed (" + b"9" * 70000 + b").", "segment"),
            "d2c-seventeen-pending": (self.START_A + self.pending(17), "pending"),
        }
        for name, (payload, boundary) in cases.items():
            with self.subTest(case=name):
                job, ticket_path, _elapsed = self.run_child(f"od16-{name}", payload)
                self.assert_failed_visibly(job, ticket_path, boundary)
                self.assertNotEqual(job.xctest_last_progress_action, "passed")
                if name == "d2c-seventeen-pending":
                    self.assertEqual(job.xctest_current_test, "-[M.S testA]")  # none of the 17 applied

    def test_at_bound_and_non_marker_records_complete_and_publish_normally(self) -> None:
        cases = {
            "d2b-sixteen-pending": self.START_A + self.pending(16),
            "non-marker-large": self.START_A + b"Test Case '" + b"x" * 70000 + b" no end\n" + b"' started.".rjust(70000, b"y") + b"\n",
        }
        for name, payload in cases.items():
            with self.subTest(case=name):
                job, ticket_path, _elapsed = self.run_child(f"od16-ok-{name}", payload)
                self.assertEqual((job.state, job.exit_code), ("completed", 0), job.result_summary)
                self.assertIsNone(job.xctest_output_failure)
                self.assertFalse(job.measurement_invalid)
                self.assertTrue(ticket_path.is_file())
                expected = "-[M.S t15]" if name == "d2b-sixteen-pending" else "-[M.S testA]"
                self.assertEqual(job.xctest_current_test, expected)

    def test_the_first_failure_keeps_its_reason(self) -> None:
        tmp, state = self.make_state()
        self.addCleanup(tmp.cleanup)
        job = self.make_job(state, "od16-first", "test", {}, ["build"], job_state="running")
        state.jobs[job.ticket] = job
        state._fail_xctest_output_contract(job.ticket, "pending", 3)
        reason = job.error
        with state.condition:
            job.xctest_deadline_phase = "startup"
            job.xctest_progress_deadline = 0.0
            # A due stall deadline never overrides the output contract failure.
            self.assertIsNone(state._claim_xctest_stall_locked(job, observed_at=1e9))
        self.assertFalse(job.xctest_watchdog_triggered)
        state._fail_xctest_output_contract(job.ticket, "segment", 9)
        self.assertEqual((job.error, job.xctest_output_failure, len(job.diagnostics)), (reason, reason, 1))
        # An earlier stall claim keeps its own error; the output failure is still recorded.
        stalled = self.make_job(state, "od16-after-stall", "test", {}, ["build"], job_state="running")
        state.jobs[stalled.ticket] = stalled
        stalled.measurement_invalid = True
        stalled.error = "XCTest STARTUP deadline fired after 1.000s; active test method=<none>"
        state._fail_xctest_output_contract(stalled.ticket, "segment", 2)
        self.assertEqual(stalled.error, "XCTest STARTUP deadline fired after 1.000s; active test method=<none>")
        self.assertTrue((stalled.xctest_output_failure or "").startswith("XCTest output contract failure (OD16): "))
        self.assertEqual(stalled.diagnostics[-1]["boundary"], "segment")

    def test_failure_terminates_a_child_that_keeps_writing_and_drains_its_output(self) -> None:
        # S3-R3-01: synchronized instead of scheduling-dependent. The child writes
        # "after-failure" only once the failure is recorded (go file), and the
        # monitor's termination starts only after the reader relayed that line.
        original_fail = conductor.DaemonState._fail_xctest_output_contract
        original_submit = conductor.DaemonState._submit_output_records
        original_terminate = conductor.DaemonState._terminate_xctest_stalled_job
        for mode in ("run", "ignore-term"):
            with self.subTest(mode=mode):
                relayed = threading.Event()
                waited: list[bool] = []

                def fail(state_self, ticket, *args, **kwargs):
                    original_fail(state_self, ticket, *args, **kwargs)
                    (state_self.paths.jobs_dir / f"{ticket}.go").touch()

                def submit(state_self, ticket, records, *args, **kwargs):
                    if any("after-failure" in str(record[2]) for record in records):
                        relayed.set()
                    return original_submit(state_self, ticket, records, *args, **kwargs)

                def terminate(state_self, job, *args, **kwargs):
                    waited.append(relayed.wait(10.0))
                    return original_terminate(state_self, job, *args, **kwargs)

                with mock.patch.multiple(
                    conductor.DaemonState,
                    _fail_xctest_output_contract=fail,
                    _submit_output_records=submit,
                    _terminate_xctest_stalled_job=terminate,
                ):
                    job, ticket_path, elapsed = self.run_child(
                        f"od16-{mode}", self.START_A + self.pending(17), f"{mode},wait-go,relay"
                    )
                log = self.assert_failed_visibly(job, ticket_path, "pending")
                self.assertEqual(waited, [True])  # the monitor terminated only after the relay
                self.assertLess(elapsed, 15.0)  # terminated by the monitor, not the 20 s job timeout
                # The reader kept relaying output after the failure until the child died.
                self.assertIn("after-failure", log[log.index("XCTest output contract failure"):])

    # OracleA round 3 (S3-R0-03): a reader still alive after both bounded joins
    # must not let the job succeed, and resuming it later must not revive success.

    def held(self, method: str):
        """Patch ``DaemonState.<method>`` so its first call blocks (the reader) until released."""
        original = getattr(conductor.DaemonState, method)
        entered, release = threading.Event(), threading.Event()
        threads: list[threading.Thread] = []

        def wrapper(state_self, *args, **kwargs):
            if not entered.is_set():
                threads.append(threading.current_thread())
                entered.set()
                self.assertTrue(release.wait(30.0))
            return original(state_self, *args, **kwargs)

        return mock.patch.object(conductor.DaemonState, method, wrapper), entered, release, threads

    def run_with_held_reader(self, ticket: str, payload: bytes, method: str, mode: str = "exit", on_hold=None):
        patch, entered, release, threads = self.held(method)
        errors: list[object] = []
        before = set(threading.enumerate())
        if on_hold is not None:
            original_wait = entered.wait

        try:
            with patch, mock.patch.object(conductor, "OUTPUT_READER_JOIN_SECONDS", 0.2), mock.patch.object(
                threading, "excepthook", errors.append
            ):
                if on_hold is not None:
                    starter = threading.Thread(target=lambda: (original_wait(20.0), on_hold()), daemon=True)
                    starter.start()
                job, ticket_path, elapsed = self.run_child(ticket, payload, mode)
                self.assertTrue(entered.is_set())
                self.assertEqual(len(threads), 1)
                # Held beyond both joins: the reader is still alive after _run_job returned.
                self.assertTrue(threads[0].is_alive())
                self.assertGreaterEqual(elapsed, 0.4)
                outcome = (job.state, job.exit_code, job.error, ticket_path.exists())
                release.set()
                threads[0].join(10.0)
                self.assertFalse(threads[0].is_alive())
                deadline = time.monotonic() + 5.0
                while time.monotonic() < deadline and [t for t in threading.enumerate() if t not in before and t.is_alive()]:
                    time.sleep(0.01)
                self.assertEqual([t.name for t in threading.enumerate() if t not in before and t.is_alive()], [])
        finally:
            release.set()
        self.assertEqual(errors, [])  # the resumed reader ended without an exception
        return job, ticket_path, outcome

    def assert_reader_incomplete_failure(self, job: conductor.Job, ticket_path: Path, outcome) -> str:
        state_, exit_code, error, ticket_existed = outcome
        self.assertEqual((state_, exit_code), ("failed", conductor.XCTEST_STALL_FAILURE_EXIT_CODE))
        self.assertTrue((error or "").startswith("XCTest output reader did not finish within 0.4s"), error)
        self.assertLess(len(error), 300)
        self.assertFalse(ticket_existed, "no success artifact before the reader resumed")
        # After the reader resumed and finished: still failed, same reason, no ticket.
        self.assertEqual((job.state, job.exit_code, job.error, job.result_summary), ("failed", exit_code, error, error))
        self.assertTrue(job.measurement_invalid)
        self.assertFalse(ticket_path.exists(), "a resumed reader never publishes a success artifact")
        incomplete = [d for d in job.diagnostics if d.get("kind") == "xctest-output-reader-incomplete"]
        self.assertEqual([(d["joinSeconds"], d["outcomeChanged"]) for d in incomplete], [(0.4, True)])
        with contextlib.redirect_stdout(io.StringIO()) as rendered:
            conductor.print_terminal_job_output(job.to_payload())
        self.assertIn(f"Error:    {error}\n", rendered.getvalue())
        log = job.log_path.read_bytes()
        self.assertIn(b"\n" + error.encode() + b"\n", log)
        return log.decode("utf-8", errors="replace")

    def test_a_reader_held_before_its_failure_report_beyond_both_joins_fails_the_job(self) -> None:
        cases = {
            "d2c": (self.START_A + self.pending(17), "pending"),
            # The log then ends mid-line, so the guard's reason starts a new line.
            "d1-eof-without-newline": (self.START_A + b"Test Case '-[M.S testA]' passed (" + b"9" * 70000 + b").", "segment"),
        }
        for name, (payload, boundary) in cases.items():
            with self.subTest(case=name):
                job, ticket_path, outcome = self.run_with_held_reader(
                    f"od16-held-{name}", payload, "_fail_xctest_output_contract"
                )
                self.assert_reader_incomplete_failure(job, ticket_path, outcome)
                # The late OD16 report is recorded but changes neither the outcome nor its reason.
                self.assertTrue((job.xctest_output_failure or "").startswith("XCTest output contract failure (OD16): "))
                self.assertEqual(
                    [d["boundary"] for d in job.diagnostics if d.get("kind") == "xctest-output-contract"], [boundary]
                )
                self.assertEqual(job.xctest_current_test, "-[M.S testA]")  # nothing of the failed record applied

    def test_a_reader_held_without_any_od16_failure_still_cannot_succeed(self) -> None:
        payload = self.START_A + b"Test Case '-[M.S testA]' passed (0.001 seconds).\n"
        job, ticket_path, outcome = self.run_with_held_reader("od16-held-ok", payload, "_submit_output_records")
        self.assert_reader_incomplete_failure(job, ticket_path, outcome)
        self.assertIsNone(job.xctest_output_failure)
        self.assertEqual(job.xctest_last_progress_action, "passed")  # applied late, outcome unchanged

    def test_the_reader_guard_terminates_remaining_job_processes(self) -> None:
        # The root exits 0 after the reader is held, leaving a TERM-ignoring
        # descendant that holds the PTY; the guard's TERM/KILL escalation ends it
        # (run_child asserts the process tree is gone).
        holder: dict[str, object] = {}

        def on_hold() -> None:
            state_self, job = holder["state"], holder["job"]
            with state_self.condition:
                # The conductor knows the descendant while the root is alive.
                self.assertTrue(state_self._process_tree_alive_locked(job))
            (state_self.paths.jobs_dir / "od16-held-tree.go").touch()

        original_make_job = self.make_job

        def make_job(state, *args, **kwargs):
            job = original_make_job(state, *args, **kwargs)
            holder["state"], holder["job"] = state, job
            return job

        payload = self.START_A + self.pending(17)
        with mock.patch.object(self, "make_job", make_job):
            job, ticket_path, outcome = self.run_with_held_reader(
                "od16-held-tree", payload, "_fail_xctest_output_contract", "exit,spawn,wait-go", on_hold
            )
        log = self.assert_reader_incomplete_failure(job, ticket_path, outcome)
        self.assertIn("killing process tree: XCTest output reader incomplete; SIGKILL after grace period", log)

    def test_the_reader_guard_keeps_a_decided_outcome_and_spares_other_operations(self) -> None:
        tmp, state = self.make_state()
        self.addCleanup(tmp.cleanup)
        cases = {
            "nonzero-exit": (1, {}),
            "timed-out": (0, {"timed_out": True, "error": "timed out after 1.0s"}),
            "stalled": (0, {"measurement_invalid": True, "error": "XCTest STARTUP deadline fired"}),
            "canceled": (0, {"cancel_requested": True}),
        }
        for name, (exit_code, fields) in cases.items():
            with self.subTest(case=name):
                job = self.make_job(state, f"guard-{name}", "test", {}, ["build"], job_state="running")
                state.jobs[job.ticket] = job
                for field, value in fields.items():
                    setattr(job, field, value)
                before = (job.measurement_invalid, job.error)
                state._fail_incomplete_xctest_output_reader(job, exit_code)
                self.assertEqual((job.measurement_invalid, job.error), before)
                self.assertEqual([d["outcomeChanged"] for d in job.diagnostics], [False])
        # Only classifying (watchdog-enabled) jobs are guarded.
        build = self.make_job(state, "guard-build", "build", {}, ["build"], job_state="running")
        self.assertFalse(state._xctest_watchdog_enabled(build))


class ProcessTreeCancellationTests(LifecycleTestCase):
    def wait_until(self, predicate, timeout: float = 5.0) -> bool:
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if predicate():
                return True
            time.sleep(0.01)
        return bool(predicate())

    def process_identity_alive(self, pid: int, start_token: str) -> bool:
        record = conductor.process_table_snapshot().get(pid)
        return record is not None and record[1] == start_token

    def run_detached_descendant_fixture(self, termination: str) -> None:
        tmp, state = self.make_state()
        self.addCleanup(tmp.cleanup)
        root = state.paths.repo_root
        parent_path = root / f"{termination}-parent.json"
        child_path = root / f"{termination}-child.json"
        child_code = textwrap.dedent(
            """\
            import json
            import os
            import signal
            import sys
            import time
            from pathlib import Path

            marker = Path(sys.argv[1])
            signal.signal(signal.SIGTERM, signal.SIG_IGN)
            marker.write_text(json.dumps({
                "pid": os.getpid(),
                "ppid": os.getppid(),
                "pgid": os.getpgid(0),
                "sid": os.getsid(0),
            }), encoding="utf-8")
            while True:
                time.sleep(0.1)
            """
        )
        parent_code = textwrap.dedent(
            f"""\
            import json
            import os
            import subprocess
            import sys
            import time
            from pathlib import Path

            parent_marker = Path(sys.argv[1])
            child_marker = Path(sys.argv[2])
            child = subprocess.Popen(
                [sys.executable, "-u", "-c", {child_code!r}, str(child_marker)],
                stdin=subprocess.DEVNULL,
                stdout=sys.stdout,
                stderr=sys.stderr,
                start_new_session=True,
            )
            parent_marker.write_text(json.dumps({{
                "pid": os.getpid(),
                "ppid": os.getppid(),
                "pgid": os.getpgid(0),
                "sid": os.getsid(0),
                "childPID": child.pid,
            }}), encoding="utf-8")
            while True:
                time.sleep(0.1)
            """
        )
        argv = [sys.executable, "-u", "-c", parent_code, str(parent_path), str(child_path)]
        job = self.make_job(state, f"tree-{termination}", "test", {}, ["build"], job_state="running")
        job.timeout = 0.25 if termination == "timeout" else 30.0
        state.jobs[job.ticket] = job
        state.active_lanes = {"build": job.ticket}
        unrelated = subprocess.Popen(
            [sys.executable, "-u", "-c", "import time; time.sleep(30)"],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            start_new_session=True,
        )

        def cleanup_unrelated() -> None:
            if unrelated.poll() is None:
                unrelated.terminate()
                try:
                    unrelated.wait(timeout=1.0)
                except subprocess.TimeoutExpired:
                    unrelated.kill()
                    unrelated.wait(timeout=1.0)

        self.addCleanup(cleanup_unrelated)

        def prepare(_request: dict) -> tuple[list[str], list[str], Path, dict[str, str], float]:
            return argv, ["build"], root, os.environ.copy(), float(job.timeout or 30.0)

        with mock.patch.object(conductor, "operation_requires_global_heavy_slot", return_value=False), mock.patch.object(
            state.registry, "prepare", side_effect=prepare
        ), mock.patch.multiple(
            conductor,
            TERMINATE_GRACE_SECONDS=0.2,
            KILL_GRACE_SECONDS=1.0,
            PROCESS_TREE_POLL_SECONDS=0.02,
        ):
            runner = threading.Thread(target=state._run_job, args=(job.ticket,))
            runner.start()
            self.assertTrue(self.wait_until(lambda: parent_path.exists() and child_path.exists()), "fixture did not publish process identities")
            parent = json.loads(parent_path.read_text(encoding="utf-8"))
            child = json.loads(child_path.read_text(encoding="utf-8"))
            parent_pid = int(parent["pid"])
            child_pid = int(child["pid"])
            self.assertEqual(int(parent["childPID"]), child_pid)
            self.assertEqual(int(child["ppid"]), parent_pid)
            self.assertEqual(int(child["pgid"]), child_pid)
            self.assertNotEqual(int(parent["pgid"]), int(child["pgid"]))
            parent_start = conductor.process_start_token(parent_pid)
            child_start = conductor.process_start_token(child_pid)
            self.assertIsNotNone(parent_start)
            self.assertIsNotNone(child_start)

            if termination == "cancel":
                payload = state.job_cancel(job.ticket, None)
                self.assertTrue(payload["cancelRequested"])
            runner.join(timeout=5.0)

        self.assertFalse(runner.is_alive(), "job runner did not finish after bounded escalation")
        self.assertTrue(self.wait_until(lambda: not self.process_identity_alive(parent_pid, str(parent_start))))
        self.assertTrue(self.wait_until(lambda: not self.process_identity_alive(child_pid, str(child_start))))
        final_snapshot = conductor.process_table_snapshot()
        child_record = final_snapshot.get(child_pid)
        self.assertFalse(child_record is not None and child_record[1] == child_start and child_record[0] == 1, "descendant survived orphaned under PID 1")
        self.assertIsNone(unrelated.poll(), "unrelated process was signaled")
        self.assertNotIn(unrelated.pid, job.tracked_processes)
        registry = json.loads(state.paths.running_processes_path.read_text(encoding="utf-8"))
        self.assertEqual(registry["processes"], [])
        self.assertNotIn("build", state.active_lanes)
        cleanup_log = job.log_path.read_text(encoding="utf-8")
        self.assertIn("genuine setsid escapee(s)", cleanup_log)
        self.assertIn(f"setsid escapee pid={child_pid}", cleanup_log)
        if termination == "cancel":
            self.assertEqual(job.state, "canceled")
            self.assertEqual(job.exit_code, 130)
        else:
            self.assertEqual(job.state, "failed")
            self.assertEqual(job.exit_code, 124)
            self.assertTrue(job.timed_out)

    def test_cancel_terminates_descendant_that_created_a_new_session(self) -> None:
        self.run_detached_descendant_fixture("cancel")

    def test_timeout_uses_same_descendant_tree_cleanup(self) -> None:
        self.run_detached_descendant_fixture("timeout")


class SmokeOperationTests(unittest.TestCase):
    def test_execution_location_ui_smoke_resolves_process_by_numeric_pid_without_name_fallback(self) -> None:
        source = (SCRIPT_DIR / "smoke_agent_execution_location_popover.sh").read_text(encoding="utf-8")

        self.assertIn("repeat with candidateProcess in application processes", source)
        self.assertIn("set candidatePID to (unix id of candidateProcess) as integer", source)
        self.assertIn("if candidatePID is targetPID then", source)
        self.assertIn("if ((unix id of candidateProcess) as integer) is targetPID then return", source)
        self.assertIn("set frontmost to true", source)
        self.assertIn("key code 53", source)
        self.assertIn("entire contents of window windowIndex whose value of attribute", source)
        self.assertIn("repeat with windowIndex from 1 to 1", source)
        self.assertNotIn("first application process whose unix id is targetPID", source)
        self.assertNotIn("process appProcessName", source)
        self.assertNotIn("contents of candidateProcess", source)
        self.assertNotIn("my targetPID", source)
        self.assertNotIn("on firstElementWithIdentifier", source)

    def test_workspace_restore_in_progress_is_retryable_transient(self) -> None:
        for phase in ("hydrating roots", "restoring state", "finalizing"):
            output = (
                'Error: [-32600] Invalid Request: Workspace switch to "test-workspace" is blocked by a active '
                f'switch to "test-workspace" (reason: restore, phase: {phase}, total age: 0.5s, phase age: 0.0s)\n'
            )

            self.assertTrue(conductor.is_workspace_restore_in_progress(output, "test-workspace"), phase)
            self.assertFalse(conductor.is_workspace_restore_in_progress(output, "other-workspace"), phase)

    def test_workspace_restore_in_progress_requires_restore_reason(self) -> None:
        output = (
            'Error: [-32600] Invalid Request: Workspace switch to "test-workspace" is blocked by a active '
            'switch to "test-workspace" (reason: user, phase: switching, total age: 0.5s, phase age: 0.0s)\n'
        )

        self.assertFalse(conductor.is_workspace_restore_in_progress(output, "test-workspace"))

    def test_smoke_retries_workspace_switch_duringRestoreHydration(self) -> None:
        calls: list[tuple[str, list[str]]] = []
        switch_attempts = 0

        def record_command(name: str, argv: list[str], *_args: object, **_kwargs: object) -> tuple[int, str, str]:
            nonlocal switch_attempts
            calls.append((name, argv))
            if name == "workspace switch":
                switch_attempts += 1
                if switch_attempts == 1:
                    return (
                        1,
                        "",
                        'Error: [-32600] Invalid Request: Workspace switch to "test-workspace" is blocked by a active '
                        'switch to "test-workspace" (reason: restore, phase: hydrating roots, total age: 0.5s, phase age: 0.0s)\n',
                    )
            return 0, "", ""

        with mock.patch.object(conductor, "require_debug_cli", return_value="/tmp/rpce-cli-debug"), mock.patch.object(
            conductor, "run_operation_command", side_effect=record_command
        ), mock.patch.object(conductor.time, "sleep", return_value=None):
            code = conductor.operation_smoke(Path.cwd(), {"windowId": "7", "workspace": "test-workspace"})

        self.assertEqual(code, 0)
        self.assertEqual(switch_attempts, 2)
        self.assertEqual([name for name, _argv in calls[:3]], ["windows", "workspace switch", "workspace switch"])

    def test_smoke_retries_workspace_switch_duringRestoringStatePhase_onStdout(self) -> None:
        calls: list[tuple[str, list[str]]] = []
        switch_attempts = 0

        def record_command(name: str, argv: list[str], *_args: object, **_kwargs: object) -> tuple[int, str, str]:
            nonlocal switch_attempts
            calls.append((name, argv))
            if name == "workspace switch":
                switch_attempts += 1
                if switch_attempts == 1:
                    return (
                        1,
                        'Error: [-32600] Invalid Request: Workspace switch to "test-workspace" is blocked by a active '
                        'switch to "test-workspace" (reason: restore, phase: restoring state, total age: 0.4s, phase age: 0.4s)\n',
                        "",
                    )
            return 0, "", ""

        with mock.patch.object(conductor, "require_debug_cli", return_value="/tmp/rpce-cli-debug"), mock.patch.object(
            conductor, "run_operation_command", side_effect=record_command
        ), mock.patch.object(conductor.time, "sleep", return_value=None):
            code = conductor.operation_smoke(Path.cwd(), {"windowId": "7", "workspace": "test-workspace"})

        self.assertEqual(code, 0)
        self.assertEqual(switch_attempts, 2)
        self.assertEqual([name for name, _argv in calls[:3]], ["windows", "workspace switch", "workspace switch"])

    def test_manage_worktree_list_stage_runs_after_tree_roots_before_agent_manage(self) -> None:
        calls: list[tuple[str, list[str]]] = []

        def record_command(name: str, argv: list[str], *_args: object, **_kwargs: object) -> tuple[int, str, str]:
            calls.append((name, argv))
            return 0, "", ""

        with mock.patch.object(conductor, "require_debug_cli", return_value="/tmp/rpce-cli-debug"), mock.patch.object(
            conductor, "run_operation_command", side_effect=record_command
        ):
            code = conductor.operation_smoke(Path.cwd(), {"windowId": "7", "workspace": "test-workspace"})

        self.assertEqual(code, 0)
        self.assertEqual(
            calls,
            [
                ("windows", ["/tmp/rpce-cli-debug", "-e", "windows"]),
                ("workspace switch", ["/tmp/rpce-cli-debug", "-w", "7", "-e", "workspace switch test-workspace"]),
                ("tree roots", ["/tmp/rpce-cli-debug", "-w", "7", "-e", "tree --type roots"]),
                ("manage_worktree list", ["/tmp/rpce-cli-debug", "-w", "7", "-e", "manage_worktree op=list"]),
                (
                    "agent_manage roles",
                    [
                        "/tmp/rpce-cli-debug",
                        "-w",
                        "7",
                        "-c",
                        "agent_manage",
                        "-j",
                        '{"op": "list_agents", "roles_only": true, "_windowID": 7}',
                    ],
                ),
            ],
        )

    def test_execution_location_ui_smoke_runs_after_worktree_readiness_stages(self) -> None:
        calls: list[tuple[str, list[str], dict[str, object]]] = []

        def record_command(name: str, argv: list[str], *_args: object, **kwargs: object) -> tuple[int, str, str]:
            calls.append((name, argv, kwargs))
            return 0, "", ""

        with mock.patch.object(conductor, "require_debug_cli", return_value="/tmp/rpce-cli-debug"), mock.patch.object(
            conductor, "find_debug_app_pids", return_value=["4242"]
        ), mock.patch.dict(
            os.environ,
            {
                "REPOPROMPT_EXECUTION_LOCATION_UI_SMOKE_WAIT": "2",
                "REPOPROMPT_EXECUTION_LOCATION_UI_SMOKE_CYCLES": "2",
            },
            clear=False,
        ), mock.patch.object(
            conductor, "run_operation_command", side_effect=record_command
        ):
            code = conductor.operation_smoke(
                Path("/tmp/repo"),
                {"windowId": "7", "workspace": "test-workspace", "executionLocationUI": True},
            )

        self.assertEqual(code, 0)
        self.assertEqual(
            [name for name, _argv, _kwargs in calls],
            [
                "windows",
                "workspace switch",
                "tree roots",
                "manage_worktree list",
                "agent_manage roles",
                "execution location UI smoke",
            ],
        )
        self.assertEqual(
            calls[-1][1],
            ["/tmp/repo/Scripts/smoke_agent_execution_location_popover.sh", "4242"],
        )
        self.assertEqual(calls[-1][2]["timeout"], 184.0)

    def test_execution_location_ui_smoke_requires_one_exact_debug_app(self) -> None:
        with mock.patch.object(conductor, "require_debug_cli", return_value="/tmp/rpce-cli-debug"), mock.patch.object(
            conductor, "find_debug_app_pids", return_value=[]
        ), mock.patch.object(conductor, "run_operation_command", return_value=(0, "", "")) as run_command, contextlib.redirect_stdout(
            io.StringIO()
        ) as output:
            code = conductor.operation_smoke(
                Path("/tmp/repo"),
                {"windowId": "7", "workspace": "test-workspace", "executionLocationUI": True},
            )

        self.assertEqual(code, 1)
        self.assertEqual(run_command.call_count, 5)
        self.assertIn("requires exactly one running RepoPrompt debug app", output.getvalue())

    def test_structured_smoke_calls_route_to_requested_window_with_fake_cli(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            log_path = root / "cli-calls.jsonl"
            fake_cli = root / "rpce-cli-debug"
            fake_cli.write_text(
                textwrap.dedent(
                    """\
                    #!/usr/bin/env python3
                    import json
                    import os
                    import sys

                    args = sys.argv[1:]
                    with open(os.environ["FAKE_CLI_LOG"], "a", encoding="utf-8") as log:
                        log.write(json.dumps(args) + "\\n")
                    if "-c" in args and args[args.index("-c") + 1] == "agent_run":
                        payload = json.loads(args[args.index("-j") + 1])
                        if payload["op"] == "start":
                            print(json.dumps({"session_id": "smoke-session"}))
                    """
                ),
                encoding="utf-8",
            )
            fake_cli.chmod(0o755)

            with mock.patch.dict(os.environ, {"FAKE_CLI_LOG": str(log_path)}), mock.patch.object(
                conductor, "require_debug_cli", return_value=str(fake_cli)
            ):
                code = conductor.operation_smoke(
                    root,
                    {"windowId": 7, "workspace": "test-workspace", "agentRun": True, "agentTimeout": 5},
                )

            calls = [json.loads(line) for line in log_path.read_text(encoding="utf-8").splitlines()]

        self.assertEqual(code, 0)
        self.assertEqual(
            calls[:4],
            [
                ["-e", "windows"],
                ["-w", "7", "-e", "workspace switch test-workspace"],
                ["-w", "7", "-e", "tree --type roots"],
                ["-w", "7", "-e", "manage_worktree op=list"],
            ],
        )
        structured_calls = calls[4:]
        self.assertEqual(
            [(call[call.index("-c") + 1], json.loads(call[call.index("-j") + 1])["op"]) for call in structured_calls],
            [("agent_manage", "list_agents"), ("agent_run", "start"), ("agent_run", "wait")],
        )
        for call in structured_calls:
            self.assertEqual(call[:3], ["-w", "7", "-c"])
            payload = json.loads(call[call.index("-j") + 1])
            self.assertEqual(payload["_windowID"], 7)

    def test_launch_smoke_uses_exact_embedded_helper_and_ignores_other_resolvers(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            app = Path(tmp) / "RepoPrompt.app"
            helper = app / "Contents" / "MacOS" / "repoprompt-mcp"
            helper.parent.mkdir(parents=True)
            helper.write_text("#!/usr/bin/env bash\nexit 0\n", encoding="utf-8")
            helper.chmod(0o755)
            calls: list[tuple[str, list[str]]] = []

            def record_command(name: str, argv: list[str], *_args: object, **_kwargs: object) -> tuple[int, str, str]:
                calls.append((name, argv))
                return 0, "", ""

            with mock.patch.object(conductor, "debug_app_bundle_path", return_value=app), mock.patch.object(
                conductor, "require_debug_cli"
            ) as fallback, mock.patch.object(
                conductor, "operation_debug_app_build_then_launch", return_value=0
            ) as launch, mock.patch.object(conductor, "run_operation_command", side_effect=record_command):
                code = conductor.operation_smoke(Path(tmp), {"launch": True, "windowId": 1, "workspace": "fixture"})

        self.assertEqual(code, 0)
        fallback.assert_not_called()
        launch.assert_called_once_with(Path(tmp), {"appArgs": []})
        for name, argv in calls:
            self.assertEqual(argv[0], str(helper.resolve()), name)

    def test_embedded_helper_resolution_rejects_symlink_escape(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            app = root / "RepoPrompt.app"
            helper = app / "Contents" / "MacOS" / "repoprompt-mcp"
            helper.parent.mkdir(parents=True)
            outside = root / "outside-helper"
            outside.write_text("#!/usr/bin/env bash\nexit 0\n", encoding="utf-8")
            outside.chmod(0o755)
            helper.symlink_to(outside)

            with self.assertRaises(conductor.ConductorError):
                conductor.resolve_embedded_helper(app)

    def test_packaged_app_smoke_delegates_to_roundtrip_script_without_launch_resolution(self) -> None:
        with mock.patch.object(conductor, "run_operation_command", return_value=(0, "", "")) as run, mock.patch.object(
            conductor, "require_debug_cli"
        ) as fallback:
            code = conductor.operation_smoke(
                Path("/tmp/repo"),
                {"packagedApp": "/tmp/App.app", "artifactManifest": "/tmp/manifest.json"},
            )

        self.assertEqual(code, 0)
        fallback.assert_not_called()
        argv = run.call_args.args[1]
        self.assertEqual(Path(argv[0]).name, "smoke_packaged_mcp_roundtrip.sh")
        self.assertEqual(argv[-2:], ["Conductor packaged app", "/tmp/manifest.json"])


class RunScriptTransitionTests(unittest.TestCase):
    def test_guarded_failed_relaunch_does_not_inspect_or_stop_before_packaging_succeeds(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            scripts = root / "Scripts"
            scripts.mkdir()
            run_script = scripts / "run.sh"
            shutil.copy2(SCRIPT_DIR / "run.sh", run_script)
            shutil.copy2(SCRIPT_DIR / "conductor.py", scripts / "conductor.py")
            shutil.copy2(SCRIPT_DIR / "conductor_entry.py", scripts / "conductor_entry.py")
            shutil.copy2(SCRIPT_DIR / "conductor_output.py", scripts / "conductor_output.py")
            run_script.chmod(0o755)
            package_script = scripts / "package_app.sh"
            package_script.write_text("#!/usr/bin/env bash\necho package failed\nexit 23\n", encoding="utf-8")
            package_script.chmod(0o755)
            marker = root / "process-helper-invoked"
            helper = scripts / "debug_app_process.py"
            helper.write_text(
                textwrap.dedent(
                    """\
                    from pathlib import Path
                    import os

                    class ProcessIdentityError(Exception):
                        pass

                    def matching_processes(_executable):
                        Path(os.environ['PROCESS_HELPER_MARKER']).write_text('invoked')
                        return []

                    def terminate_matching_processes(_executable):
                        Path(os.environ['PROCESS_HELPER_MARKER']).write_text('invoked')
                        return []
                    """
                ),
                encoding="utf-8",
            )
            env = os.environ.copy()
            env.update(
                {
                    "PROCESS_HELPER_MARKER": str(marker),
                    "REPOPROMPT_GUARD_DELAYED_LAUNCH": "1",
                    "REPOPROMPT_DEV_HEAVY_SLOTS": "8",
                }
            )

            result = subprocess.run(["bash", str(run_script)], env=env, text=True, capture_output=True, timeout=10)
            helper_invoked = marker.exists()

        self.assertEqual(result.returncode, 23, result.stdout + result.stderr)
        self.assertIn("package staged debug app", result.stdout)
        self.assertNotIn("Stopping existing RepoPrompt CE debug app instance", result.stdout)
        self.assertFalse(helper_invoked)

    def test_direct_run_packages_before_waiting_for_live_lock_then_activates(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            scripts = root / "Scripts"
            scripts.mkdir()
            run_script = scripts / "run.sh"
            shutil.copy2(SCRIPT_DIR / "run.sh", run_script)
            shutil.copy2(SCRIPT_DIR / "conductor.py", scripts / "conductor.py")
            shutil.copy2(SCRIPT_DIR / "conductor_entry.py", scripts / "conductor_entry.py")
            shutil.copy2(SCRIPT_DIR / "conductor_output.py", scripts / "conductor_output.py")
            run_script.chmod(0o755)
            event_log = root / "events.log"
            launched_marker = root / "launched"
            app_bundle = root / "DebugApps" / "RepoPrompt.app"
            package_script = scripts / "package_app.sh"
            package_script.write_text(
                textwrap.dedent(
                    """\
                    #!/usr/bin/env bash
                    set -e
                    echo package:$REPOPROMPT_DEBUG_APP_BUNDLE >> "$EVENT_LOG"
                    mkdir -p "$REPOPROMPT_DEBUG_APP_BUNDLE/Contents/MacOS"
                    printf binary > "$REPOPROMPT_DEBUG_APP_BUNDLE/Contents/MacOS/RepoPrompt"
                    chmod +x "$REPOPROMPT_DEBUG_APP_BUNDLE/Contents/MacOS/RepoPrompt"
                    """
                ),
                encoding="utf-8",
            )
            package_script.chmod(0o755)
            helper = scripts / "debug_app_process.py"
            helper.write_text(
                textwrap.dedent(
                    """\
                    import os
                    from pathlib import Path

                    class ProcessIdentityError(Exception):
                        pass

                    def _state():
                        return "launched" if Path(os.environ["LAUNCHED_MARKER"]).exists() else "stopped"

                    def _log(operation, executable):
                        with Path(os.environ["EVENT_LOG"]).open("a", encoding="utf-8") as handle:
                            handle.write(f"{operation}:{_state()}:{executable}\\n")

                    def matching_processes(executable):
                        _log("list", executable)
                        return [4242] if _state() == "launched" else []

                    def terminate_matching_processes(executable):
                        _log("terminate", executable)
                        return []
                    """
                ),
                encoding="utf-8",
            )
            bin_dir = root / "bin"
            bin_dir.mkdir()
            (bin_dir / "codesign").write_text("#!/usr/bin/env bash\necho TeamIdentifier=TEST >&2\n", encoding="utf-8")
            (bin_dir / "plutil").write_text("#!/usr/bin/env bash\necho memory\n", encoding="utf-8")
            (bin_dir / "open").write_text(
                "#!/usr/bin/env bash\necho open >> \"$EVENT_LOG\"\ntouch \"$LAUNCHED_MARKER\"\n",
                encoding="utf-8",
            )
            for command in ["codesign", "plutil", "open"]:
                (bin_dir / command).chmod(0o755)
            env = os.environ.copy()
            env.update(
                {
                    "PATH": f"{bin_dir}:{env.get('PATH', '')}",
                    "EVENT_LOG": str(event_log),
                    "LAUNCHED_MARKER": str(launched_marker),
                    "REPOPROMPT_DEBUG_APP_BUNDLE": str(app_bundle),
                    "REPOPROMPT_DEV_HEAVY_SLOTS": "8",
                }
            )
            lock_ready = threading.Event()
            release_lock = threading.Event()

            def hold_live_lock() -> None:
                metadata = conductor.display_lock_metadata(
                    lock_kind="live-app",
                    ticket="direct-run-test",
                    operation="test-live-lock",
                    operation_label="test live lock",
                    repo_root=root,
                )
                with conductor.machine_exclusive_lock(conductor.live_app_lock_path(), metadata, "live-app lock"):
                    with event_log.open("a", encoding="utf-8") as handle:
                        handle.write("lock-start\n")
                    lock_ready.set()
                    release_lock.wait(timeout=5.0)
                    with event_log.open("a", encoding="utf-8") as handle:
                        handle.write("lock-release\n")

            holder = threading.Thread(target=hold_live_lock, daemon=True)
            holder.start()
            self.assertTrue(lock_ready.wait(timeout=2.0))
            proc = subprocess.Popen(["bash", str(run_script)], env=env, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            deadline = time.monotonic() + 5.0
            while time.monotonic() < deadline:
                rows = event_log.read_text(encoding="utf-8").splitlines() if event_log.exists() else []
                if any(row.startswith("package:") for row in rows):
                    break
                time.sleep(0.02)
            rows_before_release = event_log.read_text(encoding="utf-8").splitlines()
            self.assertTrue(any(row.startswith("package:") for row in rows_before_release), rows_before_release)
            self.assertFalse(any(row.startswith(("list:", "terminate:")) for row in rows_before_release), rows_before_release)
            release_lock.set()
            stdout, stderr = proc.communicate(timeout=10)
            holder.join(timeout=2.0)
            rows = event_log.read_text(encoding="utf-8").splitlines()

        self.assertEqual(proc.returncode, 0, stdout + stderr)
        self.assertLess(
            rows.index("lock-release"),
            next(index for index, row in enumerate(rows) if row.startswith(("list:", "terminate:"))),
        )
        self.assertIn("Activated staged debug app bundle", stdout)

    def test_successful_relaunch_uses_debug_executable_for_stop_and_readiness(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            scripts = root / "Scripts"
            scripts.mkdir()
            run_script = scripts / "run.sh"
            shutil.copy2(SCRIPT_DIR / "run.sh", run_script)
            shutil.copy2(SCRIPT_DIR / "conductor.py", scripts / "conductor.py")
            shutil.copy2(SCRIPT_DIR / "conductor_entry.py", scripts / "conductor_entry.py")
            shutil.copy2(SCRIPT_DIR / "conductor_output.py", scripts / "conductor_output.py")
            run_script.chmod(0o755)
            event_log = root / "events.log"
            launched_marker = root / "launched"
            app_bundle = root / "DebugApps" / "RepoPrompt.app"
            app_executable = app_bundle / "Contents" / "MacOS" / "RepoPrompt"
            package_script = scripts / "package_app.sh"
            package_script.write_text(
                textwrap.dedent(
                    """\
                    #!/usr/bin/env bash
                    set -e
                    echo package:$REPOPROMPT_DEBUG_APP_BUNDLE >> "$EVENT_LOG"
                    mkdir -p "$REPOPROMPT_DEBUG_APP_BUNDLE/Contents/MacOS"
                    printf binary > "$REPOPROMPT_DEBUG_APP_BUNDLE/Contents/MacOS/RepoPrompt"
                    chmod +x "$REPOPROMPT_DEBUG_APP_BUNDLE/Contents/MacOS/RepoPrompt"
                    """
                ),
                encoding="utf-8",
            )
            package_script.chmod(0o755)
            helper = scripts / "debug_app_process.py"
            helper.write_text(
                textwrap.dedent(
                    """\
                    import os
                    from pathlib import Path

                    class ProcessIdentityError(Exception):
                        pass

                    def _state():
                        return "launched" if Path(os.environ["LAUNCHED_MARKER"]).exists() else "stopped"

                    def _log(operation, executable):
                        with Path(os.environ["EVENT_LOG"]).open("a", encoding="utf-8") as handle:
                            handle.write(f"{operation}:{_state()}:{executable}\\n")

                    def matching_processes(executable):
                        _log("list", executable)
                        return [4242] if _state() == "launched" else []

                    def terminate_matching_processes(executable):
                        _log("terminate", executable)
                        return []
                    """
                ),
                encoding="utf-8",
            )
            bin_dir = root / "bin"
            bin_dir.mkdir()
            (bin_dir / "codesign").write_text("#!/usr/bin/env bash\necho TeamIdentifier=TEST >&2\n", encoding="utf-8")
            (bin_dir / "plutil").write_text("#!/usr/bin/env bash\necho memory\n", encoding="utf-8")
            (bin_dir / "open").write_text(
                "#!/usr/bin/env bash\necho open >> \"$EVENT_LOG\"\ntouch \"$LAUNCHED_MARKER\"\n",
                encoding="utf-8",
            )
            for command in ["codesign", "plutil", "open"]:
                (bin_dir / command).chmod(0o755)
            env = os.environ.copy()
            env.update(
                {
                    "PATH": f"{bin_dir}:{env.get('PATH', '')}",
                    "EVENT_LOG": str(event_log),
                    "LAUNCHED_MARKER": str(launched_marker),
                    "REPOPROMPT_DEBUG_APP_BUNDLE": str(app_bundle),
                    "REPOPROMPT_DEV_HEAVY_SLOTS": "8",
                }
            )

            result = subprocess.run(["bash", str(run_script), "--demo"], env=env, text=True, capture_output=True, timeout=20)
            events = event_log.read_text(encoding="utf-8").splitlines()
            activated_executable_exists = app_executable.exists()
            compatibility_bundle = root / ".build" / "debug" / "RepoPrompt.app"
            compatibility_target = compatibility_bundle.resolve(strict=True)
            app_bundle_target = app_bundle.resolve(strict=True)

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        expected_suffix = f":{app_executable}"
        self.assertTrue(events[0].startswith("package:"), events)
        self.assertIn("/.staging/", events[0])
        self.assertNotIn(str(app_bundle), events[0])
        open_index = events.index("open")
        self.assertGreater(open_index, 1, events)
        self.assertTrue(all(event == f"list:stopped:{app_executable}" for event in events[1:open_index]), events)
        self.assertEqual(events[open_index + 1], f"list:launched:{app_executable}")
        self.assertTrue(all(event.endswith(expected_suffix) for event in events if event.startswith(("list:", "terminate:"))))
        source = (SCRIPT_DIR / "run.sh").read_text(encoding="utf-8")
        self.assertTrue(activated_executable_exists)
        self.assertEqual(compatibility_target, app_bundle_target)
        self.assertIn("Activated staged debug app bundle", result.stdout)
        self.assertIn("Observed launched RepoPrompt CE debug PID(s): 4242", result.stdout)
        self.assertNotIn("pgrep", source)
        self.assertNotIn("pkill", source)


class AppStatusIdentityTests(unittest.TestCase):
    def make_bundle(self, bundle: Path, marker: str = "binary") -> None:
        executable = bundle / "Contents" / "MacOS" / "RepoPrompt"
        executable.parent.mkdir(parents=True, exist_ok=True)
        executable.write_text(marker, encoding="utf-8")
        executable.chmod(0o755)

    def test_activate_staged_debug_bundle_replaces_live_and_cleans_staging(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            live = root / "DebugApps" / "RepoPrompt.app"
            staged = root / "DebugApps" / ".staging" / "token" / "RepoPrompt.app"
            self.make_bundle(live, "old")
            self.make_bundle(staged, "new")

            conductor.activate_staged_debug_bundle(staged, live)

            self.assertEqual((live / "Contents" / "MacOS" / "RepoPrompt").read_text(encoding="utf-8"), "new")
            self.assertFalse(staged.parent.exists())
            self.assertFalse(any(live.parent.glob(".RepoPrompt.app.previous.*")))

    def test_staged_package_names_live_bundle_as_reuse_source_and_build_still_invalidates_ticket(self) -> None:
        # Debug packaging Step 6: the staged package may clone the live bundle (noop-clone); nothing
        # else in conductor changes, and `build` keeps invalidating the root ticket unconditionally.
        captured: dict = {}

        def fake_package(name, argv, cwd, env=None, **_kwargs):
            captured.update(argv=list(argv), env=dict(env or {}))
            self.make_bundle(Path(env["REPOPROMPT_DEBUG_APP_BUNDLE"]), "staged")
            return 0, "", ""

        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            live = root / "DebugApps" / "RepoPrompt.app"
            self.make_bundle(live, "live")
            with mock.patch.dict(os.environ, {"REPOPROMPT_DEBUG_APP_BUNDLE": str(live)}), mock.patch.object(
                conductor, "machine_heavy_slot", return_value=contextlib.nullcontext()
            ), mock.patch.object(conductor, "run_operation_command", side_effect=fake_package), contextlib.redirect_stdout(
                io.StringIO()
            ):
                code, staged = conductor.package_debug_app_under_heavy(root, "run")

            self.assertEqual(code, 0)
            self.assertEqual(captured["argv"][-1], "debug")
            self.assertEqual(captured["env"]["REPOPROMPT_DEBUG_APP_REUSE_SOURCE"], str(live))
            self.assertEqual(Path(captured["env"]["REPOPROMPT_DEBUG_APP_BUNDLE"]), staged)
            self.assertIn("/.staging/", captured["env"]["REPOPROMPT_DEBUG_APP_BUNDLE"])
            self.assertEqual(staged.parent.parent, live.parent / ".staging")
            self.assertEqual((live / "Contents" / "MacOS" / "RepoPrompt").read_text(encoding="utf-8"), "live")
        for args in ({}, {"fast": True}, {"appArgs": []}):
            self.assertTrue(conductor.operation_invalidates_root_build_ticket("build", args), args)
        import inspect

        package_source = inspect.getsource(conductor.package_debug_app_under_heavy)
        self.assertEqual(package_source.count('env["REPOPROMPT_DEBUG_APP_REUSE_SOURCE"] = str(live_bundle)'), 1)

    def test_staged_package_forwards_lane_config_and_keeps_reuse_source(self) -> None:
        # Step 5: only the package_app.sh config changes; staging and the reuse source are as for debug.
        for config in ("debug", "debug-optimized", "debug-optimized-incremental"):
            captured: dict = {}

            def fake_package(name, argv, cwd, env=None, **_kwargs):
                captured.update(argv=list(argv), env=dict(env or {}))
                self.make_bundle(Path(env["REPOPROMPT_DEBUG_APP_BUNDLE"]), "staged")
                return 0, "", ""

            with self.subTest(config=config), tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp)
                live = root / "DebugApps" / "RepoPrompt.app"
                self.make_bundle(live, "live")
                with mock.patch.dict(os.environ, {"REPOPROMPT_DEBUG_APP_BUNDLE": str(live)}), mock.patch.object(
                    conductor, "machine_heavy_slot", return_value=contextlib.nullcontext()
                ), mock.patch.object(conductor, "run_operation_command", side_effect=fake_package), contextlib.redirect_stdout(
                    io.StringIO()
                ):
                    code, staged = conductor.package_debug_app_under_heavy(root, "run", package_config=config)
                self.assertEqual(code, 0)
                self.assertEqual(captured["argv"], [str(root / "Scripts" / "package_app.sh"), config])
                self.assertEqual(captured["env"]["REPOPROMPT_DEBUG_APP_REUSE_SOURCE"], str(live))
                self.assertEqual(Path(captured["env"]["REPOPROMPT_DEBUG_APP_BUNDLE"]), staged)
                self.assertEqual(staged.parent.parent, live.parent / ".staging")
                self.assertEqual((live / "Contents" / "MacOS" / "RepoPrompt").read_text(encoding="utf-8"), "live")
        import inspect

        self.assertEqual(
            inspect.signature(conductor.package_debug_app_under_heavy).parameters["package_config"].default, "debug"
        )

    def test_staged_package_rejects_unknown_config_before_staging_or_slot(self) -> None:
        for config in ("release", "fast", "", "debug ", "Debug", "debug-optimized fast", "debug-incremental",
                       "debug-optimized-incremental fast", "optimized-incremental"):
            with self.subTest(config=config), tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp)
                live = root / "DebugApps" / "RepoPrompt.app"
                self.make_bundle(live, "live")
                with mock.patch.dict(os.environ, {"REPOPROMPT_DEBUG_APP_BUNDLE": str(live)}), mock.patch.object(
                    conductor, "machine_heavy_slot"
                ) as slot, mock.patch.object(conductor, "run_operation_command") as run, mock.patch.object(
                    conductor, "staged_debug_app_parent"
                ) as staging:
                    with self.assertRaisesRegex(conductor.ConductorError, "unsupported staged debug package config"):
                        conductor.package_debug_app_under_heavy(root, "run", package_config=config)
                slot.assert_not_called()
                run.assert_not_called()
                staging.assert_not_called()
                self.assertFalse((live.parent / ".staging").exists())
                self.assertEqual((live / "Contents" / "MacOS" / "RepoPrompt").read_text(encoding="utf-8"), "live")

    def test_optimized_lane_package_failure_keeps_live_intact_and_skips_lifecycle(self) -> None:
        captured: dict = {}

        def failing_package(name, argv, cwd, env=None, **_kwargs):
            captured.update(argv=list(argv), env=dict(env or {}))
            # A partial staged bundle exists when the lane build fails or is superseded mid-package.
            self.make_bundle(Path(env["REPOPROMPT_DEBUG_APP_BUNDLE"]), "partial")
            return 65, "", ""

        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            live = root / "DebugApps" / "RepoPrompt.app"
            self.make_bundle(live, "live")
            output = io.StringIO()
            with mock.patch.dict(os.environ, {"REPOPROMPT_DEBUG_APP_BUNDLE": str(live)}), mock.patch.object(
                conductor, "machine_heavy_slot", return_value=contextlib.nullcontext()
            ), mock.patch.object(conductor, "run_operation_command", side_effect=failing_package), mock.patch.object(
                conductor, "operation_app_launch_existing"
            ) as launch, mock.patch.object(conductor, "_operation_app_stop_unlocked") as stop, contextlib.redirect_stdout(output):
                code = conductor.operation_debug_app_build_then_launch(root, {"optimized": True, "appArgs": ["--demo"]})

            self.assertEqual(code, 65)
            self.assertEqual(captured["argv"][-1], "debug-optimized")
            launch.assert_not_called()
            stop.assert_not_called()
            self.assertEqual((live / "Contents" / "MacOS" / "RepoPrompt").read_text(encoding="utf-8"), "live")
            self.assertFalse(Path(captured["env"]["REPOPROMPT_DEBUG_APP_BUNDLE"]).parent.exists())
            self.assertIn("no live bundle or stop/launch lifecycle action", output.getvalue())

    def test_build_then_launch_maps_lane_request_to_package_config(self) -> None:
        cases = (
            ({"appArgs": []}, "debug"),
            ({"appArgs": ["--demo"], "subcommand": "relaunch"}, "debug"),
            ({"optimized": True, "appArgs": []}, "debug-optimized"),
            ({"optimized": True, "appArgs": ["--demo"], "subcommand": "relaunch"}, "debug-optimized"),
            ({"optimizedIncremental": True, "appArgs": []}, "debug-optimized-incremental"),
            ({"optimizedIncremental": True, "appArgs": ["--demo"], "subcommand": "relaunch"}, "debug-optimized-incremental"),
        )
        for args, config in cases:
            with self.subTest(args=args), mock.patch.object(
                conductor, "package_debug_app_under_heavy", return_value=(0, Path("/tmp/staged/RepoPrompt.app"))
            ) as package, mock.patch.object(conductor, "operation_app_launch_existing", return_value=0) as launch:
                code = conductor.operation_debug_app_build_then_launch(Path("/tmp/repo"), dict(args))
            self.assertEqual(code, 0)
            package.assert_called_once_with(Path("/tmp/repo"), "debug app build/package", package_config=config)
            launch_args = launch.call_args.args[1]
            self.assertEqual(launch_args["stagedBundle"], "/tmp/staged/RepoPrompt.app")
            self.assertEqual(launch_args["appArgs"], args["appArgs"])
        for bad in (False, "true", 1):
            for key in ("optimized", "optimizedIncremental"):
                with self.subTest(bad=bad, key=key), mock.patch.object(conductor, "package_debug_app_under_heavy") as package:
                    with self.assertRaisesRegex(conductor.ConductorError, "must be true"):
                        conductor.operation_debug_app_build_then_launch(Path("/tmp/repo"), {key: bad, "appArgs": []})
                package.assert_not_called()
        with mock.patch.object(conductor, "package_debug_app_under_heavy") as package:
            with self.assertRaisesRegex(conductor.ConductorError, "mutually exclusive"):
                conductor.operation_debug_app_build_then_launch(
                    Path("/tmp/repo"), {"optimized": True, "optimizedIncremental": True, "appArgs": []}
                )
        package.assert_not_called()

    def test_provenance_report_names_build_lane_or_pre_lane_unknown(self) -> None:
        cases = (
            ({"buildLane": "debug-optimized"}, "    build lane: debug-optimized"),
            ({"buildLane": "debug-optimized-incremental"}, "    build lane: debug-optimized-incremental"),
            ({"buildLane": "debug"}, "    build lane: debug"),
            ({}, "    build lane: unknown (pre-lane provenance)"),
            ({"buildLane": ""}, "    build lane: <invalid: ''>"),
            ({"buildLane": 5}, "    build lane: <invalid: 5>"),
        )
        for extra, expected in cases:
            with self.subTest(extra=extra), tempfile.TemporaryDirectory() as tmp:
                bundle = Path(tmp) / "RepoPrompt.app"
                provenance_path = conductor.debug_app_provenance_path(bundle)
                provenance_path.parent.mkdir(parents=True)
                payload = {"repoRoot": tmp, "branch": "main", "commit": "a" * 40, "dirty": False, "buildTimeISO": "t", **extra}
                provenance_path.write_text(json.dumps(payload), encoding="utf-8")
                with mock.patch.object(conductor, "current_repo_commit", return_value="a" * 40):
                    lines = conductor.provenance_report_lines(Path(tmp), bundle)
                self.assertIn(expected, lines)
                self.assertEqual(sum(line.startswith("    build lane: ") for line in lines), 1)
                self.assertFalse(any("WARNING" in line for line in lines), lines)
        with tempfile.TemporaryDirectory() as tmp:
            self.assertEqual(
                conductor.provenance_report_lines(Path(tmp), Path(tmp) / "RepoPrompt.app"), ["  Bundle provenance: <missing>"]
            )

    def test_launch_report_and_app_status_both_print_the_build_lane(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            bundle = Path(tmp) / "DebugApps" / "RepoPrompt.app"
            self.make_bundle(bundle)
            provenance_path = conductor.debug_app_provenance_path(bundle)
            provenance_path.parent.mkdir(parents=True, exist_ok=True)
            provenance_path.write_text(
                json.dumps({"repoRoot": tmp, "commit": "b" * 40, "buildLane": "debug-optimized"}), encoding="utf-8"
            )
            probe = subprocess.CompletedProcess([], 1, stdout="", stderr="")
            output = io.StringIO()
            with mock.patch.dict(os.environ, {"REPOPROMPT_DEBUG_APP_BUNDLE": str(bundle)}), mock.patch.object(
                conductor.subprocess, "run", return_value=probe
            ), mock.patch.object(conductor, "current_repo_commit", return_value="b" * 40), mock.patch.object(
                conductor, "find_debug_app_pids", return_value=[]
            ), mock.patch.object(conductor, "run_operation_command", return_value=(0, "", "")), contextlib.redirect_stdout(output):
                self.assertEqual(conductor.report_launch_bundle_details(Path(tmp), bundle), 0)
                self.assertEqual(conductor.operation_app_status(Path(tmp)), 0)
            self.assertEqual(output.getvalue().count("    build lane: debug-optimized"), 2)

    def test_repair_compatibility_link_replaces_removed_staging_target(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            live = root / "DebugApps" / "RepoPrompt.app"
            removed_staging = root / "DebugApps" / ".staging" / "removed" / "RepoPrompt.app"
            self.make_bundle(live, "current")
            compatibility_bundle = root / ".build" / "debug" / "RepoPrompt.app"
            compatibility_bundle.parent.mkdir(parents=True)
            compatibility_bundle.symlink_to(removed_staging)

            repaired = conductor.repair_debug_app_compatibility_link(root, live)

            self.assertEqual(repaired, compatibility_bundle)
            self.assertTrue(compatibility_bundle.is_symlink())
            self.assertEqual(compatibility_bundle.resolve(strict=True), live.resolve(strict=True))

    def test_launch_existing_falls_back_when_launch_services_cannot_resolve_verified_bundle(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            live = root / "DebugApps" / "RepoPrompt.app"
            self.make_bundle(live, "current")
            output = io.StringIO()
            with mock.patch.dict(os.environ, {"REPOPROMPT_DEBUG_APP_BUNDLE": str(live)}), mock.patch.object(
                conductor, "machine_exclusive_lock", return_value=contextlib.nullcontext()
            ), mock.patch.object(conductor, "report_launch_bundle_details"), mock.patch.object(
                conductor, "_operation_app_stop_unlocked", return_value=0
            ), mock.patch.object(
                conductor,
                "run_operation_command",
                return_value=(1, "", 'Code=-10827 "kLSNoExecutableErr: The executable is missing"'),
            ) as launch_services, mock.patch.object(
                conductor, "launch_debug_app_executable_directly", return_value=True
            ) as direct_launch, mock.patch.object(
                conductor, "wait_for_debug_app_process", return_value=["4242"]
            ), contextlib.redirect_stdout(output):
                code = conductor.operation_app_launch_existing(root, {"appArgs": ["--demo"]})

            compatibility_bundle = root / ".build" / "debug" / "RepoPrompt.app"
            self.assertEqual(code, 0)
            self.assertEqual(compatibility_bundle.resolve(strict=True), live.resolve(strict=True))
            launch_services.assert_called_once()
            direct_launch.assert_called_once_with(live / "Contents" / "MacOS" / "RepoPrompt", ["--demo"], root)
            self.assertIn("Observed launched RepoPrompt CE debug PID(s): 4242", output.getvalue())

    def test_launch_existing_does_not_fallback_for_unrelated_open_failure(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            live = root / "DebugApps" / "RepoPrompt.app"
            self.make_bundle(live, "current")
            with mock.patch.dict(os.environ, {"REPOPROMPT_DEBUG_APP_BUNDLE": str(live)}), mock.patch.object(
                conductor, "machine_exclusive_lock", return_value=contextlib.nullcontext()
            ), mock.patch.object(conductor, "report_launch_bundle_details"), mock.patch.object(
                conductor, "_operation_app_stop_unlocked", return_value=0
            ), mock.patch.object(
                conductor, "run_operation_command", return_value=(1, "", "unrelated open failure")
            ), mock.patch.object(conductor, "launch_debug_app_executable_directly") as direct_launch, contextlib.redirect_stdout(
                io.StringIO()
            ):
                code = conductor.operation_app_launch_existing(root, {"appArgs": []})

            self.assertEqual(code, 1)
            direct_launch.assert_not_called()

    def test_staged_launch_stop_failure_preserves_live_and_cleans_staging(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            live = root / "DebugApps" / "RepoPrompt.app"
            staged = root / "DebugApps" / ".staging" / "token" / "RepoPrompt.app"
            self.make_bundle(live, "old")
            self.make_bundle(staged, "new")
            with mock.patch.dict(os.environ, {"REPOPROMPT_DEBUG_APP_BUNDLE": str(live)}), mock.patch.object(
                conductor, "_operation_app_stop_unlocked", return_value=7
            ), mock.patch.object(conductor, "run_operation_command") as run, contextlib.redirect_stdout(io.StringIO()):
                code = conductor.operation_app_launch_existing(root, {"stagedBundle": str(staged), "appArgs": []})

            self.assertEqual(code, 7)
            self.assertEqual((live / "Contents" / "MacOS" / "RepoPrompt").read_text(encoding="utf-8"), "old")
            self.assertFalse(staged.parent.exists())
            run.assert_not_called()

    def test_launch_existing_requires_bundle_and_does_not_build(self) -> None:
        output = io.StringIO()
        with tempfile.TemporaryDirectory() as tmp, mock.patch.dict(
            os.environ,
            {"REPOPROMPT_DEBUG_APP_BUNDLE": str(Path(tmp) / "missing" / "RepoPrompt.app")},
        ), mock.patch.object(conductor, "package_debug_app_under_heavy") as package, contextlib.redirect_stdout(output):
            code = conductor.operation_app_launch_existing(Path(tmp), {"appArgs": []})

        self.assertEqual(code, 1)
        package.assert_not_called()
        self.assertIn("existing debug app bundle is not launchable", output.getvalue())

    def test_split_build_failure_performs_no_lifecycle_action(self) -> None:
        with mock.patch.object(conductor, "package_debug_app_under_heavy", return_value=(23, None)) as package, mock.patch.object(
            conductor, "operation_app_launch_existing"
        ) as launch, contextlib.redirect_stdout(io.StringIO()) as output:
            code = conductor.operation_debug_app_build_then_launch(Path("/tmp/repo"), {"appArgs": []})

        self.assertEqual(code, 23)
        package.assert_called_once()
        launch.assert_not_called()
        self.assertIn("no live bundle or stop/launch lifecycle action", output.getvalue())

    def test_status_treats_missing_debug_executable_as_not_installed(self) -> None:
        output = io.StringIO()
        with tempfile.TemporaryDirectory() as tmp, mock.patch.dict(
            os.environ,
            {"REPOPROMPT_DEBUG_APP_BUNDLE": str(Path(tmp) / "missing" / "RepoPrompt.app")},
        ), mock.patch.object(conductor, "run_operation_command", return_value=(0, "", "")), contextlib.redirect_stdout(output):
            code = conductor.operation_app_status(Path("/tmp/repo"))

        self.assertEqual(code, 0)
        self.assertIn("Running matching debug app PIDs: none", output.getvalue())
        self.assertIn("Bundle exists: no", output.getvalue())

    def test_status_reports_only_path_validated_debug_pids(self) -> None:
        output = io.StringIO()
        with mock.patch.object(conductor, "find_debug_app_pids", return_value=["501"]), mock.patch.object(
            conductor, "run_operation_command", return_value=(0, "", "")
        ), mock.patch.dict(os.environ, {"REPOPROMPT_DEBUG_APP_BUNDLE": "/tmp/missing-debug/RepoPrompt.app"}), contextlib.redirect_stdout(
            output
        ):
            code = conductor.operation_app_status(Path("/tmp/repo"))

        self.assertEqual(code, 0)
        self.assertIn("Running matching debug app PIDs: 501", output.getvalue())

    def test_status_identity_failure_is_reported_as_unknown(self) -> None:
        output = io.StringIO()
        with mock.patch.object(
            conductor,
            "find_debug_app_pids",
            side_effect=conductor.ProcessIdentityError("identity unavailable"),
        ), mock.patch.object(conductor, "run_operation_command") as cli_status, contextlib.redirect_stdout(output):
            code = conductor.operation_app_status(Path("/tmp/repo"))

        self.assertEqual(code, 1)
        self.assertIn("Running matching debug app PIDs: unknown", output.getvalue())
        cli_status.assert_not_called()


class StopConfirmationTests(unittest.TestCase):
    def test_delayed_guard_exceeds_run_launch_observation_window(self) -> None:
        self.assertGreater(conductor.APP_STOP_DELAYED_LAUNCH_GUARD_SECONDS, 10.0)
        self.assertGreater(conductor.APP_STOP_DELAYED_LAUNCH_CONFIRM_TIMEOUT_SECONDS, conductor.APP_STOP_DELAYED_LAUNCH_GUARD_SECONDS)

    @contextlib.contextmanager
    def patched_timing(self):
        current_time = 0.0

        def fake_now() -> float:
            return current_time

        def fake_sleep(seconds: float) -> None:
            nonlocal current_time
            current_time += seconds

        with mock.patch.multiple(
            conductor,
            APP_STOP_POLL_SECONDS=0.001,
            APP_STOP_QUIET_SECONDS=0.002,
            APP_STOP_DELAYED_LAUNCH_GUARD_SECONDS=0.004,
            APP_STOP_CONFIRM_TIMEOUT_SECONDS=0.02,
            APP_STOP_DELAYED_LAUNCH_CONFIRM_TIMEOUT_SECONDS=0.02,
            now=fake_now,
        ), mock.patch.object(conductor.time, "sleep", side_effect=fake_sleep):
            yield

    def test_missing_debug_executable_is_confirmed_already_stopped(self) -> None:
        with tempfile.TemporaryDirectory() as tmp, self.patched_timing(), mock.patch.dict(
            os.environ,
            {"REPOPROMPT_DEBUG_APP_BUNDLE": str(Path(tmp) / "missing" / "RepoPrompt.app")},
        ), contextlib.redirect_stdout(io.StringIO()) as output:
            code = conductor.operation_app_stop(Path.cwd(), {})

        self.assertEqual(code, 0)
        self.assertIn("already stopped", output.getvalue())

    def test_already_stopped_is_confirmed_without_termination(self) -> None:
        with self.patched_timing(), mock.patch.object(conductor, "find_debug_app_pids", return_value=[]), mock.patch.object(
            conductor, "terminate_debug_app_processes"
        ) as terminate, contextlib.redirect_stdout(io.StringIO()):
            code = conductor.operation_app_stop(Path.cwd(), {})

        self.assertEqual(code, 0)
        terminate.assert_not_called()

    def test_running_process_is_terminated_then_confirmed_absent(self) -> None:
        probes = iter([["101"], [], [], [], []])
        with self.patched_timing(), mock.patch.object(conductor, "find_debug_app_pids", side_effect=lambda: next(probes, [])), mock.patch.object(
            conductor, "terminate_debug_app_processes", return_value=["101"]
        ) as terminate, contextlib.redirect_stdout(io.StringIO()):
            code = conductor.operation_app_stop(Path.cwd(), {})

        self.assertEqual(code, 0)
        terminate.assert_called_once_with()

    def test_guarded_stop_terminates_delayed_process_appearance(self) -> None:
        calls = 0

        def probe() -> list[str]:
            nonlocal calls
            calls += 1
            return ["202"] if calls == 2 else []

        with self.patched_timing(), mock.patch.object(conductor, "find_debug_app_pids", side_effect=probe), mock.patch.object(
            conductor, "terminate_debug_app_processes", return_value=["202"]
        ) as terminate, contextlib.redirect_stdout(io.StringIO()):
            code = conductor.operation_app_stop(Path.cwd(), {"guardDelayedLaunch": True})

        self.assertEqual(code, 0)
        terminate.assert_called_once_with()

    def test_identity_failure_aborts_without_name_based_fallback(self) -> None:
        with self.patched_timing(), mock.patch.object(
            conductor,
            "find_debug_app_pids",
            side_effect=conductor.ProcessIdentityError("identity unavailable"),
        ), mock.patch.object(conductor, "terminate_debug_app_processes") as terminate, contextlib.redirect_stdout(io.StringIO()):
            code = conductor.operation_app_stop(Path.cwd(), {})

        self.assertEqual(code, 1)
        terminate.assert_not_called()

    def test_persistent_process_fails_confirmation_without_force_kill(self) -> None:
        with self.patched_timing(), mock.patch.object(conductor, "find_debug_app_pids", return_value=["303"]), mock.patch.object(
            conductor, "terminate_debug_app_processes", return_value=["303"]
        ) as terminate, contextlib.redirect_stdout(io.StringIO()):
            code = conductor.operation_app_stop(Path.cwd(), {})

        self.assertEqual(code, 1)
        self.assertGreater(terminate.call_count, 0)


RUNTIME_LEDGER_HEADER = "suite\tmethod\truntime_seconds\ttarget\n"
LEDGER_SUITE = "RepoPromptTests.RuntimeLedgerCacheTests"


@contextlib.contextmanager
def record_log_writes(state_of, writes: list):  # type: ignore[no-untyped-def]
    """Record every write to a job log (``jobs/*.log`` opened for append) with whether the
    writing thread then owned ``state_of().lock``."""
    real_open = Path.open

    class Recording:
        def __init__(self, handle):  # type: ignore[no-untyped-def]
            self._handle = handle

        def write(self, data):  # type: ignore[no-untyped-def]
            writes.append((bytes(data), bool(state_of().lock._is_owned())))
            return self._handle.write(data)

        def __enter__(self):  # type: ignore[no-untyped-def]
            self._handle.__enter__()
            return self

        def __exit__(self, *exc):  # type: ignore[no-untyped-def]
            return self._handle.__exit__(*exc)

        def __getattr__(self, name):  # type: ignore[no-untyped-def]
            return getattr(self._handle, name)

    def recording_open(path, mode="r", *args, **kwargs):  # type: ignore[no-untyped-def]
        handle = real_open(path, mode, *args, **kwargs)
        if "a" in mode and path.suffix == ".log" and path.parent.name == "jobs":
            return Recording(handle)
        return handle

    with mock.patch.object(Path, "open", recording_open):
        yield


def parent_runtime_ledger_reference(rows: list[dict]) -> dict:
    """Frozen copy of the f6bc1a8e per-job loop (``_load_xctest_method_runtimes_locked``)."""
    runtimes: dict = {}
    for row in rows:
        suite = str(row.get("suite") or "").strip()
        method = str(row.get("method") or "").strip()
        raw_runtime = str(row.get("runtime_seconds") or "").strip()
        if not suite or not method or not raw_runtime:
            continue
        try:
            runtime = float(raw_runtime)
        except ValueError:
            continue
        if not conductor.math.isfinite(runtime) or runtime < 0:
            continue
        runtimes.setdefault((suite, method), runtime)
    return runtimes


class RuntimeLedgerCacheTests(LifecycleTestCase):
    """Plan Step 4: one shared, immutable runtime-ledger snapshot per daemon."""

    def write_ledger(self, root: Path, rows: str) -> Path:
        ledger = conductor._test_ledger_path(root)
        ledger.parent.mkdir(parents=True, exist_ok=True)
        ledger.write_text(RUNTIME_LEDGER_HEADER + rows, encoding="utf-8")
        return ledger

    def make_cache(self, rows: str) -> tuple[Path, conductor.RuntimeLedgerCache]:
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        ledger = self.write_ledger(Path(tmp.name), rows)
        return ledger, conductor.RuntimeLedgerCache(ledger)

    @staticmethod
    def rows(count: int, runtime: float = 1.0) -> str:
        return "".join(f"{LEDGER_SUITE}\ttest{index}\t{runtime}\troot\n" for index in range(count))

    @staticmethod
    def resident_snapshots(sentinel: tuple[str, str]) -> int:
        import gc
        import types

        gc.collect()
        return sum(
            1 for item in gc.get_objects() if isinstance(item, types.MappingProxyType) and sentinel in item
        )

    def test_parse_semantics_match_the_parent_loader(self) -> None:
        rows = (
            "S\tincomplete\t\troot\n"
            "\tnoSuite\t1.0\troot\n"
            "S\tm3\t-0.5\troot\n"
            "S\tm3\t2.0\troot\n"
            "S\tm4\tnan\troot\n"
            "S\tm4\tinf\troot\n"
            "S\tm4\t-inf\troot\n"
            "S\tm4\tabc\troot\n"
            "S\tm4\t3.5\troot\n"
            "S\tm4\t9.0\tcore\n"
            " S \t m5 \t 0.25 \tprovider\n"
            "S\tm6\t0\troot\n"
        )
        ledger, cache = self.make_cache(rows)
        load = cache.load()
        self.assertIsNone(load.diagnostic)
        expected = {("S", "m3"): 2.0, ("S", "m4"): 3.5, ("S", "m5"): 0.25, ("S", "m6"): 0.0}
        self.assertEqual(dict(load.runtimes), expected)
        self.assertEqual(
            dict(load.runtimes), parent_runtime_ledger_reference(conductor._read_test_ledger_rows(ledger.parents[2]))
        )

    def test_curated_ledger_snapshot_equals_the_parent_loader(self) -> None:
        repo_root = SCRIPT_DIR.parent
        cache = conductor.RuntimeLedgerCache(conductor._test_ledger_path(repo_root))
        load = cache.load()
        self.assertIsNone(load.diagnostic)
        reference = parent_runtime_ledger_reference(conductor._read_test_ledger_rows(repo_root))
        self.assertGreater(len(reference), 0)
        self.assertEqual(dict(load.runtimes), reference)

    def test_unchanged_identity_parses_once_and_shares_one_immutable_snapshot(self) -> None:
        ledger, cache = self.make_cache(self.rows(3))
        first = cache.load().runtimes
        for _ in range(4):
            self.assertIs(cache.load().runtimes, first)
        self.assertEqual(cache.parse_count, 1)
        self.assertIsInstance(first, conductor.MappingProxyType)
        with self.assertRaises(TypeError):
            first[(LEDGER_SUITE, "test0")] = 9.0  # type: ignore[index]
        status = os.stat(ledger.resolve())
        self.assertEqual(
            cache._identity(),
            (str(ledger.resolve()), status.st_dev, status.st_ino, status.st_size, status.st_mtime_ns, status.st_ctime_ns),
        )

    def test_identity_change_installs_a_new_snapshot_and_leaves_the_old_one_intact(self) -> None:
        ledger, cache = self.make_cache(self.rows(1, runtime=1.0))
        first = cache.load().runtimes
        self.write_ledger(ledger.parents[2], self.rows(2, runtime=4.0))
        second = cache.load().runtimes
        self.assertIsNot(second, first)
        self.assertEqual(dict(first), {(LEDGER_SUITE, "test0"): 1.0})
        self.assertEqual(second[(LEDGER_SUITE, "test1")], 4.0)
        self.assertIs(cache.load().runtimes, second)
        self.assertEqual(cache.parse_count, 2)

        # Identical bytes under a new inode are a new identity (atomic replace).
        replacement = ledger.with_name("replacement.tsv")
        shutil.copyfile(ledger, replacement)
        os.replace(replacement, ledger)
        third = cache.load().runtimes
        self.assertIsNot(third, second)
        self.assertEqual(dict(third), dict(second))
        self.assertEqual(cache.parse_count, 3)

    def test_symlinked_ledger_is_keyed_by_its_resolved_target(self) -> None:
        ledger, _cache = self.make_cache(self.rows(1, runtime=1.0))
        other = ledger.with_name("other.tsv")
        other.write_text(RUNTIME_LEDGER_HEADER + self.rows(1, runtime=7.0), encoding="utf-8")
        link = ledger.with_name("link.tsv")
        link.symlink_to(ledger)
        cache = conductor.RuntimeLedgerCache(link)
        self.assertEqual(cache.load().runtimes[(LEDGER_SUITE, "test0")], 1.0)
        link.unlink()
        link.symlink_to(other)
        self.assertEqual(cache.load().runtimes[(LEDGER_SUITE, "test0")], 7.0)
        self.assertEqual(cache.parse_count, 2)

    def run_concurrent_loads(
        self, cache: conductor.RuntimeLedgerCache, parse: object
    ) -> tuple[list, list[BaseException]]:
        entered = threading.Event()
        release = threading.Event()
        results: list = [None] * 8
        errors: list[BaseException] = []

        def blocking(rows):  # type: ignore[no-untyped-def]
            entered.set()
            self.assertTrue(release.wait(10))
            return parse(rows)  # type: ignore[operator]

        def load(index: int) -> None:
            try:
                results[index] = cache.load()
            except BaseException as exc:  # noqa: BLE001 - recorded for the assertion
                errors.append(exc)

        with mock.patch.object(conductor, "_parse_xctest_method_runtimes", side_effect=blocking):
            leader = threading.Thread(target=load, args=(0,))
            leader.start()
            self.assertTrue(entered.wait(5))
            joiners = [threading.Thread(target=load, args=(index,)) for index in range(1, 8)]
            for thread in joiners:
                thread.start()
            for thread in joiners:
                thread.join(0.05)
                self.assertTrue(thread.is_alive(), "a joiner finished before the in-flight load")
            release.set()
            for thread in [leader, *joiners]:
                thread.join(10)
                self.assertFalse(thread.is_alive())
        return results, errors

    def test_concurrent_loads_share_one_in_flight_parse(self) -> None:
        _ledger, cache = self.make_cache(self.rows(3))
        results, errors = self.run_concurrent_loads(cache, conductor._parse_xctest_method_runtimes)
        self.assertEqual(errors, [])
        self.assertEqual(cache.parse_count, 1)
        snapshot = results[0].runtimes
        self.assertIsNotNone(snapshot)
        for result in results:
            self.assertIs(result.runtimes, snapshot)
            self.assertIsNone(result.diagnostic)
        self.assertIsNone(cache._flight)
        self.assertIs(cache.load().runtimes, snapshot)
        self.assertEqual(cache.parse_count, 1)

    def test_loader_exception_releases_joiners_with_the_fallback_and_clears_the_flight(self) -> None:
        _ledger, cache = self.make_cache(self.rows(2))

        def failing(_rows):  # type: ignore[no-untyped-def]
            raise RuntimeError("parser boom")

        results, errors = self.run_concurrent_loads(cache, failing)
        self.assertEqual([str(error) for error in errors], ["parser boom"])
        joined = [result for result in results if result is not None]
        self.assertEqual(len(joined), 7)
        for result in joined:
            self.assertIsNone(result.runtimes)
            self.assertIn("runtime ledger loader failed", result.diagnostic)
            self.assertIn("using flat 180.000s active-method defaults", result.diagnostic)
        self.assertIsNone(cache._flight)
        self.assertIsNone(cache._current)
        recovered = cache.load()
        self.assertIsNone(recovered.diagnostic)
        self.assertEqual(len(recovered.runtimes), 2)

    def change_ledger_on_identity_calls(
        self, ledger: Path, cache: conductor.RuntimeLedgerCache, change_on: set[int]
    ) -> tuple[conductor.RuntimeLedgerLoad, list[int]]:
        real_identity = cache._identity
        calls: list[int] = []

        def identity():  # type: ignore[no-untyped-def]
            calls.append(len(calls) + 1)
            if len(calls) in change_on:
                self.write_ledger(ledger.parents[2], self.rows(len(calls) + 1, runtime=float(len(calls))))
            return real_identity()

        with mock.patch.object(cache, "_identity", side_effect=identity):
            load = cache.load()
        return load, calls

    def test_change_during_load_retries_once_and_caches_the_retried_identity(self) -> None:
        ledger, cache = self.make_cache(self.rows(1))
        load, calls = self.change_ledger_on_identity_calls(ledger, cache, {2})
        # Stat before (1), changed stat after the first read (2), stable stat after the retry (3).
        self.assertEqual(calls, [1, 2, 3])
        self.assertIsNone(load.diagnostic)
        self.assertEqual(len(load.runtimes), 3)
        self.assertEqual(load.runtimes[(LEDGER_SUITE, "test0")], 2.0)
        self.assertEqual(cache.parse_count, 1)
        self.assertIs(cache.load().runtimes, load.runtimes)
        self.assertEqual(cache.parse_count, 1)

    def test_repeated_change_during_load_falls_back_to_the_flat_budget(self) -> None:
        ledger, cache = self.make_cache(self.rows(1))
        load, calls = self.change_ledger_on_identity_calls(ledger, cache, {2, 3})
        self.assertEqual(calls, [1, 2, 3])
        self.assertIsNone(load.runtimes)
        self.assertIn("ledger changed during load (retried once)", load.diagnostic)
        self.assertIn("using flat 180.000s active-method defaults", load.diagnostic)
        self.assertEqual(cache.parse_count, 0)
        self.assertIsNone(cache._current)
        recovered = cache.load()
        self.assertIsNone(recovered.diagnostic)
        self.assertEqual(len(recovered.runtimes), 4)
        self.assertEqual(cache.parse_count, 1)

    def test_unreadable_ledger_falls_back_on_every_load_and_drops_the_current_snapshot(self) -> None:
        ledger, cache = self.make_cache(self.rows(1))
        self.assertIsNotNone(cache.load().runtimes)
        ledger.unlink()
        for _ in range(2):
            load = cache.load()
            self.assertIsNone(load.runtimes)
            self.assertIn(f"XCTest runtime ledger unavailable at {ledger}", load.diagnostic)
        self.assertIsNone(cache._current)
        ledger.write_bytes(RUNTIME_LEDGER_HEADER.encode() + b"S\tm\t\xff\troot\n")
        undecodable = cache.load()
        self.assertIsNone(undecodable.runtimes)
        self.assertIn("codec can't decode", undecodable.diagnostic)
        self.write_ledger(ledger.parents[2], self.rows(2))
        self.assertEqual(len(cache.load().runtimes), 2)

    def test_pinned_snapshot_survives_a_ledger_update_with_at_most_two_resident(self) -> None:
        tmp, state = self.make_state()
        self.addCleanup(tmp.cleanup)
        sentinel = (LEDGER_SUITE, "testSentinel")
        self.write_ledger(state.paths.repo_root, f"{LEDGER_SUITE}\ttestSentinel\t1.0\troot\n")
        job = self.make_job(state, "pinned", "test", {}, ["build"], job_state="running")
        state.jobs[job.ticket] = job
        state._pin_xctest_method_runtimes(job)
        self.assertEqual(self.resident_snapshots(sentinel), 1)

        self.write_ledger(state.paths.repo_root, f"{LEDGER_SUITE}\ttestSentinel\t40.0\troot\nS\tm\t1\troot\n")
        self.assertEqual(state.runtime_ledger_cache.load().runtimes[sentinel], 40.0)
        self.assertEqual(self.resident_snapshots(sentinel), 2)
        # The active job keeps the snapshot it pinned.
        with state.condition:
            state._record_xctest_progress_locked(job, f"Test Case '-[{LEDGER_SUITE} testSentinel]' started.\n", 1.0)
        self.assertEqual(job.xctest_active_method_budget_seconds, 90.0)

        with state.condition:
            state._release_xctest_method_runtimes_locked(job)
        self.assertIsNone(job.xctest_method_runtimes)
        self.assertEqual(self.resident_snapshots(sentinel), 1)

    def test_budget_lookup_uses_the_pinned_snapshot_without_ledger_io(self) -> None:
        tmp, state = self.make_state()
        self.addCleanup(tmp.cleanup)
        ledger = self.write_ledger(state.paths.repo_root, f"{LEDGER_SUITE}\ttestPinned\t40.0\troot\n")
        job = self.make_job(state, "no-io", "test", {}, ["build"], job_state="running")
        state.jobs[job.ticket] = job
        state._pin_xctest_method_runtimes(job)
        ledger.unlink()
        with mock.patch.object(state.runtime_ledger_cache, "load", side_effect=AssertionError("ledger I/O")):
            with state.condition:
                state._record_xctest_progress_locked(job, f"Test Case '-[{LEDGER_SUITE} testPinned]' started.\n", 1.0)
        self.assertEqual(job.xctest_active_method_budget_seconds, 190.0)
        self.assertEqual(job.xctest_active_method_budget_source, "ledger-derived")

    def test_jobs_that_do_not_consult_the_ledger_never_load_it(self) -> None:
        tmp, state = self.make_state()
        self.addCleanup(tmp.cleanup)
        self.write_ledger(state.paths.repo_root, self.rows(1))
        jobs = [
            self.make_job(state, "build", "build", {}, ["build"]),
            self.make_job(state, "override", "test", {"xctestStallSeconds": 5.0}, ["build"]),
            self.make_job(state, "list", "test", {"list": True}, ["build"]),
            self.make_job(state, "disabled", "test", {"xctestDeadlines": False}, ["build"]),
        ]
        for job in jobs:
            state._pin_xctest_method_runtimes(job)
            self.assertIsNone(job.xctest_method_runtimes)
        self.assertEqual(state.runtime_ledger_cache.parse_count, 0)

    def run_ledger_job(
        self,
        state: conductor.DaemonState,
        ticket: str,
        child_code: str,
        extra: contextlib.ExitStack | None = None,
        timeout: float | None = None,
    ) -> conductor.Job:
        argv = [sys.executable, "-u", "-c", child_code]
        job = self.make_job(state, ticket, "test", {}, ["build"], job_state="running")
        job.timeout = timeout
        state.jobs[job.ticket] = job
        state.active_lanes = {"build": job.ticket}

        def prepare(_request: dict) -> tuple[list[str], list[str], Path, dict[str, str], float]:
            return argv, ["build"], state.paths.repo_root, os.environ.copy(), 10.0

        with contextlib.ExitStack() as stack:
            stack.enter_context(mock.patch.object(conductor, "operation_requires_global_heavy_slot", return_value=False))
            stack.enter_context(mock.patch.object(conductor, "operation_requires_global_xctest_slot", return_value=False))
            stack.enter_context(mock.patch.object(conductor, "source_snapshot", return_value=None))
            stack.enter_context(mock.patch.object(state.registry, "prepare", side_effect=prepare))
            stack.enter_context(
                mock.patch.multiple(
                    conductor, TERMINATE_GRACE_SECONDS=0.05, KILL_GRACE_SECONDS=0.2, PROCESS_TREE_POLL_SECONDS=0.01
                )
            )
            if extra is not None:
                stack.enter_context(extra)
            state._run_job(job.ticket)
        return job

    def test_run_job_pins_before_popen_outside_the_condition_and_releases_at_completion(self) -> None:
        tmp, state = self.make_state()
        self.addCleanup(tmp.cleanup)
        ledger = self.write_ledger(state.paths.repo_root, f"{LEDGER_SUITE}\ttestFast\t40.0\troot\n")
        resolved = str(ledger.resolve())
        io_events: list[tuple[str, bool]] = []
        popen_pins: list[object] = []
        real_open = open
        real_identity = state.runtime_ledger_cache._identity
        real_parse = conductor._parse_xctest_method_runtimes
        real_popen = conductor.subprocess.Popen

        def owned() -> bool:
            return bool(state.lock._is_owned())

        def recording_open(file, *args, **kwargs):  # type: ignore[no-untyped-def]
            if str(file) == resolved:
                io_events.append(("open", owned()))
            return real_open(file, *args, **kwargs)

        def recording_identity():  # type: ignore[no-untyped-def]
            io_events.append(("stat", owned()))
            return real_identity()

        def recording_parse(rows):  # type: ignore[no-untyped-def]
            io_events.append(("parse", owned()))
            return real_parse(rows)

        def recording_popen(*args, **kwargs):  # type: ignore[no-untyped-def]
            argv = args[0] if args else kwargs.get("args")
            if isinstance(argv, list) and argv[:3] == [sys.executable, "-u", "-c"]:
                current = state.jobs.get(ticket_holder[0])
                popen_pins.append(None if current is None else current.xctest_method_runtimes)
            return real_popen(*args, **kwargs)

        child = (
            f"print(\"Test Case '-[{LEDGER_SUITE} testFast]' started.\", flush=True)\n"
            f"print(\"Test Case '-[{LEDGER_SUITE} testFast]' passed (0.001 seconds).\", flush=True)\n"
        )
        ticket_holder = [""]
        jobs = []
        for ticket in ("ledger-first", "ledger-second"):
            ticket_holder[0] = ticket
            extra = contextlib.ExitStack()
            extra.enter_context(mock.patch.object(conductor, "open", side_effect=recording_open, create=True))
            extra.enter_context(mock.patch.object(state.runtime_ledger_cache, "_identity", side_effect=recording_identity))
            extra.enter_context(mock.patch.object(conductor, "_parse_xctest_method_runtimes", side_effect=recording_parse))
            extra.enter_context(mock.patch.object(conductor.subprocess, "Popen", side_effect=recording_popen))
            jobs.append(self.run_ledger_job(state, ticket, child, extra))

        for job in jobs:
            self.assertEqual(job.state, "completed", job.error)
            self.assertEqual(job.xctest_active_method_budget_source, "ledger-derived")
            self.assertEqual(job.xctest_active_method_budget_seconds, 190.0)
            self.assertIsNone(job.xctest_method_runtimes)
        # Pinned before process start, and both jobs pinned the same snapshot.
        self.assertEqual(len(popen_pins), 2)
        self.assertIsNotNone(popen_pins[0])
        self.assertIs(popen_pins[0], popen_pins[1])
        # One read and one parse for the unchanged identity; a stat per job; none under the condition.
        self.assertEqual([kind for kind, _ in io_events if kind != "stat"], ["open", "parse"])
        self.assertEqual(sum(1 for kind, _ in io_events if kind == "stat"), 3)
        self.assertFalse(any(is_owned for _kind, is_owned in io_events), io_events)
        self.assertEqual(state.runtime_ledger_cache.parse_count, 1)

    def test_run_job_releases_the_pin_on_cancellation_and_on_runner_errors(self) -> None:
        tmp, state = self.make_state()
        self.addCleanup(tmp.cleanup)
        self.write_ledger(state.paths.repo_root, f"{LEDGER_SUITE}\ttestSlow\t1.0\troot\n")
        pinned: list[object] = []
        real_pin = state._pin_xctest_method_runtimes

        def pin_then_cancel(job: conductor.Job) -> None:
            real_pin(job)
            pinned.append(job.xctest_method_runtimes)
            with state.condition:
                job.cancel_requested = True

        extra = contextlib.ExitStack()
        extra.enter_context(mock.patch.object(state, "_pin_xctest_method_runtimes", side_effect=pin_then_cancel))
        canceled = self.run_ledger_job(state, "ledger-cancel", "import time\ntime.sleep(30)\n", extra)
        self.assertEqual(canceled.state, "canceled")
        self.assertIsNotNone(pinned[0])
        self.assertIsNone(canceled.xctest_method_runtimes)

        def failing_transport(_job: conductor.Job) -> conductor.ProcessOutputTransport:
            pinned.append(_job.xctest_method_runtimes)
            raise RuntimeError("transport boom")

        extra = contextlib.ExitStack()
        extra.enter_context(mock.patch.object(state, "_create_process_output_transport", side_effect=failing_transport))
        failed = self.run_ledger_job(state, "ledger-error", "print('unused')\n", extra)
        self.assertEqual(failed.state, "failed")
        self.assertEqual(failed.exit_code, 1)
        self.assertIn("transport boom", failed.error or "")
        self.assertIs(pinned[1], pinned[0])
        self.assertIsNone(failed.xctest_method_runtimes)
        self.assertEqual(state.runtime_ledger_cache.parse_count, 1)

    def test_clamped_budget_diagnostic_is_written_outside_the_condition_in_reader_order(self) -> None:
        tmp, state = self.make_state()
        self.addCleanup(tmp.cleanup)
        self.write_ledger(state.paths.repo_root, f"{LEDGER_SUITE}\ttestClamp\t40.0\troot\n")
        child = (
            "import time\n"
            f"print(\"Test Case '-[{LEDGER_SUITE} testClamp]' started.\", flush=True)\n"
            f"print(\"Test Case '-[{LEDGER_SUITE} testClamp]' passed (0.001 seconds).\", flush=True)\n"
            "time.sleep(0.3)\n"
            f"print(\"Test Case '-[{LEDGER_SUITE} testUnknown]' started.\", flush=True)\n"
            f"print(\"Test Case '-[{LEDGER_SUITE} testUnknown]' passed (0.001 seconds).\", flush=True)\n"
        )
        writes: list[tuple[bytes, bool]] = []
        with record_log_writes(lambda: state, writes):
            job = self.run_ledger_job(state, "clamped", child, timeout=20.0)
        self.assertEqual(job.state, "completed", job.error)
        clamp_ledger = (
            "XCTest active-method budget clamped from 190.000s to job timeout 20.000s "
            f"for method=-[{LEDGER_SUITE} testClamp]; source=ledger-derived\n"
        )
        clamp_default = (
            "XCTest active-method budget clamped from 180.000s to job timeout 20.000s "
            f"for method=-[{LEDGER_SUITE} testUnknown]; source=default\n"
        )
        # The tail gets each line under the condition, in transition order.
        self.assertEqual([entry for entry in job.tail if "budget clamped" in entry], [clamp_ledger, clamp_default])
        # The log gets each exactly once, after its marker's read and before the next marker.
        log = job.log_path.read_text(encoding="utf-8")
        self.assertEqual((log.count(clamp_ledger), log.count(clamp_default)), (1, 1))
        self.assertLess(log.index(f"-[{LEDGER_SUITE} testClamp]' started."), log.index(clamp_ledger))
        self.assertLess(log.index(clamp_ledger), log.index(f"-[{LEDGER_SUITE} testUnknown]' started."))
        self.assertLess(log.index(f"-[{LEDGER_SUITE} testUnknown]' started."), log.index(clamp_default))
        clamp_writes = [owned for data, owned in writes if b"budget clamped" in data]
        self.assertEqual(clamp_writes, [False, False])
        self.assertIsNone(job.deferred_log_lines)

    def test_direct_progress_callers_flush_queued_clamp_lines_after_the_condition(self) -> None:
        tmp, state = self.make_state()
        self.addCleanup(tmp.cleanup)
        job = self.make_job(state, "direct", "test", {}, ["build"], job_state="running")
        job.timeout = 20.0
        state.jobs[job.ticket] = job
        writes: list[tuple[bytes, bool]] = []
        with record_log_writes(lambda: state, writes):
            with state.condition:
                state._record_xctest_progress_locked(job, f"Test Case '-[{LEDGER_SUITE} testA]' started.\n", 1.0)
                self.assertEqual(len(job.deferred_log_lines), 1)
                self.assertIn("budget clamped", list(job.tail)[-1])
            self.assertFalse(job.log_path.exists())
            state._flush_deferred_log_lines(job)
            state._flush_deferred_log_lines(job)
        self.assertEqual(job.log_path.read_text(encoding="utf-8").count("budget clamped"), 1)
        self.assertEqual([owned for _data, owned in writes], [False])
        self.assertIsNone(job.deferred_log_lines)

    def test_run_job_flushes_a_left_over_queue_at_its_end(self) -> None:
        tmp, state = self.make_state()
        self.addCleanup(tmp.cleanup)
        self.write_ledger(state.paths.repo_root, self.rows(1))
        real_pin = state._pin_xctest_method_runtimes

        def pin_and_queue(job: conductor.Job) -> None:
            real_pin(job)
            with state.condition:
                state._append_deferred_system_line_locked(job, "queued by a direct caller\n")

        extra = contextlib.ExitStack()
        extra.enter_context(mock.patch.object(state, "_pin_xctest_method_runtimes", side_effect=pin_and_queue))
        job = self.run_ledger_job(state, "left-over", "import time\ntime.sleep(0.2)\n", extra)
        self.assertEqual(job.state, "completed", job.error)
        self.assertEqual(job.log_path.read_text(encoding="utf-8").count("queued by a direct caller\n"), 1)
        self.assertIsNone(job.deferred_log_lines)

    def test_every_ledger_consulting_operation_holds_the_build_lane(self) -> None:
        """The "at most 2 resident snapshots" bound: pinning jobs are mutually exclusive by lane."""
        tmp, state = self.make_state()
        self.addCleanup(tmp.cleanup)
        operations = sorted(
            name
            for name in ("test", "test-artifact", "test-parallel", "provider-test", "core-test", "build", "lint")
            if state._xctest_watchdog_enabled(self.make_job(state, name, name, {"filter": "X"}, []))
        )
        self.assertEqual(operations, ["core-test", "provider-test", "test", "test-artifact"])
        with mock.patch.object(conductor, "admit_test_artifact", return_value=None):
            for operation in operations:
                request = {"operation": operation, "args": {"filter": "X"}, "timeout": None, "verbose": False, "env": {}}
                _argv, lanes, _cwd, _env, _timeout = state.registry.prepare(request)
                self.assertIn("build", lanes, operation)


# ---------------------------------------------------------------------------
# Step 10 (lean): debug dSYM policy forwarding and ticket-preserving ``dsym`` dispatch.


class DebugSymbolPolicyTests(LifecycleTestCase):
    def setUp(self) -> None:
        super().setUp()
        self.tmp, self.state = self.make_state()
        self.addCleanup(self.tmp.cleanup)
        self.root = self.state.paths.repo_root

    def test_unset_and_off_are_one_request_identity_and_child_value(self) -> None:
        registry = self.state.registry
        base = {"operation": "swift-build", "args": {"product": "RepoPrompt"}, "timeout": None, "verbose": False}
        unset, off, on = (dict(base, env=env) for env in ({}, {"RPCE_DEBUG_DSYM": "off"}, {"RPCE_DEBUG_DSYM": "on"}))
        self.assertEqual(registry._request_env_snapshot(unset)["RPCE_DEBUG_DSYM"], "off")
        self.assertEqual(registry.fingerprint(unset), registry.fingerprint(off))
        self.assertNotEqual(registry.fingerprint(unset), registry.fingerprint(on))
        self.assertEqual(registry.prepare(unset)[3]["RPCE_DEBUG_DSYM"], "off")
        self.assertEqual(registry.prepare(on)[3]["RPCE_DEBUG_DSYM"], "on")
        self.assertIn("RPCE_DEBUG_DSYM", conductor.OperationRegistry.PASSTHROUGH_ENV_KEYS)
        # Ticket and candidate identity never include the policy: no new artifact env gate.
        self.assertNotIn("RPCE_DEBUG_DSYM", conductor.artifact_env_gates({"RPCE_DEBUG_DSYM": "on"}))
        self.assertNotIn("RPCE_DEBUG_DSYM", conductor.PARALLEL_XCTEST_RUNTIME_GATE_KEYS)

    def test_conductor_policy_constants_match_the_helper(self) -> None:
        import debug_dsym

        self.assertEqual(conductor.DEBUG_DSYM_POLICY_ENV_KEY, debug_dsym.POLICY_ENV_KEY)
        self.assertEqual(conductor.DEBUG_DSYM_POLICY_VALUES, debug_dsym.POLICY_VALUES)
        self.assertEqual(conductor.DEBUG_DSYM_PRODUCTS, debug_dsym.PRODUCT_SELECTORS)
        self.assertEqual(conductor.DEBUG_SYMBOL_POLICY_EXIT_CODE, debug_dsym.POLICY_EXIT_INVALID)

    def test_invalid_policy_is_rejected_in_the_client_and_at_enqueue(self) -> None:
        for value in ("", "ON", "1", "skip"):
            with self.subTest(value=value):
                with mock.patch.dict(os.environ, {"RPCE_DEBUG_DSYM": value}):
                    with self.assertRaises(conductor.DebugSymbolPolicyError):
                        conductor.OperationRegistry.client_env_snapshot()
                with mock.patch.object(self.state, "_schedule_locked"), \
                        self.assertRaises(conductor.DebugSymbolPolicyError):
                    self.state.enqueue({"type": "enqueue", "operation": "swift-build",
                                        "args": {"product": "RepoPrompt"}, "env": {"RPCE_DEBUG_DSYM": value}})
                self.assertEqual(self.state.jobs, {})

    def test_client_rejects_an_invalid_policy_with_exit_2_before_contacting_a_daemon(self) -> None:
        with (
            mock.patch.dict(os.environ, {"RPCE_DEBUG_DSYM": "maybe"}),
            mock.patch.object(conductor, "ensure_daemon") as ensure,
            mock.patch.object(conductor, "request_daemon") as request,
            mock.patch.object(conductor, "compute_paths", return_value=self.state.paths),
            contextlib.redirect_stderr(io.StringIO()) as stderr,
        ):
            code = conductor.cli_main(["swift-build", "--product", "RepoPrompt"])
            sleep_code = conductor.cli_main(["sleep", "0", "--lane", "build"])
        self.assertEqual((code, sleep_code), (2, 2))
        ensure.assert_not_called()
        request.assert_not_called()
        self.assertIn("RPCE_DEBUG_DSYM must be 'on' or 'off'", stderr.getvalue())

    def test_dsym_resources_argv_and_ticket_policy(self) -> None:
        request = {"operation": "dsym", "args": {"product": "root-tests"}, "timeout": None, "verbose": False, "env": {}}
        argv, lanes, cwd, env, _timeout = self.state.registry.prepare(request)
        self.assertEqual(lanes, ["build"])
        self.assertEqual(cwd, self.root)
        self.assertEqual(argv, [sys.executable, "-I", "-B", str(self.root / "Scripts" / "debug_dsym.py"), "regenerate",
                                "--product", "root-tests", "--package-root", str(self.root)])
        self.assertEqual(env["RPCE_DEBUG_DSYM"], "off")
        self.assertTrue(conductor.operation_requires_global_heavy_slot("dsym", {}))
        self.assertFalse(conductor.operation_requires_global_xctest_slot("dsym", {}))
        self.assertFalse(conductor.operation_invalidates_root_build_ticket("dsym", {"product": "all"}))
        with self.assertRaises(conductor.ConductorError):
            self.state.registry.prepare(dict(request, args={"product": "everything"}))

    def test_dsym_dispatch_preserves_the_root_build_ticket(self) -> None:
        scripts = self.root / "Scripts"
        scripts.mkdir()
        shutil.copy2(SCRIPT_DIR / "debug_dsym.py", scripts / "debug_dsym.py")
        ticket_path = self.state.paths.jobs_dir / "build-ticket-root.json"
        conductor.write_build_ticket(ticket_path, {"ticket_id": "keep"})
        before = ticket_path.read_bytes()
        job = self.make_job(self.state, "dsym-job", "dsym", {"product": "all"}, ["build"], job_state="running")
        self.state.jobs[job.ticket] = job
        with (
            mock.patch.object(conductor, "operation_requires_global_heavy_slot", return_value=False),
            mock.patch.object(self.state, "_xctest_watchdog_enabled", return_value=False),
        ):
            self.state._run_job(job.ticket)
        # No native debug build exists here: regeneration fails without building anything.
        self.assertEqual((job.state, job.exit_code), ("failed", 1), job.result_summary)
        self.assertEqual(ticket_path.read_bytes(), before)
        self.assertIn("no native debug build exists", job.log_path.read_text(encoding="utf-8"))
        self.assertFalse((self.root / ".build").exists())

    def test_dsym_cli_parsing(self) -> None:
        captured: dict = {}

        def capture(_paths, operation, args, _flags, *rest):
            captured[operation] = dict(args)
            return 0

        with mock.patch.object(conductor, "enqueue_and_maybe_wait", side_effect=capture):
            conductor.handle_real_operation(self.state.paths, "dsym", [])
        self.assertEqual(captured, {"dsym": {"product": "all"}})
        with mock.patch.object(conductor, "enqueue_and_maybe_wait", side_effect=capture):
            conductor.handle_real_operation(self.state.paths, "dsym", ["--product", "repoprompt-mcp"])
        self.assertEqual(captured["dsym"], {"product": "repoprompt-mcp"})
        with mock.patch.object(conductor, "enqueue_and_maybe_wait") as never, self.assertRaises(SystemExit), \
                contextlib.redirect_stderr(io.StringIO()):
            conductor.handle_real_operation(self.state.paths, "dsym", ["--product", "everything"])
        never.assert_not_called()
        self.assertIn("dsym", conductor.IMPLEMENTED_OPERATIONS)
        self.assertNotIn("dsym-check", conductor.IMPLEMENTED_OPERATIONS)


if __name__ == "__main__":
    unittest.main()
