#!/usr/bin/env python3
"""Identify and terminate only the configured RepoPrompt CE debug executable."""

from __future__ import annotations

import argparse
import ctypes
import errno
import os
import plistlib
import re
import signal
import stat
import subprocess
import sys
from pathlib import Path
from typing import Callable, Protocol
from xml.parsers.expat import ExpatError

PROC_ALL_PIDS = 1
PROC_PIDPATHINFO_MAXSIZE = 4096


class ProcessIdentityError(RuntimeError):
    pass


class TargetExecutableMissing(ProcessIdentityError):
    pass


class ProcessGone(ProcessIdentityError):
    pass


class ExecutableDetached(ProcessIdentityError):
    """The process is alive, but its executable file was unlinked (for example, its bundle was replaced)."""


class ProcessInspector(Protocol):
    def list_pids(self) -> list[int]: ...

    def process_name(self, pid: int) -> str | None: ...

    def process_path(self, pid: int) -> Path: ...

    def launch_services_identity(self, pid: int) -> tuple[Path, str] | None:
        """(bundle path, bundle identifier) LaunchServices registered for pid at launch, or None."""
        ...


LSAPPINFO = "/usr/bin/lsappinfo"
LSAPPINFO_TIMEOUT_SECONDS = 2.0
_LSAPPINFO_VALUE_RE = re.compile(r'^"(?P<key>[^"]+)"="(?P<value>.*)"\s*$')


def _lsappinfo_value(pid: int, field: str, key: str) -> str | None:
    try:
        completed = subprocess.run(
            [LSAPPINFO, "info", "-only", field, str(pid)],
            capture_output=True,
            text=True,
            timeout=LSAPPINFO_TIMEOUT_SECONDS,
        )
    except (OSError, subprocess.TimeoutExpired):
        return None
    if completed.returncode != 0:
        return None
    for line in completed.stdout.splitlines():
        match = _LSAPPINFO_VALUE_RE.match(line.strip())
        if match and match.group("key") == key:
            return match.group("value")
    return None


class LibProcInspector:
    def __init__(self) -> None:
        if sys.platform != "darwin":
            raise ProcessIdentityError("debug app process checks require macOS")
        self.libproc = ctypes.CDLL("/usr/lib/libproc.dylib", use_errno=True)
        self.libproc.proc_listpids.argtypes = [ctypes.c_uint32, ctypes.c_uint32, ctypes.c_void_p, ctypes.c_int]
        self.libproc.proc_listpids.restype = ctypes.c_int
        self.libproc.proc_name.argtypes = [ctypes.c_int, ctypes.c_void_p, ctypes.c_uint32]
        self.libproc.proc_name.restype = ctypes.c_int
        self.libproc.proc_pidpath.argtypes = [ctypes.c_int, ctypes.c_void_p, ctypes.c_uint32]
        self.libproc.proc_pidpath.restype = ctypes.c_int

    def list_pids(self) -> list[int]:
        capacity = 4096
        while capacity <= 1_048_576:
            buffer = (ctypes.c_int * capacity)()
            byte_count = self.libproc.proc_listpids(PROC_ALL_PIDS, 0, buffer, ctypes.sizeof(buffer))
            if byte_count <= 0:
                error = ctypes.get_errno()
                detail = os.strerror(error) if error else "process enumeration failed"
                raise ProcessIdentityError(f"could not enumerate processes: {detail}")
            count = byte_count // ctypes.sizeof(ctypes.c_int)
            if count < capacity:
                return [pid for pid in buffer[:count] if pid > 0]
            capacity *= 2
        raise ProcessIdentityError("process enumeration exceeded the supported capacity")

    def process_name(self, pid: int) -> str | None:
        buffer = ctypes.create_string_buffer(PROC_PIDPATHINFO_MAXSIZE)
        length = self.libproc.proc_name(pid, buffer, len(buffer))
        if length <= 0:
            return None
        return os.fsdecode(buffer.value)

    def process_path(self, pid: int) -> Path:
        buffer = ctypes.create_string_buffer(PROC_PIDPATHINFO_MAXSIZE)
        length = self.libproc.proc_pidpath(pid, buffer, len(buffer))
        if length <= 0:
            error = ctypes.get_errno()
            if error == errno.ESRCH or not _process_alive(pid):
                raise ProcessGone(f"process {pid} exited before its executable could be resolved")
            if error == errno.ENOENT:
                # A live process whose executable vnode has no path: its bundle was replaced and deleted.
                raise ExecutableDetached(f"pid {pid} is running from an executable that no longer exists on disk")
            detail = os.strerror(error) if error else "process is unavailable"
            raise ProcessIdentityError(f"could not resolve executable for pid {pid}: {detail}")
        try:
            return Path(os.fsdecode(buffer.value)).resolve(strict=True)
        except FileNotFoundError as exc:
            if not _process_alive(pid):
                raise ProcessGone(f"process {pid} exited before its executable could be resolved") from exc
            raise ExecutableDetached(f"pid {pid} is running from an executable that no longer exists on disk") from exc
        except OSError as exc:
            raise ProcessIdentityError(f"could not resolve executable path for pid {pid}: {exc}") from exc

    def launch_services_identity(self, pid: int) -> tuple[Path, str] | None:
        bundle_path = _lsappinfo_value(pid, "bundlepath", "LSBundlePath")
        bundle_id = _lsappinfo_value(pid, "bundleid", "CFBundleIdentifier")
        if not bundle_path or not bundle_id:
            return None
        return Path(bundle_path).resolve(strict=False), bundle_id


