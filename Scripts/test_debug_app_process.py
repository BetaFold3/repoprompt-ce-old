#!/usr/bin/env python3
"""Hermetic tests for RepoPrompt CE debug app process identity checks."""

from __future__ import annotations

import os
import plistlib
import shutil
import signal
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

SCRIPT_DIR = Path(__file__).resolve().parent
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))

import debug_app_process  # noqa: E402


class FakeInspector:
    def __init__(
        self,
        names: dict[int, str],
        paths: dict[int, Path | list[Path] | Exception],
        launch_services: dict[int, tuple[Path, str]] | None = None,
    ) -> None:
        self.names = names
        self.paths = paths
        self.launch_services = launch_services or {}
        self.launch_services_queries: list[int] = []

    def launch_services_identity(self, pid: int) -> tuple[Path, str] | None:
        self.launch_services_queries.append(pid)
        registered = self.launch_services.get(pid)
        if registered is None:
            return None
        return registered[0].resolve(strict=False), registered[1]

    def list_pids(self) -> list[int]:
        return list(self.names)

    def process_name(self, pid: int) -> str | None:
        return self.names.get(pid)

    def process_path(self, pid: int) -> Path:
        value = self.paths[pid]
        if isinstance(value, Exception):
            raise value
        if isinstance(value, list):
            current = value.pop(0) if len(value) > 1 else value[0]
            if isinstance(current, Exception):
                raise current
            return current.resolve(strict=True)
        return value.resolve(strict=True)