def _process_alive(pid: int) -> bool:
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


def expected_executable_path(path: Path) -> Path:
    try:
        resolved = path.expanduser().resolve(strict=True)
        metadata = resolved.stat()
    except FileNotFoundError as exc:
        raise TargetExecutableMissing(f"target debug app executable is not installed: {path}") from exc
    except OSError as exc:
        raise ProcessIdentityError(f"target debug app executable is unavailable: {path}: {exc}") from exc
    if not stat.S_ISREG(metadata.st_mode) or not metadata.st_mode & 0o111:
        raise ProcessIdentityError(f"target debug app executable is not executable: {resolved}")
    return resolved


PUBLISH_SIBLING_PREFIX = ".rpce-package-"


def read_bundle_identifier(bundle: Path) -> str | None:
    """CFBundleIdentifier from <bundle>/Contents/Info.plist, or None when unreadable."""
    try:
        with (bundle / "Contents" / "Info.plist").open("rb") as handle:
            info = plistlib.load(handle)
    except (OSError, plistlib.InvalidFileException, ValueError, ExpatError):
        return None
    bundle_id = info.get("CFBundleIdentifier") if isinstance(info, dict) else None
    return bundle_id if isinstance(bundle_id, str) and bundle_id else None


def _bundle_of(expected: Path) -> Path | None:
    if expected.parent.name != "MacOS" or expected.parent.parent.name != "Contents":
        return None
    return expected.parent.parent.parent


def target_bundle_identity(expected: Path) -> tuple[Path, str] | None:
    """(bundle path, CFBundleIdentifier) for an executable at <bundle>/Contents/MacOS/<name>, or None."""
    bundle = _bundle_of(expected)
    if bundle is None:
        return None
    bundle_id = read_bundle_identifier(bundle)
    return (bundle, bundle_id) if bundle_id else None


def _raise_if_gone(pid: int, inspector: ProcessInspector) -> None:
    """Re-probe pid so a process that exited during identity checks surfaces as ProcessGone."""
    try:
        inspector.process_path(pid)
    except ProcessGone:
        raise
    except ProcessIdentityError:
        pass


def _is_in_publish_sibling(actual: Path, expected: Path) -> bool:
    """Whether actual lives in a hidden publish sibling of the target bundle (renamed aside during a swap)."""
    bundle = _bundle_of(expected)
    if bundle is None:
        return False
    try:
        relative = actual.relative_to(bundle.parent)
    except ValueError:
        return False
    return bool(relative.parts) and relative.parts[0].startswith(PUBLISH_SIBLING_PREFIX)


def _is_target_registration(registered: tuple[Path, str] | None, target_bundle: tuple[Path, str] | None) -> bool:
    """True when LaunchServices registered the process at launch for the target bundle path and identifier.

    This identifies a debug app instance still running after its bundle was replaced underneath it
    (for example, by an ordinary build publishing into the running app's destination).
    """
    if registered is None or target_bundle is None:
        return False
    registered_path, registered_id = registered
    target_path, target_id = target_bundle
    return registered_id == target_id and registered_path == target_path