class DebugAppProcessTests(unittest.TestCase):
    def make_executable(self, root: Path, relative_path: str) -> Path:
        executable = root / relative_path
        executable.parent.mkdir(parents=True, exist_ok=True)
        executable.write_text("binary", encoding="utf-8")
        executable.chmod(0o755)
        return executable.resolve(strict=True)

    def test_only_exact_debug_executable_is_included(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            debug = self.make_executable(root, "Library/Application Support/RepoPrompt CE/DebugApps/RepoPrompt.app/Contents/MacOS/RepoPrompt")
            production = self.make_executable(root, "Applications/RepoPrompt.app/Contents/MacOS/RepoPrompt")
            ce_release = self.make_executable(root, "Applications/RepoPrompt CE.app/Contents/MacOS/RepoPrompt")
            inspector = FakeInspector(
                {101: "RepoPrompt", 102: "RepoPrompt", 103: "RepoPrompt", 104: "Other"},
                {101: debug, 102: production, 103: ce_release, 104: debug},
            )

            matches = debug_app_process.matching_processes(debug, inspector)

        self.assertEqual(matches, [101])

    def test_termination_revalidates_identity_and_rejects_pid_reuse(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            debug = self.make_executable(root, "Debug/RepoPrompt.app/Contents/MacOS/RepoPrompt")
            production = self.make_executable(root, "Production/RepoPrompt.app/Contents/MacOS/RepoPrompt")
            inspector = FakeInspector({201: "RepoPrompt"}, {201: [debug, production]})
            signals: list[tuple[int, int]] = []

            with self.assertRaisesRegex(debug_app_process.ProcessIdentityError, "executable changed"):
                debug_app_process.terminate_matching_processes(
                    debug,
                    inspector,
                    signaler=lambda pid, sent_signal: signals.append((pid, sent_signal)),
                )

        self.assertEqual(signals, [])

    def test_matching_identity_is_revalidated_then_signaled(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            debug = self.make_executable(Path(tmp), "Debug/RepoPrompt.app/Contents/MacOS/RepoPrompt")
            inspector = FakeInspector({301: "RepoPrompt"}, {301: [debug, debug]})
            signals: list[tuple[int, int]] = []

            signaled = debug_app_process.terminate_matching_processes(
                debug,
                inspector,
                signaler=lambda pid, sent_signal: signals.append((pid, sent_signal)),
            )

        self.assertEqual(signaled, [301])
        self.assertEqual(signals, [(301, signal.SIGTERM)])

    def test_missing_target_is_normal_not_installed_state(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            missing = Path(tmp) / "DebugApps" / "RepoPrompt.app" / "Contents" / "MacOS" / "RepoPrompt"
            inspector = FakeInspector({101: "RepoPrompt"}, {})
            signals: list[tuple[int, int]] = []

            matches = debug_app_process.matching_processes(missing, inspector)
            signaled = debug_app_process.terminate_matching_processes(
                missing,
                inspector,
                signaler=lambda pid, sent_signal: signals.append((pid, sent_signal)),
            )

        self.assertEqual(matches, [])
        self.assertEqual(signaled, [])
        self.assertEqual(signals, [])

    def make_bundle(self, root: Path, relative_bundle: str, bundle_id: str) -> tuple[Path, Path]:
        bundle = root / relative_bundle
        executable = self.make_executable(root, f"{relative_bundle}/Contents/MacOS/RepoPrompt")
        with (bundle / "Contents" / "Info.plist").open("wb") as handle:
            plistlib.dump({"CFBundleIdentifier": bundle_id, "CFBundleExecutable": "RepoPrompt"}, handle)
        return bundle.resolve(strict=True), executable

    def test_process_running_from_replaced_and_deleted_bundle_is_matched_by_launch_services_identity(self) -> None:
        # A build that publishes into the running app's destination leaves the old process on an unlinked
        # executable; proc_pidpath then reports ENOENT. It must stay visible so stop and relaunch work.
        with tempfile.TemporaryDirectory() as tmp:
            bundle, debug = self.make_bundle(Path(tmp), "Applications/RepoPrompt CE Dev.app", "com.example.debug")
            detached = debug_app_process.ExecutableDetached("pid 501 is running from an executable that no longer exists on disk")
            inspector = FakeInspector(
                {501: "RepoPrompt"},
                {501: detached},
                launch_services={501: (bundle, "com.example.debug")},
            )
            signals: list[tuple[int, int]] = []

            matches = debug_app_process.matching_processes(debug, inspector)
            signaled = debug_app_process.terminate_matching_processes(
                debug,
                inspector,
                signaler=lambda pid, sent_signal: signals.append((pid, sent_signal)),
            )

        self.assertEqual(matches, [501])
        self.assertEqual(signaled, [501])
        self.assertEqual(signals, [(501, signal.SIGTERM)])

    def test_detached_process_without_launch_services_registration_fails_closed(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            _, debug = self.make_bundle(Path(tmp), "Applications/RepoPrompt CE Dev.app", "com.example.debug")
            inspector = FakeInspector(
                {601: "RepoPrompt"},
                {601: debug_app_process.ExecutableDetached("pid 601 is running from an executable that no longer exists on disk")},
            )
            signals: list[tuple[int, int]] = []

            with self.assertRaisesRegex(debug_app_process.ProcessIdentityError, "quit it manually"):
                debug_app_process.terminate_matching_processes(
                    debug,
                    inspector,
                    signaler=lambda pid, sent_signal: signals.append((pid, sent_signal)),
                )

        self.assertEqual(signals, [])

    def test_detached_process_registered_for_another_bundle_is_ignored(self) -> None:
        # For example, a production RepoPrompt replaced in place while running: not ours, and not a reason to block.
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            _, debug = self.make_bundle(root, "Applications/RepoPrompt CE Dev.app", "com.example.debug")
            other_bundle, _ = self.make_bundle(root, "Applications/RepoPrompt.app", "com.example.production")
            for registration in [(other_bundle, "com.example.production"), (other_bundle, "com.example.debug")]:
                with self.subTest(registration=registration):
                    inspector = FakeInspector(
                        {602: "RepoPrompt"},
                        {602: debug_app_process.ExecutableDetached("pid 602 is running from an executable that no longer exists on disk")},
                        launch_services={602: registration},
                    )
                    signals: list[tuple[int, int]] = []

                    matches = debug_app_process.matching_processes(debug, inspector)
                    signaled = debug_app_process.terminate_matching_processes(
                        debug,
                        inspector,
                        signaler=lambda pid, sent_signal: signals.append((pid, sent_signal)),
                    )

                    self.assertEqual(matches, [])
                    self.assertEqual(signaled, [])
                    self.assertEqual(signals, [])

    def test_bundle_renamed_aside_is_matched_only_by_target_registration(self) -> None:
        # Between the publish swap and deletion, the old process's path points into a hidden package sibling.
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            bundle, debug = self.make_bundle(root, "Applications/RepoPrompt CE Dev.app", "com.example.debug")
            aside = self.make_executable(root, "Applications/.rpce-package-1/RepoPrompt CE Dev.app/Contents/MacOS/RepoPrompt")
            production_bundle, production = self.make_bundle(root, "Applications/RepoPrompt.app", "com.example.production")
            inspector = FakeInspector(
                {701: "RepoPrompt", 702: "RepoPrompt", 703: "RepoPrompt"},
                {701: aside, 702: production, 703: production},
                launch_services={
                    701: (bundle, "com.example.debug"),
                    702: (production_bundle, "com.example.production"),
                    703: (production_bundle, "com.example.debug"),
                },
            )

            matches = debug_app_process.matching_processes(debug, inspector)

        self.assertEqual(matches, [701])

    def test_exact_executable_match_does_not_query_launch_services(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            _, debug = self.make_bundle(Path(tmp), "Applications/RepoPrompt CE Dev.app", "com.example.debug")
            inspector = FakeInspector({801: "RepoPrompt"}, {801: debug})

            matches = debug_app_process.matching_processes(debug, inspector)

        self.assertEqual(matches, [801])
        self.assertEqual(inspector.launch_services_queries, [])

    def test_process_gone_during_identity_check_is_skipped(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            _, debug = self.make_bundle(Path(tmp), "Applications/RepoPrompt CE Dev.app", "com.example.debug")
            inspector = FakeInspector({901: "RepoPrompt"}, {901: debug_app_process.ProcessGone("process 901 exited")})

            self.assertEqual(debug_app_process.matching_processes(debug, inspector), [])

    def detached(self, pid: int) -> debug_app_process.ExecutableDetached:
        return debug_app_process.ExecutableDetached(f"pid {pid} is running from an executable that no longer exists on disk")

    def test_detached_process_that_exits_during_launch_services_lookup_is_skipped(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            _, debug = self.make_bundle(Path(tmp), "Applications/RepoPrompt CE Dev.app", "com.example.debug")
            inspector = FakeInspector(
                {1001: "RepoPrompt"},
                {1001: [self.detached(1001), debug_app_process.ProcessGone("process 1001 exited")]},
            )

            self.assertEqual(debug_app_process.matching_processes(debug, inspector), [])

    def test_signaled_process_that_exits_during_revalidation_is_not_an_identity_error(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            bundle, debug = self.make_bundle(Path(tmp), "Applications/RepoPrompt CE Dev.app", "com.example.debug")
            gone = debug_app_process.ProcessGone("process 1002 exited")
            inspector = FakeInspector(
                {1002: "RepoPrompt"},
                {1002: [self.detached(1002), self.detached(1002), gone]},
                launch_services={1002: (bundle, "com.example.debug")},
            )
            original_lookup = inspector.launch_services_identity

            def lookup_once(pid: int) -> tuple[Path, str] | None:
                # LaunchServices drops the registration once the app starts exiting.
                registered = original_lookup(pid)
                inspector.launch_services.clear()
                return registered

            inspector.launch_services_identity = lookup_once  # type: ignore[method-assign]
            signals: list[tuple[int, int]] = []

            signaled = debug_app_process.terminate_matching_processes(
                debug,
                inspector,
                signaler=lambda pid, sent_signal: signals.append((pid, sent_signal)),
            )

        self.assertEqual(signaled, [])
        self.assertEqual(signals, [])

    def test_process_in_publish_sibling_without_launch_services_registration_fails_closed(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            _, debug = self.make_bundle(root, "Applications/RepoPrompt CE Dev.app", "com.example.debug")
            aside = self.make_executable(root, "Applications/.rpce-package-7/RepoPrompt CE Dev.app/Contents/MacOS/RepoPrompt")
            inspector = FakeInspector({1101: "RepoPrompt"}, {1101: aside})

            with self.assertRaisesRegex(debug_app_process.ProcessIdentityError, "renamed aside.*quit it manually"):
                debug_app_process.matching_processes(debug, inspector)

    def test_unregistered_process_elsewhere_is_ignored(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            _, debug = self.make_bundle(root, "Applications/RepoPrompt CE Dev.app", "com.example.debug")
            build_product = self.make_executable(root, "repo/.build/debug/RepoPrompt")
            inspector = FakeInspector({1201: "RepoPrompt"}, {1201: build_product})

            self.assertEqual(debug_app_process.matching_processes(debug, inspector), [])

    def test_detached_process_with_unreadable_target_info_plist_fails_closed(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            debug = self.make_executable(Path(tmp), "Applications/RepoPrompt CE Dev.app/Contents/MacOS/RepoPrompt")
            bundle = debug.parent.parent.parent
            inspector = FakeInspector(
                {1301: "RepoPrompt"},
                {1301: self.detached(1301)},
                launch_services={1301: (bundle, "com.example.debug")},
            )

            with self.assertRaisesRegex(debug_app_process.ProcessIdentityError, "quit it manually"):
                debug_app_process.matching_processes(debug, inspector)

    def test_exact_only_excludes_launch_services_matches_and_detached_processes(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            bundle, debug = self.make_bundle(root, "Applications/RepoPrompt CE Dev.app", "com.example.debug")
            aside = self.make_executable(root, "Applications/.rpce-package-2/RepoPrompt CE Dev.app/Contents/MacOS/RepoPrompt")
            inspector = FakeInspector(
                {1401: "RepoPrompt", 1402: "RepoPrompt", 1403: "RepoPrompt"},
                {1401: debug, 1402: aside, 1403: self.detached(1403)},
                launch_services={1402: (bundle, "com.example.debug"), 1403: (bundle, "com.example.debug")},
            )

            exact = debug_app_process.matching_processes(debug, inspector, exact_only=True)
            everything = debug_app_process.matching_processes(debug, inspector)

        self.assertEqual(exact, [1401])
        self.assertEqual(everything, [1401, 1402, 1403])

    def test_processes_registered_elsewhere_lists_same_bundle_id_from_other_bundles_only(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            bundle, _ = self.make_bundle(root, "Applications/RepoPrompt CE Dev.app", "com.example.debug")
            variant, _ = self.make_bundle(root, "Applications/.RepoPrompt CE Dev-variant.app", "com.example.debug")
            production, _ = self.make_bundle(root, "Applications/RepoPrompt.app", "com.example.production")
            inspector = FakeInspector(
                {1501: "RepoPrompt", 1502: "RepoPrompt", 1503: "RepoPrompt", 1504: "RepoPrompt", 1505: "Other"},
                {},
                launch_services={
                    1501: (bundle, "com.example.debug"),
                    1502: (variant, "com.example.debug"),
                    1503: (production, "com.example.production"),
                    1505: (variant, "com.example.debug"),
                },
            )

            found = debug_app_process.processes_registered_elsewhere(bundle, "com.example.debug", "RepoPrompt", inspector)

        self.assertEqual(found, [(1502, variant)])

    def test_malformed_target_info_plist_keeps_exact_match_and_fails_ambiguous_cases_closed(self) -> None:
        for content in [b'<?xml version="1.0"?><plist><dict><key>CFBundleIdentifier</key>', b"garbage"]:
            with self.subTest(content=content), tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp)
                bundle, debug = self.make_bundle(root, "Applications/RepoPrompt CE Dev.app", "com.example.debug")
                (bundle / "Contents" / "Info.plist").write_bytes(content)
                aside = self.make_executable(root, "Applications/.rpce-package-3/RepoPrompt CE Dev.app/Contents/MacOS/RepoPrompt")
                registration = {pid: (bundle, "com.example.debug") for pid in (1601, 1602, 1603)}

                self.assertIsNone(debug_app_process.read_bundle_identifier(bundle))
                exact = FakeInspector({1601: "RepoPrompt"}, {1601: debug}, launch_services=registration)
                self.assertEqual(debug_app_process.matching_processes(debug, exact), [1601])
                self.assertEqual(debug_app_process.matching_processes(debug, exact, exact_only=True), [1601])
                for pid, path in [(1602, self.detached(1602)), (1603, aside)]:
                    ambiguous = FakeInspector({pid: "RepoPrompt"}, {pid: path}, launch_services=registration)
                    with self.assertRaisesRegex(debug_app_process.ProcessIdentityError, "quit it manually"):
                        debug_app_process.matching_processes(debug, ambiguous)

    def test_detached_process_registered_elsewhere_is_ignored_even_when_target_info_plist_is_unreadable(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            debug = self.make_executable(root, "Applications/RepoPrompt CE Dev.app/Contents/MacOS/RepoPrompt")
            production, _ = self.make_bundle(root, "Applications/RepoPrompt.app", "com.example.production")
            inspector = FakeInspector(
                {1701: "RepoPrompt"},
                {1701: self.detached(1701)},
                launch_services={1701: (production, "com.example.production")},
            )

            self.assertEqual(debug_app_process.matching_processes(debug, inspector), [])

    def test_read_bundle_identifier(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            bundle, _ = self.make_bundle(Path(tmp), "Applications/RepoPrompt CE Dev.app", "com.example.debug")
            missing = Path(tmp) / "Missing.app"

            self.assertEqual(debug_app_process.read_bundle_identifier(bundle), "com.example.debug")
            self.assertIsNone(debug_app_process.read_bundle_identifier(missing))

    def test_unresolvable_named_candidate_fails_closed(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            debug = self.make_executable(Path(tmp), "Debug/RepoPrompt.app/Contents/MacOS/RepoPrompt")
            inspector = FakeInspector(
                {401: "RepoPrompt"},
                {401: debug_app_process.ProcessIdentityError("identity unavailable")},
            )

            with self.assertRaisesRegex(debug_app_process.ProcessIdentityError, "identity unavailable"):
                debug_app_process.matching_processes(debug, inspector)


class FakeLibProc:
    def __init__(self, result: int, path: bytes, error: int) -> None:
        self.result = result
        self.path = path
        self.error = error

    def proc_pidpath(self, _pid: int, buffer: object, _size: int) -> int:
        if self.result > 0:
            ctypes_buffer = buffer  # ctypes.create_string_buffer
            ctypes_buffer.value = self.path  # type: ignore[attr-defined]
        else:
            import ctypes

            ctypes.set_errno(self.error)
        return self.result


class LibProcInspectorMappingTests(unittest.TestCase):
    def inspector(self, result: int, path: bytes = b"", error: int = 0) -> debug_app_process.LibProcInspector:
        inspector = object.__new__(debug_app_process.LibProcInspector)
        inspector.libproc = FakeLibProc(result, path, error)  # type: ignore[attr-defined]
        return inspector

    def test_errno_mapping_distinguishes_exited_and_detached_processes(self) -> None:
        import errno

        cases = [
            (errno.ESRCH, True, debug_app_process.ProcessGone),
            (errno.ENOENT, False, debug_app_process.ProcessGone),
            (errno.ENOENT, True, debug_app_process.ExecutableDetached),
            (errno.EPERM, True, debug_app_process.ProcessIdentityError),
        ]
        for error, alive, expected in cases:
            with self.subTest(error=error, alive=alive), mock.patch.object(
                debug_app_process, "_process_alive", return_value=alive
            ):
                with self.assertRaises(expected) as raised:
                    self.inspector(0, error=error).process_path(1)
                if expected is debug_app_process.ProcessIdentityError:
                    self.assertNotIsInstance(raised.exception, debug_app_process.ExecutableDetached)
                    self.assertNotIsInstance(raised.exception, debug_app_process.ProcessGone)

    def test_path_that_vanished_maps_to_detached_or_gone(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            missing = os.fsencode(Path(tmp) / "gone" / "RepoPrompt")
            for alive, expected in [(True, debug_app_process.ExecutableDetached), (False, debug_app_process.ProcessGone)]:
                with self.subTest(alive=alive), mock.patch.object(debug_app_process, "_process_alive", return_value=alive):
                    with self.assertRaises(expected):
                        self.inspector(len(missing), path=missing).process_path(1)


class LaunchServicesParsingTests(unittest.TestCase):
    def run_result(self, stdout: str, returncode: int = 0) -> subprocess.CompletedProcess[str]:
        return subprocess.CompletedProcess(args=[], returncode=returncode, stdout=stdout, stderr="")

    def test_parses_real_lsappinfo_output_and_rejects_null_or_failures(self) -> None:
        cases = [
            ('"LSBundlePath"="/Applications/RepoPrompt CE Dev.app"\n', 0, "/Applications/RepoPrompt CE Dev.app"),
            ('"LSBundlePath"=[ NULL ] \n', 0, None),
            ("", 0, None),
            ('"LSBundlePath"="/x.app"\n', 1, None),
        ]
        for stdout, code, expected in cases:
            with self.subTest(stdout=stdout, code=code), mock.patch.object(
                debug_app_process.subprocess, "run", return_value=self.run_result(stdout, code)
            ):
                self.assertEqual(debug_app_process._lsappinfo_value(1, "bundlepath", "LSBundlePath"), expected)

    def test_timeout_is_treated_as_unavailable(self) -> None:
        with mock.patch.object(
            debug_app_process.subprocess, "run", side_effect=subprocess.TimeoutExpired(cmd="lsappinfo", timeout=2.0)
        ):
            self.assertIsNone(debug_app_process._lsappinfo_value(1, "bundleid", "CFBundleIdentifier"))


class LifecycleSurfaceTests(unittest.TestCase):
    def test_lifecycle_surfaces_have_no_process_name_kill_fallback(self) -> None:
        run_script = (SCRIPT_DIR / "run.sh").read_text(encoding="utf-8")
        conductor_script = (SCRIPT_DIR / "conductor.py").read_text(encoding="utf-8")
        finder_launcher = (SCRIPT_DIR.parent / "Launch RepoPrompt CE.command").read_text(encoding="utf-8")

        for source in [run_script, conductor_script, finder_launcher]:
            self.assertNotIn("pgrep -x RepoPrompt", source)
            self.assertNotIn("pkill -x RepoPrompt", source)
        self.assertIn('exec python3 -u "$ROOT_DIR/Scripts/conductor_entry.py" __operation_runner "$PAYLOAD"', run_script)
        self.assertIn('"kind": "debug_app_build_then_launch"', run_script)
        self.assertIn("terminate_matching_processes(debug_app_executable_path())", conductor_script)
        self.assertIn("safe coordinated launcher requires Python 3", finder_launcher)
        self.assertIn("No uncoordinated fallback is provided", finder_launcher)
        self.assertNotIn("LAUNCH_MODE", finder_launcher)
        self.assertNotIn("direct mode", finder_launcher.lower())
        agents = (SCRIPT_DIR.parent / "AGENTS.md").read_text(encoding="utf-8")
        readme = (SCRIPT_DIR.parent / "README.md").read_text(encoding="utf-8")
        self.assertIn("does not provide an uncoordinated no-Python fallback", agents)
        self.assertIn("does not provide an", readme)
        self.assertIn("uncoordinated no-Python fallback", readme)

    def test_conductor_selftest_includes_process_helper_suite(self) -> None:
        makefile = (SCRIPT_DIR.parent / "Makefile").read_text(encoding="utf-8")
        target = makefile.split("conductor-selftest:", 1)[1].split("\n\n", 1)[0]
        self.assertIn("python3 Scripts/test_debug_app_process.py", target)

    def test_finder_launcher_without_python_exits_before_any_lifecycle_action(self) -> None:
        dirname = shutil.which("dirname")
        self.assertIsNotNone(dirname)
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            launcher = root / "Launch RepoPrompt CE.command"
            launcher.write_text((SCRIPT_DIR.parent / launcher.name).read_text(encoding="utf-8"), encoding="utf-8")
            bin_dir = root / "bin"
            bin_dir.mkdir()
            (bin_dir / "dirname").symlink_to(dirname)
            env = os.environ.copy()
            env["PATH"] = str(bin_dir)

            result = subprocess.run(
                ["/bin/bash", str(launcher)],
                env=env,
                input="",
                text=True,
                capture_output=True,
                timeout=2,
            )

        self.assertEqual(result.returncode, 1)
        self.assertIn("safe coordinated launcher requires Python 3", result.stdout)
        self.assertIn("No uncoordinated fallback is provided", result.stdout)
        self.assertNotIn("Building and relaunching", result.stdout)


if __name__ == "__main__":
    unittest.main()