def _identity_matches(
    pid: int,
    expected: Path,
    target_bundle: tuple[Path, str] | None,
    inspector: ProcessInspector,
) -> bool:
    """Whether pid is the target debug app. Raises ProcessGone when it exited."""
    bundle = _bundle_of(expected) or expected.parent
    try:
        actual = inspector.process_path(pid)
    except ExecutableDetached as exc:
        registered = inspector.launch_services_identity(pid)
        if registered is not None and target_bundle is not None:
            # LaunchServices names the bundle this process was launched from: ours, or clearly another app.
            return _is_target_registration(registered, target_bundle)
        if registered is not None and registered[0] != bundle.resolve(strict=False):
            return False  # Registered for another bundle; ours is unreadable, but it can't be this one.
        _raise_if_gone(pid, inspector)
        raise ProcessIdentityError(
            f"{exc}, and LaunchServices cannot confirm whether it belongs to {bundle} "
            f"(registration: {registered}); quit it manually"
        ) from exc
    if actual == expected:
        return True
    registered = inspector.launch_services_identity(pid)
    if registered is not None and target_bundle is not None:
        return _is_target_registration(registered, target_bundle)
    _raise_if_gone(pid, inspector)
    if _is_in_publish_sibling(actual, expected):
        raise ProcessIdentityError(
            f"pid {pid} runs {actual}, a bundle renamed aside while publishing {bundle}, and LaunchServices "
            f"cannot confirm its identity (registration: {registered}); quit it manually"
        )
    return False


def matching_processes(
    expected_executable: Path,
    inspector: ProcessInspector | None = None,
    *,
    exact_only: bool = False,
) -> list[int]:
    """PIDs of the target debug app. exact_only skips the LaunchServices fallback (for fresh-launch checks)."""
    try:
        expected = expected_executable_path(expected_executable)
    except TargetExecutableMissing:
        return []
    active_inspector = inspector or LibProcInspector()
    target_bundle = None if exact_only else target_bundle_identity(expected)
    matches: list[int] = []
    for pid in active_inspector.list_pids():
        if active_inspector.process_name(pid) != expected.name:
            continue
        if exact_only:
            try:
                if active_inspector.process_path(pid) == expected:
                    matches.append(pid)
            except (ProcessGone, ExecutableDetached):
                continue
            continue
        try:
            if _identity_matches(pid, expected, target_bundle, active_inspector):
                matches.append(pid)
        except ProcessGone:
            continue
    return matches


def processes_registered_elsewhere(
    target_bundle: Path,
    bundle_id: str,
    executable_name: str,
    inspector: ProcessInspector | None = None,
) -> list[tuple[int, Path]]:
    """Running apps LaunchServices registered with bundle_id from a bundle other than target_bundle.

    The debug app sets LSMultipleInstancesProhibited, so while one of these runs, `open -n` on the
    target bundle only reactivates it and starts no new process. They are never signaled here.
    """
    active_inspector = inspector or LibProcInspector()
    target = target_bundle.resolve(strict=False)
    found: list[tuple[int, Path]] = []
    for pid in active_inspector.list_pids():
        if active_inspector.process_name(pid) != executable_name:
            continue
        registered = active_inspector.launch_services_identity(pid)
        if registered is None:
            continue
        registered_path, registered_id = registered
        if registered_id == bundle_id and registered_path != target:
            found.append((pid, registered_path))
    return found


def terminate_matching_processes(
    expected_executable: Path,
    inspector: ProcessInspector | None = None,
    signaler: Callable[[int, int], None] = os.kill,
) -> list[int]:
    try:
        expected = expected_executable_path(expected_executable)
    except TargetExecutableMissing:
        return []
    active_inspector = inspector or LibProcInspector()
    target_bundle = target_bundle_identity(expected)
    signaled: list[int] = []
    for pid in matching_processes(expected, active_inspector):
        try:
            still_matches = _identity_matches(pid, expected, target_bundle, active_inspector)
        except ProcessGone:
            continue
        if not still_matches:
            raise ProcessIdentityError(
                f"refusing to signal pid {pid}: executable changed during identity revalidation (expected {expected} "
                f"or LaunchServices registration {target_bundle}); quit it manually if it is the debug app"
            )
        try:
            signaler(pid, signal.SIGTERM)
        except ProcessLookupError:
            continue
        except OSError as exc:
            raise ProcessIdentityError(f"could not signal debug app pid {pid}: {exc}") from exc
        signaled.append(pid)
    return signaled


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("operation", choices=["list", "terminate"])
    parser.add_argument("--executable", required=True, type=Path)
    return parser.parse_args(argv)


def main(argv: list[str]) -> int:
    args = parse_args(argv)
    try:
        if args.operation == "list":
            pids = matching_processes(args.executable)
        else:
            pids = terminate_matching_processes(args.executable)
    except ProcessIdentityError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1
    for pid in pids:
        print(pid)
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
