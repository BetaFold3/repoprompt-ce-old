#!/usr/bin/env python3
"""RepoPrompt CE developer daemon.

Implements repo-internal daemon/job mechanics, fake sleep validation support,
and delegated build/package/test/debug-app/live-smoke/release operation
families. Synchronous jobs print concise summaries by default and preserve raw
logs under the daemon jobs directory.
"""

from __future__ import annotations

import argparse
import contextlib
import csv
import ctypes
import dataclasses
import difflib
import errno
import fcntl
import hashlib
import importlib.util
import io
import json
import math
import os
import plistlib
import re
import select
import signal
import shutil
import socket
import socketserver
import stat
import subprocess
import sys
import threading
import time
import uuid
from collections import deque
from pathlib import Path
from types import MappingProxyType
from typing import Any, Deque, Dict, FrozenSet, Iterable, List, Mapping, Optional, Sequence, Tuple

from debug_app_process import ProcessIdentityError, matching_processes, terminate_matching_processes


def _load_sibling_helper(stem: str) -> Any:
    """Load ``<stem>.py`` from this file's directory by explicit path.

    A conductor copy never picks up another checkout's helper from
    ``sys.path``. Raises when the helper cannot be loaded.
    """
    path = Path(__file__).resolve().with_name(f"{stem}.py")
    existing = sys.modules.get(stem)
    if existing is not None and Path(getattr(existing, "__file__", "") or "").resolve() == path:
        return existing
    name = stem if existing is None else f"_rpce_{stem}_" + hashlib.sha256(str(path).encode("utf-8")).hexdigest()[:12]
    if name in sys.modules:
        return sys.modules[name]
    spec = importlib.util.spec_from_file_location(name, path)
    if spec is None or spec.loader is None:
        raise ImportError(f"cannot load {path}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    try:
        spec.loader.exec_module(module)
    except BaseException:
        sys.modules.pop(name, None)
        raise
    return module


def _load_pipeline_metrics() -> Optional[Any]:
    """``swift_pipeline_metrics.py`` from this file's directory, or ``None``.

    Telemetry is optional: any failure leaves the conductor fully functional
    with timing disabled.
    """
    try:
        return _load_sibling_helper("swift_pipeline_metrics")
    except Exception:
        return None


PIPELINE_METRICS = _load_pipeline_metrics()
# Step 3 output records (splitter, tail, batches). Required: the output path and
# summaries depend on it, so a load failure is fatal rather than silently degraded.
CONDUCTOR_OUTPUT = _load_sibling_helper("conductor_output")


def compute_conductor_digest() -> Optional[str]:
    """Informational content digest of the conductor implementation files."""
    script = Path(__file__).resolve()
    paths = [script]
    for name in ("swift_pipeline_metrics.py", "debug_app_process.py", "conductor_output.py", "conductor_entry.py"):
        candidate = script.with_name(name)
        if candidate.is_file():
            paths.append(candidate)
    if PIPELINE_METRICS is not None:
        try:
            return PIPELINE_METRICS.content_digest(paths)
        except Exception:
            return None
    try:
        return "sha256:" + hashlib.sha256(script.read_bytes()).hexdigest()
    except OSError:
        return None


# Computed once at module load: a daemon reports the bytes it started with.
CONDUCTOR_DIGEST = compute_conductor_digest()


def conductor_entry_script() -> Path:
    """The cached-import entry that the launcher, job runners and the daemon execute."""
    return Path(__file__).resolve().with_name("conductor_entry.py")


TIMING_RUNNER_PATH_ENV_KEY = "RPCE_CONDUCTOR_RUNNER_TIMINGS_PATH"
# Kill switch, read once at daemon start; forwarded into the launchd plist.
TIMING_ENV_KEY = "RPCE_CONDUCTOR_TIMING"
# Daemon exit waits at most this long for already-started timing persistence
# (never on a client request path).
TIMING_DRAIN_SECONDS = 2.0
CLIENT_METRICS_MAX_ITEMS = 16
TIMING_FILE_SUFFIXES = (".timing-events.jsonl", ".timings.json", ".runner-timings.json")
_ARTIFACT_OPERATION_SINK = threading.local()


@contextlib.contextmanager
def artifact_operation_sink(sink: Optional[Any]) -> Any:
    """Route fingerprint/evaluation timing on this thread to ``sink`` (or nowhere)."""
    previous = getattr(_ARTIFACT_OPERATION_SINK, "sink", None)
    _ARTIFACT_OPERATION_SINK.sink = sink
    try:
        yield
    finally:
        _ARTIFACT_OPERATION_SINK.sink = previous


def _resolve_operation_sink(sink: Optional[Any]) -> Optional[Any]:
    return sink if sink is not None else getattr(_ARTIFACT_OPERATION_SINK, "sink", None)


def _emit_operation(sink: Optional[Any], name: str, duration_ns: int, counters: Optional[Dict[str, int]] = None) -> None:
    if sink is None:
        return
    try:
        sink(name, duration_ns, counters)
    except Exception:
        pass


def timing_history_path(paths: "Paths") -> Path:
    return paths.state_dir / "metrics" / "build-metrics.jsonl"


def read_runner_timings(path: Path) -> Optional[Dict[str, Any]]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None
    return value if isinstance(value, dict) else None


def generated_job_file_ticket(name: str) -> Optional[str]:
    """The daemon-generated ticket owning file ``name``, or ``None``.

    Orphan sweeps delete only ``<uuid ticket><exact generated suffix>`` names;
    anything else in the jobs directory (build tickets, workdirs, foreign
    files) is never touched.
    """
    for suffix in GENERATED_JOB_FILE_SUFFIXES:
        if name.endswith(suffix):
            stem = name[: -len(suffix)]
            if JOB_TICKET_RE.match(stem):
                return stem
    return None


PROTOCOL_VERSION = 20
TERMINAL_STATES = {"completed", "failed", "canceled"}
LANE_NAMES = {"build", "debugArtifact", "liveApp", "release", "style"}
LOG_TAIL_LINES = 30
BUILD_CACHE_DIAGNOSTIC_MAX_ROWS = 12
SUMMARY_VERSION = 2
# Per-section deduplication memory; beyond it omitted counts become upper bounds.
SUMMARY_SEEN_MAX_ENTRIES = 4096
SUMMARY_SUCCESS_MAX_LINES = 25
SUMMARY_FAILURE_MAX_LINES = 100
SUMMARY_MAX_CHARS = 16000
SUMMARY_LINE_MAX_CHARS = 400
SUMMARY_CONTEXT_BEFORE = 2
SUMMARY_CONTEXT_AFTER = 4
PROGRESS_HEARTBEAT_SECONDS = 30.0
PROGRESS_MAX_LINES_PER_POLL = 6
MAX_TERMINAL_JOBS = 200
TERMINAL_RETENTION_SECONDS = 24 * 60 * 60
# Step 5 maintenance worker: orphan sweeps (and retries of failed unlinks) run at
# most this often; retries are bounded so a persistently failing unlink cannot grow memory.
ORPHAN_SWEEP_INTERVAL_SECONDS = 60.0
MAINTENANCE_RETRY_LIMIT = 1024
# The only per-ticket files retention ever deletes: logs, XCTest stall diagnostics, timing sidecars.
GENERATED_JOB_FILE_SUFFIXES = (".log", ".xctest-stall.json", ".xctest-stall.sample.txt") + TIMING_FILE_SUFFIXES
JOB_TICKET_RE = re.compile(r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\Z")
STARTUP_TIMEOUT_SECONDS = 10.0
WAIT_POLL_SECONDS = 1.0
# Client bound on re-polling a terminal job whose summary another caller is computing.
SUMMARY_PENDING_WAIT_SECONDS = 60.0
TERMINATE_GRACE_SECONDS = 3.0
KILL_GRACE_SECONDS = 2.0
PROCESS_TREE_POLL_SECONDS = 0.05
# Each of the two bounded output-reader joins after a job's root process exits.
OUTPUT_READER_JOIN_SECONDS = 2.0
XCTEST_WAKE_PROBE_PAUSE_SECONDS = 0.25
XCTEST_WAKE_PROGRESS_WAIT_SECONDS = 10.0
XCTEST_STALL_DIAGNOSTIC_MAX_PROCESSES = 64
XCTEST_STALL_SAMPLE_MAX_BYTES = 128 * 1024
XCTEST_STALL_FAILURE_EXIT_CODE = 70
XCTEST_ZERO_TESTS_FAILURE_EXIT_CODE = 66
XCTEST_SOURCE_ARTIFACT_INTEGRITY_EXIT_CODE = 67
# Step 8 (fingerprint v2) is one atomic compatibility transition, not equal
# schema numbers: unversioned root tickets are legacy schema 1 and the current
# root schema is 2; the parallel candidate advances from 2 to 3. Both envelopes
# carry the top-level ``fingerprint_version``; the six nested
# ``artifact_fingerprint`` keys are unchanged.
ROOT_BUILD_TICKET_SCHEMA_VERSION = 2
PARALLEL_TEST_CANDIDATE_SCHEMA_VERSION = 3
ARTIFACT_FINGERPRINT_VERSION = 2
ROOT_BUILD_TICKET_LEGACY_SCHEMAS = frozenset({None, 1})
PARALLEL_TEST_CANDIDATE_LEGACY_SCHEMAS = frozenset({1, 2})
# Domain separation: old (v1) readers always reject a v2 closure digest, and back.
ARTIFACT_CLOSURE_DIGEST_PREFIX = b"rpce-runtime-closure-v2\0"
FINGERPRINT_V2_LEGACY_MESSAGE = "ticket predates fingerprint v2 — re-mint with a source-validating run"
PARALLEL_TEST_CANDIDATE_KIND = "repoprompt-root-parallel-test-candidate"
PARALLEL_XCTEST_RUNTIME_GATE_KEYS = (
    "DEVELOPER_DIR",
    "REPOPROMPT_ENABLE_SENTRY",
    "RPCE_ENABLE_BENCHMARK_TESTS",
    "RPCE_RUN_CODEMAP_E2E",
    "RPCE_RUN_SCALE_TESTS",
    "SDKROOT",
    "TOOLCHAINS",
)
XCTEST_STARTUP_DEADLINE_SECONDS = 90.0
XCTEST_ACTIVE_METHOD_FLOOR_SECONDS = 90.0
XCTEST_ACTIVE_METHOD_RUNTIME_MULTIPLIER = 4.0
XCTEST_ACTIVE_METHOD_RUNTIME_PADDING_SECONDS = 30.0
XCTEST_ACTIVE_METHOD_DEADLINE_SECONDS = 180.0
XCTEST_BETWEEN_METHOD_DEADLINE_SECONDS = 60.0
XCTEST_WATCHDOG_JOIN_SECONDS = 25.0
FORCE_STOP_RPC_TIMEOUT_SECONDS = 30.0
APP_STOP_POLL_SECONDS = 0.2
APP_STOP_QUIET_SECONDS = 1.0
APP_STOP_DELAYED_LAUNCH_GUARD_SECONDS = 12.0
APP_STOP_CONFIRM_TIMEOUT_SECONDS = 8.0
APP_STOP_DELAYED_LAUNCH_CONFIRM_TIMEOUT_SECONDS = 25.0
GLOBAL_HEAVY_SLOT_POLL_SECONDS = 0.2
MACHINE_LOCK_POLL_SECONDS = 0.2
MAX_GLOBAL_HEAVY_SLOTS = 64
MAX_GLOBAL_XCTEST_SLOTS = 64
DEBUG_APP_PROVENANCE_RELATIVE_PATH = "Contents/Resources/RepoPromptDebugProvenance.json"

SHORT_TIMEOUT_SECONDS = 5 * 60
FILTERED_TEST_TIMEOUT_SECONDS = 20 * 60
ARTIFACT_TEST_TIMEOUT_SECONDS = 10 * 60
MEDIUM_TIMEOUT_SECONDS = 60 * 60
RELEASE_TIMEOUT_SECONDS = 2 * 60 * 60
# Optimized-diagnostics lane (`build --optimized`): whole-module `-c release` compiles take
# minutes and have no partial results. Floor = twice the measured cold build (797 s, including
# dependency resolution, 2026-10-16); a request without --timeout gets max(default, floor).
# The measured floor is currently below the 3600 s default, so it does not raise that default.
OPTIMIZED_LANE_TIMEOUT_FLOOR_SECONDS = 2 * 797
# The optimized-incremental App lane (`--optimized-incremental`) keeps every other module WMO, so
# it takes the same floor. Its cold builds so far (lab manifest, 473 s; production selector with
# cloned dependency state, 514 s; both 2026-10-20, advisory single samples) are below that floor.
SMOKE_AGENT_WAIT_SECONDS = 120.0

IMPLEMENTED_OPERATIONS = {
    "doctor",
    "guardrails",
    "format",
    "format-check",
    "lint",
    "format-tools-status",
    "check-format-tools",
    "install-format-tools",
    "swift-build",
    "dsym",
    "build",
    "package",
    "test",
    "test-artifact",
    "test-parallel",
    "provider-test",
    "core-test",
    "install-debug-cli",
    "debug-cli-status",
    "run",
    "app",
    "smoke",
    "diagnostics",
    "release",
}

HELP = f"""\
conductor — RepoPrompt CE developer daemon

Usage:
  ./conductor --help
  ./conductor status [--json]

Daemon lifecycle:
  ./conductor daemon start [--json]
  ./conductor daemon status [--json]
  ./conductor daemon stop [--force] [--json]

Job commands:
  ./conductor job list [--state queued|running|waiting-heavy-slot|waiting-xctest-slot|completed|failed|canceled] [--json]
  ./conductor job status <ticket> [--json] [--full-log]
  ./conductor job status --request-key <key> [--json] [--full-log]
  ./conductor job wait <ticket> [--timeout <seconds>] [--json] [--full-log]
  ./conductor job wait --request-key <key> [--timeout <seconds>] [--json] [--full-log]
  ./conductor job cancel <ticket> [--json]
  ./conductor job cancel --request-key <key> [--json]

Timing metrics:
  ./conductor metrics [--last N] [--kind K] [--ticket T] [--json]   # reads <state dir>/metrics/build-metrics.jsonl
  RPCE_CONDUCTOR_TIMING=off, read at daemon start, disables per-job timing (overhead kill switch);
    a running daemon keeps its mode (shown by 'daemon status'): stop it when idle, then start with the variable

Operation commands:
  ./conductor doctor
  ./conductor guardrails
  ./conductor format                 # mutates first-party Swift files
  ./conductor format-check           # non-mutating SwiftFormat check
  ./conductor lint                   # non-mutating format-check + SwiftLint strict
  ./conductor format-tools-status    # inspect SwiftFormat/SwiftLint availability
  ./conductor check-format-tools     # fail if style tools are missing
  ./conductor install-format-tools   # explicit Homebrew install of missing style tools
  ./conductor swift-build --product RepoPrompt|repoprompt-mcp|repoprompt-gateway|all
  ./conductor dsym [--product all|RepoPrompt|repoprompt-mcp|repoprompt-gateway|root-tests]   # regenerate debug dSYMs; never builds
  ./conductor build [--fast] [--optimized | --optimized-incremental]
    --optimized packages the opt-in optimized-diagnostics lane (swift -c release, first-party DEBUG,
    Dev identity; needs SIGN_IDENTITY='Apple Development: ...'); each build takes minutes
    --optimized-incremental packages the same lane with only RepoPromptApp non-WMO incremental (rest WMO)
    for fast App edit loops; not a performance-acceptance lane; mutually exclusive with --optimized
  ./conductor package debug|release
  ./conductor test [--list | --filter <filter>] [--test-product <product>] [--no-xctest-deadlines] [--xctest-stall-seconds <seconds>] [--xctest-stall-wake-probe]
  ./conductor test-artifact --filter <filter> [--no-xctest-deadlines] [--xctest-stall-seconds <seconds>] [--xctest-stall-wake-probe]
  ./conductor test-parallel [--workers <count>] [--filter <suite-regex>]
  ./conductor provider-test [--list | --filter <filter>] [--test-product <product>] [--no-xctest-deadlines] [--xctest-stall-seconds <seconds>] [--xctest-stall-wake-probe]
  ./conductor core-test [--list | --filter <filter>] [--test-product <product>] [--no-xctest-deadlines] [--xctest-stall-seconds <seconds>] [--xctest-stall-wake-probe]
  ./conductor install-debug-cli
  ./conductor debug-cli-status
  ./conductor run [--optimized | --optimized-incremental] [-- <app args...>]    # build/package, then FIFO coordinated launch
  ./conductor app status
  ./conductor app stop                                 # latest interactive stop intent
  ./conductor app launch-existing [-- <app args...>]   # launch existing DebugApps bundle without building
  ./conductor app relaunch [--optimized | --optimized-incremental] [-- <app args...>]   # latest interactive relaunch intent
    run/app relaunch --optimized[-incremental] package and launch the same lane as build (minutes per WMO build;
    selection is per invocation, never sticky); launch-existing never builds and rejects both lane flags
  ./conductor smoke [--launch | --packaged-app <path>] [--artifact-manifest <path>] [--workspace <name>] [--window-id <id>] [--agent-run] [--execution-location-ui]
    --execution-location-ui uses REPOPROMPT_EXECUTION_LOCATION_UI_SMOKE_WAIT (default 3s) and _CYCLES (default 3); Accessibility permission is required.
    (without --launch/--packaged-app, requires the CE debug app to already be running and CLI installed)
  ./conductor diagnostics agent-mode-on [--log-file <path>]
  ./conductor diagnostics build-cache [--limit <n>]
  ./conductor release preflight|artifact|package|local-install

Foundation validation operation:
  ./conductor sleep <seconds> [--lane <lane>]... [--message <text>] [--exit-code <n>]
  ./conductor fake-sleep <seconds> [same options]
  valid lanes: build, debugArtifact, liveApp, release, style

Global operation flags:
  --async              enqueue and return a ticket immediately
  --request-key <key>  idempotent retry key for queued/running matching requests
  --json               machine-readable output
  --timeout <seconds>  override operation timeout
  --verbose            execution verbosity: pass VERBOSE=1 to delegated scripts where applicable
  --full-log           human output rendering: replay raw full job log at completion

Debug symbols:
  RPCE_DEBUG_DSYM=on|off (unset means off) skips dSYM generation for debug Swift builds only;
    release, Sentry and unrecognized configurations keep full symbols; any other value exits 2
  on affects future links only; dsym regenerates symbols for existing debug binaries

XCTest controls:
  deadlines default on; disable with --no-xctest-deadlines or REPOPROMPT_DEV_XCTEST_DEADLINES=0
  active-method budgets use the curated runtime ledger unless --xctest-stall-seconds overrides them
  REPOPROMPT_DEV_XCTEST_ACTIVE_FLOOR_SECONDS=N overrides the 90s floor for diagnostic selftests only
  RPCE_ALLOW_UNKNOWN_FILTER=1 bypasses filter preflight; RPCE_ALLOW_ZERO_TESTS=1 permits filtered zero-test success

Output:
  Synchronous jobs and job wait/status use concise human summaries by default and
  print the full log path. Raw logs are preserved under the daemon jobs directory.
  Use --full-log for raw terminal replay; --verbose only changes delegated script
  verbosity captured in the stored log and does not imply --full-log.

State paths:
  state dir default: ~/Library/Application Support/RepoPrompt CE/Conductor/<repo-root-hash>/
  socket default:    /tmp/conductor-<uid>/<repo-root-hash16>.sock (directory mode 0700)
  machine locks:     /tmp/repoprompt-ce-dev-locks-<uid>/ (directory mode 0700; independent of socket overrides)
  heavy slots:       REPOPROMPT_DEV_HEAVY_SLOTS=N (default 1)
  XCTest slots:      REPOPROMPT_DEV_XCTEST_SLOTS=N (default 1)
  overrides: REPOPROMPT_DEV_DAEMON_STATE_DIR, REPOPROMPT_DEV_DAEMON_SOCKET (socket parent must be owned 0700)

Protocol version: {PROTOCOL_VERSION}
"""


class ConductorError(Exception):
    pass


class FilterPreflightError(ConductorError):
    pass


class ArtifactUnavailableError(ConductorError):
    pass


class DebugSymbolPolicyError(ConductorError):
    """``RPCE_DEBUG_DSYM`` is invalid; rejected (exit 2) before any mutation."""


# Step 10 debug dSYM policy switch. ``Scripts/debug_dsym.py`` owns classification
# (its POLICY_VALUES must equal these); the conductor only validates, forwards and
# normalizes the request value so unset and ``off`` are one request identity.
DEBUG_DSYM_POLICY_ENV_KEY = "RPCE_DEBUG_DSYM"
DEBUG_DSYM_POLICY_VALUES = ("on", "off")
DEBUG_DSYM_PRODUCTS = ("all", "RepoPrompt", "repoprompt-mcp", "repoprompt-gateway", "root-tests")
DEBUG_SYMBOL_POLICY_EXIT_CODE = 2


def normalize_debug_dsym_policy(env: Mapping[str, str]) -> str:
    """The normalized ``RPCE_DEBUG_DSYM`` (unset -> ``off``) or DebugSymbolPolicyError."""
    value = env.get(DEBUG_DSYM_POLICY_ENV_KEY)
    if value is None:
        return "off"
    if value in DEBUG_DSYM_POLICY_VALUES:
        return value
    shown = repr(value) if len(value) <= 32 else repr(value[:32]) + "..."
    raise DebugSymbolPolicyError(f"{DEBUG_DSYM_POLICY_ENV_KEY} must be 'on' or 'off' (unset means off); got {shown}")


XCTEST_PROGRESS_RE = re.compile(
    r"^Test Case '(.+)' (started|passed|failed|skipped)(?: \([^)]*\))?\.\s*$"
)
XCTEST_CASE_NAME_RE = re.compile(r"^-\[([^\s\]]+)\s+([^\s\]]+)\]$")
XCTEST_ANSI_SGR_RE = re.compile(r"\x1b\[[0-9:;]*m")
# Literals every recognized XCTest progress line contains: a marker line starts
# with the first, and the startup transition is a substring test for the second.
XCTEST_PROGRESS_KEYWORDS = ("Test Case '", "Build complete!")

# The output helper's bounds and over-cap scanner grammar must equal this file's.
if (
    CONDUCTOR_OUTPUT.TAIL_MAX_ENTRIES != LOG_TAIL_LINES
    or CONDUCTOR_OUTPUT.SEGMENT_SGR_PATTERN != XCTEST_ANSI_SGR_RE.pattern
    or CONDUCTOR_OUTPUT.XCTEST_MARKER_PATTERN != XCTEST_PROGRESS_RE.pattern
):
    raise ImportError(
        "conductor_output.py disagrees with conductor.py on the tail bound or the XCTest SGR or marker grammar"
    )


def _xctest_segment_item(content: Optional[str], found: FrozenSet[str]) -> Optional[Tuple[str, Any]]:
    """``(matchable_line, marker)`` for one segment of an over-cap output record.

    ``content`` is the segment exactly as ``_record_xctest_progress_locked``
    normalizes a line (SGR-stripped, then whitespace-stripped), or ``None`` when
    it exceeds ``CONDUCTOR_OUTPUT.SEGMENT_MAX_CHARS``. A line over the bound
    that would match ``XCTEST_PROGRESS_RE`` fails the scanner instead (OD16) and
    never arrives here, so for ``None`` only the ``Build complete!`` substring
    test applies, which ``found`` answers exactly.
    """
    if content is not None:
        if XCTEST_PROGRESS_KEYWORDS[0] not in content and XCTEST_PROGRESS_KEYWORDS[1] not in content:
            return None
        marker = XCTEST_PROGRESS_RE.match(content)
        if marker is not None or XCTEST_PROGRESS_KEYWORDS[1] in content:
            return (content, marker)
        return None
    if XCTEST_PROGRESS_KEYWORDS[1] in found:
        return (XCTEST_PROGRESS_KEYWORDS[1], None)
    return None


def _xctest_segment_scanner() -> Any:
    return CONDUCTOR_OUTPUT.SegmentScanner(_xctest_segment_item, XCTEST_PROGRESS_KEYWORDS, marker_shape=True)


def _test_ledger_path(repo_root: Path) -> Path:
    return repo_root / "Scripts" / "Fixtures" / "test-suite-contract-ledger.tsv"


def _read_test_ledger_rows(repo_root: Path) -> List[Dict[str, str]]:
    with _test_ledger_path(repo_root).open("r", encoding="utf-8", newline="") as handle:
        return list(csv.DictReader(handle, delimiter="\t"))


def _parse_xctest_method_runtimes(rows: Iterable[Mapping[str, Any]]) -> Dict[Tuple[str, str], float]:
    """``(suite, method) -> runtime_seconds``: incomplete, negative and non-finite rows are ignored; the first valid row wins."""
    runtimes: Dict[Tuple[str, str], float] = {}
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
        if not math.isfinite(runtime) or runtime < 0:
            continue
        runtimes.setdefault((suite, method), runtime)
    return runtimes


RuntimeLedgerIdentity = Tuple[str, int, int, int, int, int]


@dataclasses.dataclass(frozen=True)
class RuntimeLedgerLoad:
    """One ledger lookup: a shared immutable snapshot, or ``None`` (flat budget) with a diagnostic."""

    runtimes: Optional[Mapping[Tuple[str, str], float]]
    diagnostic: Optional[str] = None


class _RuntimeLedgerFlight:
    __slots__ = ("event", "result")

    def __init__(self) -> None:
        self.event = threading.Event()
        self.result: Optional[RuntimeLedgerLoad] = None


class RuntimeLedgerCache:
    """Daemon-owned XCTest runtime-ledger snapshot (plan Step 4).

    Holds one current immutable snapshot (a ``MappingProxyType``), keyed by the
    resolved path, device, inode, size, ``mtime_ns`` and ``ctime_ns``. ``load``
    runs outside the daemon condition: stat, read and parse happen under this
    cache's private single-flight, never under ``DaemonState.condition``. Callers
    that join an in-flight load take the leader's result. A read whose identity
    changes between the stat before and the stat after is retried once; a second
    change, or an unreadable ledger, falls back to the flat budget with a
    diagnostic and leaves no current snapshot. Snapshots are never mutated, so
    an active job keeps the one it pinned while a newer one becomes current.
    """

    def __init__(self, path: Path) -> None:
        self.path = path
        self._lock = threading.Lock()
        self._current: Optional[Tuple[RuntimeLedgerIdentity, Mapping[Tuple[str, str], float]]] = None
        self._flight: Optional[_RuntimeLedgerFlight] = None
        self.parse_count = 0

    def _identity(self) -> RuntimeLedgerIdentity:
        resolved = self.path.resolve()
        status = os.stat(resolved)
        return (str(resolved), status.st_dev, status.st_ino, status.st_size, status.st_mtime_ns, status.st_ctime_ns)

    def _fallback(self, reason: str) -> RuntimeLedgerLoad:
        return RuntimeLedgerLoad(
            None,
            f"XCTest runtime ledger unavailable at {self.path}; "
            f"using flat {XCTEST_ACTIVE_METHOD_DEADLINE_SECONDS:.3f}s active-method defaults: {reason}\n",
        )

    def load(self) -> RuntimeLedgerLoad:
        try:
            identity = self._identity()
        except OSError as exc:
            with self._lock:
                if self._flight is None:
                    self._current = None
            return self._fallback(str(exc))
        with self._lock:
            current = self._current
            if current is not None and current[0] == identity:
                return RuntimeLedgerLoad(current[1])
            flight = self._flight
            leader = flight is None
            if flight is None:
                flight = self._flight = _RuntimeLedgerFlight()
        if not leader:
            flight.event.wait()
            assert flight.result is not None
            return flight.result
        result: Optional[RuntimeLedgerLoad] = None
        installed: Optional[Tuple[RuntimeLedgerIdentity, Mapping[Tuple[str, str], float]]] = None
        try:
            installed, result = self._read_snapshot(identity)
        finally:
            if result is None:
                # An unexpected loader error: joiners fall back; the leader's caller sees the exception.
                result = self._fallback("runtime ledger loader failed")
            with self._lock:
                self._current = installed
                self._flight = None
            flight.result = result
            flight.event.set()
        return result

    def _read_snapshot(
        self, before: RuntimeLedgerIdentity
    ) -> Tuple[Optional[Tuple[RuntimeLedgerIdentity, Mapping[Tuple[str, str], float]]], RuntimeLedgerLoad]:
        for _attempt in range(2):
            try:
                with open(before[0], "rb") as handle:
                    data = handle.read()
                after = self._identity()
            except OSError as exc:
                return None, self._fallback(str(exc))
            if after == before:
                try:
                    rows = csv.DictReader(io.StringIO(data.decode("utf-8"), newline=""), delimiter="\t")
                    snapshot: Mapping[Tuple[str, str], float] = MappingProxyType(_parse_xctest_method_runtimes(rows))
                except (csv.Error, UnicodeError) as exc:
                    return None, self._fallback(str(exc))
                finally:
                    with self._lock:
                        self.parse_count += 1
                return (after, snapshot), RuntimeLedgerLoad(snapshot)
            before = after
        return None, self._fallback("ledger changed during load (retried once)")


def _ledger_filter_rows(repo_root: Path, operation: str) -> List[Tuple[str, str]]:
    ledger_path = _test_ledger_path(repo_root)
    target = "root" if operation in {"test", "test-artifact", "test-parallel"} else "core" if operation == "core-test" else "provider"
    try:
        rows = _read_test_ledger_rows(repo_root)
    except (OSError, csv.Error, UnicodeError) as exc:
        raise FilterPreflightError(f"could not read curated test ledger {ledger_path}: {exc}") from exc
    return [
        (str(row.get("suite") or ""), str(row.get("method") or ""))
        for row in rows
        if row.get("target") == target and row.get("suite") and row.get("method")
    ]


def parse_xctest_case_name(test_name: str) -> Optional[Tuple[str, str]]:
    match = XCTEST_CASE_NAME_RE.match(test_name.strip())
    if match is None:
        return None
    return match.group(1), match.group(2)


def xctest_active_method_budget(
    ledger_runtime_seconds: Optional[float],
    flag_override_seconds: Optional[float],
    job_timeout_seconds: Optional[float],
    *,
    floor_seconds: float = XCTEST_ACTIVE_METHOD_FLOOR_SECONDS,
) -> Tuple[float, str, bool]:
    if flag_override_seconds is not None:
        budget = float(flag_override_seconds)
        source = "flag-overridden"
    elif ledger_runtime_seconds is not None:
        budget = max(
            float(floor_seconds),
            XCTEST_ACTIVE_METHOD_RUNTIME_MULTIPLIER * float(ledger_runtime_seconds)
            + XCTEST_ACTIVE_METHOD_RUNTIME_PADDING_SECONDS,
        )
        source = "ledger-derived"
    else:
        budget = XCTEST_ACTIVE_METHOD_DEADLINE_SECONDS
        source = "default"

    clamped = False
    if job_timeout_seconds is not None and budget > float(job_timeout_seconds):
        budget = max(0.0, float(job_timeout_seconds))
        clamped = True
    return budget, source, clamped


def _xctest_active_method_floor(env: Dict[str, str]) -> float:
    raw = env.get("REPOPROMPT_DEV_XCTEST_ACTIVE_FLOOR_SECONDS")
    if raw is None:
        return XCTEST_ACTIVE_METHOD_FLOOR_SECONDS
    try:
        value = float(raw)
    except (TypeError, ValueError):
        return XCTEST_ACTIVE_METHOD_FLOOR_SECONDS
    if not math.isfinite(value) or value <= 0:
        return XCTEST_ACTIVE_METHOD_FLOOR_SECONDS
    return value


def _filter_aliases(suite: str, method: str) -> Tuple[str, str, str, str]:
    short_suite = suite.split(".", 1)[1] if "." in suite else suite
    return suite, short_suite, f"{suite}/{method}", f"{short_suite}/{method}"


def _source_contains_suite(test_root: Path, candidate: str) -> bool:
    if not candidate or not test_root.exists():
        return False
    class_pattern = re.compile(rf"\bclass\s+{re.escape(candidate)}\b")
    for source_path in test_root.rglob("*.swift"):
        try:
            if class_pattern.search(source_path.read_text(encoding="utf-8", errors="replace")):
                return True
        except OSError:
            continue
    return False


def preflight_test_filter(repo_root: Path, operation: str, filter_value: str) -> None:
    if os.environ.get("RPCE_ALLOW_UNKNOWN_FILTER") == "1":
        print("RPCE_ALLOW_UNKNOWN_FILTER=1: skipping curated test filter preflight.", file=sys.stderr)
        return

    rows = _ledger_filter_rows(repo_root, operation)
    aliases = {alias for suite, method in rows for alias in _filter_aliases(suite, method)}
    if filter_value in aliases:
        return
    try:
        filter_pattern = re.compile(filter_value)
    except re.error:
        filter_pattern = None
    if filter_pattern is not None and any(filter_pattern.search(alias) for alias in aliases):
        return

    suite_part = filter_value.split("/", 1)[0]
    candidate = suite_part.rsplit(".", 1)[-1]
    if operation in {"test", "test-artifact", "test-parallel"}:
        test_root = repo_root / "Tests" / "RepoPromptTests"
    elif operation == "core-test":
        test_root = repo_root / "Packages" / "RepoPromptCore" / "Tests"
    else:
        test_root = repo_root / "Packages" / "RepoPromptAgentProviders" / "Tests"
    if _source_contains_suite(test_root, candidate):
        print(
            f"Suite '{candidate}' found in sources but not in the curated ledger — "
            "the ledger is frozen; running with default deadlines.",
            file=sys.stderr,
        )
        return

    suites = sorted({suite for suite, _method in rows})
    suggestions = difflib.get_close_matches(suite_part, suites, n=3, cutoff=0.0)
    suggestion_text = ", ".join(suggestions) if suggestions else "none available"
    raise FilterPreflightError(
        f"test filter '{filter_value}' matched no curated ledger entry or source suite. "
        f"Closest ledger suites: {suggestion_text}. "
        "Set RPCE_ALLOW_UNKNOWN_FILTER=1 to override."
    )


def _run_snapshot_command(
    argv: Sequence[str],
    repo_root: Path,
    env: Optional[Dict[str, str]] = None,
) -> Optional[bytes]:
    try:
        completed = subprocess.run(
            list(argv),
            cwd=str(repo_root),
            env=env,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            check=False,
        )
    except (OSError, subprocess.SubprocessError):
        return None
    if completed.returncode != 0:
        return None
    return bytes(completed.stdout)


def source_snapshot(repo_root: Path, env: Optional[Dict[str, str]] = None) -> Optional[Dict[str, Any]]:
    head_raw = _run_snapshot_command(["git", "rev-parse", "HEAD"], repo_root, env)
    porcelain = _run_snapshot_command(
        ["git", "status", "--porcelain=v1", "-z", "--untracked-files=all"],
        repo_root,
        env,
    )
    dirty_paths_raw = _run_snapshot_command(
        ["git", "diff", "--name-only", "-z", "HEAD", "--"],
        repo_root,
        env,
    )
    if head_raw is None or porcelain is None or dirty_paths_raw is None:
        return None
    porcelain_digest_input = porcelain
    if (repo_root / ".gitmodules").exists():
        submodule_status = _run_snapshot_command(
            ["git", "submodule", "status", "--recursive"],
            repo_root,
            env,
        )
        if submodule_status is None:
            return None
        porcelain_digest_input += b"\0git submodule status --recursive\0" + submodule_status
        # Fail closed on any dirty submodule worktree: inner uncommitted content is
        # not representable in the outer porcelain/status digests.
        submodule_dirty = _run_snapshot_command(
            ["git", "submodule", "--quiet", "foreach", "--recursive", "git status --porcelain -uall"],
            repo_root,
            env,
        )
        if submodule_dirty is None or submodule_dirty.strip():
            return None
    dirty_paths = {raw_path for raw_path in dirty_paths_raw.split(b"\0") if raw_path}
    porcelain_entries = porcelain.split(b"\0")
    for entry in porcelain_entries:
        if entry.startswith(b"?? "):
            dirty_paths.add(entry[3:])
    dirty_file_sha256: Dict[str, str] = {}
    for raw_path in dirty_paths:
        if not raw_path:
            continue
        path_text = raw_path.decode("utf-8", errors="surrogateescape")
        path = repo_root / path_text
        if path.is_symlink():
            try:
                link_target = os.readlink(path)
            except OSError:
                return None
            link_value = f"link:{link_target}".encode("utf-8", errors="surrogateescape")
            dirty_file_sha256[path_text] = hashlib.sha256(link_value).hexdigest()
            continue
        if not path.is_file():
            continue
        digest = hashlib.sha256()
        try:
            with path.open("rb") as handle:
                for chunk in iter(lambda: handle.read(1024 * 1024), b""):
                    digest.update(chunk)
        except OSError:
            # Fail closed: an unreadable dirty file must never let two differing
            # trees produce equal snapshots.
            return None
        dirty_file_sha256[path_text] = digest.hexdigest()
    return {
        "head": head_raw.decode("utf-8", errors="replace").strip(),
        "porcelain_sha256": hashlib.sha256(porcelain_digest_input).hexdigest(),
        "dirty_file_sha256": dict(sorted(dirty_file_sha256.items())),
    }


def artifact_toolchain_snapshot(
    repo_root: Path,
    env: Optional[Dict[str, str]] = None,
) -> Dict[str, str]:
    version_raw = _run_snapshot_command(["swift", "--version"], repo_root, env)
    arch_raw = _run_snapshot_command(["uname", "-m"], repo_root, env)
    version_line = ""
    if version_raw:
        version_line = version_raw.decode("utf-8", errors="replace").splitlines()[0]
    arch = arch_raw.decode("utf-8", errors="replace").strip() if arch_raw else ""
    return {"swift_version": version_line, "arch": arch, "config": "debug"}


def artifact_env_gates(env: Dict[str, str]) -> Dict[str, Optional[str]]:
    # Only Package.swift compiled-graph gates belong here; RPCE_RUN_SCALE_TESTS/RPCE_RUN_CODEMAP_E2E are runtime-only and zero-test-backstopped.
    return {
        "REPOPROMPT_ENABLE_SENTRY": env.get("REPOPROMPT_ENABLE_SENTRY"),
        "RPCE_ENABLE_BENCHMARK_TESTS": env.get("RPCE_ENABLE_BENCHMARK_TESTS"),
    }


def parallel_xctest_runtime_gates(env: Dict[str, str]) -> Dict[str, Optional[str]]:
    return {key: env.get(key) for key in PARALLEL_XCTEST_RUNTIME_GATE_KEYS}


def build_ticket_payload(
    repo_root: Path,
    job: "Job",
    env: Dict[str, str],
    snapshot: Optional[Dict[str, Any]] = None,
    sink: Optional[Any] = None,
) -> Optional[Dict[str, Any]]:
    if snapshot is None:
        snapshot = source_snapshot(repo_root, env)
    if snapshot is None:
        return None
    toolchain = artifact_toolchain_snapshot(repo_root, env)
    artifact_path = discover_root_test_artifact(repo_root, toolchain.get("arch", ""))
    if artifact_path is None:
        raise ArtifactUnavailableError("root test artifact is missing; run `make dev-test` first")
    return {
        "schema_version": ROOT_BUILD_TICKET_SCHEMA_VERSION,
        "fingerprint_version": ARTIFACT_FINGERPRINT_VERSION,
        "ticket_id": job.ticket,
        "created_at": now(),
        "source_snapshot": snapshot,
        "env_gates": artifact_env_gates(env),
        "toolchain": toolchain,
        "artifact_fingerprint": test_artifact_fingerprint(artifact_path, sink=sink),
    }


def write_build_ticket(path: Path, payload: Dict[str, Any]) -> None:
    temporary = path.with_name(f".{path.name}.{uuid.uuid4().hex}.tmp")
    try:
        temporary.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
        with contextlib.suppress(OSError):
            os.chmod(temporary, 0o600)
        os.replace(temporary, path)
    finally:
        with contextlib.suppress(FileNotFoundError):
            temporary.unlink()


def discover_root_test_artifact(repo_root: Path, arch: str) -> Optional[Path]:
    preferred = repo_root / ".build" / f"{arch}-apple-macosx" / "debug" / "RepoPromptCEPackageTests.xctest"
    if preferred.exists():
        return preferred
    debug_link = repo_root / ".build" / "debug" / "RepoPromptCEPackageTests.xctest"
    if debug_link.exists():
        return debug_link
    if not arch:
        return None
    candidates = sorted(
        repo_root.glob(f".build/{arch}-apple-macosx*/debug/RepoPromptCEPackageTests.xctest")
    )
    return candidates[0] if candidates else None


def discover_test_artifact_executable(artifact_path: Path) -> Optional[Path]:
    expected = artifact_path / "Contents" / "MacOS" / artifact_path.stem
    if expected.is_file() and not expected.is_symlink():
        return expected
    executable_dir = artifact_path / "Contents" / "MacOS"
    try:
        candidates = [path for path in executable_dir.iterdir() if path.is_file() and not path.is_symlink()]
    except OSError:
        candidates = []
    if len(candidates) == 1:
        return candidates[0]
    if artifact_path.is_file() and not artifact_path.is_symlink():
        return artifact_path
    return None


# Step 9 (OD23): the only Swift driver diagnostics a coordinated root debug
# ``test`` may request, mapped from the additive boolean
# ``benchmarkDriverDiagnostics`` (absent means false). No arbitrary flags.
BENCHMARK_DRIVER_DIAGNOSTICS_ARG = "benchmarkDriverDiagnostics"
BENCHMARK_DRIVER_DIAGNOSTIC_SWIFT_ARGS = (
    "-Xswiftc",
    "-driver-show-incremental",
    "-Xswiftc",
    "-driver-time-compilation",
)

# Step 7: request args derived only by the daemon's execution-time evaluation.
# Enqueue strips them from every client request before request identity.
TEST_ARTIFACT_DERIVED_ARG_KEYS = (
    "artifactPath",
    "artifactFingerprint",
    "artifactScope",
    "artifactScopeDifferences",
    "artifactScopeMessage",
    "artifactTicketSourceSnapshot",
    "buildTicketId",
)
# Neutral until execution-time evaluation completes; a terminal ``pending``
# (failure or cancellation before evaluation) is never validation evidence.
TEST_ARTIFACT_PENDING_SCOPE_MESSAGE = "artifact_scope: pending — not evaluated yet; not validation evidence"
# The required root-ticket ``artifact_fingerprint`` fields and value kinds
# (the six nested keys are unchanged by Step 8; unknown top-level fields are ignored).
_TICKET_ARTIFACT_FINGERPRINT_FIELDS = (
    ("executable_path", str),
    ("size", int),
    ("mtime_ns", int),
    ("sha256", str),
    ("closure_manifest_sha256", str),
    ("closure_file_count", int),
)


def host_artifact_arch() -> str:
    """The host architecture for cheap artifact discovery (``uname -m`` without a subprocess)."""
    return os.uname().machine


class _MalformedEnvelopeVersion(ValueError):
    pass


def _envelope_version(document: Dict[str, Any], key: str) -> Optional[int]:
    if key not in document:
        return None
    value = document[key]
    if isinstance(value, bool) or not isinstance(value, int) or value < 1:
        raise _MalformedEnvelopeVersion(key)
    return value


def artifact_envelope_version_problem(
    document: Dict[str, Any],
    *,
    current_schema: int,
    legacy_schemas: FrozenSet[Optional[int]],
    label: str,
    legacy_label: str,
) -> Optional[str]:
    """Classify a ticket/candidate envelope before any structural check or hashing.

    Returns ``None`` only for the current ``(current_schema, fingerprint v2)``
    envelope. Malformed versions (bool, float, string, null, nonpositive), future
    versions, recognized historical envelopes and inconsistent combinations each
    get a specific message. Nothing is upgraded in place. No filesystem access.
    """
    try:
        schema = _envelope_version(document, "schema_version")
        fingerprint = _envelope_version(document, "fingerprint_version")
    except _MalformedEnvelopeVersion as exc:
        return f"{label} {exc.args[0]} is malformed; re-mint with a source-validating run"
    if (schema is not None and schema > current_schema) or (
        fingerprint is not None and fingerprint > ARTIFACT_FINGERPRINT_VERSION
    ):
        return (
            f"{label} version is unsupported (schema {schema}, fingerprint {fingerprint}); "
            "re-mint using this conductor"
        )
    if schema in legacy_schemas and fingerprint in (None, 1):
        return f"{legacy_label} {FINGERPRINT_V2_LEGACY_MESSAGE}"
    if schema == current_schema and fingerprint == ARTIFACT_FINGERPRINT_VERSION:
        return None
    return (
        f"{label} version combination is invalid (schema {schema}, fingerprint {fingerprint}); "
        "re-mint with a source-validating run"
    )


def root_build_ticket_version_problem(ticket: Dict[str, Any]) -> Optional[str]:
    return artifact_envelope_version_problem(
        ticket,
        current_schema=ROOT_BUILD_TICKET_SCHEMA_VERSION,
        legacy_schemas=ROOT_BUILD_TICKET_LEGACY_SCHEMAS,
        label="test artifact build ticket",
        legacy_label="test artifact build",
    )


def parallel_test_candidate_version_problem(candidate: Dict[str, Any]) -> Optional[str]:
    return artifact_envelope_version_problem(
        candidate,
        current_schema=PARALLEL_TEST_CANDIDATE_SCHEMA_VERSION,
        legacy_schemas=PARALLEL_TEST_CANDIDATE_LEGACY_SCHEMAS,
        label="parallel test candidate",
        legacy_label="parallel test candidate",
    )


def _read_root_build_ticket(jobs_dir: Path) -> Dict[str, Any]:
    ticket_path = jobs_dir / "build-ticket-root.json"
    try:
        ticket = json.loads(ticket_path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        raise ArtifactUnavailableError(
            "test artifact build ticket is missing or unreadable; run `make dev-test` first"
        )
    if not isinstance(ticket, dict):
        raise ArtifactUnavailableError(
            "test artifact build ticket is missing or unreadable; run `make dev-test` first"
        )
    # Step 8: the version envelope is judged before any artifact work or launch.
    problem = root_build_ticket_version_problem(ticket)
    if problem is not None:
        raise ArtifactUnavailableError(f"{problem}; run `make dev-test` first")
    return ticket


def _valid_ticket_artifact_fingerprint_shape(value: Any) -> bool:
    if not isinstance(value, dict):
        return False
    for key, kind in _TICKET_ARTIFACT_FINGERPRINT_FIELDS:
        field = value.get(key)
        if not isinstance(field, kind) or isinstance(field, bool):
            return False
    return True


def admit_test_artifact(repo_root: Path, jobs_dir: Path, sink: Optional[Any] = None) -> None:
    """Step 7 cheap admission shared by the client and enqueue.

    Parses the root ticket, checks the required fingerprint shape, and checks that
    the artifact bundle and executable exist. It never hashes, takes a source
    snapshot or runs ``swift --version``: the one authoritative
    ``evaluate_test_artifact`` runs at execution, after slot admission. Source
    drift is never rejected here (stale artifacts are runnable by design). ``sink``
    (or the thread's ambient sink) gets one ``artifact_admission`` operation.
    """
    sink = _resolve_operation_sink(sink)
    start = time.monotonic_ns()
    try:
        ticket = _read_root_build_ticket(jobs_dir)
        if not _valid_ticket_artifact_fingerprint_shape(ticket.get("artifact_fingerprint")):
            raise ArtifactUnavailableError(
                "test artifact build ticket has no valid artifact fingerprint; run `make dev-test` first"
            )
        artifact_path = discover_root_test_artifact(repo_root, host_artifact_arch())
        if artifact_path is None:
            raise ArtifactUnavailableError("root test artifact is missing; run `make dev-test` first")
        if discover_test_artifact_executable(artifact_path) is None:
            raise ArtifactUnavailableError(
                "root test artifact executable is missing; run `make dev-test` first"
            )
    finally:
        _emit_operation(sink, "artifact_admission", time.monotonic_ns() - start)


class ArtifactObservations:
    """Execution-local filesystem identities observed while fingerprinting (Step 7).

    Never persisted and never part of a ticket or fingerprint. An identity is
    (device, inode, file type, size, mtime_ns, ctime_ns). Hashed files are
    bracketed by path/descriptor observations; every enumerated directory is
    observed before it is listed, so an entry added, removed or renamed in it
    changes its identity. ``verify`` rechecks metadata only: at the end of the
    fingerprint pass and immediately before launch. These fences detect
    observable instability; they are not an atomic snapshot and never replace or
    skip a full hash. Unrelated churn in an observed directory also rejects.
    """

    def __init__(self) -> None:
        self._entries: Dict[str, Tuple[bool, Tuple[int, ...]]] = {}

    def __len__(self) -> int:
        return len(self._entries)

    @staticmethod
    def identity(metadata: os.stat_result) -> Tuple[int, ...]:
        return (
            metadata.st_dev,
            metadata.st_ino,
            stat.S_IFMT(metadata.st_mode),
            metadata.st_size,
            metadata.st_mtime_ns,
            metadata.st_ctime_ns,
        )

    @staticmethod
    def _metadata(path: str, directory: bool) -> os.stat_result:
        # Directories follow links (the products directory may sit under the
        # `.build/debug` link); hashed files are never links, so a swap shows.
        return os.stat(path) if directory else os.lstat(path)

    def observe_directory(self, path: Path) -> None:
        self._record(str(path), True, self.identity(self._metadata(str(path), True)))

    def record_file(self, path: Path, identity: Tuple[int, ...]) -> None:
        self._record(str(path), False, identity)

    def _record(self, key: str, directory: bool, identity: Tuple[int, ...]) -> None:
        existing = self._entries.get(key)
        if existing is not None and existing != (directory, identity):
            raise ArtifactUnavailableError(
                f"root test artifact changed while it was being fingerprinted ({key}); "
                "run `make dev-test` first"
            )
        self._entries[key] = (directory, identity)

    def verify(self, when: str) -> None:
        for key, (directory, identity) in self._entries.items():
            try:
                current = self.identity(self._metadata(key, directory))
            except OSError as exc:
                raise ArtifactUnavailableError(
                    f"root test artifact changed {when} ({key}: {exc}); run `make dev-test` first"
                ) from exc
            if current != identity:
                raise ArtifactUnavailableError(
                    f"root test artifact changed {when} ({key}); run `make dev-test` first"
                )


def _hash_artifact_file(
    path: Path,
    counters: Optional[Dict[str, int]],
    observations: Optional[ArtifactObservations],
) -> Tuple[os.stat_result, str]:
    """SHA-256 one artifact file. With ``observations``, bracket the read with
    path lstat, fstat, fstat, path lstat; all four identities and the byte count
    must agree, and the identity is kept for the later metadata fences."""
    if observations is None:
        metadata = path.stat()
    else:
        metadata = os.lstat(path)
    digest = hashlib.sha256()
    bytes_read = 0
    with path.open("rb") as handle:
        opened = os.fstat(handle.fileno()) if observations is not None else None
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
            bytes_read += len(chunk)
            if counters is not None:
                counters["bytesHashed"] += len(chunk)
        read_end = os.fstat(handle.fileno()) if observations is not None else None
    if counters is not None:
        counters["filesHashed"] += 1
    if observations is not None:
        identity = ArtifactObservations.identity(metadata)
        after = os.lstat(path)
        stable = (
            stat.S_ISREG(metadata.st_mode)
            and bytes_read == metadata.st_size
            and all(
                ArtifactObservations.identity(observed) == identity
                for observed in (opened, read_end, after)
                if observed is not None
            )
        )
        if not stable:
            raise ArtifactUnavailableError(
                f"root test artifact changed while it was being fingerprinted ({path}); "
                "run `make dev-test` first"
            )
        observations.record_file(path, identity)
    return metadata, digest.hexdigest()


def test_artifact_fingerprint(
    artifact_path: Path,
    sink: Optional[Any] = None,
    *,
    observations: Optional[ArtifactObservations] = None,
) -> Dict[str, Any]:
    """Fingerprint the test artifact; ``sink`` (or the thread's ambient sink) gets
    one ``artifact_fingerprint`` operation with bytes/files hashed and duration.
    ``observations`` (Step 7) adds read/enumeration stability checks and an
    end-of-pass metadata fence; the returned fingerprint is unchanged."""
    sink = _resolve_operation_sink(sink)
    if sink is None:
        return _test_artifact_fingerprint(artifact_path, None, observations)
    counters = {"bytesHashed": 0, "filesHashed": 0}
    start = time.monotonic_ns()
    try:
        return _test_artifact_fingerprint(artifact_path, counters, observations)
    finally:
        _emit_operation(sink, "artifact_fingerprint", time.monotonic_ns() - start, counters)


def _test_artifact_fingerprint(
    artifact_path: Path,
    counters: Optional[Dict[str, int]],
    observations: Optional[ArtifactObservations] = None,
) -> Dict[str, Any]:
    executable = discover_test_artifact_executable(artifact_path)
    if executable is None:
        raise ArtifactUnavailableError(
            "root test artifact executable is missing; run `make dev-test` first"
        )
    try:
        metadata, executable_sha256 = _hash_artifact_file(executable, counters, observations)
    except OSError as exc:
        raise ArtifactUnavailableError(
            f"root test artifact executable is unreadable ({exc}); run `make dev-test` first"
        ) from exc

    try:
        products_dir = artifact_path.parent
        if observations is not None:
            # Before enumerating `*.bundle` roots: a sibling added later shows here.
            observations.observe_directory(products_dir)
        closure_roots = [artifact_path] if artifact_path.is_dir() else []
        closure_roots.extend(
            path
            for path in sorted(products_dir.glob("*.bundle"))
            if path.is_dir() and not path.is_symlink()
        )
        manifest_lines: List[str] = []
        # Step 8: the sole exclusion is the executable's own adjacent dSYM, pruned
        # only when it is a real (no-follow) directory at exactly that location. A
        # regular file of that name and every other `.dSYM` stay content-hashed.
        excluded_parent = executable.parent
        excluded_name = executable.name + ".dSYM"

        def raise_walk_error(error: OSError) -> None:
            raise error

        for closure_root in closure_roots:
            if observations is not None:
                observations.observe_directory(closure_root)
            for directory, directory_names, file_names in os.walk(
                closure_root,
                topdown=True,
                onerror=raise_walk_error,
                followlinks=False,
            ):
                directory_path = Path(directory)
                directory_names[:] = [
                    name for name in directory_names if not (directory_path / name).is_symlink()
                ]
                if directory_path == excluded_parent and excluded_name in directory_names:
                    if stat.S_ISDIR(os.lstat(directory_path / excluded_name).st_mode):
                        directory_names.remove(excluded_name)
                if observations is not None:
                    # Top-down: each retained child is observed before the walk lists it.
                    for name in directory_names:
                        observations.observe_directory(directory_path / name)
                for file_name in file_names:
                    path = directory_path / file_name
                    if path == executable or path.is_symlink() or not path.is_file():
                        continue
                    file_metadata, file_sha256 = _hash_artifact_file(path, counters, observations)
                    relative_path = path.relative_to(products_dir).as_posix()
                    manifest_lines.append(
                        f"{relative_path}\0{file_metadata.st_size}\0{file_metadata.st_mtime_ns}\0"
                        f"{file_sha256}\n"
                    )
        manifest_lines.sort()
        closure_digest = hashlib.sha256(
            ARTIFACT_CLOSURE_DIGEST_PREFIX
            + "".join(manifest_lines).encode("utf-8", errors="surrogateescape")
        ).hexdigest()
        if observations is not None:
            observations.verify("while it was being fingerprinted")
    except OSError as exc:
        raise ArtifactUnavailableError(
            f"root test artifact closure is unreadable ({exc}); run `make dev-test` first"
        ) from exc
    return {
        "executable_path": str(executable.resolve()),
        "size": metadata.st_size,
        "mtime_ns": metadata.st_mtime_ns,
        "sha256": executable_sha256,
        "closure_manifest_sha256": closure_digest,
        "closure_file_count": len(manifest_lines),
    }


def artifact_fingerprint_differences(
    recorded: Any,
    current: Dict[str, Any],
) -> List[str]:
    if not isinstance(recorded, dict):
        return ["recorded artifact fingerprint"]
    differences: List[str] = []
    executable_keys = ("executable_path", "size", "mtime_ns", "sha256")
    closure_keys = ("closure_manifest_sha256", "closure_file_count")
    if any(recorded.get(key) != current.get(key) for key in executable_keys):
        differences.append("executable fingerprint")
    if any(recorded.get(key) != current.get(key) for key in closure_keys):
        differences.append("artifact closure")
    return differences


def verify_test_artifact_fingerprint(
    artifact_path: Path,
    recorded: Any,
    sink: Optional[Any] = None,
    *,
    observations: Optional[ArtifactObservations] = None,
) -> Dict[str, Any]:
    current = test_artifact_fingerprint(artifact_path, sink=sink, observations=observations)
    differences = artifact_fingerprint_differences(recorded, current)
    if differences:
        raise ArtifactUnavailableError(
            "root test artifact no longer matches its build ticket; changed: "
            + ", ".join(differences)
            + "; run `make dev-test` first"
        )
    return current


def source_snapshot_differences(recorded: Any, current: Optional[Dict[str, Any]]) -> List[str]:
    recorded_snapshot = recorded if isinstance(recorded, dict) else {}
    differences: List[str] = []
    if current is None or current.get("head") != recorded_snapshot.get("head"):
        differences.append("HEAD")
    if (
        current is None
        or current.get("porcelain_sha256") != recorded_snapshot.get("porcelain_sha256")
        or current.get("dirty_file_sha256") != recorded_snapshot.get("dirty_file_sha256")
    ):
        differences.append("dirty digest")
    return differences


def artifact_scope_message(scope: str, differences: Sequence[str], passed: bool = False) -> str:
    if scope == "current":
        return "artifact_scope: current"
    detail = "current source was NOT validated"
    if differences:
        detail += f"; differs: {', '.join(differences)}"
    if passed:
        detail = f"artifact passed; {detail}"
    return f"artifact_scope: stale — {detail}"


def evaluate_test_artifact(
    repo_root: Path,
    jobs_dir: Path,
    env: Dict[str, str],
    sink: Optional[Any] = None,
    *,
    observations: Optional[ArtifactObservations] = None,
) -> Dict[str, Any]:
    """Evaluate the root test artifact; ``sink`` (or the thread's ambient sink)
    gets one ``artifact_evaluation`` operation plus the nested fingerprint.
    ``observations`` collects the identities rechecked before launch (Step 7)."""
    sink = _resolve_operation_sink(sink)
    if sink is None:
        return _evaluate_test_artifact(repo_root, jobs_dir, env, None, observations)
    start = time.monotonic_ns()
    try:
        return _evaluate_test_artifact(repo_root, jobs_dir, env, sink, observations)
    finally:
        _emit_operation(sink, "artifact_evaluation", time.monotonic_ns() - start)


def _evaluate_test_artifact(
    repo_root: Path,
    jobs_dir: Path,
    env: Dict[str, str],
    sink: Optional[Any],
    observations: Optional[ArtifactObservations] = None,
) -> Dict[str, Any]:
    ticket = _read_root_build_ticket(jobs_dir)
    current_toolchain = artifact_toolchain_snapshot(repo_root, env)
    artifact_path = discover_root_test_artifact(repo_root, current_toolchain.get("arch", ""))
    if artifact_path is None:
        raise ArtifactUnavailableError(
            "root test artifact is missing; run `make dev-test` first"
        )
    current_fingerprint = verify_test_artifact_fingerprint(
        artifact_path, ticket.get("artifact_fingerprint"), sink=sink, observations=observations
    )
    current_source = source_snapshot(repo_root, env)
    ticket_source_value = ticket.get("source_snapshot")
    ticket_source = ticket_source_value if isinstance(ticket_source_value, dict) else {}
    differences = source_snapshot_differences(ticket_source, current_source)
    if artifact_env_gates(env) != (ticket.get("env_gates") or {}):
        differences.append("env gates")
    if current_toolchain != (ticket.get("toolchain") or {}):
        differences.append("toolchain")
    scope = "stale" if differences else "current"
    return {
        "artifactPath": str(artifact_path),
        "artifactFingerprint": current_fingerprint,
        "artifactScope": scope,
        "artifactScopeDifferences": differences,
        "artifactScopeMessage": artifact_scope_message(scope, differences),
        "artifactTicketSourceSnapshot": ticket_source,
        "buildTicketId": ticket.get("ticket_id"),
    }


class ParallelTestIntegrityError(ConductorError):
    pass


def parallel_test_evidence_scope(filter_value: Any) -> str:
    return "filtered" if isinstance(filter_value, str) and filter_value else "full-root"


def _valid_parallel_toolchain(value: Any) -> bool:
    return (
        isinstance(value, dict)
        and set(value) == {"swift_version", "arch", "config"}
        and isinstance(value.get("swift_version"), str)
        and bool(value.get("swift_version"))
        and isinstance(value.get("arch"), str)
        and bool(value.get("arch"))
        and value.get("config") == "debug"
    )


def _valid_parallel_source_snapshot(value: Any) -> bool:
    return (
        isinstance(value, dict)
        and set(value) == {"head", "porcelain_sha256", "dirty_file_sha256"}
        and isinstance(value.get("head"), str)
        and bool(value.get("head"))
        and isinstance(value.get("porcelain_sha256"), str)
        and bool(value.get("porcelain_sha256"))
        and isinstance(value.get("dirty_file_sha256"), dict)
        and all(
            isinstance(path, str) and isinstance(digest, str) and bool(digest)
            for path, digest in value.get("dirty_file_sha256", {}).items()
        )
    )


def _valid_parallel_artifact_fingerprint(value: Any) -> bool:
    expected_keys = {
        "executable_path",
        "size",
        "mtime_ns",
        "sha256",
        "closure_manifest_sha256",
        "closure_file_count",
    }
    return (
        isinstance(value, dict)
        and set(value) == expected_keys
        and isinstance(value.get("executable_path"), str)
        and bool(value.get("executable_path"))
        and isinstance(value.get("size"), int)
        and not isinstance(value.get("size"), bool)
        and value.get("size", -1) >= 0
        and isinstance(value.get("mtime_ns"), int)
        and not isinstance(value.get("mtime_ns"), bool)
        and value.get("mtime_ns", -1) >= 0
        and isinstance(value.get("sha256"), str)
        and bool(value.get("sha256"))
        and isinstance(value.get("closure_manifest_sha256"), str)
        and bool(value.get("closure_manifest_sha256"))
        and isinstance(value.get("closure_file_count"), int)
        and not isinstance(value.get("closure_file_count"), bool)
        and value.get("closure_file_count", -1) >= 0
    )


def _parallel_candidate_number(value: Any, *, positive: bool = False) -> bool:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return False
    numeric = float(value)
    return math.isfinite(numeric) and (numeric > 0 if positive else numeric >= 0)


def read_parallel_test_candidate(
    path: Path,
    *,
    expected_run_id: str,
    expected_ticket_id: str,
    expected_filter: Optional[str],
) -> Dict[str, Any]:
    try:
        candidate = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError) as exc:
        raise ParallelTestIntegrityError(
            f"parallel test candidate is missing or unreadable: {path} ({exc})"
        ) from exc
    if not isinstance(candidate, dict):
        raise ParallelTestIntegrityError("parallel test candidate must be a JSON object")
    # Step 8: version classification precedes the strict key set, so a historical
    # candidate gets the specific re-mint diagnostic.
    _require_current_parallel_candidate(candidate)

    expected_keys = {
        "schema_version",
        "fingerprint_version",
        "kind",
        "run_id",
        "ticket_id",
        "filter",
        "evidence_scope",
        "source_snapshot",
        "env_gates",
        "worker_runtime_gates",
        "toolchain",
        "artifact_path",
        "artifact_fingerprint",
        "build_duration_seconds",
        "runner_started_at",
    }
    if set(candidate) != expected_keys:
        missing = sorted(expected_keys - set(candidate))
        extra = sorted(set(candidate) - expected_keys)
        raise ParallelTestIntegrityError(
            f"parallel test candidate schema mismatch; missing={missing}; extra={extra}"
        )
    expected_scope = parallel_test_evidence_scope(expected_filter)
    if candidate.get("schema_version") != PARALLEL_TEST_CANDIDATE_SCHEMA_VERSION:
        raise ParallelTestIntegrityError("parallel test candidate schema version is unsupported")
    if candidate.get("kind") != PARALLEL_TEST_CANDIDATE_KIND:
        raise ParallelTestIntegrityError("parallel test candidate kind is invalid")
    if candidate.get("run_id") != expected_run_id:
        raise ParallelTestIntegrityError("parallel test candidate run ID does not match the job")
    if candidate.get("ticket_id") != expected_ticket_id:
        raise ParallelTestIntegrityError("parallel test candidate ticket ID does not match the job")
    if candidate.get("filter") != expected_filter:
        raise ParallelTestIntegrityError("parallel test candidate filter does not match the job")
    if candidate.get("evidence_scope") != expected_scope:
        raise ParallelTestIntegrityError("parallel test candidate evidence scope does not match the filter")
    if not _valid_parallel_source_snapshot(candidate.get("source_snapshot")):
        raise ParallelTestIntegrityError("parallel test candidate source snapshot is invalid")
    if candidate.get("env_gates") is None or not isinstance(candidate.get("env_gates"), dict):
        raise ParallelTestIntegrityError("parallel test candidate environment gates are invalid")
    if set(candidate["env_gates"]) != {"REPOPROMPT_ENABLE_SENTRY", "RPCE_ENABLE_BENCHMARK_TESTS"}:
        raise ParallelTestIntegrityError("parallel test candidate environment gate schema is invalid")
    if not all(value is None or isinstance(value, str) for value in candidate["env_gates"].values()):
        raise ParallelTestIntegrityError("parallel test candidate environment gate value is invalid")
    worker_runtime_gates = candidate.get("worker_runtime_gates")
    if not isinstance(worker_runtime_gates, dict):
        raise ParallelTestIntegrityError("parallel test candidate worker runtime gates are invalid")
    if set(worker_runtime_gates) != set(PARALLEL_XCTEST_RUNTIME_GATE_KEYS):
        raise ParallelTestIntegrityError("parallel test candidate worker runtime gate schema is invalid")
    if not all(value is None or isinstance(value, str) for value in worker_runtime_gates.values()):
        raise ParallelTestIntegrityError("parallel test candidate worker runtime gate value is invalid")
    if not _valid_parallel_toolchain(candidate.get("toolchain")):
        raise ParallelTestIntegrityError("parallel test candidate toolchain is unavailable or invalid")
    artifact_path_value = candidate.get("artifact_path")
    if not isinstance(artifact_path_value, str) or not Path(artifact_path_value).is_absolute():
        raise ParallelTestIntegrityError("parallel test candidate artifact path is invalid")
    if not _valid_parallel_artifact_fingerprint(candidate.get("artifact_fingerprint")):
        raise ParallelTestIntegrityError("parallel test candidate artifact fingerprint is invalid")
    if not _parallel_candidate_number(candidate.get("build_duration_seconds")):
        raise ParallelTestIntegrityError("parallel test candidate build duration is invalid")
    if not _parallel_candidate_number(candidate.get("runner_started_at"), positive=True):
        raise ParallelTestIntegrityError("parallel test candidate runner start is invalid")
    return candidate


def _require_current_parallel_candidate(candidate: Any) -> None:
    if not isinstance(candidate, dict):
        raise ParallelTestIntegrityError("parallel test candidate must be a JSON object")
    problem = parallel_test_candidate_version_problem(candidate)
    if problem is not None:
        raise ParallelTestIntegrityError(problem)


def verify_parallel_test_candidate(
    repo_root: Path,
    candidate: Dict[str, Any],
    env: Dict[str, str],
) -> None:
    _require_current_parallel_candidate(candidate)
    differences: List[str] = []
    current_source = source_snapshot(repo_root, env)
    differences.extend(
        f"source {difference}"
        for difference in source_snapshot_differences(
            candidate.get("source_snapshot"), current_source
        )
    )
    if artifact_env_gates(env) != candidate.get("env_gates"):
        differences.append("environment gates")
    if parallel_xctest_runtime_gates(env) != candidate.get("worker_runtime_gates"):
        differences.append("worker runtime gates")
    current_toolchain = artifact_toolchain_snapshot(repo_root, env)
    if not _valid_parallel_toolchain(current_toolchain):
        differences.append("toolchain unavailable")
    elif current_toolchain != candidate.get("toolchain"):
        differences.append("toolchain")

    current_artifact = discover_root_test_artifact(
        repo_root, current_toolchain.get("arch", "")
    )
    candidate_artifact = Path(str(candidate.get("artifact_path")))
    if current_artifact is None:
        differences.append("artifact missing")
    elif current_artifact.resolve() != candidate_artifact.resolve():
        differences.append("artifact path")
    else:
        try:
            current_fingerprint = test_artifact_fingerprint(current_artifact)
            differences.extend(
                artifact_fingerprint_differences(
                    candidate.get("artifact_fingerprint"), current_fingerprint
                )
            )
        except ArtifactUnavailableError:
            differences.append("artifact unreadable")

    if differences:
        raise ParallelTestIntegrityError(
            "parallel test source/artifact integrity check failed: "
            + ", ".join(dict.fromkeys(differences))
        )


def parallel_build_ticket_payload(candidate: Dict[str, Any]) -> Dict[str, Any]:
    # Projects only a current candidate, into the root (not candidate) schema.
    _require_current_parallel_candidate(candidate)
    return {
        "schema_version": ROOT_BUILD_TICKET_SCHEMA_VERSION,
        "fingerprint_version": ARTIFACT_FINGERPRINT_VERSION,
        "ticket_id": candidate["ticket_id"],
        "created_at": now(),
        "source_snapshot": candidate["source_snapshot"],
        "env_gates": candidate["env_gates"],
        "worker_runtime_gates": candidate["worker_runtime_gates"],
        "toolchain": candidate["toolchain"],
        "artifact_fingerprint": candidate["artifact_fingerprint"],
        "artifact_path": candidate["artifact_path"],
        "provenance": {
            "producer": "test-parallel",
            "run_id": candidate["run_id"],
            "completion": candidate["evidence_scope"],
            "filter": candidate["filter"],
            "claim": "artifact-provenance-only",
        },
    }


@dataclasses.dataclass(frozen=True)
class XCTestStallClaim:
    phase: str
    progress_transport: str
    progress_sequence: int
    last_progress_test: Optional[str]
    last_progress_action: Optional[str]
    last_progress_observed_at: Optional[float]
    threshold_seconds: float
    budget_source: Optional[str]
    current_test: Optional[str]
    previous_test: Optional[str]
    wake_probe: bool
    triggered_at: float


@dataclasses.dataclass
class ProcessOutputTransport:
    kind: str
    master_fd: Optional[int] = None
    slave_fd: Optional[int] = None
    pipe_stream: Optional[Any] = None
    close_lock: threading.Lock = dataclasses.field(default_factory=threading.Lock, repr=False)

    @classmethod
    def create(cls, kind: str) -> "ProcessOutputTransport":
        if kind == "pipe":
            return cls(kind="pipe")
        if kind != "pty":
            raise ValueError(f"unsupported process output transport: {kind}")
        master_fd, slave_fd = os.openpty()
        return cls(kind="pty", master_fd=master_fd, slave_fd=slave_fd)

    @property
    def popen_stdout(self) -> Any:
        return self.slave_fd if self.kind == "pty" else subprocess.PIPE

    @property
    def popen_stderr(self) -> Any:
        return self.slave_fd if self.kind == "pty" else subprocess.STDOUT

    def attach_process(self, process: subprocess.Popen[bytes]) -> None:
        if self.kind == "pty":
            self.close_slave()
            return
        if process.stdout is None:
            raise ConductorError("pipe-backed process did not expose stdout")
        with self.close_lock:
            self.pipe_stream = process.stdout

    def read_chunk(self, process: subprocess.Popen[bytes]) -> bytes:
        with self.close_lock:
            master_fd = self.master_fd
            pipe_stream = self.pipe_stream
        if self.kind == "pipe":
            if pipe_stream is None:
                return b""
            # Whatever is available (one raw read), never a fill-the-buffer read.
            return pipe_stream.read1(CONDUCTOR_OUTPUT.READ_CHUNK_BYTES)
        if master_fd is None:
            return b""
        try:
            return os.read(master_fd, CONDUCTOR_OUTPUT.READ_CHUNK_BYTES)
        except OSError as exc:
            if exc.errno == errno.EIO:
                return b""
            if exc.errno == errno.EBADF:
                with self.close_lock:
                    if self.master_fd is None:
                        return b""
            raise

    def read_available(self, max_bytes: int = CONDUCTOR_OUTPUT.READ_CHUNK_BYTES) -> Optional[bytes]:
        """One PTY read of at most ``max_bytes`` already-available bytes, else ``None`` (OD14).

        Never waits: ``select`` with a zero timeout gates a single read. ``None``
        means nothing is available right now, the reader was closed, the descriptor
        cannot be polled, or the read failed; the next blocking ``read_chunk`` then
        observes EOF, cancellation or the error exactly as without coalescing.
        """
        if self.kind != "pty":
            return None
        with self.close_lock:
            master_fd = self.master_fd
        if master_fd is None:
            return None
        try:
            ready, _, _ = select.select([master_fd], [], [], 0)
            if not ready:
                return None
            chunk = os.read(master_fd, max(1, min(int(max_bytes), CONDUCTOR_OUTPUT.READ_CHUNK_BYTES)))
        except (OSError, ValueError):
            return None
        return chunk or None

    def close_slave(self) -> None:
        with self.close_lock:
            slave_fd = self.slave_fd
            self.slave_fd = None
        if slave_fd is not None:
            with contextlib.suppress(OSError):
                os.close(slave_fd)

    def close_reader(self) -> None:
        with self.close_lock:
            master_fd = self.master_fd
            pipe_stream = self.pipe_stream
            self.master_fd = None
            self.pipe_stream = None
        if master_fd is not None:
            with contextlib.suppress(OSError):
                os.close(master_fd)
        if pipe_stream is not None:
            with contextlib.suppress(OSError):
                pipe_stream.close()

    def close_all(self) -> None:
        self.close_slave()
        self.close_reader()


def is_xctest_process_command(command: str) -> bool:
    normalized = command.strip()
    executable = normalized.split(None, 1)[0] if normalized else ""
    return (
        ".xctest/" in executable
        or executable.endswith(".xctest")
        or Path(executable).name == "xctest"
    )


@dataclasses.dataclass(frozen=True)
class Paths:
    repo_root: Path
    repo_hash: str
    state_dir: Path
    socket_path: Path
    pid_path: Path
    lock_path: Path
    jobs_dir: Path
    daemon_log_path: Path
    daemon_meta_path: Path
    running_processes_path: Path


def resolve_repo_root() -> Path:
    return Path(__file__).resolve().parent.parent


def compute_paths(repo_root: Path) -> Paths:
    real_root = repo_root.resolve()
    repo_hash = hashlib.sha256(str(real_root).encode("utf-8")).hexdigest()
    state_override = os.environ.get("REPOPROMPT_DEV_DAEMON_STATE_DIR")
    socket_override = os.environ.get("REPOPROMPT_DEV_DAEMON_SOCKET")

    if state_override:
        state_dir = Path(state_override).expanduser().resolve()
    else:
        state_dir = (
            Path.home()
            / "Library"
            / "Application Support"
            / "RepoPrompt CE"
            / "Conductor"
            / repo_hash
        )
    uid = os.getuid() if hasattr(os, "getuid") else 0
    socket_path = (
        Path(socket_override).expanduser().resolve()
        if socket_override
        else Path("/tmp") / f"conductor-{uid}" / f"{repo_hash[:16]}.sock"
    )
    return Paths(
        repo_root=real_root,
        repo_hash=repo_hash,
        state_dir=state_dir,
        socket_path=socket_path,
        pid_path=state_dir / "daemon.pid",
        lock_path=state_dir / "daemon.start.lock",
        jobs_dir=state_dir / "jobs",
        daemon_log_path=state_dir / "daemon.log",
        daemon_meta_path=state_dir / "daemon.json",
        running_processes_path=state_dir / "running-processes.json",
    )


def ensure_private_dir(path: Path) -> None:
    try:
        existing = os.lstat(path)
    except FileNotFoundError:
        path.mkdir(mode=0o700, parents=True, exist_ok=True)
    else:
        if stat.S_ISLNK(existing.st_mode):
            raise ConductorError(f"private directory {path} must not be a symlink")
        if not stat.S_ISDIR(existing.st_mode):
            raise ConductorError(f"private directory {path} is not a directory")
    try:
        stat_result = os.lstat(path)
    except OSError as exc:
        raise ConductorError(f"could not stat private directory {path}: {exc}")
    if stat.S_ISLNK(stat_result.st_mode):
        raise ConductorError(f"private directory {path} must not be a symlink")
    if not stat.S_ISDIR(stat_result.st_mode):
        raise ConductorError(f"private directory {path} is not a directory")
    if hasattr(os, "getuid") and stat_result.st_uid != os.getuid():
        raise ConductorError(f"private directory {path} is not owned by the current user")
    mode = stat_result.st_mode & 0o777
    if mode & 0o077:
        try:
            os.chmod(path, 0o700)
        except OSError as exc:
            raise ConductorError(f"could not restrict private directory {path} to 0700: {exc}")
        mode = os.lstat(path).st_mode & 0o777
        if mode & 0o077:
            raise ConductorError(f"private directory {path} is not credential-safe (mode {mode:o})")


def ensure_state_dirs(paths: Paths) -> None:
    ensure_private_dir(paths.state_dir)
    ensure_private_dir(paths.jobs_dir)
    ensure_private_dir(paths.socket_path.parent)
    ensure_private_dir(machine_lock_dir())


def machine_lock_dir() -> Path:
    uid = os.getuid() if hasattr(os, "getuid") else 0
    return Path("/tmp") / f"repoprompt-ce-dev-locks-{uid}"


def configured_global_heavy_slots(env: Optional[Dict[str, str]] = None) -> int:
    raw = (env or os.environ).get("REPOPROMPT_DEV_HEAVY_SLOTS")
    if raw is None or raw == "":
        return 1
    try:
        slots = int(raw)
    except ValueError as exc:
        raise ConductorError("REPOPROMPT_DEV_HEAVY_SLOTS must be a positive integer") from exc
    if slots < 1 or slots > MAX_GLOBAL_HEAVY_SLOTS:
        raise ConductorError(f"REPOPROMPT_DEV_HEAVY_SLOTS must be between 1 and {MAX_GLOBAL_HEAVY_SLOTS}")
    return slots


def global_heavy_slot_paths(env: Optional[Dict[str, str]] = None) -> List[Path]:
    root = machine_lock_dir()
    return [root / f"global-heavy-{index}.lock" for index in range(configured_global_heavy_slots(env))]


def configured_global_xctest_slots(env: Optional[Dict[str, str]] = None) -> int:
    raw = (env or os.environ).get("REPOPROMPT_DEV_XCTEST_SLOTS")
    if raw is None or raw == "":
        return 1
    try:
        slots = int(raw)
    except ValueError as exc:
        raise ConductorError("REPOPROMPT_DEV_XCTEST_SLOTS must be a positive integer") from exc
    if slots < 1 or slots > MAX_GLOBAL_XCTEST_SLOTS:
        raise ConductorError(f"REPOPROMPT_DEV_XCTEST_SLOTS must be between 1 and {MAX_GLOBAL_XCTEST_SLOTS}")
    return slots


def global_xctest_slot_paths(env: Optional[Dict[str, str]] = None) -> List[Path]:
    root = machine_lock_dir()
    return [root / f"global-xctest-{index}.lock" for index in range(configured_global_xctest_slots(env))]


def live_app_lock_path() -> Path:
    return machine_lock_dir() / "live-app.lock"


def repo_worktree_name(repo_root: Path) -> str:
    return repo_root.name or str(repo_root)


def display_lock_metadata(
    *,
    lock_kind: str,
    ticket: Optional[str],
    operation: str,
    operation_label: str,
    repo_root: Path,
    repo_hash: Optional[str] = None,
) -> Dict[str, Any]:
    acquired_at = now()
    return {
        "version": 1,
        "displayOnly": True,
        "kind": lock_kind,
        "ticket": ticket,
        "operation": operation,
        "operationLabel": operation_label,
        "repoRoot": str(repo_root),
        "repoHash": repo_hash,
        "worktree": repo_worktree_name(repo_root),
        "pid": os.getpid(),
        "acquiredAt": acquired_at,
        "acquiredAtISO": iso_timestamp(acquired_at),
    }


def write_display_lock_metadata(lock_file: Any, metadata: Dict[str, Any]) -> None:
    try:
        lock_file.seek(0)
        lock_file.truncate()
        lock_file.write(json.dumps(metadata, indent=2, sort_keys=True))
        lock_file.write("\n")
        lock_file.flush()
    except OSError:
        pass


def read_display_lock_metadata(path: Path) -> Optional[Dict[str, Any]]:
    try:
        raw = path.read_text(encoding="utf-8", errors="replace")
        payload = json.loads(raw) if raw.strip() else None
    except (OSError, json.JSONDecodeError):
        return None
    return payload if isinstance(payload, dict) else None


def format_display_lock_holder(metadata: Optional[Dict[str, Any]]) -> str:
    if not metadata:
        return "holder unknown"
    label = metadata.get("operationLabel") or metadata.get("operation") or "unknown operation"
    ticket = metadata.get("ticket") or "no-ticket"
    repo = metadata.get("repoRoot") or "unknown repo"
    worktree = metadata.get("worktree") or Path(str(repo)).name
    acquired_at = metadata.get("acquiredAt")
    held_for = "unknown duration"
    if isinstance(acquired_at, (int, float)):
        held_for = format_duration(now() - float(acquired_at))
    return f"holder {label} ticket={ticket} repo={repo} worktree={worktree} held={held_for}"


@contextlib.contextmanager
def machine_exclusive_lock(lock_path: Path, metadata: Dict[str, Any], wait_label: str):
    ensure_private_dir(lock_path.parent)
    lock_file = lock_path.open("a+", encoding="utf-8")
    did_log_wait = False
    while True:
        try:
            fcntl.flock(lock_file.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
            break
        except BlockingIOError:
            if not did_log_wait:
                holder = format_display_lock_holder(read_display_lock_metadata(lock_path))
                print(f"waiting for {wait_label}: {lock_path} ({holder})", flush=True)
                did_log_wait = True
            time.sleep(MACHINE_LOCK_POLL_SECONDS)
        except OSError as exc:
            if exc.errno == errno.EINTR:
                continue
            lock_file.close()
            raise
    write_display_lock_metadata(lock_file, metadata)
    try:
        yield lock_file
    finally:
        with contextlib.suppress(OSError):
            lock_file.seek(0)
            lock_file.truncate()
            lock_file.flush()
        with contextlib.suppress(OSError):
            fcntl.flock(lock_file.fileno(), fcntl.LOCK_UN)
        with contextlib.suppress(OSError):
            lock_file.close()


@contextlib.contextmanager
def machine_heavy_slot(metadata: Dict[str, Any], env: Optional[Dict[str, str]], wait_label: str):
    ensure_private_dir(machine_lock_dir())
    lock_files = [(path, path.open("a+", encoding="utf-8")) for path in global_heavy_slot_paths(env)]
    did_log_wait = False
    selected_file: Optional[Any] = None
    try:
        while True:
            for lock_path, lock_file in lock_files:
                try:
                    fcntl.flock(lock_file.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
                    selected_file = lock_file
                    write_display_lock_metadata(lock_file, metadata)
                    print(f"acquired {wait_label}: {lock_path}", flush=True)
                    yield lock_file
                    return
                except BlockingIOError:
                    continue
                except OSError as exc:
                    if exc.errno == errno.EINTR:
                        continue
                    raise
            if not did_log_wait:
                holders = "; ".join(format_display_lock_holder(read_display_lock_metadata(path)) for path, _ in lock_files)
                paths = ",".join(str(path) for path, _ in lock_files)
                print(f"waiting for {wait_label} ({len(lock_files)} configured): {paths}; {holders}", flush=True)
                did_log_wait = True
            time.sleep(GLOBAL_HEAVY_SLOT_POLL_SECONDS)
    finally:
        for _path, lock_file in lock_files:
            if lock_file is selected_file:
                with contextlib.suppress(OSError):
                    lock_file.seek(0)
                    lock_file.truncate()
                    lock_file.flush()
                with contextlib.suppress(OSError):
                    fcntl.flock(lock_file.fileno(), fcntl.LOCK_UN)
            with contextlib.suppress(OSError):
                lock_file.close()


def read_pid(path: Path) -> Optional[int]:
    try:
        raw = path.read_text(encoding="utf-8").strip()
        return int(raw) if raw else None
    except (FileNotFoundError, ValueError, OSError):
        return None


def pid_alive(pid: int) -> bool:
    if pid <= 0:
        return False
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    except OSError:
        return False


def cleanup_stale_files(paths: Paths) -> None:
    pid = read_pid(paths.pid_path)
    if pid is not None and pid_alive(pid):
        return
    for path in (paths.pid_path, paths.socket_path, paths.daemon_meta_path, paths.running_processes_path):
        with contextlib.suppress(FileNotFoundError):
            path.unlink()


def process_start_token(pid: int) -> Optional[str]:
    try:
        completed = subprocess.run(
            ["ps", "-p", str(pid), "-o", "lstart="],
            text=True,
            capture_output=True,
            timeout=2.0,
        )
    except (OSError, subprocess.TimeoutExpired):
        return None
    if completed.returncode != 0:
        return None
    token = completed.stdout.strip()
    return token or None


def process_table_snapshot() -> Dict[int, Tuple[int, str]]:
    try:
        completed = subprocess.run(
            ["ps", "-axo", "pid=,ppid=,lstart="],
            text=True,
            capture_output=True,
            timeout=2.0,
        )
    except (OSError, subprocess.TimeoutExpired):
        return {}
    if completed.returncode != 0:
        return {}
    snapshot: Dict[int, Tuple[int, str]] = {}
    for line in completed.stdout.splitlines():
        parts = line.strip().split(None, 2)
        if len(parts) != 3:
            continue
        try:
            pid = int(parts[0])
            ppid = int(parts[1])
        except ValueError:
            continue
        if pid > 0 and parts[2]:
            snapshot[pid] = (ppid, parts[2])
    return snapshot


def process_group_snapshot(pgid: int) -> Dict[int, Tuple[int, str]]:
    if pgid <= 0:
        return {}
    try:
        completed = subprocess.run(
            ["ps", "-axo", "pid=,ppid=,pgid=,lstart="],
            text=True,
            capture_output=True,
            timeout=2.0,
        )
    except (OSError, subprocess.TimeoutExpired):
        return {}
    if completed.returncode != 0:
        return {}
    snapshot: Dict[int, Tuple[int, str]] = {}
    for line in completed.stdout.splitlines():
        parts = line.strip().split(None, 3)
        if len(parts) != 4:
            continue
        try:
            pid = int(parts[0])
            ppid = int(parts[1])
            candidate_pgid = int(parts[2])
        except ValueError:
            continue
        if pid > 0 and candidate_pgid == pgid and parts[3]:
            snapshot[pid] = (ppid, parts[3])
    return snapshot


def process_command_snapshot(pids: Sequence[int]) -> Dict[int, str]:
    selected = sorted({pid for pid in pids if pid > 0})[:XCTEST_STALL_DIAGNOSTIC_MAX_PROCESSES]
    if not selected:
        return {}
    try:
        completed = subprocess.run(
            ["ps", "-ww", "-p", ",".join(str(pid) for pid in selected), "-o", "pid=,command="],
            text=True,
            capture_output=True,
            timeout=2.0,
        )
    except (OSError, subprocess.TimeoutExpired):
        return {}
    if completed.returncode != 0:
        return {}
    commands: Dict[int, str] = {}
    for line in completed.stdout.splitlines():
        stripped = line.strip()
        if not stripped:
            continue
        parts = stripped.split(None, 1)
        if len(parts) != 2:
            continue
        try:
            pid = int(parts[0])
        except ValueError:
            continue
        commands[pid] = parts[1]
    return commands


def process_command(pid: int) -> str:
    try:
        completed = subprocess.run(
            ["ps", "-ww", "-p", str(pid), "-o", "command="],
            text=True,
            capture_output=True,
            timeout=2.0,
        )
    except (OSError, subprocess.TimeoutExpired):
        return ""
    if completed.returncode != 0:
        return ""
    return completed.stdout.strip()


def write_daemon_metadata(paths: Paths) -> None:
    payload = {
        "pid": os.getpid(),
        "repoRoot": str(paths.repo_root),
        "repoHash": paths.repo_hash,
        "script": str(Path(__file__).resolve()),
        "processStart": process_start_token(os.getpid()),
        "createdAt": now(),
    }
    paths.daemon_meta_path.write_text(json.dumps(payload, indent=2, sort_keys=True), encoding="utf-8")
    with contextlib.suppress(OSError):
        os.chmod(paths.daemon_meta_path, 0o600)


def read_daemon_metadata(paths: Paths) -> Dict[str, Any]:
    try:
        raw = paths.daemon_meta_path.read_text(encoding="utf-8")
        payload = json.loads(raw)
        return payload if isinstance(payload, dict) else {}
    except (FileNotFoundError, json.JSONDecodeError, OSError):
        return {}


def verify_daemon_pid_identity(paths: Paths, pid: int) -> bool:
    metadata = read_daemon_metadata(paths)
    if metadata.get("pid") != pid:
        return False
    if metadata.get("repoRoot") != str(paths.repo_root) or metadata.get("repoHash") != paths.repo_hash:
        return False
    expected_start = metadata.get("processStart")
    if expected_start and process_start_token(pid) != expected_start:
        return False
    return daemon_command_matches(process_command(pid), paths)


def daemon_command_matches(command: str, paths: Paths) -> bool:
    """Whether ``ps`` command text is this checkout's daemon.

    A daemon started through the entry must end with exactly the arguments
    ``spawn_daemon`` passes. The interpreter path is not compared, because
    ``ps`` may show a framework Python's re-executed binary. A daemon started
    directly from ``conductor.py`` by an earlier conductor keeps the legacy
    check.
    """
    entry_arguments = f" {conductor_entry_script()} __daemon --repo-root {paths.repo_root}"
    if command.endswith(entry_arguments):
        return True
    return "conductor.py" in command and "__daemon" in command and str(paths.repo_root) in command


def json_dumps(obj: Any) -> str:
    return json.dumps(obj, sort_keys=True, separators=(",", ":"))


def print_json(obj: Any) -> None:
    print(json.dumps(obj, indent=2, sort_keys=True))


def now() -> float:
    return time.time()


def iso_timestamp(ts: Optional[float]) -> Optional[str]:
    if ts is None:
        return None
    return time.strftime("%Y-%m-%dT%H:%M:%S%z", time.localtime(ts))


def terminal_exit_code(payload: Dict[str, Any]) -> int:
    state = payload.get("state")
    exit_code = payload.get("exitCode")
    if state == "completed":
        return int(exit_code or 0)
    if state == "failed":
        return int(exit_code if exit_code is not None else 1)
    if state == "canceled":
        return 130
    return 1


ANSI_RE = re.compile(r"\x1b\[[0-?]*[ -/]*[@-~]")


def clean_summary_line(line: str) -> str:
    cleaned = ANSI_RE.sub("", line.rstrip("\r\n"))
    if len(cleaned) > SUMMARY_LINE_MAX_CHARS:
        return cleaned[: SUMMARY_LINE_MAX_CHARS - 1] + "…"
    return cleaned


class VisibleSummaryLine(str):
    """An over-cap log record already cleaned of ``ANSI_RE`` (one pass over the whole
    record): its first ``SUMMARY_LINE_MAX_CHARS + 1`` visible characters, so
    ``clean_summary_line`` of the whole record is this text, cut the same way."""


if CONDUCTOR_OUTPUT.CSI_RE.pattern != ANSI_RE.pattern:
    raise ImportError("conductor_output.py disagrees with conductor.py on the summary ANSI grammar")


class SummarySectionBuilder:
    """One summary section with bounded deduplication memory.

    ``seen`` holds at most ``max_seen`` lines. Behavior is exact until it is
    full; afterwards an unseen line can no longer be told apart from an earlier
    omitted duplicate, so it is still checked against the displayed lines but
    ``omittedLineCount`` becomes an upper bound (``deduplicationLimited``).
    A ``keep_last`` section can then also re-display an older line that has
    left its window; when such a line evicts another, the section discloses
    ``displayedLinesMayRepeat`` (OD15). First-lines sections never evict, so
    their displayed lines stay exact.
    """

    def __init__(self, title: str, max_lines: int, keep_last: bool = False, max_seen: Optional[int] = None) -> None:
        self.title = title
        self.max_lines = max_lines
        self.keep_last = keep_last
        self.max_seen = SUMMARY_SEEN_MAX_ENTRIES if max_seen is None else max_seen
        self.lines: List[str] = []
        self.seen: set[str] = set()
        self.omitted = 0
        self.deduplication_limited = False
        self.displayed_lines_may_repeat = False

    def add(self, line: str) -> None:
        cleaned = clean_summary_line(line)
        if not cleaned or cleaned in self.seen:
            return
        unverified = False
        if len(self.seen) < self.max_seen:
            self.seen.add(cleaned)
        elif cleaned in self.lines:
            return
        else:
            self.deduplication_limited = True
            unverified = True
        if len(self.lines) < self.max_lines:
            self.lines.append(cleaned)
        elif self.keep_last:
            self.lines.pop(0)
            self.lines.append(cleaned)
            self.omitted += 1
            if unverified:
                self.displayed_lines_may_repeat = True
        else:
            self.omitted += 1

    def extend(self, lines: Sequence[str]) -> None:
        for line in lines:
            self.add(line)

    def payload(self) -> Optional[Dict[str, Any]]:
        if not self.lines:
            return None
        return {
            "title": self.title,
            "lines": list(self.lines),
            "truncated": self.omitted > 0,
            "omittedLineCount": self.omitted,
            "deduplicationLimited": self.deduplication_limited,
            "omittedLineCountQuality": "upper_bound" if self.deduplication_limited else "exact",
            "displayedLinesMayRepeat": self.displayed_lines_may_repeat,
        }


class OutputSummarizer:
    FAILURE_RE = re.compile(
        r"(ERROR:|FAILED|failed with|process exited with status|fatal error|Traceback|Exception|Permission denied|No such file or directory|timed out|killing process (?:group|tree)|terminating process (?:group|tree))",
        re.IGNORECASE,
    )
    SWIFT_ERROR_RE = re.compile(r"(: error:|error: emit-module command failed|Command SwiftCompile failed|Command CompileSwift failed|fatal error:)")
    WARNING_RE = re.compile(r"(: warning:|^WARNING:)")
    TEST_FAILURE_RE = re.compile(
        r"(Test Case '.*' failed|XCTAssert|: error: .*Test|Executed .* tests?, with .* failures?|Failing tests:|error: Exited with unexpected signal|error: terminated)"
    )
    STYLE_FINDING_RE = re.compile(
        r"(SwiftFormat|SwiftLint|linting|Missing required tool|Run 'make install-format-tools'|ERROR: Missing required Swift style tools|[^\s:]+:\d+:\d+: (warning|error):)"
    )
    TIMEOUT_RE = re.compile(
        r"(timed out after|XCTest .* deadline triggered|terminating process (?:group|tree)|killing process (?:group|tree)|canceled)",
        re.IGNORECASE,
    )
    PHASE_RE = re.compile(r"^(==>|\$ |\+ )")
    ARTIFACT_RE = re.compile(
        r"^(Created:|APP_BUNDLE=|COMPAT_APP_BUNDLE=|CLI_PATH=|Output written to:|Agent Mode diagnostics enabled|Resolved rpce-cli-debug:|Build cache diagnostics|Current \.build:|Managed worktree container:|Worktree \.build total:|Top \.build directories:|\s+[0-9.]+ [KMGT]?i?B\s+)"
    )
    APP_LIFECYCLE_RE = re.compile(
        r"(Stopping existing RepoPrompt|Waiting for existing RepoPrompt|Launching .*RepoPrompt\.app|Confirming launched RepoPrompt|Observed launched RepoPrompt|Guarding against a delayed RepoPrompt|Delayed launch guard confirmed|RepoPrompt(?: CE debug app)? stop confirmed|RepoPrompt was (not running|already stopped))"
    )
    SOURCE_CHANGED_DURING_BUILD_RE = re.compile(r"input file .* was modified during the build", re.IGNORECASE)
    # Tests compare against the unconditional (pre-Step-3) classification.
    KEYWORD_PRECHECK = True

    @classmethod
    def summarize_file(
        cls,
        operation: str,
        args: Dict[str, Any],
        state: str,
        exit_code: Optional[int],
        timed_out: bool,
        log_path: Path,
    ) -> Dict[str, Any]:
        # The raw log streams through the shared record splitter (Step 3): records
        # end at LF, CR LF or a bare CR, exactly like universal-newline reading.
        # An over-cap record yields its cleaned visible prefix over the whole record.
        try:
            texts = CONDUCTOR_OUTPUT.iter_file_texts(
                log_path,
                over_cap=VisibleSummaryLine,
                visible_chars=SUMMARY_LINE_MAX_CHARS + 1,
                visible_pattern=CONDUCTOR_OUTPUT.CSI_RE,
            )
            return cls.summarize_lines(operation, args, state, exit_code, timed_out, texts)
        except OSError as exc:
            return cls._minimal_summary(operation, state, exit_code, f"could not read log for summary: {exc}")

    @classmethod
    def summarize_lines(
        cls,
        operation: str,
        args: Dict[str, Any],
        state: str,
        exit_code: Optional[int],
        timed_out: bool,
        lines_iterable: Any,
    ) -> Dict[str, Any]:
        del args
        failure = state in {"failed", "canceled"} or bool(timed_out) or (exit_code not in (None, 0))
        launch_lifecycle = {
            "transitionStarted": False,
            "launchRequested": False,
            "launchConfirmed": False,
            "sourceChangedDuringBuild": False,
        }
        section_limit = SUMMARY_FAILURE_MAX_LINES if failure else SUMMARY_SUCCESS_MAX_LINES
        per_section_limit = max(5, min(30, section_limit // 2))
        sections = {
            "App lifecycle": SummarySectionBuilder("App lifecycle", 12, keep_last=True),
            "Phases": SummarySectionBuilder("Phases", 20 if failure else 10, keep_last=True),
            "Failure highlights": SummarySectionBuilder("Failure highlights", per_section_limit),
            "Swift compiler errors": SummarySectionBuilder("Swift compiler errors", per_section_limit),
            "Test failures": SummarySectionBuilder("Test failures", per_section_limit),
            "Style findings": SummarySectionBuilder("Style findings", per_section_limit),
            "Warnings": SummarySectionBuilder("Warnings", 5 if not failure else 10),
            "Timeout or cancellation": SummarySectionBuilder("Timeout or cancellation", per_section_limit),
            "Artifacts": SummarySectionBuilder("Artifacts", 10),
            "Recent output": SummarySectionBuilder("Recent output", 20),
            "Summary notes": SummarySectionBuilder("Summary notes", 5),
        }
        line_count = 0
        warning_count = 0
        error_count = 0
        tail: Deque[str] = deque(maxlen=20)
        previous_context: Deque[str] = deque(maxlen=SUMMARY_CONTEXT_BEFORE)
        pending_context: List[Tuple[str, int]] = []
        style_operation = operation in {"format", "format-check", "lint", "check-format-tools", "install-format-tools", "format-tools-status"}
        precheck = cls.KEYWORD_PRECHECK

        for raw_line in lines_iterable:
            line_count += 1
            if type(raw_line) is str:
                line = clean_summary_line(raw_line)
            elif type(raw_line) is VisibleSummaryLine:
                # Already cleaned over the whole record: only the length cut remains.
                line = str(raw_line)
                if len(line) > SUMMARY_LINE_MAX_CHARS:
                    line = line[: SUMMARY_LINE_MAX_CHARS - 1] + "…"
            else:
                line = clean_summary_line(str(raw_line))
            tail.append(line)

            # Casefolded keyword precheck: each gate is implied by every
            # alternative of its regex, so a closed gate proves a non-match.
            # It is exact for ASCII lines (casefold is ASCII lowercase and
            # IGNORECASE cannot match a different ASCII letter); other lines
            # run every regex. Each regex runs at most once per record.
            if precheck and line.isascii():
                low = line.casefold()
                g_error = "error:" in low
                g_warning = "warning:" in low
                g_repoprompt = "repoprompt" in low
                g_kill = "killing process " in low or "terminating process " in low
                g_source = "was modified during the build" in low
                g_swift = g_error or "swiftcompile failed" in low or "compileswift failed" in low
                g_failure = (
                    g_error or g_kill or "failed" in low or "fatal error" in low or "exception" in low
                    or "timed out" in low or "process exited with status" in low or "traceback" in low
                    or "permission denied" in low or "no such file or directory" in low
                )
                g_timeout = g_kill or "canceled" in low or "timed out after" in low or "deadline triggered" in low
                g_test = (
                    g_error or "test case '" in low or "executed " in low or "xctassert" in low or "failing tests:" in low
                )
                g_lifecycle = g_repoprompt or "delayed launch guard confirmed" in low
                g_style = style_operation and (
                    g_error or g_warning or "swiftformat" in low or "swiftlint" in low or "linting" in low
                    or "missing required" in low or "install-format-tools" in low
                )
            else:
                g_error = g_warning = g_repoprompt = g_source = g_swift = g_failure = True
                g_timeout = g_test = g_lifecycle = True
                g_style = style_operation

            if g_repoprompt:
                if "Stopping existing RepoPrompt" in line:
                    launch_lifecycle["transitionStarted"] = True
                if "Launching " in line and "RepoPrompt.app" in line:
                    launch_lifecycle["transitionStarted"] = True
                    launch_lifecycle["launchRequested"] = True
                if "Observed launched RepoPrompt" in line:
                    launch_lifecycle["launchConfirmed"] = True
            if g_source and cls.SOURCE_CHANGED_DURING_BUILD_RE.search(line):
                launch_lifecycle["sourceChangedDuringBuild"] = True

            swift_error = g_swift and cls.SWIFT_ERROR_RE.search(line) is not None
            failure_match = g_failure and cls.FAILURE_RE.search(line) is not None
            if g_warning and cls.WARNING_RE.search(line):
                warning_count += 1
                if failure or line.startswith("WARNING:"):
                    sections["Warnings"].add(line)
            if swift_error or failure_match:
                error_count += 1

            if pending_context:
                next_pending: List[Tuple[str, int]] = []
                for title, remaining in pending_context:
                    sections[title].add(line)
                    if remaining > 1:
                        next_pending.append((title, remaining - 1))
                pending_context = next_pending

            matched_titles: List[str] = []
            first = line[:1]
            # Anchored patterns: exact first-character gates (``\s`` is str.isspace).
            if first in "=$+" and cls.PHASE_RE.search(line):
                sections["Phases"].add(line)
            if g_lifecycle and cls.APP_LIFECYCLE_RE.search(line):
                sections["App lifecycle"].add(line)
            if (first in "CAORBMWT" or first.isspace()) and cls.ARTIFACT_RE.search(line):
                sections["Artifacts"].add(line)
            if g_timeout and cls.TIMEOUT_RE.search(line):
                matched_titles.append("Timeout or cancellation")
            if g_test and cls.TEST_FAILURE_RE.search(line):
                matched_titles.append("Test failures")
            if swift_error:
                matched_titles.append("Swift compiler errors")
            if g_style and cls.STYLE_FINDING_RE.search(line):
                matched_titles.append("Style findings")
            if failure_match:
                matched_titles.append("Failure highlights")

            for title in matched_titles:
                sections[title].extend(list(previous_context))
                sections[title].add(line)
                pending_context.append((title, SUMMARY_CONTEXT_AFTER))

            previous_context.append(line)

        if failure:
            has_strong_failure_section = any(
                sections[title].lines
                for title in [
                    "Swift compiler errors",
                    "Test failures",
                    "Style findings",
                    "Timeout or cancellation",
                ]
            )
            if not has_strong_failure_section:
                sections["Recent output"].extend(list(tail))
        else:
            # Success summaries should stay artifact/phase focused and avoid raw build noise.
            sections["Recent output"].lines.clear()

        headline = cls._headline(state, exit_code, timed_out)
        ordered_titles = [
            "Failure highlights",
            "Swift compiler errors",
            "Test failures",
            "Style findings",
            "Timeout or cancellation",
            "Warnings",
            "Artifacts",
            "App lifecycle",
            "Phases",
            "Recent output",
            "Summary notes",
        ]
        payload_sections: List[Dict[str, Any]] = []
        rendered_line_count = 0
        rendered_chars = 0
        truncated = False
        for title in ordered_titles:
            section = sections[title].payload()
            if not section:
                continue
            remaining_lines = section_limit - rendered_line_count
            if remaining_lines <= 0:
                truncated = True
                break
            if len(section["lines"]) > remaining_lines:
                omitted = len(section["lines"]) - remaining_lines + int(section.get("omittedLineCount") or 0)
                section = dict(section)
                section["lines"] = section["lines"][:remaining_lines]
                section["truncated"] = True
                section["omittedLineCount"] = omitted
                truncated = True
            section_chars = sum(len(line) for line in section["lines"])
            if rendered_chars + section_chars > SUMMARY_MAX_CHARS:
                truncated = True
                break
            payload_sections.append(section)
            rendered_line_count += len(section["lines"])
            rendered_chars += section_chars
            if section.get("truncated"):
                truncated = True

        omitted_line_count = max(0, line_count - rendered_line_count)
        deduplication_limited = any(builder.deduplication_limited for builder in sections.values())
        may_repeat = any(builder.displayed_lines_may_repeat for builder in sections.values())
        return {
            "version": SUMMARY_VERSION,
            "operation": operation,
            "state": state,
            "exitCode": exit_code,
            "headline": headline,
            "logLineCount": line_count,
            "omittedLineCount": omitted_line_count,
            "errorCount": error_count,
            "warningCount": warning_count,
            "launchLifecycle": launch_lifecycle,
            "sections": payload_sections,
            "truncated": truncated,
            # Any section's deduplication saturated (its counts are upper bounds),
            # and whether a keep-last section may show a repeated older line.
            "deduplicationLimited": deduplication_limited,
            "displayedLinesMayRepeat": may_repeat,
            # Describes the top-level ``omittedLineCount`` (log lines minus
            # rendered lines), which is always exact.
            "omittedLineCountQuality": "exact",
        }

    @classmethod
    def _headline(cls, state: str, exit_code: Optional[int], timed_out: bool) -> str:
        if state == "completed":
            return "completed successfully"
        if timed_out:
            return "failed after timeout"
        if state == "canceled":
            return "canceled"
        if exit_code is not None:
            return f"failed with exit code {exit_code}"
        return state or "unknown result"

    @classmethod
    def _minimal_summary(cls, operation: str, state: str, exit_code: Optional[int], note: str) -> Dict[str, Any]:
        return {
            "version": SUMMARY_VERSION,
            "operation": operation,
            "state": state,
            "exitCode": exit_code,
            "headline": cls._headline(state, exit_code, False),
            "logLineCount": 0,
            "omittedLineCount": 0,
            "errorCount": 0,
            "warningCount": 0,
            "sections": [
                {
                    "title": "Summary notes",
                    "lines": [clean_summary_line(note)],
                    "truncated": False,
                    "omittedLineCount": 0,
                    "deduplicationLimited": False,
                    "omittedLineCountQuality": "exact",
                    "displayedLinesMayRepeat": False,
                }
            ],
            "truncated": False,
            "deduplicationLimited": False,
            "displayedLinesMayRepeat": False,
            "omittedLineCountQuality": "exact",
        }


OPTIMIZED_LANE_ARG = "optimized"
OPTIMIZED_LANE_FLAG = "--optimized"
OPTIMIZED_INCREMENTAL_LANE_ARG = "optimizedIncremental"
OPTIMIZED_INCREMENTAL_LANE_FLAG = "--optimized-incremental"
OPTIMIZED_LANE_FLAGS = (OPTIMIZED_LANE_FLAG, OPTIMIZED_INCREMENTAL_LANE_FLAG)
OPTIMIZED_LANE_FLAG_ARGS = {
    OPTIMIZED_LANE_FLAG: OPTIMIZED_LANE_ARG,
    OPTIMIZED_INCREMENTAL_LANE_FLAG: OPTIMIZED_INCREMENTAL_LANE_ARG,
}
OPTIMIZED_LANES_EXCLUSIVE_REJECTION = "--optimized and --optimized-incremental are mutually exclusive; choose one lane"
# `package_app.sh` configs the staged build-then-launch helper may forward (the debug lane is the default).
DEBUG_APP_PACKAGE_CONFIGS = ("debug", "debug-optimized", "debug-optimized-incremental")
LAUNCH_EXISTING_OPTIMIZED_REJECTION = (
    "launch-existing does not build; its lane is whatever the bundle was packaged with "
    "(see RepoPromptDebugProvenance.json)."
)


def is_optimized_lane_request(args: Dict[str, Any]) -> bool:
    """True for an optimized-diagnostics lane request. The client sets the key only when true,
    so any other present value is a malformed request rather than a second spelling of debug."""
    if OPTIMIZED_LANE_ARG not in args:
        return False
    if args[OPTIMIZED_LANE_ARG] is not True:
        raise ConductorError(f"request arg '{OPTIMIZED_LANE_ARG}' must be true when present")
    return True


def is_optimized_incremental_lane_request(args: Dict[str, Any]) -> bool:
    """True for an optimized-incremental App lane request; the same set-only-when-true rule."""
    if OPTIMIZED_INCREMENTAL_LANE_ARG not in args:
        return False
    if args[OPTIMIZED_INCREMENTAL_LANE_ARG] is not True:
        raise ConductorError(f"request arg '{OPTIMIZED_INCREMENTAL_LANE_ARG}' must be true when present")
    return True


def debug_package_config_for_request(args: Dict[str, Any]) -> str:
    """The `package_app.sh` debug config a lane-capable request selects; both lane keys is malformed."""
    optimized = is_optimized_lane_request(args)
    incremental = is_optimized_incremental_lane_request(args)
    if optimized and incremental:
        raise ConductorError(OPTIMIZED_LANES_EXCLUSIVE_REJECTION)
    if incremental:
        return "debug-optimized-incremental"
    return "debug-optimized" if optimized else "debug"


def optimized_lane_packaging_command(operation: Any, args: Dict[str, Any]) -> Optional[str]:
    """The user-facing command for an operation that packages a debug app and accepts --optimized
    (`build`, `run`, `app relaunch`); None for every other operation."""
    if operation in {"build", "run"}:
        return str(operation)
    if operation == "app" and args.get("subcommand") == "relaunch":
        return "app relaunch"
    return None


def optimized_lane_timeout_hint(operation: Any, args: Dict[str, Any], effective_timeout: float) -> Optional[str]:
    """Actionable suffix for a timed-out lane job; None for every other job (messages unchanged)."""
    command = optimized_lane_packaging_command(operation, args)
    if command is None:
        return None
    if args.get(OPTIMIZED_INCREMENTAL_LANE_ARG) is True and args.get(OPTIMIZED_LANE_ARG) is not True:
        return (
            f"; optimized-incremental builds compile every module except RepoPromptApp as a whole module "
            f"with no partial results; rerun with a longer limit: "
            f"./conductor {command} --optimized-incremental --timeout <seconds> "
            f"(this run allowed {effective_timeout:.0f}s)"
        )
    if args.get(OPTIMIZED_LANE_ARG) is not True:
        return None
    return (
        f"; optimized-lane builds compile whole modules with no partial results; "
        f"rerun with a longer limit: ./conductor {command} --optimized --timeout <seconds> "
        f"(this run allowed {effective_timeout:.0f}s)"
    )


def operation_display_name(operation: str, args: Dict[str, Any]) -> str:
    if operation == "app" and args.get("subcommand") in {"status", "stop", "launch-existing", "relaunch"}:
        return f"app {args['subcommand']}"
    return operation


def latest_lifecycle_intent(operation: str, args: Dict[str, Any]) -> Optional[str]:
    if operation == "app" and args.get("subcommand") in {"stop", "launch-existing", "relaunch"}:
        return operation_display_name(operation, args)
    return None


def is_launch_capable_job(operation: str, args: Dict[str, Any]) -> bool:
    return (
        operation == "run"
        or (operation == "app" and args.get("subcommand") in {"launch-existing", "relaunch"})
        or (operation == "smoke" and bool(args.get("launch") or args.get("packagedApp")))
    )


def job_ticket_env_eligible(argv: Sequence[str]) -> bool:
    """Whether the child process should receive REPOPROMPT_CONDUCTOR_JOB_TICKET.

    SwiftPM child invocations, including the canonical wrapper, must not
    receive per-job environment values: SwiftPM keys its manifest/build-plan
    caches on the child environment, so a unique per-job value forces a full
    multi-second re-plan. Delegated scripts still receive the ticket for lock
    metadata; canonical_swift.sh excludes it before invoking SwiftPM.
    """
    if not argv:
        return True
    return Path(str(argv[0])).name not in {"swift", "canonical_swift.sh"}


def operation_invalidates_root_build_ticket(operation: str, args: Dict[str, Any]) -> bool:
    if operation in {"test", "test-parallel", "swift-build", "build", "package", "install-debug-cli"}:
        return True
    return operation == "release" and args.get("subcommand") in {
        "artifact",
        "package",
        "local-install",
    }


def operation_requires_global_heavy_slot(operation: str, args: Dict[str, Any]) -> bool:
    if operation in {
        "swift-build", "dsym", "build", "package", "test", "test-parallel", "provider-test", "core-test",
        "install-debug-cli",
    }:
        return True
    if operation in {"sleep", "fake-sleep"} and "build" in set(args.get("lanes") or []):
        return True
    if operation == "release" and args.get("subcommand") in {"artifact", "package", "local-install"}:
        return True
    return False


def operation_requires_global_xctest_slot(operation: str, args: Dict[str, Any]) -> bool:
    return operation in {"test-artifact", "test-parallel"}


def format_duration(seconds: Optional[float]) -> str:
    if seconds is None:
        return "n/a"
    seconds = max(0.0, float(seconds))
    if seconds < 1:
        return f"{seconds * 1000:.0f}ms"
    if seconds < 60:
        return f"{seconds:.1f}s"
    minutes, remainder = divmod(seconds, 60)
    if minutes < 60:
        return f"{int(minutes)}m {remainder:.0f}s"
    hours, minutes = divmod(minutes, 60)
    return f"{int(hours)}h {int(minutes)}m {remainder:.0f}s"


def format_bytes(byte_count: Optional[int]) -> str:
    if byte_count is None:
        return "n/a"
    value = float(max(0, int(byte_count)))
    units = ["B", "KiB", "MiB", "GiB", "TiB"]
    unit = units[0]
    for unit in units:
        if value < 1024 or unit == units[-1]:
            break
        value /= 1024
    if unit == "B":
        return f"{int(value)} B"
    return f"{value:.1f} {unit}"


@dataclasses.dataclass
class Job:
    ticket: str
    request_key: Optional[str]
    fingerprint: str
    operation: str
    args: Dict[str, Any]
    lanes: List[str]
    timeout: Optional[float]
    verbose: bool
    env: Dict[str, str]
    created_at: float
    log_path: Path
    state: str = "queued"
    started_at: Optional[float] = None
    finished_at: Optional[float] = None
    process_started_at: Optional[float] = None
    process_finished_at: Optional[float] = None
    process_pid: Optional[int] = None
    process_pgid: Optional[int] = None
    process_start: Optional[str] = None
    tracked_processes: Dict[int, str] = dataclasses.field(default_factory=dict, repr=False)
    process_group_identity_confirmed: bool = False
    global_heavy_slot_wait_seconds: Optional[float] = None
    global_heavy_slot_path: Optional[str] = None
    global_heavy_slot_holder: Optional[str] = None
    global_xctest_slot_wait_seconds: Optional[float] = None
    global_xctest_slot_path: Optional[str] = None
    global_xctest_slot_holder: Optional[str] = None
    artifact_scope: Optional[str] = None
    artifact_scope_differences: List[str] = dataclasses.field(default_factory=list)
    artifact_scope_message: Optional[str] = None
    test_evidence_scope: Optional[str] = None
    build_phase_seconds: Optional[float] = None
    run_phase_seconds: Optional[float] = None
    exit_code: Optional[int] = None
    error: Optional[str] = None
    result_summary: Optional[str] = None
    cancel_requested: bool = False
    superseded_by_ticket: Optional[str] = None
    superseded_by_operation: Optional[str] = None
    timed_out: bool = False
    measurement_invalid: bool = False
    progress_transport: Optional[str] = None
    xctest_progress_sequence: int = 0
    xctest_started_count: int = 0
    xctest_deadline_phase: Optional[str] = None
    xctest_progress_deadline: Optional[float] = None
    xctest_active_method_budget_seconds: Optional[float] = None
    xctest_active_method_budget_source: Optional[str] = None
    # Step 4: the shared, immutable runtime-ledger snapshot pinned before process
    # start (``None``: not pinned, released, or flat-budget fallback).
    xctest_method_runtimes: Optional[Mapping[Tuple[str, str], float]] = dataclasses.field(
        default=None, repr=False
    )
    # Step 4: system lines added to the tail under the condition whose log write
    # is deferred until the condition is released (budget-clamp diagnostics).
    deferred_log_lines: Optional[List[str]] = dataclasses.field(default=None, repr=False, compare=False)
    xctest_current_test: Optional[str] = None
    xctest_previous_test: Optional[str] = None
    xctest_last_progress_test: Optional[str] = None
    xctest_last_progress_action: Optional[str] = None
    xctest_last_progress_observed_at: Optional[float] = None
    xctest_watchdog_triggered: bool = False
    xctest_process_finished: bool = False
    # OD16: the bounded reason the output reader could not classify XCTest progress.
    xctest_output_failure: Optional[str] = None
    diagnostics: List[Dict[str, Any]] = dataclasses.field(default_factory=list)
    diagnostic_paths: List[Path] = dataclasses.field(default_factory=list, repr=False)
    output_summary: Optional[Dict[str, Any]] = None
    # Summary single-flight (Step 3): none | running | complete | failed. The
    # claimant computes outside ``condition``; joiners wait on ``summary_event``.
    summary_state: str = "none"
    summary_event: Optional[threading.Event] = dataclasses.field(default=None, repr=False, compare=False)
    # Retention pin (Step 3): summary work and its status/wait consumers hold one
    # each until their payload is built; retention defers a pinned job and
    # reruns when the last pin is released.
    summary_pins: int = dataclasses.field(default=0, repr=False, compare=False)
    retention_deferred: bool = dataclasses.field(default=False, repr=False, compare=False)
    # CR-segmented, ANSI-stripped entries: at most 30 entries / 64 KiB, 4 KiB each.
    tail: Any = dataclasses.field(
        default_factory=lambda: CONDUCTOR_OUTPUT.OutputTail(max_entries=LOG_TAIL_LINES)
    )
    # Step 2 passive timing. ``telemetry`` is set once at creation and never
    # replaced; its private lock is never taken while holding ``condition``.
    telemetry: Optional[Any] = dataclasses.field(default=None, repr=False, compare=False)
    telemetry_dispatch_ns: Optional[int] = None
    telemetry_lane_released: bool = False
    telemetry_persist_claimed: bool = False
    telemetry_persisted: bool = False
    telemetry_persist_error: Optional[str] = None
    phase_metrics: Optional[Dict[str, Any]] = dataclasses.field(default=None, repr=False)
    # (wall ns, thread CPU ns) of the published summary, set with ``output_summary``.
    output_summary_timing: Optional[Tuple[int, int]] = dataclasses.field(default=None, repr=False)

    def to_payload(self, include_tail: bool = True, include_summary: bool = True) -> Dict[str, Any]:
        queue_wait_seconds = None
        if self.started_at is not None:
            queue_wait_seconds = max(0.0, self.started_at - self.created_at)
        execution_seconds = None
        if self.process_started_at is not None and self.process_finished_at is not None:
            execution_seconds = max(0.0, self.process_finished_at - self.process_started_at)
        payload: Dict[str, Any] = {
            "ticket": self.ticket,
            "requestKey": self.request_key,
            "fingerprint": self.fingerprint,
            "operation": self.operation,
            "operationLabel": operation_display_name(self.operation, self.args),
            "args": self.args,
            "lanes": self.lanes,
            "state": self.state,
            "createdAt": self.created_at,
            "createdAtISO": iso_timestamp(self.created_at),
            "startedAt": self.started_at,
            "startedAtISO": iso_timestamp(self.started_at),
            "finishedAt": self.finished_at,
            "finishedAtISO": iso_timestamp(self.finished_at),
            "queuedAt": self.created_at,
            "processStartedAt": self.process_started_at,
            "processStartedAtISO": iso_timestamp(self.process_started_at),
            "processFinishedAt": self.process_finished_at,
            "processFinishedAtISO": iso_timestamp(self.process_finished_at),
            "queueWaitSeconds": queue_wait_seconds,
            "executionSeconds": execution_seconds,
            "logPath": str(self.log_path),
            "processPID": self.process_pid,
            "processPGID": self.process_pgid,
            "globalHeavySlotWaitSeconds": self.global_heavy_slot_wait_seconds,
            "globalHeavySlotPath": self.global_heavy_slot_path,
            "globalHeavySlotHolder": self.global_heavy_slot_holder,
            "xctestSlotWaitSeconds": self.global_xctest_slot_wait_seconds,
            "xctestSlotPath": self.global_xctest_slot_path,
            "xctestSlotHolder": self.global_xctest_slot_holder,
            "artifactScope": self.artifact_scope,
            "artifactScopeDifferences": list(self.artifact_scope_differences),
            "artifactScopeMessage": self.artifact_scope_message,
            "testEvidenceScope": self.test_evidence_scope,
            "buildPhaseSeconds": self.build_phase_seconds,
            "runPhaseSeconds": self.run_phase_seconds,
            "exitCode": self.exit_code,
            "error": self.error,
            "resultSummary": self.result_summary,
            "cancelRequested": self.cancel_requested,
            "supersededByTicket": self.superseded_by_ticket,
            "supersededByOperation": self.superseded_by_operation,
            "timedOut": self.timed_out,
            "measurementInvalid": self.measurement_invalid,
            "progressTransport": self.progress_transport,
            "progressSequence": self.xctest_progress_sequence,
            "lastProgressTest": self.xctest_last_progress_test,
            "lastProgressAction": self.xctest_last_progress_action,
            "lastProgressObservedAt": self.xctest_last_progress_observed_at,
            "diagnosticPaths": [str(path) for path in self.diagnostic_paths],
        }
        if self.diagnostics:
            payload["diagnostics"] = list(self.diagnostics)
        if include_summary and self.output_summary is not None:
            payload["outputSummary"] = self.output_summary
        payload["conductorDigest"] = CONDUCTOR_DIGEST
        if include_summary:
            payload["phaseMetrics"] = self.phase_metrics_payload()
            if self.telemetry_persist_error is not None:
                payload["phaseMetricsPersistError"] = self.telemetry_persist_error
        if include_tail:
            payload["logTail"] = list(self.tail)
        return payload

    def phase_metrics_payload(self) -> Dict[str, Any]:
        if self.phase_metrics is not None:
            return self.phase_metrics
        if self.telemetry is None:
            return {"schema": 1, "status": "disabled"}
        if self.telemetry_persisted:
            # Completion ended without a payload (worker not started or finalize failed).
            return {"schema": 1, "status": "failed", "telemetryError": self.telemetry_persist_error}
        return {"schema": 1, "status": "pending" if self.state in TERMINAL_STATES else "running"}


class OperationRegistry:
    """Daemon-side operation registration and argv construction."""

    SIGNING_ENV_KEYS = [
        "SIGN_IDENTITY",
        "SIGNING_TEAM_ID",
        "ALLOW_ADHOC_SIGNING",
        "RELEASE_ALLOW_ADHOC_SIGNING",
        "CONFIRM_LOCAL_PRODUCTION_INSTALL",
        "LOCAL_CERTIFICATE_DAYS",
        "LOCAL_PRODUCTION_INSTALL_DIR",
        "LOCAL_SELF_SIGNED_RELEASE",
        "PREFER_STABLE_DEBUG_SIGNING",
        "DEBUG_SECURE_STORAGE_BACKEND",
        "REPOPROMPT_PROVISIONING_PROFILE",
        "APP_ENTITLEMENTS_TEMPLATE",
        "BUNDLE_ID",
    ]
    DEBUG_ENV_KEYS = [
        "REPOPROMPT_DEBUG_APP_ROOT",
        "REPOPROMPT_DEBUG_APP_BUNDLE",
        "REPOPROMPT_DEBUG_CLI_INSTALL_PATH",
        # Debug package cache escape (on|off); package_app.sh validates it before any build or mutation.
        "REPOPROMPT_DEBUG_PACKAGE_CACHE",
    ]
    BUILD_ENV_KEYS = [
        "PATH",
        "DEVELOPER_DIR",
        "TOOLCHAINS",
        "SDKROOT",
        "SWIFT_EXEC",
        "CC",
        "CXX",
        "TMPDIR",
        "HOME",
        "USER",
        "LOGNAME",
        "SHELL",
        "LANG",
        "LC_ALL",
        "LC_CTYPE",
    ]
    STYLE_ENV_KEYS = [
        "GITHUB_ACTIONS",
        "CI",
        "HOMEBREW_NO_AUTO_UPDATE",
        "HOMEBREW_NO_INSTALL_CLEANUP",
        "HOMEBREW_CACHE",
    ]
    TEST_ENV_KEYS = [
        "RPCE_ALLOW_ZERO_TESTS",
        "RPCE_ENABLE_BENCHMARK_TESTS",
        "RPCE_RUN_CODEMAP_E2E",
        "RPCE_RUN_SCALE_TESTS",
        "REPOPROMPT_DEV_XCTEST_DEADLINES",
        "REPOPROMPT_DEV_XCTEST_ACTIVE_FLOOR_SECONDS",
    ]
    CONDUCTOR_ENV_KEYS = [
        "REPOPROMPT_DEV_HEAVY_SLOTS",
        "REPOPROMPT_DEV_XCTEST_SLOTS",
    ]
    # Step 10: RPCE_DEBUG_DSYM is validated in the client and normalized (unset -> "off") in every
    # request snapshot. RPCE_INDEX_STORE is forwarded verbatim; canonical_swift.sh validates it.
    DEBUG_SYMBOL_ENV_KEYS = [DEBUG_DSYM_POLICY_ENV_KEY, "RPCE_INDEX_STORE"]
    TELEMETRY_ENV_KEYS = [
        "REPOPROMPT_ENABLE_SENTRY",
        "REPOPROMPT_SENTRY_DSN",
        "REPOPROMPT_UPLOAD_SENTRY_SYMBOLS",
        "REPOPROMPT_SENTRY_AUTH_TOKEN_FILE",
        "REPOPROMPT_SENTRY_ORG",
        "REPOPROMPT_SENTRY_PROJECT",
        "REPOPROMPT_SENTRY_UPLOAD_WAIT",
        "SENTRY_URL",
    ]
    PASSTHROUGH_ENV_KEYS = sorted(
        set(
            SIGNING_ENV_KEYS
            + DEBUG_ENV_KEYS
            + BUILD_ENV_KEYS
            + STYLE_ENV_KEYS
            + TEST_ENV_KEYS
            + CONDUCTOR_ENV_KEYS
            + DEBUG_SYMBOL_ENV_KEYS
            + TELEMETRY_ENV_KEYS
        )
    )

    def __init__(self, repo_root: Path, jobs_dir: Optional[Path] = None) -> None:
        self.repo_root = repo_root
        self.jobs_dir = jobs_dir or compute_paths(repo_root).jobs_dir
        self.script_path = conductor_entry_script()

    @classmethod
    def client_env_snapshot(cls) -> Dict[str, str]:
        snapshot: Dict[str, str] = {}
        for key in cls.PASSTHROUGH_ENV_KEYS:
            value = os.environ.get(key)
            if value is not None:
                snapshot[key] = value
        normalize_debug_dsym_policy(snapshot)  # Step 10: reject an invalid policy before any request
        return snapshot

    @classmethod
    def _request_env_snapshot(cls, request: Dict[str, Any]) -> Dict[str, str]:
        raw = request.get("env") or {}
        if not isinstance(raw, dict):
            raise ConductorError("request env must be an object")
        snapshot: Dict[str, str] = {}
        allowed = set(cls.PASSTHROUGH_ENV_KEYS)
        for key, value in raw.items():
            if key not in allowed:
                continue
            if not isinstance(value, str):
                raise ConductorError(f"request env value for {key} must be a string")
            snapshot[key] = value
        # Step 10: unset and "off" are one identity (fingerprint, job env, child env).
        snapshot[DEBUG_DSYM_POLICY_ENV_KEY] = normalize_debug_dsym_policy(snapshot)
        return snapshot

    def prepare(self, request: Dict[str, Any]) -> Tuple[List[str], List[str], Path, Dict[str, str], Optional[float]]:
        operation = request.get("operation")
        args = request.get("args") or {}
        timeout = request.get("timeout")
        verbose = bool(request.get("verbose"))
        if timeout is not None and float(timeout) < 0:
            raise ConductorError("timeout must be non-negative")

        if operation in {"sleep", "fake-sleep"}:
            return self._prepare_sleep(operation, args, timeout, request)
        if operation not in IMPLEMENTED_OPERATIONS:
            raise ConductorError(f"operation '{operation}' is not implemented")

        if operation in {"test", "test-artifact", "provider-test", "core-test"}:
            self._validate_xctest_stall_options(args)
        self._validate_benchmark_driver_diagnostics(operation, args)

        env = self.request_environment(verbose, request)
        effective_timeout = self._default_timeout(operation, args)
        if timeout is not None:
            effective_timeout = float(timeout)

        script = lambda name: str(self.repo_root / "Scripts" / name)
        canonical_swift = script("canonical_swift.sh")
        lanes: List[str] = []
        cwd = self.repo_root

        if operation == "doctor":
            return [script("doctor.sh")], lanes, cwd, env, effective_timeout
        if operation == "guardrails":
            return [script("guardrails.sh")], lanes, cwd, env, effective_timeout
        if operation == "format":
            return [script("swift_style.sh"), "format"], ["style", "build"], cwd, env, effective_timeout
        if operation == "format-check":
            return [script("swift_style.sh"), "format-check"], ["style"], cwd, env, effective_timeout
        if operation == "lint":
            return [script("swift_style.sh"), "lint"], ["style"], cwd, env, effective_timeout
        if operation == "format-tools-status":
            return [script("install_format_tools.sh"), "status"], lanes, cwd, env, effective_timeout
        if operation == "check-format-tools":
            return [script("install_format_tools.sh"), "check"], ["style"], cwd, env, effective_timeout
        if operation == "install-format-tools":
            return [script("install_format_tools.sh"), "install"], ["style"], cwd, env, effective_timeout
        if operation == "swift-build":
            product = args.get("product")
            lanes = ["build"]
            if product == "all":
                return self._internal_argv("swift_build_all", {}), lanes, cwd, env, effective_timeout
            return [canonical_swift, "build", "--product", str(product)], lanes, cwd, env, effective_timeout
        if operation == "dsym":
            # Never builds and writes only adjacent dSYMs, outside every artifact
            # fingerprint closure: the root build ticket stays valid.
            product = args.get("product") or "all"
            if product not in DEBUG_DSYM_PRODUCTS:
                raise ConductorError(f"dsym --product must be one of {', '.join(DEBUG_DSYM_PRODUCTS)}")
            argv = [sys.executable, "-I", "-B", script("debug_dsym.py"), "regenerate", "--product", str(product),
                    "--package-root", str(self.repo_root)]
            return argv, ["build"], cwd, env, effective_timeout
        if operation == "build":
            argv = [script("package_app.sh"), debug_package_config_for_request(args)]
            if args.get("fastPackage"):
                argv.append("fast")
            return argv, ["build", "debugArtifact"], cwd, env, effective_timeout
        if operation == "package":
            config = str(args.get("config"))
            lanes = ["build", "debugArtifact"] + (["release"] if config == "release" else [])
            return [script("package_app.sh"), config], lanes, cwd, env, effective_timeout
        if operation == "test":
            argv = [canonical_swift, "test"]
            if args.get("testProduct"):
                argv.extend(["--test-product", str(args["testProduct"])])
            if args.get("list"):
                argv.append("list")
            elif args.get("filter"):
                argv.extend(["--filter", str(args["filter"])])
            if args.get(BENCHMARK_DRIVER_DIAGNOSTICS_ARG) is True:
                argv.extend(BENCHMARK_DRIVER_DIAGNOSTIC_SWIFT_ARGS)
            return argv, ["build"], cwd, env, effective_timeout
        if operation == "test-artifact":
            if not args.get("filter"):
                raise ConductorError("test-artifact requires --filter")
            # Step 7: cheap admission only. The one authoritative evaluation runs in
            # `_run_job` after lane and XCTest-slot admission; the argv has no
            # hash-derived input.
            admit_test_artifact(self.repo_root, self.jobs_dir)
            return [canonical_swift, "test", "--skip-build", "--filter", str(args["filter"])], ["build"], cwd, env, effective_timeout
        if operation == "test-parallel":
            if not args.get("parallelRunId"):
                run_id = str(uuid.uuid4())
                args["parallelRunId"] = run_id
                args["parallelWorkdir"] = str(self.jobs_dir / f"parallel-xctest-{run_id}")
                args["parallelTestList"] = str(
                    self.jobs_dir / f"parallel-xctest-{run_id}-test-list.txt"
                )
                args["parallelCandidate"] = str(
                    self.jobs_dir / f"parallel-xctest-{run_id}-candidate.json"
                )
            return (
                self._internal_argv("parallel_root_test", dict(args)),
                ["build"],
                cwd,
                env,
                effective_timeout,
            )
        if operation in {"provider-test", "core-test"}:
            argv = [canonical_swift, "test"]
            if args.get("testProduct"):
                argv.extend(["--test-product", str(args["testProduct"])])
            if args.get("list"):
                argv.append("list")
            elif args.get("filter"):
                argv.extend(["--filter", str(args["filter"])])
            package_name = "RepoPromptCore" if operation == "core-test" else "RepoPromptAgentProviders"
            return argv, ["build"], self.repo_root / "Packages" / package_name, env, effective_timeout
        if operation == "install-debug-cli":
            return [script("install_debug_cli.sh"), "install", "--build"], ["build", "debugArtifact"], cwd, env, effective_timeout
        if operation == "debug-cli-status":
            return [script("install_debug_cli.sh"), "status"], lanes, cwd, env, effective_timeout
        if operation == "run":
            # Validate at dispatch too, independently of default-timeout calculation.
            debug_package_config_for_request(args)
            return self._internal_argv("debug_app_build_then_launch", dict(args)), ["liveApp"], cwd, env, effective_timeout
        if operation == "app":
            subcommand = args.get("subcommand")
            if subcommand == "stop":
                internal_args = {"guardDelayedLaunch": bool(args.get("guardDelayedLaunch"))}
                return self._internal_argv("app_stop", internal_args), ["liveApp"], cwd, env, effective_timeout
            if subcommand == "status":
                return self._internal_argv("app_status", {}), lanes, cwd, env, effective_timeout
            if subcommand == "launch-existing":
                if OPTIMIZED_LANE_ARG in args or OPTIMIZED_INCREMENTAL_LANE_ARG in args:
                    raise ConductorError(LAUNCH_EXISTING_OPTIMIZED_REJECTION)
                return self._internal_argv("app_launch_existing", dict(args)), ["liveApp"], cwd, env, effective_timeout
            if subcommand == "relaunch":
                debug_package_config_for_request(args)  # independent of the timeout path, as for run
                return self._internal_argv("debug_app_build_then_launch", dict(args)), ["liveApp"], cwd, env, effective_timeout
        if operation == "smoke":
            lanes = ["debugArtifact", "liveApp"]
            if args.get("launch"):
                lanes = ["liveApp"]
            elif args.get("packagedApp"):
                lanes = ["liveApp"]
            smoke_args = dict(args)
            smoke_args["operationTimeout"] = effective_timeout
            return self._internal_argv("smoke", smoke_args), lanes, cwd, env, effective_timeout
        if operation == "diagnostics":
            subcommand = args.get("subcommand")
            if subcommand == "agent-mode-on":
                return self._internal_argv("diagnostics_agent_mode_on", dict(args)), ["debugArtifact", "liveApp"], cwd, env, effective_timeout
            if subcommand == "build-cache":
                return self._internal_argv("diagnostics_build_cache", dict(args)), lanes, cwd, env, effective_timeout
        if operation == "release":
            subcommand = args.get("subcommand")
            if subcommand == "package":
                return [script("package_app.sh"), "release"], ["build", "debugArtifact", "release"], cwd, env, effective_timeout
            if subcommand == "local-install":
                return [script("install_local_production.sh")], ["build", "debugArtifact", "release"], cwd, env, effective_timeout
            if subcommand == "artifact":
                return [script("release.sh"), "artifact"], ["build", "debugArtifact", "release"], cwd, env, effective_timeout
            if subcommand == "preflight":
                release_script = self.repo_root / "Scripts" / "release.sh"
                if release_script.exists():
                    return [str(release_script), "preflight"], ["release"], cwd, env, effective_timeout
                return self._internal_argv("release_preflight_missing", {}), ["release"], cwd, env, effective_timeout

        raise ConductorError(f"invalid arguments for operation '{operation}'")

    @staticmethod
    def _validate_benchmark_driver_diagnostics(operation: Any, args: Dict[str, Any]) -> None:
        if BENCHMARK_DRIVER_DIAGNOSTICS_ARG not in args:
            return
        if args.get(BENCHMARK_DRIVER_DIAGNOSTICS_ARG) is not True:
            raise ConductorError("benchmarkDriverDiagnostics must be true when present")
        if operation != "test":
            raise ConductorError("--benchmark-driver-diagnostics is only supported for the root debug test operation")
        if args.get("list"):
            raise ConductorError("--benchmark-driver-diagnostics cannot be combined with --list")
        if args.get("testProduct"):
            raise ConductorError("--benchmark-driver-diagnostics cannot be combined with --test-product")

    @staticmethod
    def _validate_xctest_stall_options(args: Dict[str, Any]) -> None:
        list_mode = bool(args.get("list"))
        raw_seconds = args.get("xctestStallSeconds")
        wake_probe = bool(args.get("xctestStallWakeProbe"))
        if list_mode and args.get("filter"):
            raise ConductorError("test list mode cannot be combined with a filter")
        if list_mode and (raw_seconds is not None or wake_probe):
            raise ConductorError("test list mode cannot be combined with XCTest stall diagnostics")
        if list_mode and args.get("testProduct"):
            raise ConductorError("test list mode cannot be combined with --test-product")
        if args.get("xctestDeadlines") is False and (raw_seconds is not None or wake_probe):
            raise ConductorError("disabled XCTest deadlines cannot be combined with XCTest stall diagnostics")
        if raw_seconds is None:
            if wake_probe:
                raise ConductorError("--xctest-stall-wake-probe requires --xctest-stall-seconds")
            return
        try:
            seconds = float(raw_seconds)
        except (TypeError, ValueError):
            raise ConductorError("--xctest-stall-seconds must be a positive number")
        if not math.isfinite(seconds) or seconds <= 0:
            raise ConductorError("--xctest-stall-seconds must be greater than zero")

    def _prepare_sleep(self, operation: Any, args: Dict[str, Any], timeout: Optional[Any], request: Dict[str, Any]) -> Tuple[List[str], List[str], Path, Dict[str, str], Optional[float]]:
        try:
            seconds = float(args.get("seconds"))
        except (TypeError, ValueError):
            raise ConductorError("sleep operation requires a numeric seconds value")
        if seconds < 0:
            raise ConductorError("sleep seconds must be non-negative")
        lanes = list(args.get("lanes") or [])
        invalid_lanes = [lane for lane in lanes if lane not in LANE_NAMES]
        if invalid_lanes:
            raise ConductorError(f"unknown lane(s): {', '.join(invalid_lanes)}")
        message = str(args.get("message") or "conductor sleep")
        exit_code = int(args.get("exitCode") or 0)
        child_code = (
            "import os,sys,time\n"
            "seconds=float(sys.argv[1]); message=sys.argv[2]; exit_code=int(sys.argv[3])\n"
            "print(f'{message}: start seconds={seconds} pid={os.getpid()}', flush=True)\n"
            "deadline=time.time()+seconds\n"
            "while True:\n"
            "    remaining=deadline-time.time()\n"
            "    if remaining <= 0: break\n"
            "    time.sleep(min(0.2, remaining))\n"
            "print(f'{message}: done exit_code={exit_code}', flush=True)\n"
            "sys.exit(exit_code)\n"
        )
        argv = [sys.executable, "-u", "-c", child_code, str(seconds), message, str(exit_code)]
        env = self.request_environment(bool(request.get("verbose")), request)
        effective_timeout = float(timeout) if timeout is not None else max(30.0, seconds + 30.0)
        return argv, lanes, self.repo_root, env, effective_timeout

    def _base_env(self, verbose: bool, request: Dict[str, Any]) -> Dict[str, str]:
        env = self._request_env_snapshot(request)
        if verbose:
            env["VERBOSE"] = "1"
        return env

    def request_environment(self, verbose: bool, request: Dict[str, Any]) -> Dict[str, str]:
        return self._base_env(verbose, request)

    def _internal_argv(self, kind: str, args: Dict[str, Any]) -> List[str]:
        payload = {"kind": kind, "args": args, "repoRoot": str(self.repo_root)}
        return [sys.executable, "-u", str(self.script_path), "__operation_runner", json_dumps(payload)]

    def _default_timeout(self, operation: Any, args: Dict[str, Any]) -> float:
        if operation in {"doctor", "guardrails", "debug-cli-status", "format-tools-status", "check-format-tools"}:
            return SHORT_TIMEOUT_SECONDS
        if operation == "app" and args.get("subcommand") in {"status", "stop"}:
            return SHORT_TIMEOUT_SECONDS
        if operation in {"package", "release"} and (args.get("config") == "release" or args.get("subcommand") in {"artifact", "package", "local-install"}):
            return RELEASE_TIMEOUT_SECONDS
        if operation == "smoke" and args.get("agentRun"):
            return MEDIUM_TIMEOUT_SECONDS
        if operation == "diagnostics":
            return SHORT_TIMEOUT_SECONDS
        if operation == "test-artifact":
            return ARTIFACT_TEST_TIMEOUT_SECONDS
        if operation == "test-parallel":
            return MEDIUM_TIMEOUT_SECONDS
        if operation in {"test", "provider-test", "core-test"} and args.get("filter"):
            return FILTERED_TEST_TIMEOUT_SECONDS
        if (
            optimized_lane_packaging_command(operation, args) is not None
            and debug_package_config_for_request(args) != "debug"
        ):
            return max(MEDIUM_TIMEOUT_SECONDS, OPTIMIZED_LANE_TIMEOUT_FLOOR_SECONDS)
        return MEDIUM_TIMEOUT_SECONDS

    def fingerprint(self, request: Dict[str, Any]) -> str:
        operation = request.get("operation")
        snapshot = self._request_env_snapshot(request)
        material = {
            "operation": operation,
            "args": request.get("args") or {},
            "timeout": request.get("timeout"),
            "verbose": bool(request.get("verbose")),
            "env": {key: snapshot.get(key) for key in self.PASSTHROUGH_ENV_KEYS},
        }
        return hashlib.sha256(json_dumps(material).encode("utf-8")).hexdigest()


class DaemonState:
    def __init__(self, paths: Paths) -> None:
        self.paths = paths
        self.registry = OperationRegistry(paths.repo_root, paths.jobs_dir)
        self.lock = threading.RLock()
        self.condition = threading.Condition(self.lock)
        self.jobs: Dict[str, Job] = {}
        self.queue: List[str] = []
        self.request_keys: Dict[str, str] = {}
        self.active_lanes: Dict[str, str] = {}
        self.shutdown_requested = False
        self.server: Optional[socketserver.BaseServer] = None
        self.runtime_ledger_cache = RuntimeLedgerCache(_test_ledger_path(paths.repo_root))
        # Kill switch read once at daemon start (``RPCE_CONDUCTOR_TIMING=off``).
        self.timing_setting: Optional[str] = os.environ.get(TIMING_ENV_KEY)
        if self.timing_setting is not None:
            self.timing_setting = self.timing_setting[:64]
        self.timing_enabled = PIPELINE_METRICS is not None and PIPELINE_METRICS.timing_enabled(os.environ)
        self.timing_history: Optional[Any] = None
        self._telemetry_completions = 0  # background completions of never-dispatched jobs
        # Step 5 retention: ``_retention_pass_locked`` decides evictions in memory;
        # one on-demand maintenance worker does every scan, stat and unlink outside
        # ``condition``. Lock order is ``condition`` -> ``_maintenance_cv``; the
        # worker never takes ``condition`` while holding ``_maintenance_cv``.
        self._maintenance_cv = threading.Condition(threading.Lock())
        self._maintenance_items: List[Tuple[str, Tuple[Path, ...]]] = []
        self._maintenance_retry: Dict[Path, str] = {}  # failed exact unlinks: path -> ticket
        self._maintenance_thread: Optional[threading.Thread] = None
        self._maintenance_busy = False
        self._orphan_sweep_requested = False
        self._last_orphan_sweep: Optional[float] = None  # monotonic start of the last sweep
        self._maintenance_error: Optional[str] = None
        if self.timing_enabled:
            try:
                self.timing_history = PIPELINE_METRICS.RotatingJsonl(timing_history_path(paths))
            except Exception:
                self.timing_history = None

    # -- Step 2 passive timing ------------------------------------------------
    # Lock order: recorder methods are only called without ``self.condition``
    # held; the recorder never calls back into the daemon. Every hook is
    # fail-neutral: telemetry errors never change job state or output.

    def attach_job_telemetry(self, operation: str, accepted_ns: Optional[int] = None) -> Optional[Any]:
        """Create a job recorder (or ``None`` when timing is off) and record acceptance."""
        if not self.timing_enabled:
            return None
        try:
            accepted = time.monotonic_ns() if accepted_ns is None else accepted_ns
            recorder = PIPELINE_METRICS.PipelineRecorder(
                origin_ns=accepted,
                process="daemon",
                wall_anchor=(time.time_ns(), time.monotonic_ns()),
                not_applicable_intervals=() if operation == "test" else ("sourceSnapshot",),
            )
            recorder.record_boundary(PIPELINE_METRICS.REQUEST_ACCEPTED, accepted)
            return recorder
        except Exception:
            return None

    @staticmethod
    def _telemetry_boundary(
        recorder: Optional[Any],
        name: str,
        at_ns: Optional[int] = None,
        metadata: Optional[Dict[str, Any]] = None,
    ) -> None:
        if recorder is None:
            return
        try:
            recorder.record_boundary(name, time.monotonic_ns() if at_ns is None else at_ns, metadata)
        except Exception:
            pass

    @staticmethod
    def _telemetry_operation(
        recorder: Optional[Any],
        name: str,
        duration_ns: Optional[int],
        counters: Optional[Dict[str, int]] = None,
        origin: str = "",
        quality: Optional[str] = None,
    ) -> None:
        if recorder is None:
            return
        try:
            if quality is None:
                recorder.record_operation(name, duration_ns, counters, origin)
            else:
                recorder.record_operation(name, duration_ns, counters, origin, quality=quality)
        except Exception:
            pass

    @staticmethod
    def _telemetry_sink(recorder: Optional[Any], origin: str) -> Optional[Any]:
        if recorder is None:
            return None
        try:
            return recorder.operation_sink(origin)
        except Exception:
            return None

    def _record_client_metrics(self, recorder: Optional[Any], raw: Any) -> None:
        """Advisory client-reported durations; bounded and never part of request identity."""
        if recorder is None or not isinstance(raw, list):
            return
        for item in raw[:CLIENT_METRICS_MAX_ITEMS]:
            if not isinstance(item, dict):
                continue
            name = item.get("name")
            duration = item.get("durationNs")
            counters = item.get("counters")
            if not isinstance(name, str) or isinstance(duration, bool) or not isinstance(duration, int):
                continue
            clean_counters = None
            if isinstance(counters, dict):
                clean_counters = {
                    str(key)[:64]: value
                    for key, value in list(counters.items())[:8]
                    if isinstance(value, int) and not isinstance(value, bool)
                }
            self._telemetry_operation(
                recorder,
                name[:64],
                duration,
                clean_counters,
                "client",
                quality=PIPELINE_METRICS.REPORTED_DURATION,
            )

    def complete_job_telemetry(
        self,
        job: Job,
        operations: Sequence[Tuple[str, Optional[int], Optional[Dict[str, int]], str]] = (),
    ) -> Optional[Dict[str, Any]]:
        """Finalize, publish and persist ``job``'s timing once; return the ``phaseMetrics`` payload.

        Called only by the thread that owns the job's terminal transition (the
        job thread after lane release, or the background completion of a job
        that was never dispatched), never by a client request. ``phaseMetrics``
        is published before persistence, and the job result never waits for
        either: client reads see ``pending`` until this publishes. Persistence
        runs outside every lock; only the first caller persists. Both callers
        hold a retention pin across this call (Step 5), so persistence never
        recreates a pruned timing sidecar.
        """
        recorder = job.telemetry
        if recorder is None:
            return None
        with self.condition:
            summary_timing = job.output_summary_timing
        if summary_timing is not None:
            # The published summary's cost, whichever thread produced it.
            operations = [("output_summary", summary_timing[0], {"threadCpuNs": summary_timing[1]}, "daemon.summary"), *operations]
        try:
            for name, duration_ns, counters, origin in operations:
                self._telemetry_operation(recorder, name, duration_ns, counters, origin)
            payload = recorder.finalize()
        except Exception as exc:
            with self.condition:
                if not job.telemetry_persist_claimed:
                    job.telemetry_persist_claimed = True
                    job.telemetry_persist_error = f"finalize: {type(exc).__name__}: {exc}"[:256]
                    job.telemetry_persisted = True
                    self.condition.notify_all()
            return None
        with self.condition:
            claim = not job.telemetry_persist_claimed
            job.telemetry_persist_claimed = True
            if job.phase_metrics is None:
                job.phase_metrics = payload
            kind = job.operation
            exit_code = job.exit_code
            finished_at = job.finished_at
            self.condition.notify_all()
        if claim:
            error = self._persist_job_telemetry(job.ticket, recorder, payload, kind, exit_code, finished_at)
            with self.condition:
                job.telemetry_persist_error = error
                job.telemetry_persisted = True
                self.condition.notify_all()
        return payload

    def _complete_undispatched_telemetry_locked(self, job: Job) -> None:
        """A job made terminal before dispatch: complete its timing off the scheduler lock.

        Intervals it never reached stay unavailable; nothing waits for this.
        The worker pins the job against retention until it has persisted (Step 5),
        so a late timing write can never recreate a pruned sidecar.
        """
        if job.telemetry is None or job.telemetry_dispatch_ns is not None or job.telemetry_persist_claimed:
            return
        self._telemetry_completions += 1
        self._pin_job_locked(job)

        def complete() -> None:
            try:
                self.complete_job_telemetry(job)
            finally:
                with self.condition:
                    self._telemetry_completions -= 1
                    self.condition.notify_all()
                    self._unpin_job_locked(job)

        try:
            threading.Thread(target=complete, name=f"timing-{job.ticket}", daemon=True).start()
        except Exception as exc:  # noqa: BLE001 - optional timing never changes the lifecycle
            # No worker will run: undo the accounting and record a terminal error
            # without touching the recorder (its lock is never taken under ``condition``).
            self._telemetry_completions -= 1
            job.telemetry_persist_claimed = True
            job.telemetry_persist_error = f"timing worker not started: {type(exc).__name__}: {exc}"[:256]
            job.telemetry_persisted = True
            self.condition.notify_all()
            self._unpin_job_locked(job)

    def _await_job_telemetry(self, timeout: float, job: Optional[Job] = None) -> bool:
        """Private drain for tests, qualification and daemon exit; never on a client path.

        Waits until ``job`` (or every terminal or persisting job) has persisted
        its timing; returns ``False`` when ``timeout`` expires first.
        """
        deadline = time.monotonic() + timeout
        with self.condition:
            while True:
                if job is not None:
                    pending = job.telemetry is not None and not job.telemetry_persisted
                else:
                    # Jobs some thread will still persist: claimed, queued for
                    # background completion, or dispatched and already terminal.
                    pending = self._telemetry_completions > 0 or any(
                        item.telemetry is not None
                        and not item.telemetry_persisted
                        and (
                            item.telemetry_persist_claimed
                            or (item.telemetry_dispatch_ns is not None and item.state in TERMINAL_STATES)
                        )
                        for item in self.jobs.values()
                    )
                if not pending:
                    return True
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    return False
                self.condition.wait(min(remaining, 0.1))

    def _persist_job_telemetry(
        self,
        ticket: str,
        recorder: Any,
        payload: Dict[str, Any],
        kind: str,
        exit_code: Optional[int],
        finished_at: Optional[float],
    ) -> Optional[str]:
        try:
            jobs_dir = self.paths.jobs_dir
            PIPELINE_METRICS.write_events_jsonl(jobs_dir / f"{ticket}.timing-events.jsonl", recorder.events())
            runner = read_runner_timings(jobs_dir / f"{ticket}.runner-timings.json")
            PIPELINE_METRICS.atomic_write_json(
                jobs_dir / f"{ticket}.timings.json",
                {
                    "schema": 1,
                    "ticket": ticket,
                    "kind": kind,
                    "conductorDigest": CONDUCTOR_DIGEST,
                    "phaseMetrics": payload,
                    "runner": runner,
                },
            )
            if self.timing_history is not None:
                row = PIPELINE_METRICS.history_row(
                    payload,
                    ticket=ticket,
                    kind=kind,
                    finished_wall_ns=int(finished_at * 1_000_000_000) if finished_at is not None else None,
                    conductor_digest=CONDUCTOR_DIGEST,
                    exit_code=exit_code,
                )
                row["runnerConductorDigest"] = runner.get("conductorDigest") if isinstance(runner, dict) else None
                self.timing_history.append(row)
        except Exception as exc:
            return f"{type(exc).__name__}: {exc}"[:256]
        return None

    def _global_heavy_slot_paths(self, env: Optional[Dict[str, str]] = None) -> List[Path]:
        return global_heavy_slot_paths(env)

    def _global_xctest_slot_paths(self, env: Optional[Dict[str, str]] = None) -> List[Path]:
        return global_xctest_slot_paths(env)

    def status_payload(self) -> Dict[str, Any]:
        with self.lock:
            active_by_lane = {
                lane: self._job_payload_locked(self.jobs[ticket], include_tail=False, include_summary=False)
                for lane, ticket in sorted(self.active_lanes.items())
                if ticket in self.jobs
            }
            running_jobs = [self._job_payload_locked(job, include_tail=False, include_summary=False) for job in self.jobs.values() if job.state == "running"]
            queued_jobs = [self._job_payload_locked(self.jobs[ticket], include_tail=False, include_summary=False) for ticket in self.queue if ticket in self.jobs]
            terminal_count = sum(1 for job in self.jobs.values() if job.state in TERMINAL_STATES)
            return {
                "protocolVersion": PROTOCOL_VERSION,
                "pid": os.getpid(),
                "repoRoot": str(self.paths.repo_root),
                "repoHash": self.paths.repo_hash,
                "socketPath": str(self.paths.socket_path),
                "stateDir": str(self.paths.state_dir),
                "globalHeavySlotPaths": [str(path) for path in self._global_heavy_slot_paths()],
                "globalHeavySlotCount": configured_global_heavy_slots(),
                "xctestSlotPaths": [str(path) for path in self._global_xctest_slot_paths()],
                "xctestSlotCount": configured_global_xctest_slots(),
                "liveAppLockPath": str(live_app_lock_path()),
                "activeJobsByLane": active_by_lane,
                "runningJobs": running_jobs,
                "queuedJobs": queued_jobs,
                "queueDepth": len(self.queue),
                "retainedTerminalCount": terminal_count,
                "shutdownRequested": self.shutdown_requested,
                "conductorDigest": CONDUCTOR_DIGEST,
                "timingEnabled": self.timing_enabled,
                "timing": {
                    "enabled": self.timing_enabled,
                    "setting": self.timing_setting,
                    "helperLoaded": PIPELINE_METRICS is not None,
                    "readAt": "daemon start",
                },
            }

    def _job_payload_locked(self, job: Job, include_tail: bool = True, include_summary: bool = True) -> Dict[str, Any]:
        payload = job.to_payload(include_tail=include_tail, include_summary=include_summary)
        slot_wait_state = self._machine_slot_wait_state_locked(job)
        if slot_wait_state:
            payload["state"] = slot_wait_state
        if job.state == "queued":
            payload["blockedBy"] = self._blocked_by_locked(job)
        return payload

    @staticmethod
    def _machine_slot_wait_state_locked(job: Job) -> Optional[str]:
        if job.state != "running" or job.process_started_at is not None:
            return None
        if job.global_heavy_slot_path and job.global_heavy_slot_holder is not None:
            return "waiting-heavy-slot"
        if job.global_xctest_slot_path and job.global_xctest_slot_holder is not None:
            return "waiting-xctest-slot"
        return None

    def _blocked_by_locked(self, job: Job) -> List[Dict[str, Any]]:
        blockers: List[Dict[str, Any]] = []
        seen: set[str] = set()
        job_lanes = set(job.lanes)
        for ticket in self.active_lanes.values():
            blocker = self.jobs.get(ticket)
            if not blocker or blocker.ticket in seen:
                continue
            conflicting = sorted(job_lanes & set(blocker.lanes))
            if conflicting:
                seen.add(blocker.ticket)
                blockers.append(
                    {
                        "ticket": blocker.ticket,
                        "operationLabel": operation_display_name(blocker.operation, blocker.args),
                        "state": blocker.state,
                        "conflictingLanes": conflicting,
                        "cancelRequested": blocker.cancel_requested,
                    }
                )
        for ticket in self.queue:
            if ticket == job.ticket:
                break
            blocker = self.jobs.get(ticket)
            if not blocker or blocker.state != "queued" or blocker.ticket in seen:
                continue
            conflicting = sorted(job_lanes & set(blocker.lanes))
            if conflicting:
                seen.add(blocker.ticket)
                blockers.append(
                    {
                        "ticket": blocker.ticket,
                        "operationLabel": operation_display_name(blocker.operation, blocker.args),
                        "state": blocker.state,
                        "conflictingLanes": conflicting,
                        "cancelRequested": blocker.cancel_requested,
                    }
                )
        return blockers

    def enqueue(self, request: Dict[str, Any]) -> Dict[str, Any]:
        accepted_ns = time.monotonic_ns()
        raw_args = request.get("args") or {}
        if not isinstance(raw_args, dict):
            raise ConductorError("request args must be an object")
        args = dict(raw_args)
        # Step 7: only the execution-time evaluation may set artifact-derived args.
        for key in TEST_ARTIFACT_DERIVED_ARG_KEYS:
            args.pop(key, None)
        operation = str(request.get("operation") or "")
        if operation == "test-parallel":
            for key in (
                "parallelRunId",
                "parallelCandidate",
                "parallelTestList",
                "parallelWorkdir",
            ):
                args.pop(key, None)
        if operation == "app" and args.get("subcommand") in {"stop", "launch-existing", "relaunch"}:
            # Derived exclusively by supersession below, never accepted from a client.
            args.pop("guardDelayedLaunch", None)
        normalized_request = dict(request)
        normalized_request["args"] = args
        fingerprint = self.registry.fingerprint(normalized_request)
        request_key = request.get("requestKey")
        verbose = bool(request.get("verbose"))
        timeout_value = request.get("timeout")
        telemetry = self.attach_job_telemetry(operation, accepted_ns)
        if telemetry is None:
            _argv, lanes, _cwd, _env, effective_timeout = self.registry.prepare(normalized_request)
        else:
            self._record_client_metrics(telemetry, request.get("clientMetrics"))
            with artifact_operation_sink(self._telemetry_sink(telemetry, "daemon.enqueue_prepare")):
                _argv, lanes, _cwd, _env, effective_timeout = self.registry.prepare(normalized_request)
        env_snapshot = self.registry._request_env_snapshot(normalized_request)
        retention_ns: Optional[int] = None
        retention_cpu_ns = 0

        with self.condition:
            if self.shutdown_requested:
                raise ConductorError("daemon is stopping; cannot enqueue new jobs")
            if request_key:
                existing_ticket = self.request_keys.get(request_key)
                existing = self.jobs.get(existing_ticket or "") if existing_ticket else None
                if existing and existing.state not in TERMINAL_STATES:
                    if existing.fingerprint != fingerprint:
                        raise ConductorError(
                            "request-key mismatch: an active job with this key has a different fingerprint "
                            f"(existing ticket {existing.ticket})"
                        )
                    reused = self._job_payload_locked(existing, include_tail=False, include_summary=False)
                    reused["reused"] = True
                    return reused

            ticket = str(uuid.uuid4())
            log_path = self.paths.jobs_dir / f"{ticket}.log"
            job = Job(
                ticket=ticket,
                request_key=request_key,
                fingerprint=fingerprint,
                operation=operation,
                args=args,
                lanes=lanes,
                timeout=effective_timeout if timeout_value is not None or effective_timeout is not None else None,
                verbose=verbose,
                env=env_snapshot,
                created_at=now(),
                log_path=log_path,
                global_heavy_slot_wait_seconds=(
                    0.0 if operation_requires_global_heavy_slot(operation, args) else None
                ),
                global_xctest_slot_wait_seconds=(
                    0.0 if operation_requires_global_xctest_slot(operation, args) else None
                ),
                telemetry=telemetry,
                artifact_scope="pending" if operation == "test-artifact" else None,
                artifact_scope_message=(
                    TEST_ARTIFACT_PENDING_SCOPE_MESSAGE if operation == "test-artifact" else None
                ),
                test_evidence_scope=(
                    parallel_test_evidence_scope(args.get("filter"))
                    if operation == "test-parallel"
                    else None
                ),
            )
            intent = latest_lifecycle_intent(job.operation, job.args)
            superseded_jobs: List[Dict[str, Any]] = []
            guard_delayed_launch = False
            if intent:
                superseded_jobs, guard_delayed_launch = self._supersede_live_app_jobs_locked(job, intent)
                if guard_delayed_launch:
                    job.args["guardDelayedLaunch"] = True
            self.jobs[ticket] = job
            self.queue.append(ticket)
            if request_key:
                self.request_keys[request_key] = ticket
            if telemetry is None:
                self._retention_pass_locked()
            else:
                retention_start = time.monotonic_ns()
                retention_cpu_start = time.thread_time_ns()
                self._retention_pass_locked()
                retention_cpu_ns = time.thread_time_ns() - retention_cpu_start
                retention_ns = time.monotonic_ns() - retention_start
            self._schedule_locked()
            self.condition.notify_all()
            payload = self._job_payload_locked(job, include_tail=False, include_summary=False)
            payload["reused"] = False
            payload["supersededJobs"] = superseded_jobs
        if retention_ns is not None:
            self._telemetry_operation(
                telemetry, "retention_pass", retention_ns, {"threadCpuNs": retention_cpu_ns}, "daemon.enqueue"
            )
        return payload

    def _supersede_live_app_jobs_locked(self, new_job: Job, intent: str) -> Tuple[List[Dict[str, Any]], bool]:
        superseded: List[Dict[str, Any]] = []
        guard_delayed_launch = False
        for old_job in list(self.jobs.values()):
            if old_job.state not in {"queued", "running"} or "liveApp" not in old_job.lanes:
                continue
            prior_state = old_job.state
            old_job.cancel_requested = True
            old_job.superseded_by_ticket = new_job.ticket
            old_job.superseded_by_operation = intent
            guard_delayed_launch = guard_delayed_launch or bool(old_job.args.get("guardDelayedLaunch"))
            if prior_state == "queued":
                old_job.state = "canceled"
                old_job.finished_at = now()
                old_job.exit_code = 130
                old_job.result_summary = f"superseded before start by {intent}"
                with contextlib.suppress(ValueError):
                    self.queue.remove(old_job.ticket)
                self._append_system_line_locked(old_job, f"job superseded before start by {intent} {new_job.ticket}\n")
                self._complete_undispatched_telemetry_locked(old_job)
                cancellation_state = "canceled"
            else:
                guard_delayed_launch = guard_delayed_launch or is_launch_capable_job(old_job.operation, old_job.args)
                reason = f"superseded by {intent} {new_job.ticket}"
                termination_sent = bool(old_job.process_pid or old_job.process_pgid)
                if termination_sent:
                    self._terminate_process_group_locked(old_job, reason=reason)
                # Step 5: pinned until the escalation's last write; released in its
                # ``finally`` (or here when the thread cannot start).
                self._pin_job_locked(old_job)
                try:
                    threading.Thread(
                        target=self._escalate_canceled_job_after_grace,
                        args=(old_job.ticket, reason, termination_sent, old_job),
                        daemon=True,
                    ).start()
                except BaseException:
                    self._unpin_job_locked(old_job)
                    raise
                cancellation_state = "cancellation-requested"
            superseded.append(
                {
                    "ticket": old_job.ticket,
                    "operationLabel": operation_display_name(old_job.operation, old_job.args),
                    "priorState": prior_state,
                    "cancellationState": cancellation_state,
                }
            )
        return superseded, guard_delayed_launch

    def _escalate_canceled_job_after_grace(
        self, ticket: str, reason: str, termination_sent: bool, pinned_job: Optional[Job] = None
    ) -> None:
        """Escalate a superseded running job; releases ``pinned_job``'s retention pin last."""
        with self.condition:
            try:
                job = self.jobs.get(ticket)
                while job and job.state == "running" and not job.process_pid:
                    self.condition.wait(timeout=PROCESS_TREE_POLL_SECONDS)
                    job = self.jobs.get(ticket)
                if not job or job.state != "running":
                    return
                if not termination_sent:
                    self._terminate_process_group_locked(job, reason=reason)
                descendants_alive = self._wait_for_process_tree_exit_locked(
                    job,
                    now() + TERMINATE_GRACE_SECONDS,
                    signal_for_new=signal.SIGTERM,
                )
                if descendants_alive:
                    self._kill_process_group_locked(job, reason=f"{reason}; SIGKILL after grace period")
                    self._wait_for_process_tree_exit_locked(
                        job,
                        now() + KILL_GRACE_SECONDS,
                        signal_for_new=signal.SIGKILL,
                    )
                self.condition.notify_all()
            finally:
                if pinned_job is not None:
                    self._unpin_job_locked(pinned_job)

    def list_jobs(self, state_filter: Optional[str]) -> Dict[str, Any]:
        with self.lock:
            jobs = list(self.jobs.values())
            jobs.sort(key=lambda job: job.created_at)
            if state_filter in {"waiting-heavy-slot", "waiting-xctest-slot"}:
                jobs = [job for job in jobs if self._machine_slot_wait_state_locked(job) == state_filter]
            elif state_filter:
                jobs = [
                    job
                    for job in jobs
                    if (self._machine_slot_wait_state_locked(job) or job.state) == state_filter
                ]
            return {"jobs": [self._job_payload_locked(job, include_tail=False, include_summary=False) for job in jobs]}

    def resolve_job_locked(self, ticket: Optional[str], request_key: Optional[str]) -> Job:
        if request_key:
            ticket = self.request_keys.get(request_key)
            if not ticket:
                raise ConductorError(f"no job found for request key '{request_key}'")
        if not ticket:
            raise ConductorError("ticket or request key is required")
        job = self.jobs.get(ticket)
        if not job:
            raise ConductorError(f"unknown job '{ticket}'")
        return job

    def _pin_job_locked(self, job: Job) -> None:
        """Protect ``job`` and its files from retention until the matching unpin.

        Holders: ``_run_job`` from dispatch through summary and timing
        finalization, its reader/watchdog/summary threads, the undispatched
        timing worker, the cancellation owners that wait on the condition
        (``_cancel_running_job_locked``, supersession escalation, ``stop --force``
        cleanup), and status/wait/summary calls. Every pin is released in a
        ``finally`` after the holder's last write, so no late write can recreate a
        pruned file.
        """
        job.summary_pins += 1

    def _unpin_job_locked(self, job: Job) -> None:
        job.summary_pins -= 1
        if job.summary_pins <= 0 and job.retention_deferred:
            job.retention_deferred = False
            self._retention_pass_locked()

    def _start_job_owned_thread(self, job: Job, target: Any, args: Tuple[Any, ...]) -> threading.Thread:
        """Start a daemon thread that writes ``job``'s files, pinned until ``target`` returns."""
        with self.condition:
            self._pin_job_locked(job)

        def run() -> None:
            try:
                target(*args)
            finally:
                with self.condition:
                    self._unpin_job_locked(job)

        try:
            thread = threading.Thread(target=run, daemon=True)
            thread.start()
        except BaseException:
            with self.condition:
                self._unpin_job_locked(job)
            raise
        return thread

    def job_status(self, ticket: Optional[str], request_key: Optional[str]) -> Dict[str, Any]:
        with self.lock:
            job = self.resolve_job_locked(ticket, request_key)
            if job.state not in TERMINAL_STATES or job.output_summary is not None:
                return self._job_payload_locked(job, include_tail=True)
            self._pin_job_locked(job)
        try:
            self._refresh_output_summary(job)
            with self.lock:
                return self._job_payload_locked(job, include_tail=True)
        finally:
            with self.lock:
                self._unpin_job_locked(job)

    def job_wait(self, ticket: Optional[str], request_key: Optional[str], timeout: Optional[float]) -> Dict[str, Any]:
        deadline = now() + timeout if timeout is not None else None
        with self.condition:
            job = self.resolve_job_locked(ticket, request_key)
            while job.state not in TERMINAL_STATES:
                remaining = None if deadline is None else deadline - now()
                if remaining is not None and remaining <= 0:
                    payload = self._job_payload_locked(job, include_tail=True)
                    payload["waitTimedOut"] = True
                    return payload
                self.condition.wait(timeout=remaining if remaining is not None else 30.0)
            if job.output_summary is not None:
                payload = self._job_payload_locked(job, include_tail=True)
                payload["waitTimedOut"] = False
                return payload
            self._pin_job_locked(job)
        try:
            self._refresh_output_summary(job, deadline=deadline)
            with self.condition:
                payload = self._job_payload_locked(job, include_tail=True)
                payload["waitTimedOut"] = False
                if job.output_summary is None and job.summary_state == "running":
                    # This wait's deadline ended while another caller is still
                    # summarizing: clients must not scan the log themselves.
                    payload["summaryPending"] = True
                return payload
        finally:
            with self.condition:
                self._unpin_job_locked(job)

    def job_cancel(self, ticket: Optional[str], request_key: Optional[str]) -> Dict[str, Any]:
        with self.condition:
            job = self.resolve_job_locked(ticket, request_key)
            if job.state == "queued":
                job.cancel_requested = True
                job.state = "canceled"
                job.finished_at = now()
                job.exit_code = 130
                job.result_summary = "canceled before start"
                with contextlib.suppress(ValueError):
                    self.queue.remove(job.ticket)
                self._append_system_line_locked(job, "job canceled before start\n")
                self._complete_undispatched_telemetry_locked(job)
                self._schedule_locked()
                self.condition.notify_all()
                self._retention_pass_locked()
                return self._job_payload_locked(job, include_tail=True)
            if job.state == "running":
                job.cancel_requested = True
                self._cancel_running_job_locked(job, reason="cancellation requested")
                return self._job_payload_locked(job, include_tail=True)
            return self._job_payload_locked(job, include_tail=True)

    def stop(self, force: bool) -> Dict[str, Any]:
        running_tickets: List[str] = []
        # Step 5: every pin acquired below is owned here until the force-shutdown
        # thread has started; from then on that thread releases them after its
        # last write. Any failure before the handoff releases exactly these pins.
        running_jobs: List[Job] = []
        handed_off = False
        try:
            with self.condition:
                active_or_queued = [job for job in self.jobs.values() if job.state in {"queued", "running"}]
                if active_or_queued and not force:
                    raise ConductorError(
                        "daemon has active or queued jobs; use 'daemon stop --force' to cancel them before stopping"
                    )
                self.shutdown_requested = True
                if force:
                    for job in list(active_or_queued):
                        job.cancel_requested = True
                        if job.state == "queued":
                            job.state = "canceled"
                            job.finished_at = now()
                            job.exit_code = 130
                            job.result_summary = "canceled by daemon stop --force"
                            with contextlib.suppress(ValueError):
                                self.queue.remove(job.ticket)
                            self._append_system_line_locked(job, "job canceled by daemon stop --force before start\n")
                            self._complete_undispatched_telemetry_locked(job)
                        elif job.state == "running":
                            running_tickets.append(job.ticket)
                            # Step 5: pinned until the force-shutdown cleanup's last write.
                            self._pin_job_locked(job)
                            running_jobs.append(job)
                            self._terminate_process_group_locked(job, reason="daemon stop --force")
                    self._write_running_processes_locked()
                    self.condition.notify_all()
                payload = self.status_payload()
            if force and running_tickets:
                threading.Thread(
                    target=self._force_shutdown_when_canceled, args=(running_tickets, running_jobs), daemon=True
                ).start()
                handed_off = True
            else:
                threading.Thread(target=self._shutdown_server_soon, daemon=True).start()
        except BaseException:
            if running_jobs and not handed_off:
                with self.condition:
                    for job in running_jobs:
                        self._unpin_job_locked(job)
            raise
        return payload

    def _shutdown_server_soon(self) -> None:
        time.sleep(0.1)
        if self.server is not None:
            self.server.shutdown()

    def _force_shutdown_when_canceled(self, tickets: List[str], pinned_jobs: Sequence[Job] = ()) -> None:
        """Escalate ``stop --force`` cleanup; releases ``pinned_jobs``' retention pins after the last write."""
        with self.condition:
            try:
                for ticket in tickets:
                    job = self.jobs.get(ticket)
                    if not job or job.state != "running":
                        continue
                    descendants_alive = self._wait_for_process_tree_exit_locked(
                        job,
                        now() + TERMINATE_GRACE_SECONDS,
                        signal_for_new=signal.SIGTERM,
                    )
                    if descendants_alive:
                        self._kill_process_group_locked(job, reason="daemon stop --force; SIGKILL after grace period")
                        self._wait_for_process_tree_exit_locked(
                            job,
                            now() + KILL_GRACE_SECONDS,
                            signal_for_new=signal.SIGKILL,
                        )
                self.condition.notify_all()
            finally:
                for job in pinned_jobs:
                    self._unpin_job_locked(job)
        time.sleep(0.2)
        if self.server is not None:
            self.server.shutdown()

    def _schedule_locked(self) -> None:
        blocked_lanes: set[str] = set()
        new_queue: List[str] = []
        to_start: List[Job] = []
        active_lane_set = set(self.active_lanes.keys())

        for ticket in self.queue:
            job = self.jobs.get(ticket)
            if not job or job.state != "queued":
                continue
            job_lanes = set(job.lanes)
            if job_lanes & active_lane_set or job_lanes & blocked_lanes:
                blocked_lanes.update(job_lanes)
                new_queue.append(ticket)
                continue
            to_start.append(job)
            active_lane_set.update(job_lanes)

        self.queue = new_queue
        for job in to_start:
            job.state = "running"
            job.started_at = now()
            if job.telemetry is not None:
                job.telemetry_dispatch_ns = time.monotonic_ns()
            for lane in job.lanes:
                self.active_lanes[lane] = job.ticket
            thread = threading.Thread(target=self._run_job, args=(job.ticket,), daemon=True)
            thread.start()
        if to_start:
            self.condition.notify_all()

    def _acquire_global_slot(self, ticket: str, slot_class: str) -> Optional[Any]:
        if slot_class == "heavy":
            slot_label = "heavy"
            lock_kind = "global-heavy"
            paths_getter = self._global_heavy_slot_paths
            wait_attr = "global_heavy_slot_wait_seconds"
            path_attr = "global_heavy_slot_path"
            holder_attr = "global_heavy_slot_holder"
        elif slot_class == "xctest":
            slot_label = "xctest"
            lock_kind = "global-xctest"
            paths_getter = self._global_xctest_slot_paths
            wait_attr = "global_xctest_slot_wait_seconds"
            path_attr = "global_xctest_slot_path"
            holder_attr = "global_xctest_slot_holder"
        else:
            raise ConductorError(f"unknown global slot class '{slot_class}'")

        wait_start = now()
        with self.condition:
            job = self.jobs.get(ticket)
            if job:
                setattr(job, wait_attr, 0.0)
            env = dict(job.env) if job else {}
            telemetry = job.telemetry if job else None
        self._telemetry_boundary(telemetry, "slot_wait_start", metadata={"slot": slot_label})
        contended = False
        outcome = "not_acquired"
        lock_paths = paths_getter(env)
        ensure_private_dir(machine_lock_dir())
        lock_files = [(path, path.open("a+", encoding="utf-8")) for path in lock_paths]
        did_log_wait = False
        selected_path: Optional[Path] = None
        selected_file: Optional[Any] = None
        try:
            while True:
                with self.condition:
                    job = self.jobs.get(ticket)
                    if not job or job.state != "running":
                        return None
                    if job.cancel_requested:
                        job.state = "canceled"
                        job.exit_code = 130
                        job.result_summary = f"canceled before global {slot_label} slot"
                        job.finished_at = now()
                        self._append_system_line_locked(job, f"job canceled before global {slot_label} slot\n")
                        self.condition.notify_all()
                        return None
                for lock_path, lock_file in lock_files:
                    try:
                        fcntl.flock(lock_file.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
                        selected_path = lock_path
                        selected_file = lock_file
                        break
                    except BlockingIOError:
                        continue
                    except OSError as exc:
                        if exc.errno == errno.EINTR:
                            continue
                        raise
                if selected_file is not None and selected_path is not None:
                    break
                # Every configured slot refused a non-blocking flock: a foreign holder exists.
                contended = True
                holders = [format_display_lock_holder(read_display_lock_metadata(path)) for path, _file in lock_files]
                with self.condition:
                    job = self.jobs.get(ticket)
                    if job and job.state == "running":
                        setattr(job, wait_attr, max(0.0, now() - wait_start))
                        setattr(job, path_attr, ",".join(str(path) for path, _file in lock_files))
                        setattr(job, holder_attr, "; ".join(holders))
                        if not did_log_wait:
                            self._append_system_line_locked(
                                job,
                                f"waiting for global {slot_label} slot ({len(lock_files)} configured): "
                                f"{getattr(job, path_attr)}; {getattr(job, holder_attr)}\n",
                            )
                            self.condition.notify_all()
                            did_log_wait = True
                time.sleep(GLOBAL_HEAVY_SLOT_POLL_SECONDS)
            waited = now() - wait_start
            with self.condition:
                job = self.jobs.get(ticket)
                if job and job.state == "running":
                    metadata = display_lock_metadata(
                        lock_kind=lock_kind,
                        ticket=job.ticket,
                        operation=job.operation,
                        operation_label=operation_display_name(job.operation, job.args),
                        repo_root=self.paths.repo_root,
                        repo_hash=self.paths.repo_hash,
                    )
                    write_display_lock_metadata(selected_file, metadata)
                    setattr(job, wait_attr, waited)
                    setattr(job, path_attr, str(selected_path))
                    setattr(job, holder_attr, None)
                    self._append_system_line_locked(
                        job,
                        f"acquired global {slot_label} slot {selected_path} after {format_duration(waited)}\n",
                    )
                    self.condition.notify_all()
            outcome = "acquired"
            return selected_file
        except BaseException:
            outcome = "error"
            raise
        finally:
            for _path, lock_file in lock_files:
                if lock_file is selected_file:
                    continue
                with contextlib.suppress(OSError):
                    lock_file.close()
            self._telemetry_boundary(
                telemetry,
                "slot_wait_end",
                metadata={"slot": slot_label, "contended": contended, "outcome": outcome},
            )

    def _acquire_global_heavy_slot(self, ticket: str) -> Optional[Any]:
        return self._acquire_global_slot(ticket, "heavy")

    def _acquire_global_xctest_slot(self, ticket: str) -> Optional[Any]:
        return self._acquire_global_slot(ticket, "xctest")

    @staticmethod
    def _release_global_slot(lock_file: Optional[Any]) -> None:
        if lock_file is None:
            return
        with contextlib.suppress(OSError):
            lock_file.seek(0)
            lock_file.truncate()
            lock_file.flush()
        with contextlib.suppress(OSError):
            fcntl.flock(lock_file.fileno(), fcntl.LOCK_UN)
        with contextlib.suppress(OSError):
            lock_file.close()

    def _invalidate_root_build_ticket_locked(self, job: Job) -> None:
        ticket_path = self.paths.jobs_dir / "build-ticket-root.json"
        try:
            ticket_path.unlink()
        except FileNotFoundError:
            pass
        except OSError as exc:
            self._append_system_line_locked(
                job, f"could not invalidate prior root build ticket: {exc}\n"
            )

    def _run_job(self, ticket: str) -> None:
        job: Optional[Job] = None
        root_test_start_snapshot: Optional[Dict[str, Any]] = None
        process: Optional[subprocess.Popen[bytes]] = None
        output_transport: Optional[ProcessOutputTransport] = None
        watchdog: Optional[threading.Thread] = None
        global_heavy_slot: Optional[Any] = None
        global_xctest_slot: Optional[Any] = None
        telemetry: Optional[Any] = None
        provenance_scope = contextlib.ExitStack()
        artifact_observations: Optional[ArtifactObservations] = None
        owner_pinned = False
        try:
            with self.lock:
                job = self.jobs[ticket]
                # Step 5: a running job is never evicted; this pin extends that
                # through the terminal transition, summary and timing persistence.
                self._pin_job_locked(job)
                owner_pinned = True
                telemetry = job.telemetry
                dispatch_ns = job.telemetry_dispatch_ns
                request = {
                    "operation": job.operation,
                    "args": job.args,
                    "timeout": job.timeout,
                    "verbose": job.verbose,
                    "env": job.env,
                }
                if operation_invalidates_root_build_ticket(job.operation, job.args):
                    self._invalidate_root_build_ticket_locked(job)
                if job.cancel_requested:
                    job.state = "canceled"
                    job.exit_code = 130
                    job.result_summary = "canceled before process start"
                    job.finished_at = now()
                    self._append_system_line_locked(job, "job canceled before process start\n")
                    canceled_before_start = True
                else:
                    canceled_before_start = False
            if dispatch_ns is not None:
                self._telemetry_boundary(telemetry, "lane_dispatched", dispatch_ns)
            if canceled_before_start:
                return
            if job.operation == "test":
                # Snapshot failures must never break the runner; a missing start
                # snapshot simply withholds the build ticket (fail-closed).
                self._telemetry_boundary(telemetry, "source_snapshot_start")
                try:
                    root_test_start_snapshot = source_snapshot(self.paths.repo_root, job.env)
                except Exception:
                    root_test_start_snapshot = None
                self._telemetry_boundary(telemetry, "source_snapshot_end")
            self._telemetry_boundary(telemetry, "prepare_start")
            if telemetry is None:
                argv, _lanes, cwd, env, effective_timeout = self.registry.prepare(request)
            else:
                with artifact_operation_sink(self._telemetry_sink(telemetry, "daemon.run_prepare")):
                    argv, _lanes, cwd, env, effective_timeout = self.registry.prepare(request)
            self._telemetry_boundary(telemetry, "prepare_end")
            # The evaluation sees the prepared environment, before job-ticket and
            # timing keys are added for the child.
            artifact_env = dict(env)
            if job_ticket_env_eligible(argv):
                env["REPOPROMPT_CONDUCTOR_JOB_TICKET"] = job.ticket
            else:
                env.pop("REPOPROMPT_CONDUCTOR_JOB_TICKET", None)
            env.pop(TIMING_RUNNER_PATH_ENV_KEY, None)
            if telemetry is not None and "__operation_runner" in argv[2:4]:
                # Only the conductor's own runner reads this; SwiftPM never sees it.
                env[TIMING_RUNNER_PATH_ENV_KEY] = str(self.paths.jobs_dir / f"{job.ticket}.runner-timings.json")
            if operation_requires_global_heavy_slot(job.operation, job.args):
                global_heavy_slot = self._acquire_global_heavy_slot(job.ticket)
                if global_heavy_slot is None:
                    return
            if operation_requires_global_xctest_slot(job.operation, job.args):
                global_xctest_slot = self._acquire_global_xctest_slot(job.ticket)
                if global_xctest_slot is None:
                    return
            if job.operation == "test-artifact":
                # Step 7: the one authoritative evaluation (toolchain, source scope,
                # full fingerprint), after lane and XCTest-slot admission and outside
                # the condition. Its identities feed the immediate pre-launch fence.
                artifact_observations = ArtifactObservations()
                with artifact_operation_sink(self._telemetry_sink(telemetry, "daemon.run_evaluate")):
                    evaluation = evaluate_test_artifact(
                        self.paths.repo_root,
                        self.paths.jobs_dir,
                        artifact_env,
                        observations=artifact_observations,
                    )
                with self.condition:
                    job.args.update(evaluation)
                    job.artifact_scope = evaluation["artifactScope"]
                    job.artifact_scope_differences = list(evaluation["artifactScopeDifferences"])
                    job.artifact_scope_message = evaluation["artifactScopeMessage"]
                    canceled_after_validation = bool(job.cancel_requested)
                    if canceled_after_validation:
                        job.state = "canceled"
                        job.exit_code = 130
                        job.result_summary = "canceled before process start"
                        job.finished_at = now()
                        self._append_system_line_locked(job, "job canceled before process start\n")
                        self.condition.notify_all()
                if canceled_after_validation:
                    return
            start_line = f"$ {format_argv(argv)}\n"
            with job.log_path.open("ab") as log_file:
                with self.lock:
                    self._append_tail_locked(job, start_line)
                log_file.write(start_line.encode("utf-8", errors="replace"))
                log_file.flush()
                self._pin_xctest_method_runtimes(job)
                if telemetry is not None:
                    self._telemetry_boundary(telemetry, "command_start", metadata={"command": format_argv(argv)})
                output_transport = self._create_process_output_transport(job)
                job.progress_transport = output_transport.kind
                if job.operation == "test-artifact":
                    if artifact_observations is None or not isinstance(job.args.get("artifactPath"), str):
                        raise ArtifactUnavailableError(
                            "test artifact was not validated before launch; run `make dev-test` first"
                        )
                    # Step 7: metadata-only fence of the identities captured while
                    # hashing; no second pre-launch hash (OD5: two full hashes per run).
                    fence_start = time.monotonic_ns()
                    artifact_observations.verify("after validation, before launch")
                    _emit_operation(
                        self._telemetry_sink(telemetry, "daemon.pre_popen_fence"),
                        "artifact_metadata_fence",
                        time.monotonic_ns() - fence_start,
                        {"pathsChecked": len(artifact_observations)},
                    )
                self._telemetry_boundary(telemetry, "popen_before")
                process = subprocess.Popen(
                    argv,
                    cwd=str(cwd),
                    env=env,
                    stdin=subprocess.DEVNULL,
                    stdout=output_transport.popen_stdout,
                    stderr=output_transport.popen_stderr,
                    start_new_session=True,
                )
                self._telemetry_boundary(telemetry, "popen_after")
                output_transport.attach_process(process)
                with self.condition:
                    job.process_started_at = now()
                    if self._xctest_watchdog_enabled(job):
                        swiftpm_build_expected = (
                            len(argv) >= 2
                            and Path(argv[0]).name in {"swift", "canonical_swift.sh"}
                            and argv[1] == "test"
                            and "--skip-build" not in argv
                        )
                        if swiftpm_build_expected:
                            job.xctest_deadline_phase = "build"
                            job.xctest_progress_deadline = None
                        else:
                            job.xctest_deadline_phase = "startup"
                            job.xctest_progress_deadline = time.monotonic() + XCTEST_STARTUP_DEADLINE_SECONDS
                    job.process_pid = process.pid
                    with contextlib.suppress(OSError):
                        job.process_pgid = os.getpgid(process.pid)
                    snapshot = process_table_snapshot()
                    process_record = snapshot.get(process.pid)
                    job.process_start = process_record[1] if process_record else process_start_token(process.pid)
                    if job.process_start:
                        job.tracked_processes[process.pid] = job.process_start
                    self._write_running_processes_locked()
                    if job.cancel_requested and job.superseded_by_ticket is None:
                        self._terminate_process_group_locked(job, reason="cancellation requested before PID assignment")
                    self.condition.notify_all()

                # Both may outlive their bounded joins; each pins the job until it returns.
                reader = self._start_job_owned_thread(
                    job, self._read_process_output, (job.ticket, process, log_file, output_transport)
                )
                if self._xctest_watchdog_enabled(job):
                    watchdog = self._start_job_owned_thread(job, self._monitor_xctest_stall, (job.ticket,))
                try:
                    exit_code = process.wait(timeout=effective_timeout)
                except subprocess.TimeoutExpired:
                    term_deadline = now() + TERMINATE_GRACE_SECONDS
                    with self.condition:
                        job.timed_out = True
                        job.error = f"timed out after {effective_timeout:.1f}s"
                        self._append_system_line_locked(job, job.error + "\n")
                        self._terminate_process_group_locked(job, reason=job.error)
                    root_alive = False
                    try:
                        exit_code = process.wait(timeout=TERMINATE_GRACE_SECONDS)
                    except subprocess.TimeoutExpired:
                        root_alive = True
                        exit_code = 124
                    with self.condition:
                        descendants_alive = self._wait_for_process_tree_exit_locked(
                            job,
                            term_deadline,
                            signal_for_new=signal.SIGTERM,
                        )
                        if root_alive or descendants_alive:
                            self._kill_process_group_locked(job, reason="SIGKILL after timeout grace period")
                    if root_alive:
                        try:
                            exit_code = process.wait(timeout=KILL_GRACE_SECONDS)
                        except subprocess.TimeoutExpired:
                            exit_code = 124
                            with self.condition:
                                job.error = (
                                    f"timed out after {effective_timeout:.1f}s; "
                                    "root process did not exit after SIGKILL escalation"
                                )
                                self._append_system_line_locked(job, job.error + "\n")
                    with self.condition:
                        descendants_alive = self._wait_for_process_tree_exit_locked(
                            job,
                            now() + KILL_GRACE_SECONDS,
                            signal_for_new=signal.SIGKILL,
                        )
                        if descendants_alive:
                            job.error = (
                                f"timed out after {effective_timeout:.1f}s; "
                                "job processes remained alive after SIGKILL escalation"
                            )
                            self._append_system_line_locked(job, job.error + "\n")
                    if exit_code == 0:
                        exit_code = 124
                    timeout_hint = optimized_lane_timeout_hint(job.operation, job.args, effective_timeout)
                    if timeout_hint is not None:
                        with self.condition:
                            job.error = (job.error or f"timed out after {effective_timeout:.1f}s") + timeout_hint
                            self._append_system_line_locked(job, "hint: " + timeout_hint.lstrip("; ") + "\n")
                if telemetry is not None:
                    self._telemetry_boundary(
                        telemetry, "exit_observed", metadata={"exitCode": exit_code, "timedOut": job.timed_out}
                    )
                with self.condition:
                    job.process_finished_at = now()
                if job.cancel_requested:
                    with self.condition:
                        if self._process_tree_alive_locked(job):
                            self._terminate_process_group_locked(job, reason="cancellation descendant cleanup")
                            term_deadline = now() + TERMINATE_GRACE_SECONDS
                            descendants_alive = self._wait_for_process_tree_exit_locked(
                                job, term_deadline, signal_for_new=signal.SIGTERM
                            )
                            if descendants_alive:
                                self._kill_process_group_locked(job, reason="cancellation descendant cleanup; SIGKILL after grace period")
                                descendants_alive = self._wait_for_process_tree_exit_locked(
                                    job, now() + KILL_GRACE_SECONDS, signal_for_new=signal.SIGKILL
                                )
                            if descendants_alive:
                                raise ConductorError("canceled job descendants remained alive after SIGKILL escalation")
                reader.join(timeout=OUTPUT_READER_JOIN_SECONDS)
                if reader.is_alive():
                    output_transport.close_reader()
                    reader.join(timeout=OUTPUT_READER_JOIN_SECONDS)
                else:
                    output_transport.close_reader()
                if reader.is_alive() and self._xctest_watchdog_enabled(job):
                    # OD16: success requires the classifying reader to have finished.
                    self._fail_incomplete_xctest_output_reader(job, exit_code)
                with self.condition:
                    job.xctest_process_finished = True
                    self.condition.notify_all()
                if watchdog is not None:
                    watchdog.join(timeout=XCTEST_WATCHDOG_JOIN_SECONDS)
                    if watchdog.is_alive():
                        with self.condition:
                            job.measurement_invalid = True
                            job.error = "XCTest progress stall watchdog did not finish bounded diagnostics"
                            self._append_system_line_locked(job, job.error + "\n")
                self._telemetry_boundary(telemetry, "provenance_start")
                if telemetry is not None:
                    provenance_scope.enter_context(
                        artifact_operation_sink(self._telemetry_sink(telemetry, "daemon.post_run_provenance"))
                    )
                ticket_payload = None
                ticket_error = None
                ticket_withheld_reason = None
                if exit_code == 0 and job.operation == "test" and job.args.get(BENCHMARK_DRIVER_DIAGNOSTICS_ARG) is True:
                    # Diagnostic driver flags change the compile command line; such a
                    # build never mints the root ticket that test-artifact reuses.
                    ticket_withheld_reason = "ticket withheld: benchmark driver diagnostics build"
                elif exit_code == 0 and job.operation == "test":
                    try:
                        root_test_end_snapshot = source_snapshot(self.paths.repo_root, env)
                        if root_test_start_snapshot is None or root_test_end_snapshot is None:
                            ticket_withheld_reason = "ticket withheld: source snapshot unavailable during run"
                        elif root_test_start_snapshot != root_test_end_snapshot:
                            ticket_withheld_reason = "ticket withheld: source changed during run"
                        else:
                            ticket_payload = build_ticket_payload(
                                self.paths.repo_root,
                                job,
                                env,
                                snapshot=root_test_start_snapshot,
                            )
                    except Exception as exc:
                        ticket_error = str(exc)
                parallel_candidate: Optional[Dict[str, Any]] = None
                parallel_integrity_error: Optional[str] = None
                if job.operation == "test-parallel":
                    candidate_value = job.args.get("parallelCandidate")
                    candidate_path = (
                        Path(candidate_value) if isinstance(candidate_value, str) else None
                    )
                    should_validate_candidate = (
                        exit_code in {0, XCTEST_SOURCE_ARTIFACT_INTEGRITY_EXIT_CODE}
                        or (candidate_path is not None and candidate_path.exists())
                    )
                    if should_validate_candidate:
                        try:
                            if candidate_path is None:
                                raise ParallelTestIntegrityError(
                                    "parallel test candidate path is unavailable"
                                )
                            parallel_candidate = read_parallel_test_candidate(
                                candidate_path,
                                expected_run_id=str(job.args.get("parallelRunId") or ""),
                                expected_ticket_id=job.ticket,
                                expected_filter=(
                                    str(job.args["filter"])
                                    if isinstance(job.args.get("filter"), str)
                                    and job.args.get("filter")
                                    else None
                                ),
                            )
                            verify_parallel_test_candidate(
                                self.paths.repo_root, parallel_candidate, env
                            )
                            job.build_phase_seconds = float(
                                parallel_candidate["build_duration_seconds"]
                            )
                            runner_started_at = float(
                                parallel_candidate["runner_started_at"]
                            )
                            if job.process_finished_at is not None:
                                job.run_phase_seconds = max(
                                    0.0, job.process_finished_at - runner_started_at
                                )
                            if (
                                exit_code == 0
                                and not job.cancel_requested
                                and not job.measurement_invalid
                                and not job.timed_out
                            ):
                                write_build_ticket(
                                    self.paths.jobs_dir / "build-ticket-root.json",
                                    parallel_build_ticket_payload(parallel_candidate),
                                )
                        except (OSError, ParallelTestIntegrityError) as exc:
                            parallel_integrity_error = str(exc)
                            exit_code = XCTEST_SOURCE_ARTIFACT_INTEGRITY_EXIT_CODE
                    elif exit_code == XCTEST_SOURCE_ARTIFACT_INTEGRITY_EXIT_CODE:
                        parallel_integrity_error = (
                            "parallel test source/artifact integrity check failed "
                            "before candidate creation"
                        )

                artifact_post_differences: List[str] = []
                artifact_integrity_failure: Optional[str] = None
                if job.operation == "test-artifact":
                    post_snapshot = source_snapshot(self.paths.repo_root, env)
                    recorded_snapshot = job.args.get("artifactTicketSourceSnapshot")
                    artifact_post_differences = [
                        f"post-run {difference}"
                        for difference in source_snapshot_differences(recorded_snapshot, post_snapshot)
                    ]
                    artifact_path_value = job.args.get("artifactPath")
                    artifact_fingerprint = job.args.get("artifactFingerprint")
                    if isinstance(artifact_path_value, str) and artifact_fingerprint is not None:
                        try:
                            # One full, stability-checked fingerprint; its observations
                            # only fence this pass.
                            post_fingerprint = test_artifact_fingerprint(
                                Path(artifact_path_value), observations=ArtifactObservations()
                            )
                            changed = artifact_fingerprint_differences(
                                artifact_fingerprint, post_fingerprint
                            )
                            if changed:
                                artifact_integrity_failure = (
                                    "test artifact changed during the run; changed: " + ", ".join(changed)
                                )
                                artifact_post_differences.append("artifact mutated during run")
                        except ArtifactUnavailableError as exc:
                            artifact_integrity_failure = f"post-run artifact integrity unavailable: {exc}"
                            artifact_post_differences.append("post-run artifact integrity unavailable")
                    else:
                        artifact_integrity_failure = (
                            "post-run artifact integrity unavailable: no validated artifact fingerprint"
                        )
                        artifact_post_differences.append("post-run artifact integrity unavailable")
                provenance_scope.close()
                self._telemetry_boundary(telemetry, "provenance_end")
                with self.condition:
                    if ticket_error:
                        self._append_system_line_locked(job, f"could not compute root build ticket: {ticket_error}\n")
                    if ticket_withheld_reason:
                        self._append_system_line_locked(job, ticket_withheld_reason + "\n")
                    if parallel_integrity_error:
                        self._append_system_line_locked(
                            job, f"parallel integrity failure: {parallel_integrity_error}\n"
                        )
                    if job.operation == "test-artifact" and artifact_post_differences:
                        for difference in artifact_post_differences:
                            if difference not in job.artifact_scope_differences:
                                job.artifact_scope_differences.append(difference)
                        job.artifact_scope = "stale"
                        job.artifact_scope_message = artifact_scope_message(
                            "stale", job.artifact_scope_differences
                        )
                    self._finalize_process_exit_locked(job, exit_code)
                    if parallel_integrity_error:
                        job.error = parallel_integrity_error
                        job.result_summary = parallel_integrity_error
                    if artifact_integrity_failure:
                        # Step 7: a post-run byte change invalidates an otherwise
                        # successful result (65, the artifact-unavailable status).
                        # An earlier failure, timeout or cancellation stays primary;
                        # the integrity line and stale scope are attached.
                        self._append_system_line_locked(
                            job, f"artifact integrity failure: {artifact_integrity_failure}\n"
                        )
                        if job.state == "completed":
                            job.state = "failed"
                            job.exit_code = 65
                            job.error = artifact_integrity_failure
                            job.result_summary = (
                                "test artifact integrity failed after execution; "
                                "run `make dev-test` first"
                            )
                    if (
                        job.operation == "test-artifact"
                        and job.process_started_at is not None
                        and job.process_finished_at is not None
                    ):
                        job.run_phase_seconds = max(
                            0.0, job.process_finished_at - job.process_started_at
                        )
                    if job.state == "completed" and job.operation == "test" and ticket_payload is not None:
                        try:
                            write_build_ticket(self.paths.jobs_dir / "build-ticket-root.json", ticket_payload)
                        except OSError as exc:
                            self._append_system_line_locked(job, f"could not write root build ticket: {exc}\n")
                    if (
                        job.state == "completed"
                        and job.operation == "test-artifact"
                        and job.artifact_scope_message
                    ):
                        job.result_summary = job.artifact_scope_message
                    if job.state == "completed" and job.operation == "test-parallel":
                        scope = parallel_test_evidence_scope(job.args.get("filter"))
                        if scope == "full-root":
                            job.result_summary = (
                                "full-root source validation completed successfully"
                            )
                        else:
                            job.result_summary = (
                                "filtered source validation completed successfully; "
                                "not full-root contribution evidence"
                            )
                    job.finished_at = now()
        except ArtifactUnavailableError as exc:
            if job is not None:
                with self.condition:
                    job.state = "failed"
                    job.exit_code = 65
                    job.error = str(exc)
                    job.result_summary = str(exc)
                    job.finished_at = now()
                    self._append_system_line_locked(job, f"artifact unavailable: {exc}\n")
        except Exception as exc:  # defensive: preserve daemon health
            if job is not None:
                with self.condition:
                    job.state = "failed"
                    job.exit_code = 1
                    job.error = str(exc)
                    job.result_summary = f"daemon runner error: {exc}"
                    job.finished_at = now()
                    self._append_system_line_locked(job, f"daemon runner error: {exc}\n")
        finally:
            try:
                provenance_scope.close()
                self._release_global_slot(global_xctest_slot)
                self._release_global_slot(global_heavy_slot)
                if output_transport is not None:
                    output_transport.close_all()
                if job is not None and job.deferred_log_lines:
                    # Defensive: the reader writes its own queue after every batch.
                    self._flush_deferred_log_lines(job)
                refresh_after_release = False
                lane_release_ns: Optional[int] = None
                retention_ns: Optional[int] = None
                retention_cpu_ns = 0
                with self.condition:
                    if job is not None:
                        # Every _run_job exit is the job's terminal transition here.
                        self._release_xctest_method_runtimes_locked(job)
                        refresh_after_release = job.state in TERMINAL_STATES and job.output_summary is None
                        for lane in list(job.lanes):
                            if self.active_lanes.get(lane) == job.ticket:
                                del self.active_lanes[lane]
                        self._write_running_processes_locked()
                        if telemetry is None:
                            self._retention_pass_locked()
                        else:
                            lane_release_ns = time.monotonic_ns()
                            retention_cpu_start = time.thread_time_ns()
                            self._retention_pass_locked()
                            retention_cpu_ns = time.thread_time_ns() - retention_cpu_start
                            retention_ns = time.monotonic_ns() - lane_release_ns
                    self._schedule_locked()
                    self.condition.notify_all()
                if job is not None and telemetry is not None:
                    # Recorded after the scheduler lock; the lane-released flag is set
                    # only afterwards so finalization never precedes these records.
                    self._telemetry_boundary(telemetry, "lane_released", lane_release_ns)
                    self._telemetry_operation(
                        telemetry, "retention_pass", retention_ns, {"threadCpuNs": retention_cpu_ns}, "daemon.lane_release"
                    )
                    with self.condition:
                        job.telemetry_lane_released = True
                        self.condition.notify_all()
                    if refresh_after_release:
                        # Same summary work as the legacy thread, run on this job
                        # thread: the summary is published first, then timing is
                        # finalized, published and persisted without blocking it.
                        self._refresh_output_summary(job, complete_telemetry=True)
                    else:
                        self.complete_job_telemetry(job)
                elif job is not None and refresh_after_release:
                    self._start_job_owned_thread(job, self._refresh_output_summary, (job,))
            finally:
                if owner_pinned and job is not None:
                    # Released last: summary, timing persistence and every writer it
                    # started are done or hold their own pins (Step 5). Writers it did
                    # not start (job cancel, supersession escalation, force-stop
                    # cleanup) pin the job themselves until their last write.
                    with self.condition:
                        self._unpin_job_locked(job)

    def _xctest_progress_transitions(self, records: Sequence[Any]) -> List[Tuple[int, str, Any]]:
        """Recognized XCTest progress lines of ``records``, in order (outside the lock).

        Each entry is ``(receive_ns, matchable_line, marker)`` with exactly the
        line normalization and match of ``_record_xctest_progress_locked``;
        whether it changes job state is decided under the lock by
        ``_apply_xctest_progress_line_locked``.
        """
        transitions: List[Tuple[int, str, Any]] = []
        sgr_sub = XCTEST_ANSI_SGR_RE.sub
        match = XCTEST_PROGRESS_RE.match
        for record in records:
            if record[4]:
                # Over cap: the scanner classified the whole record before any
                # byte was dropped (no items once the scanner failed, OD16).
                receive_ns = record[1]
                transitions.extend((receive_ns, line, marker) for line, marker in record[7])
                continue
            text = record[2]
            if "\x1b" in text:
                text = sgr_sub("", text)
            if "Test Case '" not in text and "Build complete!" not in text:
                continue
            # SGR sequences hold no line separators, so stripping them before
            # ``splitlines`` equals today's per-line strip.
            for raw_line in text.splitlines():
                matchable_line = raw_line.strip()
                marker = match(matchable_line)
                if marker is not None or "Build complete!" in matchable_line:
                    transitions.append((record[1], matchable_line, marker))
        return transitions

    def _submit_output_records(
        self,
        ticket: str,
        records: List[Any],
        receive_wall: float,
        watchdog: bool,
        cursor: Optional[Any],
        walls: Optional[Mapping[int, float]] = None,
    ) -> None:
        """Steps 3–5 of the Step 3 reader contract for one read's (or one coalesced group's) records.

        Telemetry, tail normalization and XCTest classification run outside
        ``self.condition``. Each batch (at most 256 records / 64 KiB) then takes
        the lock once, extends the tail, applies every recognized XCTest
        transition individually and in order with its record's receive time,
        and notifies once. ``walls`` maps a coalesced read's receive time to its
        wall time; records of any other read use ``receive_wall``.
        """
        if cursor is not None and cursor.active:
            cursor.observe_split_records(records)
        output = CONDUCTOR_OUTPUT
        for batch in output.record_batches(records):
            entries = output.tail_entries(batch)
            transitions = self._xctest_progress_transitions(batch) if watchdog else ()
            deferred: Optional[List[str]] = None
            with self.condition:
                job = self.jobs.get(ticket)
                if job is None:
                    continue
                job.tail.extend_sized(entries)
                for receive_ns, matchable_line, marker in transitions:
                    self._apply_xctest_progress_line_locked(
                        job,
                        matchable_line,
                        marker,
                        receive_ns / 1_000_000_000,
                        receive_wall if walls is None else walls.get(receive_ns, receive_wall),
                    )
                deferred = self._take_deferred_log_lines_locked(job)
                self.condition.notify_all()
            # Before the next batch and the next read, as when these lines were written under the lock.
            self._write_deferred_log_lines(job, deferred)

    def _fail_xctest_output_contract(self, ticket: str, kind: str, record_seq: int, line_open: bool = False) -> None:
        """OD16: fail the job visibly when over-cap XCTest output exceeds the scanner's bounds.

        ``kind`` is ``SegmentScanner.failure``: ``"segment"`` (D1, a normalized
        marker line over ``SEGMENT_MAX_CHARS``) or ``"pending"`` (D2, more than
        ``SEGMENT_MAX_PENDING_ITEMS`` items in one over-cap record). The reason is
        bounded and echoes no output. A running job becomes measurement-invalid,
        so it finalizes as failed (exit ``XCTEST_STALL_FAILURE_EXIT_CODE``) even
        when the child exits 0, and publishes no success artifact; an earlier
        stall claim keeps its own error. The XCTest monitor thread owns
        terminating the process tree, so the reader keeps draining output.
        ``line_open`` (the raw log ends mid-line) starts the system line on a
        new log line, so it never joins the oversized output in summaries.
        """
        output = CONDUCTOR_OUTPUT
        if kind == "segment":
            limit = output.SEGMENT_MAX_CHARS
            reason = (
                f"XCTest output contract failure (OD16): a normalized XCTest progress marker in over-cap "
                f"output record {record_seq} exceeds {limit} characters and cannot be applied within the "
                "conductor's bounds"
            )
        else:
            limit = output.SEGMENT_MAX_PENDING_ITEMS
            reason = (
                f"XCTest output contract failure (OD16): over-cap output record {record_seq} holds more "
                f"than {limit} XCTest progress lines, which are not applied before the record completes"
            )
        with self.condition:
            job = self.jobs.get(ticket)
            if job is None or job.xctest_output_failure is not None:
                return
            job.xctest_output_failure = reason
            if line_open:
                try:
                    with job.log_path.open("ab") as handle:
                        handle.write(b"\n")
                except OSError:
                    pass
            job.diagnostics.append(
                {
                    "kind": "xctest-output-contract",
                    "boundary": kind,
                    "recordSeq": record_seq,
                    "limit": limit,
                    "capturedAt": now(),
                }
            )
            self._append_system_line_locked(job, reason + "\n")
            if job.state == "running" and not job.measurement_invalid:
                job.measurement_invalid = True
                job.error = reason
            self.condition.notify_all()

    def _fail_incomplete_xctest_output_reader(self, job: Job, exit_code: int) -> None:
        """OD16 completion guard: an XCTest job succeeds only after its output reader finished.

        Called by ``_run_job`` when the reader of a classifying (watchdog-enabled)
        job is still alive after both bounded joins and the reader close. Such a
        reader may still hold output it has read but not classified, including an
        unreported OD16 failure, so the job must not succeed. It is not waited for
        further. One bounded diagnostic and system line are always recorded. A job
        that would otherwise succeed (exit 0, not canceled, timed out or already
        measurement-invalid) becomes measurement-invalid, so it finalizes as failed
        (exit ``XCTEST_STALL_FAILURE_EXIT_CODE``) and publishes no success artifact;
        an outcome already decided keeps its own reason. Remaining job processes get
        the bounded TERM/KILL escalation. When the reader resumes, its descriptor is
        closed (EOF), and a late OD16 report records only its diagnostic.
        """
        waited = 2 * OUTPUT_READER_JOIN_SECONDS
        reason = (
            f"XCTest output reader did not finish within {waited:.1f}s after the process exited; "
            "its output is not fully classified, so the job cannot succeed (OD16)"
        )
        with self.condition:
            changes_outcome = exit_code == 0 and not (
                job.cancel_requested or job.timed_out or job.measurement_invalid
            )
            job.diagnostics.append(
                {
                    "kind": "xctest-output-reader-incomplete",
                    "joinSeconds": waited,
                    "outcomeChanged": changes_outcome,
                    "capturedAt": now(),
                }
            )
            try:
                with job.log_path.open("rb") as handle:
                    handle.seek(0, os.SEEK_END)
                    if handle.tell():
                        handle.seek(-1, os.SEEK_END)
                        line_open = handle.read(1) not in (b"\n", b"\r")
                    else:
                        line_open = False
            except OSError:
                line_open = False
            self._append_system_line_locked(job, ("\n" if line_open else "") + reason + "\n")
            if changes_outcome:
                job.measurement_invalid = True
                job.error = reason
            if self._process_tree_alive_locked(job) or self._process_group_id_alive_locked(job):
                cleanup = "XCTest output reader incomplete"
                self._terminate_process_group_locked(job, reason=cleanup)
                if self._wait_for_process_tree_exit_locked(
                    job, now() + TERMINATE_GRACE_SECONDS, signal_for_new=signal.SIGTERM
                ):
                    self._kill_process_group_locked(job, reason=f"{cleanup}; SIGKILL after grace period")
                    if self._wait_for_process_tree_exit_locked(
                        job, now() + KILL_GRACE_SECONDS, signal_for_new=signal.SIGKILL
                    ):
                        self._append_system_line_locked(
                            job, f"{cleanup} cleanup could not confirm descendant exit after SIGKILL\n"
                        )
            self.condition.notify_all()

    def _submit_output_group(
        self,
        ticket: str,
        splitter: Any,
        records: List[Any],
        receive_wall: float,
        classify: bool,
        cursor: Optional[Any],
        walls: Optional[Mapping[int, float]] = None,
    ) -> bool:
        """Submit one group's records; returns whether XCTest classification continues.

        Once the splitter latches a scanner failure (OD16), the records before
        the failed one keep their transitions, the job fails, and every later
        record (the failed one included) feeds telemetry and the tail only.
        """
        failure = splitter.segment_failure if classify else None
        if failure is None:
            if records:
                self._submit_output_records(ticket, records, receive_wall, classify, cursor, walls)
            return classify
        kind, failed_seq = failure
        cut = 0
        while cut < len(records) and records[cut][0] < failed_seq:
            cut += 1
        if cut:
            self._submit_output_records(ticket, records[:cut], receive_wall, True, cursor, walls)
        # Every raw byte of the group is already in the log.
        line_open = splitter.line_open or bool(records and records[-1][3] == "eof")
        self._fail_xctest_output_contract(ticket, kind, failed_seq, line_open)
        if cut < len(records):
            self._submit_output_records(ticket, records[cut:], receive_wall, False, cursor, walls)
        return False

    def _pump_output(
        self,
        ticket: str,
        read_chunk: Any,
        sink: Any,
        cursor: Optional[Any] = None,
        read_available: Optional[Any] = None,
    ) -> None:
        """Relay raw output chunks to ``sink`` and output records to the job.

        ``read_chunk`` returns the next available chunk, or ``b""`` at EOF.
        Per read: the receive time is captured immediately, the raw chunk is
        written and flushed unchanged, then the shared splitter's records feed
        telemetry (``cursor``, optional), the tail and XCTest progress through
        ``_submit_output_records``. A record completed by a later read takes that
        read's receive time; an unterminated final record is flushed at EOF or on
        a reader error. With the watchdog enabled, a record beyond the 64 KiB cap
        is classified as a bounded stream before bytes are dropped; its
        transitions ride on the record and take the receive time of the read
        that completes it, like any line. A marker line over
        ``SEGMENT_MAX_CHARS`` or more than ``SEGMENT_MAX_PENDING_ITEMS`` items in
        one record fails the job instead (OD16, ``_fail_xctest_output_contract``):
        nothing is applied early or from a partial line, classification stops,
        and the raw bytes, records and tail continue unchanged until EOF.

        OD14 coalescing (``read_available``, PTY only): after a blocking read,
        further reads are taken only while ``read_available`` returns data that
        is already there, up to ``COALESCE_MAX_BYTES`` / ``COALESCE_MAX_READS`` /
        ``COALESCE_MAX_NS`` per group. Each further read asks for at most the
        group's remaining bytes, and none starts once the group's time budget
        (measured from the first read's receive time) is spent; only the work of
        a read already taken can end after it. Each read is still timestamped on
        return, written and flushed to ``sink`` unchanged before the next read
        (one flush per read, never per group), and fed to the splitter
        with its own receive time (and wall time for transitions); only the
        submission (lock, tail, transitions, notify) is shared by the group.
        A scanner failure ends a group, so the job fails right after the reads
        that caused it. This is the reader-loop seam: its unit tests call it
        directly, while ``Scripts/conductor_benchmark.py`` measures the path
        through ``_read_process_output``.
        """
        monotonic_ns = time.monotonic_ns
        wall_time = time.time
        reader_cpu_start = time.thread_time_ns() if cursor is not None else 0
        with self.condition:
            job = self.jobs.get(ticket)
            watchdog = job is not None and self._xctest_watchdog_enabled(job)
        splitter = CONDUCTOR_OUTPUT.RecordSplitter(segment_scanner=_xctest_segment_scanner if watchdog else None)
        # XCTest classification of submitted records; off after an OD16 failure.
        classify = watchdog
        feed = splitter.feed
        output = CONDUCTOR_OUTPUT
        max_bytes = output.COALESCE_MAX_BYTES
        max_reads = output.COALESCE_MAX_READS
        max_ns = output.COALESCE_MAX_NS
        eof_ns: Optional[int] = None
        # Records read but not yet submitted, kept so a failure mid-group still
        # delivers them (before the splitter's own final records).
        group_records: List[Any] = []
        group_wall = 0.0
        group_walls: Optional[Dict[int, float]] = None
        try:
            while True:
                chunk = read_chunk()
                receive_ns = monotonic_ns()
                if not chunk:
                    eof_ns = receive_ns
                    break
                receive_wall = wall_time()
                sink.write(chunk)
                sink.flush()
                group_records = feed(chunk, receive_ns)
                group_wall = receive_wall
                group_walls = None
                if read_available is not None and not (classify and splitter.segment_failure is not None):
                    group_bytes = len(chunk)
                    group_reads = 1
                    while group_bytes < max_bytes and group_reads < max_reads:
                        # Budgets are checked before a read starts: never start one
                        # after the time budget is spent, and never ask for more than
                        # the bytes left in the group.
                        if monotonic_ns() - receive_ns >= max_ns:
                            break
                        more = read_available(max_bytes - group_bytes)
                        if not more:
                            break
                        more_ns = monotonic_ns()
                        more_wall = wall_time()
                        sink.write(more)
                        sink.flush()
                        more_records = feed(more, more_ns)
                        if more_records:
                            if group_walls is None:
                                group_walls = {receive_ns: receive_wall}
                            group_walls[more_ns] = more_wall
                            group_records.extend(more_records)
                        group_bytes += len(more)
                        group_reads += 1
                        if classify and splitter.segment_failure is not None:
                            break
                records, group_records = group_records, []
                classify = self._submit_output_group(
                    ticket, splitter, records, group_wall, classify, cursor, group_walls
                )
        finally:
            if eof_ns is None:
                eof_ns = monotonic_ns()
            try:
                if group_records or (classify and splitter.segment_failure is not None):
                    records, group_records = group_records, []
                    classify = self._submit_output_group(
                        ticket, splitter, records, group_wall, classify, cursor, group_walls
                    )
                records = splitter.finish(eof_ns)
                if records or (classify and splitter.segment_failure is not None):
                    classify = self._submit_output_group(ticket, splitter, records, wall_time(), classify, cursor)
            finally:
                if cursor is not None:
                    cursor.finish_split()
                    # Whole reader-thread CPU (output work included), for decomposition.
                    self._telemetry_operation(
                        cursor.recorder,
                        "output_reader_cpu",
                        time.thread_time_ns() - reader_cpu_start,
                        None,
                        "daemon.reader",
                        quality=PIPELINE_METRICS.MEASURED_CPU,
                    )

    def _output_telemetry_cursor(self, ticket: str) -> Optional[Any]:
        if not self.timing_enabled:
            return None
        try:
            with self.condition:
                job = self.jobs.get(ticket)
                recorder = job.telemetry if job is not None else None
            if recorder is None:
                return None
            cursor = PIPELINE_METRICS.OutputTelemetryCursor(recorder)
        except Exception:
            return None
        return cursor if cursor.active else None

    def _read_process_output(
        self,
        ticket: str,
        process: subprocess.Popen[bytes],
        log_file: Any,
        output_transport: ProcessOutputTransport,
    ) -> None:
        try:
            cursor = self._output_telemetry_cursor(ticket)
            # OD14: only a real PTY transport coalesces available reads.
            read_available = output_transport.read_available if output_transport.kind == "pty" else None
            self._pump_output(
                ticket, lambda: output_transport.read_chunk(process), log_file, cursor, read_available
            )
        finally:
            output_transport.close_reader()

    @staticmethod
    def _filtered_test_log_has_started_case(job: Job) -> bool:
        try:
            with job.log_path.open("r", encoding="utf-8", errors="replace") as handle:
                for raw_line in handle:
                    line = XCTEST_ANSI_SGR_RE.sub("", raw_line.rstrip("\r\n")).strip()
                    marker = XCTEST_PROGRESS_RE.match(line)
                    if marker is not None and marker.group(2) == "started":
                        return True
        except OSError:
            return job.xctest_started_count > 0
        return False

    def _finalize_process_exit_locked(self, job: Job, exit_code: int) -> None:
        if job.cancel_requested:
            job.state = "canceled"
            job.exit_code = 130
            job.result_summary = "canceled"
        elif job.measurement_invalid:
            job.state = "failed"
            job.exit_code = XCTEST_STALL_FAILURE_EXIT_CODE
            job.error = job.error or "XCTest progress stall watchdog invalidated this measurement"
            job.result_summary = job.error
        elif job.timed_out:
            job.state = "failed"
            job.exit_code = 124
            job.result_summary = job.error or "timed out"
        elif (
            exit_code == 0
            and job.operation in {"test", "test-artifact", "provider-test", "core-test"}
            and bool(job.args.get("filter"))
            and job.env.get("RPCE_ALLOW_ZERO_TESTS") != "1"
            and not self._filtered_test_log_has_started_case(job)
        ):
            filter_value = str(job.args.get("filter"))
            job.state = "failed"
            job.exit_code = XCTEST_ZERO_TESTS_FAILURE_EXIT_CODE
            job.error = (
                f"0 tests executed for filter '{filter_value}' — filter matched nothing at runtime "
                "(stale ledger entry, regex mismatch, or config-gated suite)"
            )
            job.result_summary = job.error
            self._append_system_line_locked(job, job.error + "\n")
        elif exit_code == 0:
            job.state = "completed"
            job.exit_code = 0
            job.result_summary = "completed successfully"
        else:
            job.state = "failed"
            job.exit_code = int(exit_code)
            job.error = f"process exited with status {exit_code}"
            job.result_summary = job.error

    def _xctest_watchdog_enabled(self, job: Job) -> bool:
        return (
            job.operation in {"test", "test-artifact", "provider-test", "core-test"}
            and not bool(job.args.get("list"))
            and job.args.get("xctestDeadlines") is not False
            and job.env.get("REPOPROMPT_DEV_XCTEST_DEADLINES") != "0"
        )

    def _create_process_output_transport(self, job: Job) -> ProcessOutputTransport:
        kind = "pty" if self._xctest_watchdog_enabled(job) else "pipe"
        return ProcessOutputTransport.create(kind)

    def _pin_xctest_method_runtimes(self, job: Job) -> None:
        """Pin the shared runtime-ledger snapshot to ``job`` before process start (Step 4).

        Called without ``self.condition``: the cache stats, reads and parses under
        its own single-flight. Only a watchdog-enabled job without an explicit
        ``--xctest-stall-seconds`` budget consults the ledger. A fallback writes its
        diagnostic to the log outside the condition and adds it to the tail under it.
        """
        if not self._xctest_watchdog_enabled(job) or job.args.get("xctestStallSeconds") is not None:
            return
        load = self.runtime_ledger_cache.load()
        if load.diagnostic:
            with contextlib.suppress(OSError), job.log_path.open("ab") as handle:
                handle.write(load.diagnostic.encode("utf-8", errors="replace"))
        with self.condition:
            if load.diagnostic:
                self._append_tail_locked(job, load.diagnostic)
            job.xctest_method_runtimes = load.runtimes

    @staticmethod
    def _release_xctest_method_runtimes_locked(job: Job) -> None:
        """The terminal transition drops the job's pinned ledger snapshot (Step 4)."""
        job.xctest_method_runtimes = None

    def _append_deferred_system_line_locked(self, job: Job, text: str) -> None:
        """Add ``text`` to the tail now and queue its log write for after the condition (Step 4).

        Whoever releases the condition after queueing writes the queue with
        ``_write_deferred_log_lines`` (the output reader after each batch,
        ``_run_job`` at its end, or ``_flush_deferred_log_lines``), so no file I/O
        happens under the condition and the log keeps the reader's write order.
        """
        self._append_tail_locked(job, text)
        if job.deferred_log_lines is None:
            job.deferred_log_lines = [text]
        else:
            job.deferred_log_lines.append(text)

    @staticmethod
    def _take_deferred_log_lines_locked(job: Job) -> Optional[List[str]]:
        lines = job.deferred_log_lines
        job.deferred_log_lines = None
        return lines

    @staticmethod
    def _write_deferred_log_lines(job: Optional[Job], lines: Optional[List[str]]) -> None:
        """Append queued system lines in order, outside the condition (as ``_append_system_line_locked`` did)."""
        if job is None or not lines:
            return
        try:
            with job.log_path.open("ab") as handle:
                for text in lines:
                    handle.write(text.encode("utf-8", errors="replace"))
        except OSError:
            pass

    def _flush_deferred_log_lines(self, job: Job) -> None:
        """Write ``job``'s queued system lines; call without ``self.condition``."""
        with self.condition:
            lines = self._take_deferred_log_lines_locked(job)
        self._write_deferred_log_lines(job, lines)

    def _set_xctest_active_method_budget_locked(self, job: Job, test_name: str) -> float:
        flag_override = job.args.get("xctestStallSeconds")
        runtime: Optional[float] = None
        if flag_override is None:
            case_key = parse_xctest_case_name(test_name)
            runtimes = job.xctest_method_runtimes
            if case_key is not None and runtimes is not None:
                # The pinned snapshot only: no ledger I/O under the condition.
                runtime = runtimes.get(case_key)
        budget, source, clamped = xctest_active_method_budget(
            runtime,
            float(flag_override) if flag_override is not None else None,
            job.timeout,
            floor_seconds=_xctest_active_method_floor(job.env),
        )
        job.xctest_active_method_budget_seconds = budget
        job.xctest_active_method_budget_source = source
        if clamped:
            unclamped_budget, _source, _clamped = xctest_active_method_budget(
                runtime,
                float(flag_override) if flag_override is not None else None,
                None,
                floor_seconds=_xctest_active_method_floor(job.env),
            )
            self._append_deferred_system_line_locked(
                job,
                f"XCTest active-method budget clamped from {unclamped_budget:.3f}s "
                f"to job timeout {budget:.3f}s for method={test_name}; source={source}\n",
            )
        return budget

    def _record_xctest_progress_locked(
        self,
        job: Job,
        text: str,
        observed_at: Optional[float] = None,
    ) -> bool:
        """Apply ``text``'s XCTest progress lines under the condition.

        A clamped active-method budget queues its diagnostic's log write
        (Step 4): after releasing the condition, the caller writes it with
        ``_flush_deferred_log_lines`` (``_run_job`` also flushes at the end).
        """
        if not self._xctest_watchdog_enabled(job):
            return False
        matched = False
        timestamp = time.monotonic() if observed_at is None else observed_at
        progress_observed_at = now() if observed_at is None else observed_at
        for raw_line in text.splitlines():
            matchable_line = XCTEST_ANSI_SGR_RE.sub("", raw_line.rstrip("\r\n")).strip()
            marker = XCTEST_PROGRESS_RE.match(matchable_line)
            if self._apply_xctest_progress_line_locked(job, matchable_line, marker, timestamp, progress_observed_at):
                matched = True
        return matched

    def _apply_xctest_progress_line_locked(
        self,
        job: Job,
        matchable_line: str,
        marker: Any,
        timestamp: float,
        progress_observed_at: float,
    ) -> bool:
        """Today's per-line XCTest transition body, unchanged.

        ``marker`` is ``XCTEST_PROGRESS_RE.match(matchable_line)``. ``timestamp``
        (monotonic seconds) drives deadlines and ``progress_observed_at`` (wall
        seconds) is reported; the output reader passes the read's receive time.
        Each recognized transition increments ``xctest_progress_sequence``.
        """
        if "Build complete!" in matchable_line and job.xctest_progress_sequence == 0:
            job.xctest_deadline_phase = "startup"
            job.xctest_progress_deadline = timestamp + XCTEST_STARTUP_DEADLINE_SECONDS
            return False
        if marker is None:
            return False
        test_name, action = marker.groups()
        if action != "started" and job.xctest_progress_sequence == 0:
            return False
        job.xctest_progress_sequence += 1
        job.xctest_last_progress_test = test_name
        job.xctest_last_progress_action = action
        job.xctest_last_progress_observed_at = progress_observed_at
        if action == "started":
            job.xctest_started_count += 1
            job.xctest_deadline_phase = "active-method"
            active_method_budget = self._set_xctest_active_method_budget_locked(job, test_name)
            job.xctest_progress_deadline = timestamp + active_method_budget
            if job.xctest_current_test and job.xctest_current_test != test_name:
                job.xctest_previous_test = job.xctest_current_test
            job.xctest_current_test = test_name
        else:
            job.xctest_deadline_phase = "between-method"
            job.xctest_progress_deadline = timestamp + XCTEST_BETWEEN_METHOD_DEADLINE_SECONDS
            job.xctest_previous_test = test_name
            if job.xctest_current_test == test_name:
                job.xctest_current_test = None
        return True

    def _claim_xctest_stall_locked(
        self,
        job: Job,
        observed_at: Optional[float] = None,
    ) -> Optional[XCTestStallClaim]:
        if (
            not self._xctest_watchdog_enabled(job)
            or job.xctest_watchdog_triggered
            or job.xctest_output_failure is not None
        ):
            return None
        timestamp = time.monotonic() if observed_at is None else observed_at
        deadline = job.xctest_progress_deadline
        if deadline is None or timestamp < deadline:
            return None
        phase = job.xctest_deadline_phase or "startup"
        thresholds = {
            "startup": XCTEST_STARTUP_DEADLINE_SECONDS,
            "active-method": (
                job.xctest_active_method_budget_seconds
                if job.xctest_active_method_budget_seconds is not None
                else XCTEST_ACTIVE_METHOD_DEADLINE_SECONDS
            ),
            "between-method": XCTEST_BETWEEN_METHOD_DEADLINE_SECONDS,
        }
        threshold_seconds = thresholds.get(phase, XCTEST_STARTUP_DEADLINE_SECONDS)
        active_test = job.xctest_current_test if phase == "active-method" else None
        active_label = active_test or "<none>"
        budget_source = job.xctest_active_method_budget_source if phase == "active-method" else None
        job.xctest_watchdog_triggered = True
        job.measurement_invalid = True
        if phase == "active-method":
            job.error = (
                f"XCTest ACTIVE-METHOD deadline fired; active test method={active_label}; "
                f"budget={threshold_seconds:.3f}s; budget source={budget_source or 'default'}"
            )
        else:
            job.error = (
                f"XCTest {phase.upper()} deadline fired after {threshold_seconds:.3f}s; "
                f"active test method={active_label}"
            )
        return XCTestStallClaim(
            phase=phase,
            progress_transport=job.progress_transport or "pty",
            progress_sequence=job.xctest_progress_sequence,
            last_progress_test=job.xctest_last_progress_test,
            last_progress_action=job.xctest_last_progress_action,
            last_progress_observed_at=job.xctest_last_progress_observed_at,
            threshold_seconds=threshold_seconds,
            budget_source=budget_source,
            current_test=active_test,
            previous_test=job.xctest_previous_test,
            wake_probe=phase == "active-method" and bool(job.args.get("xctestStallWakeProbe")),
            triggered_at=timestamp,
        )

    def _monitor_xctest_stall(self, ticket: str) -> None:
        while True:
            with self.condition:
                job = self.jobs.get(ticket)
                if (
                    job is None
                    or job.state != "running"
                    or job.xctest_watchdog_triggered
                    or job.xctest_process_finished
                ):
                    return
                if job.xctest_output_failure is not None:
                    # OD16: the reader failed the job; terminate it here so the
                    # reader keeps draining output until EOF.
                    job.xctest_watchdog_triggered = True
                    break
                deadline = job.xctest_progress_deadline
                if deadline is None:
                    self.condition.wait()
                    continue
                remaining = deadline - time.monotonic()
                if remaining > 0:
                    self.condition.wait(timeout=remaining)
                    continue
                claim = self._claim_xctest_stall_locked(job)
                if claim is None:
                    continue
            self._handle_xctest_stall(ticket, claim)
            return
        self._terminate_xctest_stalled_job(job, cleanup="XCTest output contract failure")

    def _xctest_process_snapshot_locked(
        self,
        job: Job,
    ) -> Tuple[Optional[Tuple[int, str]], List[Dict[str, Any]]]:
        verified, depths = self._refresh_process_tree_locked(job)
        commands = process_command_snapshot(verified.keys())
        entries: List[Dict[str, Any]] = []
        matches: List[Tuple[int, int, str]] = []
        for pid in sorted(verified, key=lambda candidate: (depths.get(candidate, 0), candidate)):
            ppid, start_token = verified[pid]
            command = commands.get(pid, "")
            entry = {
                "pid": pid,
                "ppid": ppid,
                "depth": depths.get(pid, 0),
                "startToken": start_token,
                "command": command[:500],
            }
            if len(entries) < XCTEST_STALL_DIAGNOSTIC_MAX_PROCESSES:
                entries.append(entry)
            if is_xctest_process_command(command):
                matches.append((depths.get(pid, 0), pid, start_token))
        if not matches:
            return None, entries
        _depth, pid, start_token = max(matches)
        return (pid, start_token), entries

    def _signal_process_identity(self, pid: int, start_token: str, sig: signal.Signals) -> bool:
        confirmation = process_table_snapshot().get(pid)
        if confirmation is None or confirmation[1] != start_token:
            return False
        try:
            os.kill(pid, sig)
            return True
        except (ProcessLookupError, PermissionError, OSError):
            return False

    @staticmethod
    def _bound_diagnostic_file(path: Path, max_bytes: int = XCTEST_STALL_SAMPLE_MAX_BYTES) -> None:
        try:
            data = path.read_bytes()
        except OSError:
            return
        if len(data) <= max_bytes:
            return
        marker = b"\n... conductor truncated bounded XCTest stall diagnostic ...\n"
        payload_bytes = max(0, max_bytes - len(marker))
        head_bytes = payload_bytes // 2
        tail_bytes = payload_bytes - head_bytes
        path.write_bytes(data[:head_bytes] + marker + data[-tail_bytes:])

    def _capture_xctest_stall_diagnostics(
        self,
        job: Job,
        diagnostic: Dict[str, Any],
        xctest_identity: Optional[Tuple[int, str]],
    ) -> Dict[str, Any]:
        snapshot_path = self.paths.jobs_dir / f"{job.ticket}.xctest-stall.json"
        diagnostic["processSnapshotPath"] = str(snapshot_path)
        try:
            snapshot_path.write_text(json.dumps(diagnostic, indent=2, sort_keys=True), encoding="utf-8")
            self._bound_diagnostic_file(snapshot_path)
            job.diagnostic_paths.append(snapshot_path)
        except OSError as exc:
            diagnostic["processSnapshotError"] = str(exc)

        if xctest_identity is None:
            return diagnostic
        pid, _start_token = xctest_identity
        sample_path = self.paths.jobs_dir / f"{job.ticket}.xctest-stall.sample.txt"
        diagnostic["samplePath"] = str(sample_path)
        try:
            completed = subprocess.run(
                ["/usr/bin/sample", str(pid), "1", "10", "-file", str(sample_path)],
                text=True,
                capture_output=True,
                timeout=3.0,
            )
            diagnostic["sampleExitCode"] = completed.returncode
            if completed.stderr:
                diagnostic["sampleStderr"] = completed.stderr[-1000:]
            if sample_path.exists():
                self._bound_diagnostic_file(sample_path)
                job.diagnostic_paths.append(sample_path)
        except (OSError, subprocess.TimeoutExpired) as exc:
            diagnostic["sampleError"] = str(exc)
        return diagnostic

    def _wait_for_xctest_progress_after_probe(
        self,
        job: Job,
        progress_sequence: int,
        timeout: float = XCTEST_WAKE_PROGRESS_WAIT_SECONDS,
    ) -> bool:
        deadline = time.monotonic() + min(timeout, XCTEST_WAKE_PROGRESS_WAIT_SECONDS)
        with self.condition:
            while job.state == "running" and job.xctest_progress_sequence <= progress_sequence:
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    break
                self.condition.wait(timeout=remaining)
            return job.xctest_progress_sequence > progress_sequence

    def _terminate_xctest_stalled_job(self, job: Job, cleanup: str = "XCTest phase deadline") -> None:
        with self.condition:
            if job.state != "running":
                return
            self._terminate_process_group_locked(job, reason=job.error or f"{cleanup} fired")
            descendants_alive = self._wait_for_process_tree_exit_locked(
                job,
                now() + TERMINATE_GRACE_SECONDS,
                signal_for_new=signal.SIGTERM,
            )
            if descendants_alive:
                self._kill_process_group_locked(
                    job,
                    reason=f"{cleanup} cleanup; SIGKILL after grace period",
                )
                descendants_alive = self._wait_for_process_tree_exit_locked(
                    job,
                    now() + KILL_GRACE_SECONDS,
                    signal_for_new=signal.SIGKILL,
                )
            if descendants_alive:
                self._append_system_line_locked(
                    job,
                    "XCTest deadline watchdog cleanup could not confirm descendant exit after SIGKILL\n"
                    if cleanup == "XCTest phase deadline"
                    else f"{cleanup} cleanup could not confirm descendant exit after SIGKILL\n",
                )
            self.condition.notify_all()

    def _handle_xctest_stall(self, ticket: str, claim: XCTestStallClaim) -> None:
        with self.condition:
            job = self.jobs.get(ticket)
            if job is None:
                return
            xctest_identity, process_tree = self._xctest_process_snapshot_locked(job)
            diagnostic: Dict[str, Any] = {
                "kind": "xctest-phase-deadline",
                "phase": claim.phase,
                "capturedAt": now(),
                "thresholdSeconds": claim.threshold_seconds,
                "budgetSource": claim.budget_source,
                "progressTransport": claim.progress_transport,
                "progressSequence": claim.progress_sequence,
                "lastProgressTest": claim.last_progress_test,
                "lastProgressAction": claim.last_progress_action,
                "lastProgressObservedAt": claim.last_progress_observed_at,
                "currentTest": claim.current_test,
                "previousTest": claim.previous_test,
                "wakeProbeRequested": claim.wake_probe,
                "processTree": process_tree,
            }
            if xctest_identity is not None:
                diagnostic["xctestPID"] = xctest_identity[0]
                diagnostic["xctestStartToken"] = xctest_identity[1]
            current = claim.current_test or "<none>"
            previous = claim.previous_test or "<none>"
            if claim.phase == "active-method":
                deadline_line = (
                    f"XCTest ACTIVE-METHOD deadline triggered; active test method={current}; "
                    f"budget={claim.threshold_seconds:.3f}s; budget source={claim.budget_source or 'default'}; "
                    f"previous={previous}\n"
                )
            else:
                deadline_line = (
                    f"XCTest {claim.phase.upper()} deadline triggered after {claim.threshold_seconds:.3f}s; "
                    f"active test method={current}; previous={previous}\n"
                )
            self._append_system_line_locked(job, deadline_line)
            self._append_system_line_locked(job, "XCTest descendant process tree:\n")
            for entry in process_tree:
                self._append_system_line_locked(
                    job,
                    "  pid={pid} ppid={ppid} depth={depth} start={startToken} command={command}\n".format(**entry),
                )

        diagnostic = self._capture_xctest_stall_diagnostics(job, diagnostic, xctest_identity)
        resumed = False
        stop_sent = False
        continue_sent = False
        if claim.wake_probe and xctest_identity is not None:
            pid, start_token = xctest_identity
            stop_sent = self._signal_process_identity(pid, start_token, signal.SIGSTOP)
            if stop_sent:
                time.sleep(XCTEST_WAKE_PROBE_PAUSE_SECONDS)
                continue_sent = self._signal_process_identity(pid, start_token, signal.SIGCONT)
                if continue_sent:
                    resumed = self._wait_for_xctest_progress_after_probe(job, claim.progress_sequence)
        diagnostic["stopSent"] = stop_sent
        diagnostic["continueSent"] = continue_sent
        diagnostic["progressResumed"] = resumed
        snapshot_path_value = diagnostic.get("processSnapshotPath")
        if isinstance(snapshot_path_value, str):
            try:
                snapshot_path = Path(snapshot_path_value)
                snapshot_path.write_text(json.dumps(diagnostic, indent=2, sort_keys=True), encoding="utf-8")
                self._bound_diagnostic_file(snapshot_path)
            except OSError as exc:
                diagnostic["processSnapshotFinalWriteError"] = str(exc)
        with self.condition:
            job.diagnostics.append(diagnostic)
            self._append_system_line_locked(
                job,
                "XCTest stall wake probe result: "
                f"stopSent={stop_sent} continueSent={continue_sent} progressResumed={resumed}; "
                "measurement remains invalid\n",
            )
        self._terminate_xctest_stalled_job(job)

    def _refresh_output_summary(
        self,
        job: Job,
        complete_telemetry: bool = False,
        deadline: Optional[float] = None,
    ) -> None:
        """Summarize a terminal job's log once and publish the summary (single-flight).

        The first caller claims the work under ``self.condition`` and scans the
        log outside it; racing callers join the claimant's event and stop waiting
        at their own ``deadline`` (wall seconds; ``None`` waits for the result).
        Every exception publishes a minimal error summary and releases the claim.
        Claimant and joiners each pin the job against retention for the call.

        Timing never delays the summary: the published summary's duration is
        stored with it (no recorder call) and only ``complete_telemetry`` (the
        job thread) finalizes and persists, after publication. Client request
        paths never wait on timing.
        """
        with self.condition:
            if job.output_summary is not None:
                claimed = False
                event = None
            elif job.summary_state == "running" and job.summary_event is not None:
                claimed = False
                event = job.summary_event
            else:
                claimed = True
                event = job.summary_event = threading.Event()
                job.summary_state = "running"
            if event is not None:
                self._pin_job_locked(job)
        if not claimed:
            if event is not None:
                try:
                    event.wait(None if deadline is None else max(0.0, deadline - now()))
                finally:
                    with self.condition:
                        self._unpin_job_locked(job)
            if complete_telemetry:
                self.complete_job_telemetry(job)
            return
        summary: Optional[Dict[str, Any]] = None
        summary_timing = None
        final_state = "failed"
        try:
            telemetry = job.telemetry
            if telemetry is not None:
                summary_start = time.monotonic_ns()
                summary_cpu_start = time.thread_time_ns()
            summary = OutputSummarizer.summarize_file(
                job.operation,
                job.args,
                job.state,
                job.exit_code,
                job.timed_out,
                job.log_path,
            )
            if telemetry is not None:
                summary_timing = (time.monotonic_ns() - summary_start, time.thread_time_ns() - summary_cpu_start)
            final_state = "complete"
        except BaseException as exc:
            summary = OutputSummarizer._minimal_summary(
                job.operation, job.state, job.exit_code, f"summary failed: {type(exc).__name__}: {exc}"
            )
            if not isinstance(exc, Exception):
                raise
        finally:
            with self.condition:
                if job.output_summary is None and summary is not None:
                    job.output_summary = summary
                    job.output_summary_timing = summary_timing
                job.summary_state = final_state
                self.condition.notify_all()
                self._unpin_job_locked(job)
            event.set()
        if complete_telemetry:
            self.complete_job_telemetry(job)

    def _publish_phase_metrics(self, job: Job, phase_metrics: Optional[Dict[str, Any]]) -> None:
        if phase_metrics is None:
            return
        with self.condition:
            if job.phase_metrics is None:
                job.phase_metrics = phase_metrics
                self.condition.notify_all()

    def _append_tail_locked(self, job: Job, text: str) -> None:
        job.tail.append_text(text)

    def _append_system_line_locked(self, job: Job, text: str) -> None:
        self._append_tail_locked(job, text)
        try:
            with job.log_path.open("ab") as handle:
                handle.write(text.encode("utf-8", errors="replace"))
        except OSError:
            pass

    def _write_running_processes_locked(self) -> None:
        processes = []
        for job in self.jobs.values():
            if job.state == "running" and (job.process_pid or job.process_pgid):
                processes.append(
                    {
                        "ticket": job.ticket,
                        "operation": job.operation,
                        "pid": job.process_pid,
                        "pgid": job.process_pgid,
                        "processStart": job.process_start,
                    }
                )
        payload = {"updatedAt": now(), "processes": processes}
        try:
            self.paths.running_processes_path.write_text(json.dumps(payload, indent=2, sort_keys=True), encoding="utf-8")
            with contextlib.suppress(OSError):
                os.chmod(self.paths.running_processes_path, 0o600)
        except OSError:
            pass

    def _cancel_running_job_locked(self, job: Job, reason: str) -> None:
        # Step 5: the condition waits below let ``_run_job`` finish and unpin; this
        # pin keeps the job (and its log) until the last cancellation write.
        self._pin_job_locked(job)
        try:
            pid_deadline = now() + 1.0
            while job.state == "running" and not job.process_pid and now() < pid_deadline:
                self.condition.wait(timeout=PROCESS_TREE_POLL_SECONDS)
            if job.state != "running":
                return
            self._terminate_process_group_locked(job, reason=reason)
            descendants_alive = self._wait_for_process_tree_exit_locked(
                job,
                now() + TERMINATE_GRACE_SECONDS,
                signal_for_new=signal.SIGTERM,
            )
            if descendants_alive:
                self._kill_process_group_locked(job, reason=f"{reason}; SIGKILL after grace period")
                self._wait_for_process_tree_exit_locked(
                    job,
                    now() + KILL_GRACE_SECONDS,
                    signal_for_new=signal.SIGKILL,
                )
            completion_deadline = now() + KILL_GRACE_SECONDS
            while job.state == "running" and now() < completion_deadline:
                self.condition.wait(timeout=PROCESS_TREE_POLL_SECONDS)
        finally:
            self._unpin_job_locked(job)

    def _refresh_process_tree_locked(self, job: Job) -> Tuple[Dict[int, Tuple[int, str]], Dict[int, int]]:
        snapshot = process_table_snapshot()
        root_pid = job.process_pid
        if root_pid and root_pid not in job.tracked_processes:
            record = snapshot.get(root_pid)
            token = job.process_start or (record[1] if record else None)
            if token:
                job.process_start = token
                job.tracked_processes[root_pid] = token

        live_tracked = {
            pid
            for pid, token in job.tracked_processes.items()
            if snapshot.get(pid) is not None and snapshot[pid][1] == token
        }
        children_by_parent: Dict[int, List[int]] = {}
        for pid, (ppid, _token) in snapshot.items():
            children_by_parent.setdefault(ppid, []).append(pid)

        depths: Dict[int, int] = {pid: 0 for pid in live_tracked}
        queue: Deque[int] = deque(live_tracked)
        while queue:
            parent = queue.popleft()
            parent_depth = depths[parent]
            for child in children_by_parent.get(parent, []):
                child_record = snapshot.get(child)
                if child_record is None:
                    continue
                child_token = child_record[1]
                if job.tracked_processes.get(child) != child_token:
                    job.tracked_processes[child] = child_token
                next_depth = parent_depth + 1
                if next_depth > depths.get(child, -1):
                    depths[child] = next_depth
                    queue.append(child)

        verified = {
            pid: snapshot[pid]
            for pid, token in job.tracked_processes.items()
            if snapshot.get(pid) is not None and snapshot[pid][1] == token
        }
        for pid in verified:
            depths.setdefault(pid, 0)
        return verified, depths

    def _signal_verified_processes_locked(
        self,
        job: Job,
        sig: signal.Signals,
        verified: Dict[int, Tuple[int, str]],
        depths: Dict[int, int],
    ) -> int:
        confirmation = process_table_snapshot()
        signaled = 0
        for pid in sorted(verified, key=lambda candidate: (depths.get(candidate, 0), candidate), reverse=True):
            token = job.tracked_processes.get(pid)
            if not token or confirmation.get(pid) is None or confirmation[pid][1] != token:
                continue
            try:
                os.kill(pid, sig)
                signaled += 1
            except (ProcessLookupError, PermissionError, OSError):
                continue
        return signaled

    def _signal_process_tree_locked(self, job: Job, sig: signal.Signals) -> int:
        verified, depths = self._refresh_process_tree_locked(job)
        return self._signal_verified_processes_locked(job, sig, verified, depths)

    def _process_tree_alive_locked(self, job: Job) -> bool:
        verified, _depths = self._refresh_process_tree_locked(job)
        return bool(verified)

    def _verified_process_group_members_locked(
        self,
        job: Job,
        pgid: int,
    ) -> Dict[int, Tuple[int, str]]:
        group_members = process_group_snapshot(pgid)
        root_pid = job.process_pid
        if root_pid is not None:
            root_record = process_table_snapshot().get(root_pid)
            expected_root_start = job.process_start or job.tracked_processes.get(root_pid)
            if root_record is not None and (
                not expected_root_start
                or root_record[1] != expected_root_start
                or root_pid not in group_members
            ):
                return {}
        if root_pid is not None and root_pid in group_members:
            expected_start = job.process_start or job.tracked_processes.get(root_pid)
            if expected_start and group_members[root_pid][1] != expected_start:
                return {}
            if expected_start:
                job.tracked_processes[root_pid] = expected_start
        elif not job.process_group_identity_confirmed:
            return {}

        verified_members = {
            pid: record
            for pid, record in group_members.items()
            if job.tracked_processes.get(pid) == record[1]
        }
        if root_pid is not None and root_pid in verified_members:
            for pid, (_ppid, start_token) in group_members.items():
                job.tracked_processes[pid] = start_token
            verified_members = dict(group_members)
        if verified_members:
            job.process_group_identity_confirmed = True
        return verified_members

    def _process_group_id_alive_locked(self, job: Job) -> bool:
        try:
            pgid = int(job.process_pgid) if job.process_pgid is not None else 0
        except (TypeError, ValueError):
            return False
        if pgid <= 0:
            return False
        with contextlib.suppress(OSError):
            if pgid == os.getpgrp():
                return False
        return bool(self._verified_process_group_members_locked(job, pgid))

    def _wait_for_process_tree_exit_locked(
        self,
        job: Job,
        deadline: float,
        signal_for_new: signal.Signals,
    ) -> bool:
        while now() < deadline:
            verified, depths = self._refresh_process_tree_locked(job)
            if not verified:
                if not self._process_group_id_alive_locked(job):
                    return False
                self._signal_process_group_id_locked(job, signal_for_new)
                self.condition.wait(timeout=min(PROCESS_TREE_POLL_SECONDS, max(0.0, deadline - now())))
                continue
            self._signal_verified_processes_locked(job, signal_for_new, verified, depths)
            self.condition.wait(timeout=min(PROCESS_TREE_POLL_SECONDS, max(0.0, deadline - now())))
        return self._process_tree_alive_locked(job) or self._process_group_id_alive_locked(job)

    def _signal_process_group_id_locked(self, job: Job, sig: signal.Signals) -> bool:
        try:
            pgid = int(job.process_pgid) if job.process_pgid is not None else 0
        except (TypeError, ValueError):
            return False
        if pgid <= 0:
            return False
        with contextlib.suppress(OSError):
            if pgid == os.getpgrp():
                return False

        if not self._verified_process_group_members_locked(job, pgid):
            self._append_system_line_locked(
                job,
                f"refusing to signal process group {pgid}: recorded child identity no longer matches\n",
            )
            return False
        try:
            os.killpg(pgid, sig)
            return True
        except (ProcessLookupError, PermissionError, OSError):
            return False

    def _terminate_process_group_locked(self, job: Job, reason: str) -> None:
        ancestry_snapshot, depths = self._refresh_process_tree_locked(job)
        if self._signal_process_group_id_locked(job, signal.SIGTERM):
            self._append_system_line_locked(job, f"terminating process group: {reason}\n")
        self._append_system_line_locked(job, f"terminating process tree: {reason}\n")
        self._signal_verified_processes_locked(
            job,
            signal.SIGTERM,
            ancestry_snapshot,
            depths,
        )

    def _kill_escaped_descendants_locked(
        self,
        job: Job,
        ancestry_snapshot: Dict[int, Tuple[int, str]],
        depths: Dict[int, int],
    ) -> None:
        confirmation = process_table_snapshot()
        escapees = {
            pid: confirmation[pid]
            for pid, (_ppid, start_token) in ancestry_snapshot.items()
            if confirmation.get(pid) is not None and confirmation[pid][1] == start_token
        }
        if not escapees:
            return
        commands = process_command_snapshot(escapees.keys())
        group_members: set[int] = set()
        setsid_escapees: set[int] = set()
        unclassified: set[int] = set()
        for pid in escapees:
            try:
                if job.process_pgid is not None and os.getpgid(pid) == job.process_pgid:
                    group_members.add(pid)
                else:
                    setsid_escapees.add(pid)
            except (ProcessLookupError, PermissionError, OSError):
                unclassified.add(pid)
        self._append_system_line_locked(
            job,
            f"found {len(group_members)} unreaped process-group member(s) (expected) and "
            f"{len(setsid_escapees)} genuine setsid escapee(s), with {len(unclassified)} "
            "descendant identity unavailable after process-group SIGKILL\n",
        )
        for pid in sorted(escapees):
            if pid in group_members:
                label = "unreaped group member"
            elif pid in setsid_escapees:
                label = "setsid escapee"
            else:
                label = "unclassified descendant"
            self._append_system_line_locked(
                job,
                f"  {label} pid={pid} command={commands.get(pid, '')[:500]}\n",
            )
        killed = self._signal_verified_processes_locked(job, signal.SIGKILL, escapees, depths)
        self._append_system_line_locked(job, f"SIGKILL sent to {killed} remaining descendant(s)\n")

    def _kill_process_group_locked(self, job: Job, reason: str) -> None:
        ancestry_snapshot, depths = self._refresh_process_tree_locked(job)
        if self._signal_process_group_id_locked(job, signal.SIGKILL):
            self._append_system_line_locked(job, f"killing process group: {reason}\n")
        self._append_system_line_locked(job, f"killing process tree: {reason}\n")
        self._kill_escaped_descendants_locked(job, ancestry_snapshot, depths)
        self._signal_process_tree_locked(job, signal.SIGKILL)

    def _retention_pass_locked(self) -> None:
        """Decide evictions in memory only (24 h / ``MAX_TERMINAL_JOBS``); never touch the filesystem.

        Runs under ``self.condition`` on every transition. An evicted job's exact
        generated files are handed to the maintenance worker, which also runs a
        coalesced orphan sweep at most once per ``ORPHAN_SWEEP_INTERVAL_SECONDS``.
        A pinned job is never evicted; its last unpin reruns this pass. An
        evicted ticket then reads as unknown, as before.
        """
        cutoff = now() - TERMINAL_RETENTION_SECONDS
        terminal = [job for job in self.jobs.values() if job.state in TERMINAL_STATES]
        prune: set[str] = set()
        due: List[Job] = []
        for job in terminal:
            if job.finished_at is not None and job.finished_at < cutoff:
                due.append(job)
        terminal_sorted = sorted(terminal, key=lambda job: job.finished_at or job.created_at)
        excess = max(0, len(terminal_sorted) - MAX_TERMINAL_JOBS)
        due.extend(terminal_sorted[:excess])
        for job in due:
            if job.summary_pins > 0:
                # Summary work, timing finalization, a job-owned writer or a
                # status/wait payload still uses this job and its files; the
                # last unpin reruns this pass.
                job.retention_deferred = True
            else:
                prune.add(job.ticket)
        removals: List[Tuple[str, Tuple[Path, ...]]] = []
        for ticket in prune:
            job = self.jobs.pop(ticket, None)
            if not job:
                continue
            removals.append(
                (
                    ticket,
                    (
                        job.log_path,
                        *job.diagnostic_paths,
                        *(self.paths.jobs_dir / f"{ticket}{suffix}" for suffix in TIMING_FILE_SUFFIXES),
                    ),
                )
            )
            for key, mapped_ticket in list(self.request_keys.items()):
                if mapped_ticket == ticket:
                    del self.request_keys[key]
        self._signal_maintenance_locked(removals)

    # -- Step 5 maintenance worker ---------------------------------------------
    # Signaled by retention passes; started on demand and exits when no work is
    # due, so at most one runs per daemon. It never holds ``self.condition``
    # while it scans, stats or unlinks. Failures are retried by later sweeps,
    # recorded only in ``_maintenance_error`` and never change a job.

    def _orphan_sweep_due_locked(self, monotonic_now: float) -> bool:
        """Under ``_maintenance_cv``: a requested sweep whose interval has elapsed."""
        return self._orphan_sweep_requested and (
            self._last_orphan_sweep is None
            or monotonic_now - self._last_orphan_sweep >= ORPHAN_SWEEP_INTERVAL_SECONDS
        )

    def _signal_maintenance_locked(self, removals: Sequence[Tuple[str, Tuple[Path, ...]]]) -> None:
        """Queue exact removals, request a sweep and wake (or start) the worker; no I/O."""
        with self._maintenance_cv:
            self._maintenance_items.extend(removals)
            self._orphan_sweep_requested = True
            if self._maintenance_thread is not None:
                # The running worker re-checks for due work before it exits.
                self._maintenance_cv.notify_all()
                return
            if not self._maintenance_items and not self._orphan_sweep_due_locked(time.monotonic()):
                return  # coalesced: the request waits for a later signal once due
            thread = threading.Thread(target=self._maintenance_loop, name="conductor-maintenance", daemon=True)
            self._maintenance_thread = thread
            try:
                thread.start()
            except Exception as exc:  # noqa: BLE001 - cleanup never changes the lifecycle
                # Work stays queued; the next signal tries to start a worker again.
                self._maintenance_thread = None
                self._maintenance_error = f"maintenance worker not started: {type(exc).__name__}: {exc}"[:256]

    def _maintenance_loop(self) -> None:
        current = threading.current_thread()
        try:
            while True:
                with self._maintenance_cv:
                    monotonic_now = time.monotonic()
                    sweep = self._orphan_sweep_due_locked(monotonic_now)
                    if not self._maintenance_items and not sweep:
                        self._maintenance_thread = None
                        self._maintenance_cv.notify_all()
                        return
                    work = [
                        (ticket, path) for ticket, paths in self._maintenance_items for path in paths
                    ]
                    self._maintenance_items = []
                    if sweep:
                        self._orphan_sweep_requested = False
                        self._last_orphan_sweep = monotonic_now
                        work.extend((ticket, path) for path, ticket in self._maintenance_retry.items())
                        self._maintenance_retry.clear()
                    self._maintenance_busy = True
                failed: List[Tuple[str, Path]] = []
                sweep_failed = False
                error: Optional[str] = None
                try:
                    for ticket, path in work:
                        if not self._unlink_generated_job_file(ticket, path):
                            failed.append((ticket, path))
                    if sweep:
                        sweep_failed = not self._sweep_orphaned_job_files()
                except Exception as exc:  # noqa: BLE001 - retried by a later sweep
                    error = f"{type(exc).__name__}: {exc}"[:256]
                    failed = work
                    sweep_failed = sweep
                finally:
                    with self._maintenance_cv:
                        self._maintenance_busy = False
                        for ticket, path in failed:
                            self._maintenance_retry[path] = ticket
                        while len(self._maintenance_retry) > MAINTENANCE_RETRY_LIMIT:
                            # Oldest first; an aged orphan is still caught by name.
                            del self._maintenance_retry[next(iter(self._maintenance_retry))]
                        if failed or sweep_failed:
                            self._orphan_sweep_requested = True
                            self._maintenance_error = error or "cleanup incomplete; retried by a later sweep"
                        self._maintenance_cv.notify_all()
        finally:
            with self._maintenance_cv:
                if self._maintenance_thread is current:
                    self._maintenance_thread = None
                self._maintenance_busy = False
                self._maintenance_cv.notify_all()

    def _unlink_generated_job_file(self, ticket: str, path: Path) -> bool:
        """Remove one exact generated file of ``ticket``; ``False`` means retry later."""
        if path.parent != self.paths.jobs_dir or path.name not in {
            f"{ticket}{suffix}" for suffix in GENERATED_JOB_FILE_SUFFIXES
        }:
            return True  # not a generated file of this ticket: never deleted
        try:
            path.unlink()
        except FileNotFoundError:
            pass
        except OSError:
            return False
        return True

    def _sweep_orphaned_job_files(self) -> bool:
        """Remove aged generated files of tickets the daemon no longer holds; ``False`` means retry later."""
        with self.condition:
            retained = set(self.jobs)  # in-memory snapshot only
        cutoff = now() - TERMINAL_RETENTION_SECONDS
        complete = True
        try:
            entries = list(os.scandir(self.paths.jobs_dir))
        except FileNotFoundError:
            return True
        except OSError:
            return False
        for entry in entries:
            ticket = generated_job_file_ticket(entry.name)
            if ticket is None or ticket in retained:
                continue
            try:
                if entry.is_dir(follow_symlinks=False) or entry.stat(follow_symlinks=False).st_mtime >= cutoff:
                    continue
            except OSError:
                continue
            try:
                os.unlink(entry.path)
            except FileNotFoundError:
                pass
            except OSError:
                complete = False
        return complete

    def _await_maintenance(self, timeout: float) -> bool:
        """Private drain for tests, qualification and daemon exit; never on a client path.

        Waits until no worker runs; ``True`` when no queued removal remains.
        A sweep that is requested but not yet due is not waited for.
        """
        deadline = time.monotonic() + timeout
        with self._maintenance_cv:
            while self._maintenance_thread is not None or self._maintenance_busy:
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    return False
                self._maintenance_cv.wait(min(remaining, 0.1))
            return not self._maintenance_items

class ThreadedUnixServer(socketserver.ThreadingMixIn, socketserver.UnixStreamServer):
    daemon_threads = True
    allow_reuse_address = True

    def __init__(self, server_address: str, handler_cls: Any, state: DaemonState) -> None:
        self.state = state
        super().__init__(server_address, handler_cls)


class RequestHandler(socketserver.StreamRequestHandler):
    def handle(self) -> None:
        state: DaemonState = self.server.state  # type: ignore[attr-defined]
        request_id = "unknown"
        try:
            raw = self.rfile.readline(10 * 1024 * 1024)
            if not raw:
                return
            request = json.loads(raw.decode("utf-8"))
            request_id = str(request.get("id") or "unknown")
            payload = handle_request(state, request)
            response = {"id": request_id, "ok": True, "payload": payload}
        except Exception as exc:
            response = {
                "id": request_id,
                "ok": False,
                "error": str(exc),
                "errorType": type(exc).__name__,
            }
        self.wfile.write((json.dumps(response) + "\n").encode("utf-8"))
        self.wfile.flush()


def handle_request(state: DaemonState, request: Dict[str, Any]) -> Dict[str, Any]:
    req_type = request.get("type")
    if req_type == "status":
        return state.status_payload()
    if req_type == "stop":
        return state.stop(force=bool(request.get("force")))
    if req_type == "enqueue":
        return state.enqueue(request)
    if req_type == "job-list":
        return state.list_jobs(request.get("state"))
    if req_type == "job-status":
        return state.job_status(request.get("ticket"), request.get("requestKey"))
    if req_type == "job-wait":
        timeout = request.get("timeout")
        if timeout is not None and float(timeout) < 0:
            raise ConductorError("wait timeout must be non-negative")
        return state.job_wait(
            request.get("ticket"),
            request.get("requestKey"),
            float(timeout) if timeout is not None else None,
        )
    if req_type == "job-cancel":
        return state.job_cancel(request.get("ticket"), request.get("requestKey"))
    raise ConductorError(f"unknown protocol request type '{req_type}'")


def run_daemon(paths: Paths) -> int:
    ensure_state_dirs(paths)
    with contextlib.suppress(FileNotFoundError):
        paths.socket_path.unlink()
    paths.pid_path.write_text(f"{os.getpid()}\n", encoding="utf-8")
    with contextlib.suppress(OSError):
        os.chmod(paths.pid_path, 0o600)
    write_daemon_metadata(paths)
    paths.running_processes_path.write_text(json.dumps({"updatedAt": now(), "processes": []}, indent=2), encoding="utf-8")
    with contextlib.suppress(OSError):
        os.chmod(paths.running_processes_path, 0o600)
    state = DaemonState(paths)
    server = ThreadedUnixServer(str(paths.socket_path), RequestHandler, state)
    with contextlib.suppress(OSError):
        os.chmod(paths.socket_path, 0o600)
    state.server = server

    def _signal_stop(signum: int, _frame: Any) -> None:
        with state.condition:
            state.shutdown_requested = True
            for job in state.jobs.values():
                if job.state == "running":
                    job.cancel_requested = True
                    state._terminate_process_group_locked(job, reason=f"signal {signum}")
            state.condition.notify_all()
        threading.Thread(target=server.shutdown, daemon=True).start()

    signal.signal(signal.SIGTERM, _signal_stop)
    signal.signal(signal.SIGINT, _signal_stop)
    try:
        server.serve_forever(poll_interval=0.2)
    finally:
        server.server_close()
        metadata = read_daemon_metadata(paths)
        owns_daemon_files = read_pid(paths.pid_path) == os.getpid() and metadata.get("pid") == os.getpid()
        if owns_daemon_files:
            for path in (paths.socket_path, paths.pid_path, paths.daemon_meta_path, paths.running_processes_path):
                with contextlib.suppress(FileNotFoundError):
                    path.unlink()
        # After the files are gone, so ``daemon stop`` timing is unchanged: let
        # already-started timing persistence finish (bounded; optional data).
        with contextlib.suppress(Exception):
            state._await_job_telemetry(TIMING_DRAIN_SECONDS)
        # Then let queued retention removals finish (bounded); anything left is
        # an aged orphan for a later daemon's sweep.
        with contextlib.suppress(Exception):
            state._await_maintenance(TIMING_DRAIN_SECONDS)
    return 0


def format_argv(argv: Sequence[str]) -> str:
    import shlex

    return " ".join(shlex.quote(part) for part in argv)


def request_daemon(paths: Paths, payload: Dict[str, Any], timeout: Optional[float] = None) -> Dict[str, Any]:
    request = dict(payload)
    request.setdefault("id", str(uuid.uuid4()))
    data = (json.dumps(request) + "\n").encode("utf-8")
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        sock.settimeout(timeout or 30.0)
        sock.connect(str(paths.socket_path))
        sock.sendall(data)
        file = sock.makefile("rb")
        line = file.readline()
        if not line:
            raise ConductorError("daemon closed connection without a response")
        response = json.loads(line.decode("utf-8"))
    except (FileNotFoundError, ConnectionRefusedError, socket.timeout, OSError) as exc:
        raise ConductorError(f"could not contact daemon at {paths.socket_path}: {exc}")
    finally:
        sock.close()
    if not response.get("ok"):
        message = response.get("error") or "daemon request failed"
        if response.get("errorType") == "ArtifactUnavailableError":
            raise ArtifactUnavailableError(message)
        raise ConductorError(message)
    return response.get("payload") or {}


def compatible_daemon_status_or_stop_idle_mismatch(paths: Paths) -> Tuple[Optional[Dict[str, Any]], Optional[ConductorError]]:
    try:
        payload = request_daemon(paths, {"type": "status"}, timeout=1.0)
    except ConductorError as exc:
        return None, exc

    protocol = payload.get("protocolVersion")
    if protocol == PROTOCOL_VERSION:
        return payload, None

    active = payload.get("runningJobs") or []
    queued = payload.get("queuedJobs") or []
    if active or queued:
        raise ConductorError(
            f"daemon protocol mismatch (daemon={protocol}, client={PROTOCOL_VERSION}) and jobs are active; "
            "run './conductor daemon stop --force' after deciding it is safe"
        )
    try:
        request_daemon(paths, {"type": "stop", "force": False}, timeout=FORCE_STOP_RPC_TIMEOUT_SECONDS)
    except ConductorError as exc:
        raise ConductorError(
            f"daemon protocol mismatch (daemon={protocol}, client={PROTOCOL_VERSION}) could not stop without force; "
            "jobs may have become active. Run './conductor daemon stop --force' after deciding it is safe"
        ) from exc
    if not wait_until_stopped(paths, timeout=TERMINATE_GRACE_SECONDS + 5.0):
        raise ConductorError(
            f"daemon protocol mismatch (daemon={protocol}, client={PROTOCOL_VERSION}) did not stop cleanly; "
            "run './conductor daemon stop --force' after deciding it is safe"
        )
    return None, None


def daemon_launchd_label(paths: Paths) -> str:
    return f"com.repoprompt.ce.conductor.{paths.repo_hash[:16]}"


def daemon_launchd_plist_path(paths: Paths) -> Path:
    return paths.state_dir / f"{daemon_launchd_label(paths)}.plist"


def run_launchctl(args: Sequence[str]) -> int:
    try:
        completed = subprocess.run(
            ["launchctl", *args],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            check=False,
        )
    except OSError:
        return 127
    return completed.returncode


def bootout_daemon_launchd(paths: Paths) -> None:
    uid = os.getuid()
    run_launchctl(["bootout", f"gui/{uid}/{daemon_launchd_label(paths)}"])


def daemon_launchd_environment(paths: Paths, environ: Optional[Mapping[str, str]] = None) -> Dict[str, str]:
    """The launchd job's environment: launchd does not inherit the client's.

    The timing kill switch is forwarded verbatim when the client sets it; it
    never enters job request identity or job child environments.
    """
    source = os.environ if environ is None else environ
    env = {
        "REPOPROMPT_DEV_DAEMON_STATE_DIR": str(paths.state_dir),
        "REPOPROMPT_DEV_DAEMON_SOCKET": str(paths.socket_path),
    }
    setting = source.get(TIMING_ENV_KEY)
    if setting is not None:
        env[TIMING_ENV_KEY] = setting
    return env


def daemon_timing_source(payload: Dict[str, Any]) -> str:
    """Why a daemon status payload has its timing mode, as read at daemon start."""
    timing = payload.get("timing") if isinstance(payload.get("timing"), dict) else {}
    if timing.get("helperLoaded") is False:
        return "timing helper not loaded"
    setting = timing.get("setting")
    return f"{TIMING_ENV_KEY}={setting}" if setting is not None else f"{TIMING_ENV_KEY} unset"


def requested_timing_enabled(environ: Optional[Mapping[str, str]] = None) -> bool:
    """The timing mode this client's environment would give a newly started daemon."""
    source = os.environ if environ is None else environ
    return source.get(TIMING_ENV_KEY, "").strip().lower() != "off"


def daemon_timing_notice(payload: Dict[str, Any], environ: Optional[Mapping[str, str]] = None) -> Optional[str]:
    """Explain a running daemon whose timing mode differs from this client's request.

    The mode is read only at daemon start; a running daemon is never restarted
    implicitly (that could cancel jobs), so the operator decides.
    """
    running = payload.get("timingEnabled")
    if not isinstance(running, bool):
        return None
    requested = requested_timing_enabled(environ)
    if requested == running:
        return None
    started_with = daemon_timing_source(payload)
    wanted = "enabled" if requested else "disabled"
    return (
        f"timing: the running daemon (pid {payload.get('pid')}) has timing "
        f"{'enabled' if running else 'disabled'} ({started_with} at its start); this environment asks for {wanted}. "
        "The mode is read only at daemon start and the daemon was not restarted. To change it, stop the idle daemon "
        f"('./conductor daemon stop') and start it again with the desired {TIMING_ENV_KEY}."
    )


def write_daemon_launchd_plist(paths: Paths, script: Path) -> Path:
    plist_path = daemon_launchd_plist_path(paths)
    payload = {
        "Label": daemon_launchd_label(paths),
        "ProgramArguments": [
            sys.executable,
            str(script),
            "__daemon",
            "--repo-root",
            str(paths.repo_root),
        ],
        "ProcessType": "Interactive",
        "RunAtLoad": True,
        "KeepAlive": False,
        "WorkingDirectory": str(paths.repo_root),
        "StandardOutPath": str(paths.daemon_log_path),
        "StandardErrorPath": str(paths.daemon_log_path),
        "EnvironmentVariables": daemon_launchd_environment(paths),
    }
    plist_path.write_bytes(plistlib.dumps(payload, fmt=plistlib.FMT_XML, sort_keys=False))
    with contextlib.suppress(OSError):
        os.chmod(plist_path, 0o600)
    return plist_path


def spawn_daemon_direct(paths: Paths, script: Path) -> None:
    with paths.daemon_log_path.open("ab") as daemon_log:
        daemon_log.write(
            b"WARNING: conductor daemon is running in a possibly QoS-clamped context.\n"
        )
        daemon_log.flush()
        subprocess.Popen(
            [sys.executable, str(script), "__daemon", "--repo-root", str(paths.repo_root)],
            cwd=str(paths.repo_root),
            stdin=subprocess.DEVNULL,
            stdout=daemon_log,
            stderr=subprocess.STDOUT,
            start_new_session=True,
        )


def spawn_daemon(paths: Paths, script: Path) -> None:
    if os.environ.get("REPOPROMPT_DEV_DAEMON_LAUNCHD") != "0":
        plist_path = write_daemon_launchd_plist(paths, script)
        bootout_daemon_launchd(paths)
        uid = os.getuid()
        if run_launchctl(["bootstrap", f"gui/{uid}", str(plist_path)]) == 0:
            return
    spawn_daemon_direct(paths, script)


def ensure_daemon(paths: Paths, start_if_needed: bool = True) -> Dict[str, Any]:
    ensure_state_dirs(paths)
    cleanup_stale_files(paths)
    contact_error: Optional[ConductorError] = None
    payload, contact_error = compatible_daemon_status_or_stop_idle_mismatch(paths)
    if payload is not None:
        return payload

    live_pid = read_pid(paths.pid_path)
    if contact_error and live_pid and pid_alive(live_pid):
        raise ConductorError(
            f"daemon pid {live_pid} is alive but the socket is unresponsive; "
            "run './conductor daemon stop --force' before starting a replacement"
        )

    if not start_if_needed:
        if contact_error:
            raise contact_error
        raise ConductorError("daemon is not running")

    with paths.lock_path.open("a+") as lock_file:
        fcntl.flock(lock_file.fileno(), fcntl.LOCK_EX)
        cleanup_stale_files(paths)
        payload, locked_contact_error = compatible_daemon_status_or_stop_idle_mismatch(paths)
        if payload is not None:
            return payload
        locked_live_pid = read_pid(paths.pid_path)
        if locked_contact_error and locked_live_pid and pid_alive(locked_live_pid):
            raise ConductorError(
                f"daemon pid {locked_live_pid} is alive but the socket is unresponsive; "
                "run './conductor daemon stop --force' before starting a replacement"
            )
        script = conductor_entry_script()
        spawn_daemon(paths, script)
        deadline = now() + STARTUP_TIMEOUT_SECONDS
        last_error: Optional[Exception] = None
        while now() < deadline:
            try:
                return request_daemon(paths, {"type": "status"}, timeout=0.5)
            except Exception as exc:  # wait until socket accepts
                last_error = exc
                time.sleep(0.1)
        raise ConductorError(
            f"daemon did not start within {STARTUP_TIMEOUT_SECONDS:.1f}s; "
            f"see {paths.daemon_log_path}" + (f" ({last_error})" if last_error else "")
        )


def wait_until_stopped(paths: Paths, timeout: float) -> bool:
    deadline = now() + timeout
    while now() < deadline:
        cleanup_stale_files(paths)
        if not paths.socket_path.exists() and not paths.pid_path.exists():
            return True
        time.sleep(0.1)
    return False


def read_running_processes(paths: Paths) -> List[Dict[str, Any]]:
    try:
        payload = json.loads(paths.running_processes_path.read_text(encoding="utf-8"))
    except (FileNotFoundError, json.JSONDecodeError, OSError):
        return []
    processes = payload.get("processes") if isinstance(payload, dict) else None
    return [item for item in processes if isinstance(item, dict)] if isinstance(processes, list) else []


def signal_running_process_groups(paths: Paths, sig: signal.Signals) -> None:
    for item in read_running_processes(paths):
        pgid = item.get("pgid") or item.get("pid")
        try:
            pgid_int = int(pgid)
        except (TypeError, ValueError):
            continue
        if pgid_int <= 0:
            continue
        with contextlib.suppress(ProcessLookupError, PermissionError, OSError):
            os.killpg(pgid_int, sig)


def force_stop_unresponsive_daemon(paths: Paths) -> Dict[str, Any]:
    pid = read_pid(paths.pid_path)
    if not pid or not pid_alive(pid):
        cleanup_stale_files(paths)
        return {"stopped": True, "pid": pid, "forced": True, "message": "no live daemon pid"}
    if not verify_daemon_pid_identity(paths, pid):
        raise ConductorError(
            f"refusing to force-stop pid {pid}: daemon identity could not be verified; "
            f"inspect {paths.pid_path} and {paths.daemon_meta_path} before removing stale files manually"
        )
    signal_running_process_groups(paths, signal.SIGTERM)
    with contextlib.suppress(ProcessLookupError, PermissionError, OSError):
        os.kill(pid, signal.SIGTERM)
    deadline = now() + TERMINATE_GRACE_SECONDS
    while pid_alive(pid) and now() < deadline:
        time.sleep(0.1)
    if pid_alive(pid):
        signal_running_process_groups(paths, signal.SIGKILL)
        with contextlib.suppress(ProcessLookupError, PermissionError, OSError):
            os.kill(pid, signal.SIGKILL)
        deadline = now() + 2.0
        while pid_alive(pid) and now() < deadline:
            time.sleep(0.1)
    if pid_alive(pid):
        raise ConductorError(f"force-stop signaled verified daemon pid {pid}, but it is still alive; leaving pid/socket files intact")
    cleanup_stale_files(paths)
    with contextlib.suppress(FileNotFoundError):
        paths.socket_path.unlink()
    with contextlib.suppress(FileNotFoundError):
        paths.pid_path.unlink()
    with contextlib.suppress(FileNotFoundError):
        paths.daemon_meta_path.unlink()
    with contextlib.suppress(FileNotFoundError):
        paths.running_processes_path.unlink()
    return {"stopped": True, "pid": pid, "forced": True, "socketPath": str(paths.socket_path), "stateDir": str(paths.state_dir)}


def parse_json_flag(argv: List[str]) -> Tuple[bool, List[str]]:
    json_mode = False
    remaining: List[str] = []
    for arg in argv:
        if arg == "--json":
            json_mode = True
        else:
            remaining.append(arg)
    return json_mode, remaining


def render_daemon_status(payload: Dict[str, Any], shorthand: bool = False) -> None:
    print(f"conductor daemon running (pid {payload.get('pid')})")
    print(f"protocol: {payload.get('protocolVersion')}")
    print(f"socket:   {payload.get('socketPath')}")
    print(f"state:    {payload.get('stateDir')}")
    if isinstance(payload.get("timingEnabled"), bool):
        mode = "enabled" if payload["timingEnabled"] else "disabled"
        print(f"timing:   {mode} ({daemon_timing_source(payload)} at daemon start)")
    active = payload.get("activeJobsByLane") or {}
    if active:
        print("active lanes:")
        for lane, job in active.items():
            run_for = None
            if job.get("startedAt"):
                run_for = max(0.0, now() - float(job.get("startedAt")))
            timing = f" run={format_duration(run_for)}" if run_for is not None else ""
            global_wait = job.get("globalHeavySlotWaitSeconds")
            if global_wait is not None:
                timing += f" global-wait={format_duration(float(global_wait))}"
            xctest_wait = job.get("xctestSlotWaitSeconds")
            if xctest_wait is not None:
                timing += f" xctest-wait={format_duration(float(xctest_wait))}"
            print(f"  {lane}: {job.get('ticket')} {job.get('operationLabel') or job.get('operation')} [{job.get('state')}]{timing}")
    else:
        print("active lanes: none")
    print(f"queued:   {payload.get('queueDepth', 0)}")
    print(f"retained terminal jobs: {payload.get('retainedTerminalCount', 0)}")
    if shorthand and payload.get("queuedJobs"):
        print("queued jobs:")
        for job in payload.get("queuedJobs") or []:
            queued_for = None
            if job.get("createdAt"):
                queued_for = max(0.0, now() - float(job.get("createdAt")))
            timing = f" queued={format_duration(queued_for)}" if queued_for is not None else ""
            print(f"  {job.get('ticket')} {job.get('operationLabel') or job.get('operation')} lanes={','.join(job.get('lanes') or [])}{timing}")


def render_superseded_jobs(payload: Dict[str, Any]) -> None:
    for job in payload.get("supersededJobs") or []:
        action = "Canceled" if job.get("cancellationState") == "canceled" else "Canceling"
        print(
            f"{action} older live-app work: {job.get('operationLabel')} {job.get('ticket')} "
            f"({job.get('priorState')})."
        )


def select_progress_lines(operation: str, lines: Sequence[str]) -> List[str]:
    selected: List[str] = []
    style_operation = operation in {"format", "format-check", "lint", "check-format-tools", "install-format-tools", "format-tools-status"}
    for raw_line in lines:
        line = clean_summary_line(str(raw_line))
        if not line:
            continue
        allowed = False
        if OutputSummarizer.PHASE_RE.search(line) or OutputSummarizer.ARTIFACT_RE.search(line) or OutputSummarizer.APP_LIFECYCLE_RE.search(line):
            allowed = True
        elif OutputSummarizer.TIMEOUT_RE.search(line) or OutputSummarizer.FAILURE_RE.search(line):
            allowed = True
        elif OutputSummarizer.TEST_FAILURE_RE.search(line) or OutputSummarizer.SWIFT_ERROR_RE.search(line):
            allowed = True
        elif style_operation and OutputSummarizer.STYLE_FINDING_RE.search(line):
            allowed = True
        if allowed:
            selected.append(line)
        if len(selected) >= PROGRESS_MAX_LINES_PER_POLL:
            break
    return selected


def _with_artifact_scope_summary(payload: Dict[str, Any], summary: Dict[str, Any]) -> Dict[str, Any]:
    scope = payload.get("artifactScope")
    if scope not in {"current", "stale"}:
        return summary
    if summary.get("artifactScope") == scope:
        return summary
    enriched = dict(summary)
    enriched["artifactScope"] = scope
    differences = list(payload.get("artifactScopeDifferences") or [])
    enriched["artifactScopeDifferences"] = differences
    passed = (
        scope == "stale"
        and payload.get("state") == "completed"
        and payload.get("exitCode") == 0
    )
    message = (
        artifact_scope_message(scope, differences, passed=passed)
        if scope == "stale"
        else str(payload.get("artifactScopeMessage") or "artifact_scope: current")
    )
    sections = list(enriched.get("sections") or [])
    detail = message
    sections.insert(
        0,
        {
            "title": "Artifact scope",
            "lines": [detail],
            "truncated": False,
            "omittedLineCount": 0,
            "deduplicationLimited": False,
            "omittedLineCountQuality": "exact",
            "displayedLinesMayRepeat": False,
        },
    )
    enriched["sections"] = sections
    if passed:
        enriched["headline"] = message
    return enriched


SUMMARY_PENDING_NOTE = "output summary is still being generated by the conductor; see the full log path above"


def output_summary_for_payload(payload: Dict[str, Any]) -> Dict[str, Any]:
    summary = payload.get("outputSummary")
    label = payload.get("operationLabel") or operation_display_name(str(payload.get("operation") or ""), payload.get("args") or {})
    requires_lifecycle_classification = label == "app relaunch" and payload.get("state") == "failed"
    if isinstance(summary, dict) and (not requires_lifecycle_classification or isinstance(summary.get("launchLifecycle"), dict)):
        return _with_artifact_scope_summary(payload, summary)
    log_path = payload.get("logPath")
    if payload.get("summaryPending") and not isinstance(summary, dict):
        # The daemon is scanning this log (single flight); never scan it again here.
        generated = OutputSummarizer._minimal_summary(
            str(payload.get("operation") or ""),
            str(payload.get("state") or ""),
            payload.get("exitCode"),
            SUMMARY_PENDING_NOTE,
        )
    elif log_path:
        generated = OutputSummarizer.summarize_file(
            str(payload.get("operation") or ""),
            payload.get("args") or {},
            str(payload.get("state") or ""),
            payload.get("exitCode"),
            bool(payload.get("timedOut")),
            Path(str(log_path)),
        )
    else:
        generated = OutputSummarizer._minimal_summary(
            str(payload.get("operation") or ""),
            str(payload.get("state") or ""),
            payload.get("exitCode"),
            "no log path available for summary",
        )
    return _with_artifact_scope_summary(payload, generated)


def payload_with_output_summary(payload: Dict[str, Any], include_log_tail: bool = False) -> Dict[str, Any]:
    if payload.get("state") not in TERMINAL_STATES:
        return payload
    existing_summary = payload.get("outputSummary")
    label = payload.get("operationLabel") or operation_display_name(str(payload.get("operation") or ""), payload.get("args") or {})
    needs_lifecycle_classification = label == "app relaunch" and payload.get("state") == "failed"
    needs_artifact_scope = (
        payload.get("artifactScope") in {"current", "stale"}
        and (
            not isinstance(existing_summary, dict)
            or existing_summary.get("artifactScope") != payload.get("artifactScope")
        )
    )
    needs_summary = not isinstance(existing_summary, dict) or (
        needs_lifecycle_classification and not isinstance(existing_summary.get("launchLifecycle"), dict)
    ) or needs_artifact_scope
    tail = payload.get("logTail")
    needs_tail_trim = include_log_tail and isinstance(tail, list) and len(tail) > LOG_TAIL_LINES
    has_tail = "logTail" in payload
    should_drop_tail = has_tail and not include_log_tail
    if not needs_summary and not needs_tail_trim and not should_drop_tail:
        return payload
    enriched = dict(payload)
    if needs_summary:
        enriched["outputSummary"] = output_summary_for_payload(enriched)
    if include_log_tail:
        if needs_tail_trim:
            enriched["logTail"] = tail[-LOG_TAIL_LINES:]
    elif isinstance(enriched.get("outputSummary"), dict) and not enriched.get("summaryPending"):
        enriched.pop("logTail", None)
    return enriched


def print_job_result_header(payload: Dict[str, Any], summary: Optional[Dict[str, Any]] = None) -> None:
    summary = summary or output_summary_for_payload(payload)
    print(f"Result:   {summary.get('headline') or payload.get('resultSummary') or payload.get('state')}")
    print(f"Ticket:   {payload.get('ticket')}")
    if payload.get("requestKey"):
        print(f"Request:  {payload.get('requestKey')}")
    label = payload.get("operationLabel") or operation_display_name(str(payload.get("operation") or ""), payload.get("args") or {})
    print(f"Operation:{' ' if label else ''}{label}")
    print(f"State:    {payload.get('state')}")
    if payload.get("exitCode") is not None:
        print(f"Exit:     {payload.get('exitCode')}")
    print(f"Log:      {payload.get('logPath')}")
    timing_parts: List[str] = []
    if payload.get("queueWaitSeconds") is not None:
        timing_parts.append(f"queue={format_duration(float(payload.get('queueWaitSeconds')))}")
    if payload.get("executionSeconds") is not None:
        timing_parts.append(f"exec={format_duration(float(payload.get('executionSeconds')))}")
    if payload.get("globalHeavySlotWaitSeconds") is not None:
        timing_parts.append(f"global-wait={format_duration(float(payload.get('globalHeavySlotWaitSeconds')))}")
    if payload.get("xctestSlotWaitSeconds") is not None:
        timing_parts.append(f"xctest-wait={format_duration(float(payload.get('xctestSlotWaitSeconds')))}")
    if payload.get("runPhaseSeconds") is not None:
        timing_parts.append(f"run={format_duration(float(payload.get('runPhaseSeconds')))}")
    if timing_parts:
        print(f"Timing:   {', '.join(timing_parts)}")
    if payload.get("error"):
        print(f"Error:    {payload.get('error')}")


def render_output_summary(summary: Dict[str, Any]) -> None:
    sections = summary.get("sections") or []
    for section in sections:
        title = section.get("title") or "Summary"
        lines = section.get("lines") or []
        if not lines:
            continue
        print()
        print(f"{title}:")
        for line in lines:
            print(f"  {line}")
        if section.get("truncated"):
            omitted = int(section.get("omittedLineCount") or 0)
            if section.get("omittedLineCountQuality") == "upper_bound":
                print(
                    f"  ... omitted at most {omitted} matching line(s) (deduplication limited: the count is an upper bound); "
                    "see full log path above"
                )
            else:
                print(f"  ... omitted {omitted} matching line(s); see full log path above")
        if section.get("displayedLinesMayRepeat"):
            print("  ... deduplication limited: these lines may repeat older lines of this section")
    if summary.get("truncated"):
        print()
        print("Summary truncated; see full log for complete output.")


def lifecycle_outcome_lines(payload: Dict[str, Any], summary: Dict[str, Any]) -> List[str]:
    label = payload.get("operationLabel") or operation_display_name(str(payload.get("operation") or ""), payload.get("args") or {})
    state = payload.get("state")
    if label not in {"app relaunch", "app stop"}:
        return []
    if state == "canceled":
        replacement = payload.get("supersededByOperation")
        replacement_ticket = payload.get("supersededByTicket")
        subject = "relaunch" if label == "app relaunch" else "stop"
        if replacement:
            ticket_detail = f" (ticket {replacement_ticket})" if replacement_ticket else ""
            return [f"This app {subject} ticket was superseded by newer {replacement} intent{ticket_detail}."]
        return [f"This app {subject} ticket was canceled before completion."]
    if label != "app relaunch" or state != "failed":
        return []
    lifecycle = summary.get("launchLifecycle")
    if not isinstance(lifecycle, dict):
        return [
            "Relaunch failed, but lifecycle phase information is unavailable from this job log.",
            "Check app status before retrying.",
        ]
    if lifecycle.get("transitionStarted"):
        return [
            "Relaunch failed after this ticket began app stop/open lifecycle work; app state may have changed.",
            "Check app status before retrying.",
        ]
    lines = [
        "Rebuild/package failed before this relaunch ticket reached app stop/open.",
        "This ticket did not stop or reopen RepoPrompt.",
    ]
    if lifecycle.get("sourceChangedDuringBuild"):
        lines.extend(
            [
                "The compiler reported that source files changed during the build.",
                "Daemon lanes do not prevent external/direct source edits; retry after edits settle.",
            ]
        )
    return lines


def render_lifecycle_outcome(payload: Dict[str, Any], summary: Dict[str, Any]) -> None:
    lines = lifecycle_outcome_lines(payload, summary)
    if not lines:
        return
    print()
    print("Outcome:")
    for line in lines:
        print(f"  {line}")


def print_full_log(payload: Dict[str, Any]) -> None:
    log_path = payload.get("logPath")
    if not log_path:
        return
    print()
    print(f"--- raw log: {log_path} ---")
    try:
        with open(log_path, "r", encoding="utf-8", errors="replace") as handle:
            content = handle.read()
            print(content, end="")
            if content and not content.endswith("\n"):
                print()
    except OSError as exc:
        print(f"(could not read log: {exc})")
        tail = payload.get("logTail") or []
        if tail:
            print("--- log tail fallback ---")
            print("".join(tail), end="")
            if not str(tail[-1]).endswith("\n"):
                print()


def print_terminal_job_output(payload: Dict[str, Any], output_mode: str = "summary") -> None:
    summary = output_summary_for_payload(payload)
    print_job_result_header(payload, summary=summary)
    render_lifecycle_outcome(payload, summary)
    if output_mode == "full":
        print_full_log(payload)
        return
    render_output_summary(summary)


def render_job(job: Dict[str, Any], output_mode: str = "summary", include_tail: bool = True) -> None:
    if job.get("state") in TERMINAL_STATES:
        print_terminal_job_output(job, output_mode=output_mode)
        return
    print(f"ticket:    {job.get('ticket')}")
    if job.get("requestKey"):
        print(f"request:   {job.get('requestKey')}")
    print(f"operation: {job.get('operationLabel') or job.get('operation')}")
    print(f"state:     {job.get('state')}")
    print(f"lanes:     {', '.join(job.get('lanes') or []) or 'none'}")
    timing_parts: List[str] = []
    if job.get("createdAt"):
        timing_parts.append(f"queued={format_duration(max(0.0, now() - float(job.get('createdAt'))))}")
    if job.get("startedAt"):
        timing_parts.append(f"running={format_duration(max(0.0, now() - float(job.get('startedAt'))))}")
    if job.get("globalHeavySlotWaitSeconds") is not None:
        timing_parts.append(f"global-wait={format_duration(float(job.get('globalHeavySlotWaitSeconds')))}")
    if job.get("xctestSlotWaitSeconds") is not None:
        timing_parts.append(f"xctest-wait={format_duration(float(job.get('xctestSlotWaitSeconds')))}")
    if job.get("runPhaseSeconds") is not None:
        timing_parts.append(f"run={format_duration(float(job.get('runPhaseSeconds')))}")
    if timing_parts:
        print(f"timing:    {', '.join(timing_parts)}")
    if job.get("globalHeavySlotPath") and job.get("state") in {"running", "waiting-heavy-slot"}:
        print(f"heavy:     {job.get('globalHeavySlotPath')}")
    if job.get("globalHeavySlotHolder") and job.get("state") in {"running", "waiting-heavy-slot"}:
        print(f"holder:    {job.get('globalHeavySlotHolder')}")
    if job.get("xctestSlotPath") and job.get("state") in {"running", "waiting-xctest-slot"}:
        print(f"xctest:    {job.get('xctestSlotPath')}")
    if job.get("xctestSlotHolder") and job.get("state") in {"running", "waiting-xctest-slot"}:
        print(f"holder:    {job.get('xctestSlotHolder')}")
    print(f"log:       {job.get('logPath')}")
    if job.get("startedAtISO"):
        print(f"started:   {job.get('startedAtISO')}")
    if job.get("resultSummary"):
        print(f"result:    {job.get('resultSummary')}")
    if job.get("error"):
        print(f"error:     {job.get('error')}")
    if include_tail and job.get("logTail"):
        if output_mode == "full":
            print("--- log tail ---")
            print("".join(job.get("logTail") or []), end="")
            if not str(job.get("logTail")[-1]).endswith("\n"):
                print()
        else:
            noteworthy = select_progress_lines(str(job.get("operation") or ""), job.get("logTail") or [])
            if noteworthy:
                print("--- noteworthy recent output ---")
                for line in noteworthy:
                    print(line)


def handle_daemon_command(paths: Paths, argv: List[str]) -> int:
    if not argv or argv[0] in {"-h", "--help"}:
        print("Usage: ./conductor daemon start|status|stop [--force] [--json]")
        return 0
    sub = argv[0]
    json_mode, rest = parse_json_flag(argv[1:])
    if sub == "start":
        payload = ensure_daemon(paths, start_if_needed=True)
        notice = daemon_timing_notice(payload)
        if json_mode:
            if notice is not None:
                payload = dict(payload, timingNotice=notice)
            print_json(payload)
        else:
            print("daemon running")
            render_daemon_status(payload)
        if notice is not None:
            print(notice, file=sys.stderr)
        return 0
    if sub == "status":
        try:
            payload = ensure_daemon(paths, start_if_needed=False)
        except ConductorError as exc:
            if json_mode:
                print_json({"running": False, "error": str(exc), "socketPath": str(paths.socket_path), "stateDir": str(paths.state_dir)})
            else:
                print(f"daemon not running: {exc}")
            return 1
        if json_mode:
            print_json(payload)
        else:
            render_daemon_status(payload)
        return 0
    if sub == "stop":
        force = False
        for arg in rest:
            if arg == "--force":
                force = True
            else:
                raise ConductorError(f"unknown daemon stop option '{arg}'")
        try:
            payload = request_daemon(
                paths,
                {"type": "stop", "force": force},
                timeout=FORCE_STOP_RPC_TIMEOUT_SECONDS if force else 5.0,
            )
            stopped = wait_until_stopped(paths, timeout=(TERMINATE_GRACE_SECONDS + 5.0) if force else 5.0)
            if force and not stopped:
                payload = force_stop_unresponsive_daemon(paths)
        except ConductorError:
            if not force:
                raise
            payload = force_stop_unresponsive_daemon(paths)
        bootout_daemon_launchd(paths)
        if json_mode:
            print_json(payload)
        else:
            print("daemon stopping" if not payload.get("forced") else "daemon force-stopped")
        return 0
    raise ConductorError(f"unknown daemon command '{sub}'")


def handle_status_command(paths: Paths, argv: List[str]) -> int:
    json_mode, rest = parse_json_flag(argv)
    if rest:
        raise ConductorError(f"unknown status option(s): {' '.join(rest)}")
    try:
        payload = ensure_daemon(paths, start_if_needed=False)
    except ConductorError as exc:
        if json_mode:
            print_json({"running": False, "error": str(exc), "socketPath": str(paths.socket_path), "stateDir": str(paths.state_dir)})
        else:
            print("conductor daemon not running")
            print(f"socket: {paths.socket_path}")
            print("start with: ./conductor daemon start")
        return 1
    if json_mode:
        print_json(payload)
    else:
        render_daemon_status(payload, shorthand=True)
    return 0


def _format_span_ms(value: Any) -> str:
    if isinstance(value, dict) and isinstance(value.get("ns"), int):
        return f"{value['ns'] / 1_000_000:.1f}ms"
    if isinstance(value, dict) and value.get("quality") == "not_applicable":
        return "n/a"
    return "?"


def handle_metrics_command(paths: Paths, argv: List[str]) -> int:
    """Client-side read of the per-job timing history; never contacts the daemon."""
    parser = argparse.ArgumentParser(prog="conductor metrics")
    parser.add_argument("--last", type=int, default=20)
    parser.add_argument("--kind")
    parser.add_argument("--ticket")
    parser.add_argument("--json", action="store_true")
    ns = parser.parse_args(argv)
    if ns.last < 0:
        raise ConductorError("metrics --last must be non-negative")
    if PIPELINE_METRICS is None:
        raise ConductorError("timing metrics are unavailable: Scripts/swift_pipeline_metrics.py could not be loaded")
    history = PIPELINE_METRICS.RotatingJsonl(timing_history_path(paths))
    rows, malformed = history.read_rows()
    selected = PIPELINE_METRICS.filter_history(rows, last=ns.last, kind=ns.kind, ticket=ns.ticket)
    if ns.json:
        print_json(
            {
                "historyPath": str(history.path),
                "totalRows": len(rows),
                "malformedLines": malformed,
                "rows": list(selected),
            }
        )
        return 0
    print(f"timing history: {history.path} ({len(selected)} of {len(rows)} rows; {malformed} malformed)")
    for row in selected:
        intervals = row.get("intervals") if isinstance(row.get("intervals"), dict) else {}
        finished = row.get("finishedAtWallNs")
        finished_text = iso_timestamp(finished / 1_000_000_000) if isinstance(finished, int) else "?"
        print(
            f"{str(row.get('ticket'))[:8]}  {row.get('kind')}  {row.get('status')}  exit={row.get('exitCode')}  "
            f"queue={_format_span_ms(intervals.get('queueWait'))}  "
            f"process={_format_span_ms(intervals.get('processObserved'))}  "
            f"total={_format_span_ms(intervals.get('acceptedToLaneRelease'))}  "
            f"segments={len(row.get('segments') or [])}  finished={finished_text}"
        )
    return 0


def handle_job_command(paths: Paths, argv: List[str]) -> int:
    if not argv or argv[0] in {"-h", "--help"}:
        print("Usage: ./conductor job list|status|wait|cancel ...")
        return 0
    ensure_daemon(paths, start_if_needed=False)
    sub = argv[0]
    parser = argparse.ArgumentParser(prog=f"conductor job {sub}", add_help=True)
    parser.add_argument("--json", action="store_true", help="machine-readable output; includes logPath, not raw full logs")
    if sub in {"status", "wait"}:
        parser.add_argument(
            "--full-log",
            action="store_true",
            help="human output only: render the raw full job log instead of the concise summary",
        )

    if sub == "list":
        parser.add_argument(
            "--state",
            choices=sorted(
                [
                    "queued",
                    "running",
                    "waiting-heavy-slot",
                    "waiting-xctest-slot",
                    "completed",
                    "failed",
                    "canceled",
                ]
            ),
        )
        ns = parser.parse_args(argv[1:])
        payload = request_daemon(paths, {"type": "job-list", "state": ns.state}, timeout=5.0)
        if ns.json:
            print_json(payload)
        else:
            jobs = payload.get("jobs") or []
            if not jobs:
                print("no retained jobs")
            for job in jobs:
                print(f"{job.get('ticket')} {job.get('state')} {job.get('operationLabel') or job.get('operation')} lanes={','.join(job.get('lanes') or []) or 'none'}")
        return 0

    if sub in {"status", "wait", "cancel"}:
        parser.add_argument("ticket", nargs="?")
        parser.add_argument("--request-key")
        if sub == "wait":
            parser.add_argument("--timeout", type=float)
        ns = parser.parse_args(argv[1:])
        if getattr(ns, "json", False) and getattr(ns, "full_log", False):
            raise ConductorError("--full-log is only supported for human output; JSON output includes logPath instead")
        if bool(ns.ticket) == bool(ns.request_key):
            raise ConductorError("provide exactly one of <ticket> or --request-key <key>")
        req: Dict[str, Any] = {
            "type": {"status": "job-status", "wait": "job-wait", "cancel": "job-cancel"}[sub],
            "ticket": ns.ticket,
            "requestKey": ns.request_key,
        }
        if sub == "wait":
            if ns.timeout is not None and ns.timeout < 0:
                raise ConductorError("wait timeout must be non-negative")
            if ns.timeout is None:
                output_mode = "full" if getattr(ns, "full_log", False) else "summary"
                payload = wait_for_terminal(paths, ns.ticket, ns.request_key, json_mode=ns.json, output_mode=output_mode)
            else:
                req["timeout"] = ns.timeout
                payload = request_daemon(paths, req, timeout=ns.timeout + 5.0)
        else:
            payload = request_daemon(paths, req, timeout=10.0)
        if ns.json:
            print_json(payload_with_output_summary(payload))
        else:
            render_job(payload, output_mode="full" if getattr(ns, "full_log", False) else "summary")
            if payload.get("waitTimedOut"):
                print("wait timed out before job reached a terminal state")
        if sub == "wait" and payload.get("waitTimedOut"):
            return 124
        return terminal_exit_code(payload) if sub == "wait" and payload.get("state") in TERMINAL_STATES else 0

    raise ConductorError(f"unknown job command '{sub}'")


def split_operation_flags(argv: List[str]) -> Tuple[argparse.Namespace, List[str]]:
    parser = argparse.ArgumentParser(add_help=False)
    parser.add_argument("--async", dest="async_mode", action="store_true")
    parser.add_argument("--request-key")
    parser.add_argument("--json", action="store_true")
    parser.add_argument("--timeout", type=float)
    parser.add_argument("--verbose", action="store_true")
    parser.add_argument("--full-log", action="store_true")
    known, rest = parser.parse_known_args(argv)
    if known.json and known.full_log:
        raise ConductorError("--full-log is only supported for human output; JSON output includes logPath instead")
    if known.async_mode and known.full_log:
        raise ConductorError("--full-log requires synchronous human output; use './conductor job wait <ticket> --full-log' for async jobs")
    return known, rest


def handle_sleep_operation(paths: Paths, operation: str, argv: List[str]) -> int:
    global_flags, rest = split_operation_flags(argv)
    parser = argparse.ArgumentParser(prog=f"conductor {operation}")
    parser.add_argument("seconds", type=float)
    parser.add_argument("--lane", action="append", default=[])
    parser.add_argument("--message", default="conductor sleep")
    parser.add_argument("--exit-code", type=int, default=0)
    ns = parser.parse_args(rest)
    if global_flags.timeout is not None and global_flags.timeout < 0:
        raise ConductorError("timeout must be non-negative")

    lanes: List[str] = []
    for lane_arg in ns.lane:
        lanes.extend([part for part in lane_arg.split(",") if part])
    invalid_lanes = [lane for lane in lanes if lane not in LANE_NAMES]
    if invalid_lanes:
        raise ConductorError(f"unknown lane(s): {', '.join(invalid_lanes)}")

    env_snapshot = OperationRegistry.client_env_snapshot()  # Step 10: validates before any daemon contact
    ensure_daemon(paths, start_if_needed=True)
    request = {
        "type": "enqueue",
        "operation": operation,
        "args": {
            "seconds": ns.seconds,
            "lanes": lanes,
            "message": ns.message,
            "exitCode": ns.exit_code,
        },
        "requestKey": global_flags.request_key,
        "timeout": global_flags.timeout,
        "verbose": global_flags.verbose,
        "env": env_snapshot,
    }
    enqueue_payload = request_daemon(paths, request, timeout=10.0)
    if global_flags.async_mode:
        if global_flags.json:
            print_json(enqueue_payload)
        else:
            print(f"ticket: {enqueue_payload.get('ticket')}")
            print(f"state:  {enqueue_payload.get('state')}")
            print(f"lanes:  {', '.join(enqueue_payload.get('lanes') or []) or 'none'}")
            print(f"log:    {enqueue_payload.get('logPath')}")
            if enqueue_payload.get("reused"):
                print("reused existing queued/running job for request key")
            render_superseded_jobs(enqueue_payload)
            print(f"wait:   ./conductor job wait {enqueue_payload.get('ticket')}")
        return 0

    ticket = enqueue_payload.get("ticket")
    if global_flags.json:
        final = payload_with_output_summary(wait_for_terminal(paths, ticket, request_key=None, json_mode=True))
        print_json({"enqueue": enqueue_payload, "result": final})
        return terminal_exit_code(final)

    print(f"ticket: {ticket}")
    print(f"log:    {enqueue_payload.get('logPath')}")
    print(f"reconnect: ./conductor job wait {ticket}")
    render_superseded_jobs(enqueue_payload)
    output_mode = "full" if global_flags.full_log else "summary"
    final_payload = wait_for_terminal(paths, ticket, request_key=None, json_mode=False, output_mode=output_mode)
    print_terminal_job_output(final_payload, output_mode=output_mode)
    return terminal_exit_code(final_payload)


def wait_for_terminal(
    paths: Paths,
    ticket: Optional[str],
    request_key: Optional[str],
    json_mode: bool,
    output_mode: str = "summary",
) -> Dict[str, Any]:
    last_state: Optional[str] = None
    last_tail: List[str] = []
    last_blockers: Optional[Tuple[Tuple[str, ...], ...]] = None
    printed_progress: Deque[str] = deque(maxlen=200)
    printed_progress_set: set[str] = set()
    last_progress_at = now()
    pending_since: Optional[float] = None
    while True:
        payload = request_daemon(
            paths,
            {"type": "job-wait", "ticket": ticket, "requestKey": request_key, "timeout": WAIT_POLL_SECONDS},
            timeout=WAIT_POLL_SECONDS + 5.0,
        )
        if not json_mode:
            state = payload.get("state")
            tail = payload.get("logTail") or []
            if state != last_state:
                print(f"[{time.strftime('%H:%M:%S')}] state: {state}")
                last_state = state
            blockers = payload.get("blockedBy") or [] if state == "queued" else []
            blocker_signature = tuple(
                (str(item.get("ticket")), str(item.get("operationLabel")), ",".join(item.get("conflictingLanes") or []), str(item.get("cancelRequested")))
                for item in blockers
            )
            if state == "queued" and blockers and blocker_signature != last_blockers:
                for blocker in blockers:
                    lanes = ",".join(blocker.get("conflictingLanes") or [])
                    cancellation = " (cancellation requested)" if blocker.get("cancelRequested") else ""
                    print(
                        f"Waiting to begin {payload.get('operationLabel') or payload.get('operation')}; "
                        f"blocked by {blocker.get('operationLabel')} {blocker.get('ticket')} on {lanes}{cancellation}."
                    )
                last_blockers = blocker_signature
            if tail != last_tail and state not in TERMINAL_STATES:
                new_lines = tail[len(last_tail) :] if len(tail) >= len(last_tail) and tail[: len(last_tail)] == last_tail else tail[-5:]
                if output_mode == "full":
                    for line in new_lines:
                        print(line, end="")
                    if new_lines:
                        last_progress_at = now()
                else:
                    for line in select_progress_lines(str(payload.get("operation") or ""), new_lines):
                        if line in printed_progress_set:
                            continue
                        print(line)
                        printed_progress.append(line)
                        printed_progress_set.add(line)
                        while len(printed_progress_set) > len(printed_progress):
                            printed_progress_set = set(printed_progress)
                        last_progress_at = now()
                last_tail = tail
            if state not in TERMINAL_STATES and output_mode != "full" and now() - last_progress_at >= PROGRESS_HEARTBEAT_SECONDS:
                print(f"[{time.strftime('%H:%M:%S')}] still running; log: {payload.get('logPath')}")
                last_progress_at = now()
        if payload.get("state") in TERMINAL_STATES:
            if payload.get("summaryPending"):
                # Another caller's summary scan is still running: each poll joins
                # it for up to WAIT_POLL_SECONDS. After the bound, return without
                # it (rendered as a pending note, never a second scan).
                pending_since = now() if pending_since is None else pending_since
                if now() - pending_since < SUMMARY_PENDING_WAIT_SECONDS:
                    continue
            return payload


def run_operation_command(
    name: str,
    argv: Sequence[str],
    cwd: Path,
    env: Optional[Dict[str, str]] = None,
    allow_exit_codes: Optional[set[int]] = None,
    timeout: Optional[float] = None,
) -> Tuple[int, str, str]:
    allowed = allow_exit_codes if allow_exit_codes is not None else {0}
    print(f"\n==> {name}", flush=True)
    print(f"$ {format_argv(argv)}", flush=True)
    try:
        completed = subprocess.run(
            list(argv),
            cwd=str(cwd),
            env=env,
            stdin=subprocess.DEVNULL,
            text=True,
            capture_output=True,
            timeout=timeout,
        )
    except subprocess.TimeoutExpired as exc:
        stdout = exc.stdout or ""
        stderr = exc.stderr or ""
        if isinstance(stdout, bytes):
            stdout = stdout.decode("utf-8", errors="replace")
        if isinstance(stderr, bytes):
            stderr = stderr.decode("utf-8", errors="replace")
        print(f"status: timed out after {timeout}s", flush=True)
        _print_captured(stdout, stderr)
        return 124, stdout, stderr
    stdout = completed.stdout or ""
    stderr = completed.stderr or ""
    print(f"status: {completed.returncode}", flush=True)
    _print_captured(stdout, stderr)
    if completed.returncode not in allowed:
        print(f"FAILED stage '{name}' with status {completed.returncode}", flush=True)
    return int(completed.returncode), stdout, stderr


def _print_captured(stdout: str, stderr: str) -> None:
    print("--- stdout ---", flush=True)
    if stdout:
        print(stdout, end="" if stdout.endswith("\n") else "\n", flush=True)
    print("--- stderr ---", flush=True)
    if stderr:
        print(stderr, end="" if stderr.endswith("\n") else "\n", flush=True)


def is_already_on_workspace(output: str, workspace: str) -> bool:
    lines = [line.strip() for line in output.splitlines() if line.strip()]
    expected = f'Already on workspace "{workspace}"'
    return expected in lines or f"Error: [-32600] Invalid Request: {expected}." in lines


def is_workspace_restore_in_progress(output: str, workspace: str) -> bool:
    normalized = " ".join(line.strip() for line in output.splitlines() if line.strip()).lower()
    return (
        f'workspace switch to "{workspace.lower()}"' in normalized
        and "blocked by a active switch" in normalized
        and "reason: restore" in normalized
    )


def routed_structured_cli_argv(cli: str, window_id: int, command: str, payload: Dict[str, Any]) -> List[str]:
    routed_payload = dict(payload)
    routed_payload["_windowID"] = window_id
    return [cli, "-w", str(window_id), "-c", command, "-j", json.dumps(routed_payload)]


def resolve_debug_cli() -> Optional[str]:
    install_override = os.environ.get("REPOPROMPT_DEBUG_CLI_INSTALL_PATH")
    if install_override:
        override_path = Path(install_override).expanduser()
        if override_path.is_file() and os.access(override_path, os.X_OK):
            return str(override_path)
    path_cli = shutil.which("rpce-cli-debug")
    if path_cli and os.access(path_cli, os.X_OK):
        return path_cli
    fallback = Path.home() / "Library" / "Application Support" / "RepoPrompt CE" / "repoprompt_ce_cli_debug"
    if fallback.is_file() and os.access(fallback, os.X_OK):
        return str(fallback)
    bundled = debug_app_bundle_path() / "Contents" / "MacOS" / "repoprompt-mcp"
    if bundled.is_file() and os.access(bundled, os.X_OK):
        return str(bundled)
    return None


def resolve_embedded_helper(app_bundle: Path) -> str:
    app = app_bundle.expanduser().resolve(strict=True)
    candidate = app / "Contents" / "MacOS" / "repoprompt-mcp"
    if candidate.is_symlink():
        raise ConductorError(f"embedded MCP helper must not be a symlink: {candidate}")
    helper = candidate.resolve(strict=True)
    try:
        helper.relative_to(app)
    except ValueError as exc:
        raise ConductorError(f"embedded MCP helper escapes launched app bundle: {helper}") from exc
    if not helper.is_file() or not os.access(helper, os.X_OK):
        raise ConductorError(f"embedded MCP helper is not an executable regular file: {helper}")
    return str(helper)


def require_debug_cli() -> Optional[str]:
    cli = resolve_debug_cli()
    if cli:
        print(f"Resolved rpce-cli-debug: {cli}", flush=True)
        return cli
    print("ERROR: rpce-cli-debug was not found via REPOPROMPT_DEBUG_CLI_INSTALL_PATH, PATH, user-space fallback, or the debug app bundle.", flush=True)
    print("Install it with:", flush=True)
    print("  make install-debug-cli", flush=True)
    print("  # or", flush=True)
    print("  ./conductor install-debug-cli", flush=True)
    return None


def find_session_id(obj: Any) -> Optional[str]:
    if isinstance(obj, dict):
        value = obj.get("session_id") or obj.get("sessionId")
        if isinstance(value, str) and value:
            return value
        for child in obj.values():
            found = find_session_id(child)
            if found:
                return found
    elif isinstance(obj, list):
        for child in obj:
            found = find_session_id(child)
            if found:
                return found
    return None


def find_session_id_in_text(text: str) -> Optional[str]:
    match = re.search(r"(?im)^\s*-?\s*Session ID:\s*`?([A-F0-9-]+)`?\s*$", text)
    return match.group(1) if match else None


def debug_app_bundle_path() -> Path:
    # Mirrors Scripts/run.sh path resolution so app status reports the same bundle that run delegates launch.
    root = os.environ.get(
        "REPOPROMPT_DEBUG_APP_ROOT",
        str(Path.home() / "Library" / "Application Support" / "RepoPrompt CE" / "DebugApps"),
    )
    return Path(os.environ.get("REPOPROMPT_DEBUG_APP_BUNDLE", str(Path(root) / "RepoPrompt.app")))


def debug_app_executable_path() -> Path:
    return debug_app_bundle_path() / "Contents" / "MacOS" / "RepoPrompt"


def find_debug_app_pids() -> List[str]:
    return [str(pid) for pid in matching_processes(debug_app_executable_path())]


def execution_location_ui_smoke_timeout(env: Dict[str, str]) -> float:
    try:
        wait_seconds = max(0.0, float(env.get("REPOPROMPT_EXECUTION_LOCATION_UI_SMOKE_WAIT", "3")))
    except ValueError:
        wait_seconds = 3.0
    try:
        cycles = max(1, int(env.get("REPOPROMPT_EXECUTION_LOCATION_UI_SMOKE_CYCLES", "3")))
    except ValueError:
        cycles = 3
    return cycles * (wait_seconds + 60.0) + 60.0


def terminate_debug_app_processes() -> List[str]:
    return [str(pid) for pid in terminate_matching_processes(debug_app_executable_path())]


def debug_app_provenance_path(bundle: Path) -> Path:
    return bundle / DEBUG_APP_PROVENANCE_RELATIVE_PATH


def read_debug_app_provenance(bundle: Path) -> Optional[Dict[str, Any]]:
    path = debug_app_provenance_path(bundle)
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except (FileNotFoundError, OSError, json.JSONDecodeError):
        return None
    return payload if isinstance(payload, dict) else None


def git_metadata_value(repo_root: Path, args: Sequence[str]) -> Optional[str]:
    try:
        completed = subprocess.run(
            ["git", "-C", str(repo_root), *args],
            text=True,
            capture_output=True,
            timeout=2.0,
        )
    except (OSError, subprocess.TimeoutExpired):
        return None
    if completed.returncode != 0:
        return None
    value = completed.stdout.strip()
    return value or None


def current_repo_commit(repo_root: Path) -> Optional[str]:
    return git_metadata_value(repo_root, ["rev-parse", "HEAD"])


def provenance_build_lane_label(provenance: Dict[str, Any]) -> str:
    """`buildLane` as packaged (§4.9); bundles packaged before the lane key existed have none."""
    if "buildLane" not in provenance:
        return "unknown (pre-lane provenance)"
    lane = provenance.get("buildLane")
    if isinstance(lane, str) and lane:
        return lane
    return f"<invalid: {lane!r}>"


def provenance_report_lines(repo_root: Path, bundle: Path) -> List[str]:
    provenance = read_debug_app_provenance(bundle)
    if not provenance:
        return ["  Bundle provenance: <missing>"]
    lines = ["  Bundle provenance:"]
    repo = str(provenance.get("repoRoot") or "<unknown>")
    worktree = str(provenance.get("worktreePath") or repo)
    branch = str(provenance.get("branch") or "<unknown>")
    commit = str(provenance.get("commit") or "<unknown>")
    dirty = provenance.get("dirty")
    built_at = str(provenance.get("buildTimeISO") or "<unknown>")
    lines.append(f"    repo: {repo}")
    lines.append(f"    worktree: {worktree}")
    lines.append(f"    branch: {branch}")
    lines.append(f"    commit: {commit[:12] if commit != '<unknown>' else commit}")
    lines.append(f"    dirty at build: {dirty if isinstance(dirty, bool) else '<unknown>'}")
    lines.append(f"    built: {built_at}")
    lines.append(f"    build lane: {provenance_build_lane_label(provenance)}")
    flags: List[str] = []
    try:
        current_root = str(repo_root.resolve())
        built_root = str(Path(repo).resolve(strict=False))
        if built_root != current_root:
            flags.append("foreign worktree")
    except OSError:
        flags.append("foreign worktree unknown")
    current_commit = current_repo_commit(repo_root)
    if current_commit and commit not in {"<unknown>", current_commit}:
        flags.append("stale commit")
    if flags:
        lines.append(f"    WARNING: {'; '.join(flags)}")
    return lines


def print_debug_app_provenance(repo_root: Path, bundle: Path) -> None:
    for line in provenance_report_lines(repo_root, bundle):
        print(line, flush=True)


def report_launch_bundle_details(repo_root: Path, bundle: Path) -> int:
    print(f"Launch app path: {bundle}", flush=True)
    print_debug_app_provenance(repo_root, bundle)
    codesign = subprocess.run(["codesign", "-dv", str(bundle)], text=True, capture_output=True)
    details = (codesign.stdout or "") + (codesign.stderr or "")
    team = "<missing>"
    authorities: List[str] = []
    for line in details.splitlines():
        if line.startswith("TeamIdentifier="):
            team = line.split("=", 1)[1] or "<missing>"
        elif line.startswith("Authority="):
            authorities.append(line.split("=", 1)[1])
    marker = subprocess.run(
        ["plutil", "-extract", "RepoPromptDebugSecureStorageBackend", "raw", "-o", "-", str(bundle / "Contents" / "Info.plist")],
        text=True,
        capture_output=True,
    )
    storage = marker.stdout.strip() if marker.returncode == 0 and marker.stdout.strip() else "<missing>"
    print(f"Launch app team: {team}", flush=True)
    print(f"Launch app signing authorities: {', '.join(authorities) if authorities else '<none/ad-hoc>'}", flush=True)
    print(f"Launch app debug secure storage marker: {storage}", flush=True)
    if storage != "keychain":
        print("WARNING: Debug secure storage is in-memory this run; secrets and permission changes won't persist.", flush=True)
    elif not team or team in {"<missing>", "not set"}:
        print("WARNING: Launching a keychain-marked debug app without a team identifier; runtime will fall back to in-memory secure storage.", flush=True)
    return 0


def wait_for_no_debug_app_process(timeout: float = 5.0) -> bool:
    deadline = now() + timeout
    while now() <= deadline:
        pids = find_debug_app_pids()
        if not pids:
            return True
        time.sleep(APP_STOP_POLL_SECONDS)
    return False


def wait_for_debug_app_process(timeout: float = STARTUP_TIMEOUT_SECONDS) -> List[str]:
    deadline = now() + timeout
    while now() <= deadline:
        pids = find_debug_app_pids()
        if pids:
            return pids
        time.sleep(APP_STOP_POLL_SECONDS)
    return []


def guard_delayed_debug_app_launch() -> int:
    print("Guarding against a delayed RepoPrompt CE debug app launch from superseded app work.", flush=True)
    return _operation_app_stop_unlocked(Path.cwd(), {"guardDelayedLaunch": True})


def _operation_app_stop_unlocked(_repo_root: Path, args: Dict[str, Any]) -> int:
    guard_delayed_launch = bool(args.get("guardDelayedLaunch"))
    required_quiet = APP_STOP_DELAYED_LAUNCH_GUARD_SECONDS if guard_delayed_launch else APP_STOP_QUIET_SECONDS
    confirmation_timeout = APP_STOP_DELAYED_LAUNCH_CONFIRM_TIMEOUT_SECONDS if guard_delayed_launch else APP_STOP_CONFIRM_TIMEOUT_SECONDS
    deadline = now() + confirmation_timeout
    quiet_since: Optional[float] = None
    observed_process = False
    if guard_delayed_launch:
        print("Guarding against a delayed RepoPrompt CE debug app launch from superseded app work.", flush=True)
    while True:
        try:
            pids = find_debug_app_pids()
        except ProcessIdentityError as exc:
            print(f"ERROR: could not safely identify the debug app process: {exc}", flush=True)
            return 1
        if pids:
            observed_process = True
            quiet_since = None
            print(f"Observed running RepoPrompt CE debug PID(s): {', '.join(pids)}", flush=True)
            try:
                terminate_debug_app_processes()
            except ProcessIdentityError as exc:
                print(f"ERROR: refused to signal a process without validated debug app identity: {exc}", flush=True)
                return 1
        else:
            if quiet_since is None:
                quiet_since = now()
            if now() - quiet_since >= required_quiet:
                if observed_process:
                    print("RepoPrompt stop confirmed.", flush=True)
                else:
                    print("RepoPrompt was already stopped; stop confirmed.", flush=True)
                return 0
        if now() >= deadline:
            print("ERROR: timed out confirming that RepoPrompt remained stopped.", flush=True)
            return 1
        time.sleep(APP_STOP_POLL_SECONDS)


def staged_debug_app_parent(live_bundle: Optional[Path] = None) -> Path:
    bundle = live_bundle or debug_app_bundle_path()
    token = f"{int(now() * 1000)}-{os.getpid()}-{uuid.uuid4().hex[:8]}"
    return bundle.parent / ".staging" / token


def cleanup_staged_debug_bundle(staged_bundle: Optional[Path]) -> None:
    if staged_bundle is None:
        return
    parent = staged_bundle.parent
    with contextlib.suppress(FileNotFoundError):
        shutil.rmtree(parent)


def package_debug_app_under_heavy(
    repo_root: Path, operation_label: str, package_config: str = "debug"
) -> Tuple[int, Optional[Path]]:
    # Validated before any staging path, lock or child process exists.
    if package_config not in DEBUG_APP_PACKAGE_CONFIGS:
        raise ConductorError(
            f"unsupported staged debug package config {package_config!r}; expected one of: "
            + ", ".join(DEBUG_APP_PACKAGE_CONFIGS)
        )
    live_bundle = debug_app_bundle_path()
    staging_parent = staged_debug_app_parent(live_bundle)
    staged_bundle = staging_parent / live_bundle.name
    metadata = display_lock_metadata(
        lock_kind="global-heavy",
        ticket=os.environ.get("REPOPROMPT_CONDUCTOR_JOB_TICKET"),
        operation=operation_label,
        operation_label=operation_label,
        repo_root=repo_root,
        repo_hash=None,
    )
    env = os.environ.copy()
    env["REPOPROMPT_DEBUG_APP_BUNDLE"] = str(staged_bundle)
    env["REPOPROMPT_DEBUG_APP_REUSE_SOURCE"] = str(live_bundle)
    try:
        with machine_heavy_slot(metadata, env, "global heavy slot for debug package"):
            code, _stdout, _stderr = run_operation_command(
                "package staged debug app",
                [str(repo_root / "Scripts" / "package_app.sh"), package_config],
                repo_root,
                env=env,
            )
        if code != 0:
            cleanup_staged_debug_bundle(staged_bundle)
            return code, None
        executable = staged_bundle / "Contents" / "MacOS" / "RepoPrompt"
        if not executable.is_file() or not os.access(executable, os.X_OK):
            print(f"ERROR: staged debug app is not launchable: {staged_bundle}", flush=True)
            cleanup_staged_debug_bundle(staged_bundle)
            return 1, None
        print(f"Staged debug app bundle: {staged_bundle}", flush=True)
        return 0, staged_bundle
    except BaseException:
        cleanup_staged_debug_bundle(staged_bundle)
        raise


def swap_staged_debug_bundle_into_place(staged_bundle: Path, live_bundle: Path) -> bool:
    if not live_bundle.exists():
        staged_bundle.rename(live_bundle)
        return True
    if sys.platform != "darwin":
        return False
    try:
        renamex_np = ctypes.CDLL(None, use_errno=True).renamex_np
    except AttributeError:
        return False
    renamex_np.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint]
    renamex_np.restype = ctypes.c_int
    rename_swap = 0x00000002
    result = renamex_np(os.fsencode(staged_bundle), os.fsencode(live_bundle), rename_swap)
    if result == 0:
        return True
    return False


def activate_staged_debug_bundle(staged_bundle: Path, live_bundle: Optional[Path] = None) -> None:
    live = live_bundle or debug_app_bundle_path()
    if not staged_bundle.exists():
        raise ConductorError(f"staged debug app bundle is missing: {staged_bundle}")
    executable = staged_bundle / "Contents" / "MacOS" / "RepoPrompt"
    if not executable.is_file() or not os.access(executable, os.X_OK):
        raise ConductorError(f"staged debug app bundle is not launchable: {staged_bundle}")
    live.parent.mkdir(parents=True, exist_ok=True)
    backup = live.parent / f".{live.name}.previous.{os.getpid()}.{uuid.uuid4().hex[:8]}"
    moved_existing = False
    try:
        if not swap_staged_debug_bundle_into_place(staged_bundle, live):
            if live.exists():
                live.rename(backup)
                moved_existing = True
            staged_bundle.rename(live)
    except BaseException:
        if moved_existing and not live.exists() and backup.exists():
            with contextlib.suppress(OSError):
                backup.rename(live)
        raise
    finally:
        if backup.exists():
            shutil.rmtree(backup, ignore_errors=True)
        staging_parent = staged_bundle.parent
        if staging_parent.exists():
            shutil.rmtree(staging_parent, ignore_errors=True)
    print(f"Activated staged debug app bundle: {live}", flush=True)


def repair_debug_app_compatibility_link(repo_root: Path, live_bundle: Path) -> Path:
    compatibility_bundle = repo_root / ".build" / "debug" / "RepoPrompt.app"
    if compatibility_bundle == live_bundle:
        return compatibility_bundle

    executable = live_bundle / "Contents" / "MacOS" / "RepoPrompt"
    if not executable.is_file() or not os.access(executable, os.X_OK):
        raise ConductorError(f"activated debug app bundle is not launchable: {live_bundle}")

    compatibility_bundle.parent.mkdir(parents=True, exist_ok=True)
    temporary_link = compatibility_bundle.parent / f".{compatibility_bundle.name}.link.{os.getpid()}.{uuid.uuid4().hex[:8]}"
    try:
        temporary_link.symlink_to(live_bundle)
        if compatibility_bundle.is_dir() and not compatibility_bundle.is_symlink():
            shutil.rmtree(compatibility_bundle)
        os.replace(temporary_link, compatibility_bundle)
    finally:
        with contextlib.suppress(FileNotFoundError):
            temporary_link.unlink()
    print(f"Compatibility app bundle link: {compatibility_bundle} -> {live_bundle}", flush=True)
    return compatibility_bundle


def launch_services_cannot_resolve_executable(stderr: str) -> bool:
    return any(
        marker in stderr
        for marker in (
            "kLSNoExecutableErr",
            "Code=-10827",
            "kLSServerCommunicationErr",
            "Code=-10822",
        )
    )


def launch_debug_app_executable_directly(executable: Path, app_args: Sequence[str], repo_root: Path) -> bool:
    if not executable.is_file() or not os.access(executable, os.X_OK):
        print(f"ERROR: direct-launch executable is missing or not executable: {executable}", flush=True)
        return False
    argv = [str(executable), *app_args]
    print("LaunchServices could not resolve the verified app bundle; launching its executable directly.", flush=True)
    print(f"$ {format_argv(argv)}", flush=True)
    try:
        process = subprocess.Popen(
            argv,
            cwd=str(repo_root),
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            start_new_session=True,
            close_fds=True,
        )
    except OSError as exc:
        print(f"ERROR: direct debug app launch failed: {exc}", flush=True)
        return False
    print(f"Started direct debug app process PID {process.pid}", flush=True)
    return True


def operation_app_launch_existing(repo_root: Path, args: Dict[str, Any]) -> int:
    bundle = debug_app_bundle_path()
    staged_value = args.get("stagedBundle")
    staged_bundle = Path(str(staged_value)) if staged_value else None
    activated = False
    executable = bundle / "Contents" / "MacOS" / "RepoPrompt"
    if staged_bundle is None and (not bundle.exists() or not executable.is_file() or not os.access(executable, os.X_OK)):
        print(f"ERROR: existing debug app bundle is not launchable: {bundle}", flush=True)
        print("Build it first with './conductor build' or './conductor run'.", flush=True)
        return 1
    metadata = display_lock_metadata(
        lock_kind="live-app",
        ticket=os.environ.get("REPOPROMPT_CONDUCTOR_JOB_TICKET"),
        operation="app launch-existing" if staged_bundle is None else "app activate-staged-and-launch",
        operation_label="app launch-existing" if staged_bundle is None else "app activate staged and launch",
        repo_root=repo_root,
        repo_hash=None,
    )
    try:
        with machine_exclusive_lock(live_app_lock_path(), metadata, "live-app lock"):
            if staged_bundle is None:
                report_launch_bundle_details(repo_root, bundle)
            print("Stopping existing RepoPrompt CE debug app instance", flush=True)
            stop_code = _operation_app_stop_unlocked(repo_root, {"guardDelayedLaunch": bool(args.get("guardDelayedLaunch"))})
            if stop_code != 0:
                return stop_code
            if staged_bundle is not None:
                activate_staged_debug_bundle(staged_bundle, bundle)
                activated = True
                report_launch_bundle_details(repo_root, bundle)
            executable = bundle / "Contents" / "MacOS" / "RepoPrompt"
            if not executable.is_file() or not os.access(executable, os.X_OK):
                print(f"ERROR: activated debug app bundle is not launchable: {bundle}", flush=True)
                return 1
            repair_debug_app_compatibility_link(repo_root, bundle)
            app_args = [str(arg) for arg in args.get("appArgs") or []]
            argv = ["open", "-n", str(bundle)]
            if app_args:
                argv.extend(["--args", *app_args])
            code, _stdout, stderr = run_operation_command(
                "launch existing debug app",
                argv,
                repo_root,
                allow_exit_codes={0, 1},
            )
            if code != 0:
                if code == 1 and launch_services_cannot_resolve_executable(stderr):
                    if not launch_debug_app_executable_directly(executable, app_args, repo_root):
                        return 1
                else:
                    print(f"FAILED stage 'launch existing debug app' with status {code}", flush=True)
                    return code
            try:
                launched_pids = wait_for_debug_app_process()
            except ProcessIdentityError as exc:
                print(f"ERROR: could not safely identify the launched RepoPrompt CE debug app process: {exc}", flush=True)
                return 1
            if not launched_pids:
                print("ERROR: launch request returned, but no matching RepoPrompt CE debug app process appeared within 10 seconds.", flush=True)
                _operation_app_stop_unlocked(repo_root, {"guardDelayedLaunch": True})
                return 1
            print(f"Observed launched RepoPrompt CE debug PID(s): {', '.join(launched_pids)}", flush=True)
        return 0
    finally:
        if staged_bundle is not None and not activated:
            cleanup_staged_debug_bundle(staged_bundle)


def operation_debug_app_build_then_launch(repo_root: Path, args: Dict[str, Any]) -> int:
    package_config = debug_package_config_for_request(args)
    package_code, staged_bundle = package_debug_app_under_heavy(
        repo_root, "debug app build/package", package_config=package_config
    )
    if package_code != 0 or staged_bundle is None:
        print("Package failed; no live bundle or stop/launch lifecycle action was performed.", flush=True)
        return package_code or 1
    launch_args = dict(args)
    launch_args.setdefault("appArgs", [])
    launch_args["stagedBundle"] = str(staged_bundle)
    return operation_app_launch_existing(repo_root, launch_args)


def operation_app_status(repo_root: Path) -> int:
    bundle = debug_app_bundle_path()
    print("RepoPrompt CE debug app status")
    print(f"  Debug app bundle: {bundle}")
    print("  Running matching debug app PIDs: ", end="")
    try:
        pids = find_debug_app_pids()
    except ProcessIdentityError as exc:
        print("unknown")
        print(f"ERROR: could not safely identify the debug app process: {exc}")
        return 1
    print(", ".join(pids) if pids else "none")
    print(f"  Bundle exists: {'yes' if bundle.exists() else 'no'}")
    if bundle.exists():
        # Keep the signing/storage probes aligned with Scripts/run.sh launch diagnostics.
        codesign = subprocess.run(["codesign", "-dv", str(bundle)], text=True, capture_output=True)
        details = (codesign.stdout or "") + (codesign.stderr or "")
        team = "<missing>"
        authorities: List[str] = []
        for line in details.splitlines():
            if line.startswith("TeamIdentifier="):
                team = line.split("=", 1)[1] or "<missing>"
            elif line.startswith("Authority="):
                authorities.append(line.split("=", 1)[1])
        print(f"  Signing team: {team}")
        print(f"  Signing authorities: {', '.join(authorities) if authorities else '<none/ad-hoc>'}")
        plist = bundle / "Contents" / "Info.plist"
        marker = subprocess.run(
            ["plutil", "-extract", "RepoPromptDebugSecureStorageBackend", "raw", "-o", "-", str(plist)],
            text=True,
            capture_output=True,
        )
        print(f"  Debug secure storage marker: {marker.stdout.strip() if marker.returncode == 0 and marker.stdout.strip() else '<missing>'}")
        for line in provenance_report_lines(repo_root, bundle):
            print(line)
    status_script = repo_root / "Scripts" / "install_debug_cli.sh"
    code, _stdout, _stderr = run_operation_command("debug CLI status", [str(status_script), "status"], repo_root, allow_exit_codes={0, 1})
    return 0 if code in {0, 1} else code


def operation_app_stop(repo_root: Path, args: Dict[str, Any]) -> int:
    metadata = display_lock_metadata(
        lock_kind="live-app",
        ticket=os.environ.get("REPOPROMPT_CONDUCTOR_JOB_TICKET"),
        operation="app stop",
        operation_label="app stop",
        repo_root=repo_root,
        repo_hash=None,
    )
    with machine_exclusive_lock(live_app_lock_path(), metadata, "live-app lock"):
        return _operation_app_stop_unlocked(repo_root, args)


def operation_swift_build_all(repo_root: Path) -> int:
    canonical_swift = str(repo_root / "Scripts" / "canonical_swift.sh")
    for product in ["RepoPrompt", "repoprompt-mcp", "repoprompt-gateway"]:
        code, _stdout, _stderr = run_operation_command(
            f"swift build --product {product}",
            [canonical_swift, "build", "--product", product],
            repo_root,
        )
        if code != 0:
            return code
    return 0


def operation_release_preflight_missing(_repo_root: Path) -> int:
    print("ERROR: Scripts/release.sh does not exist, so release preflight is not available yet.", flush=True)
    print("See docs/open-source-readiness.md for release-readiness notes.", flush=True)
    return 1


def operation_smoke(repo_root: Path, args: Dict[str, Any]) -> int:
    env = os.environ.copy()
    packaged_app = args.get("packagedApp")
    if packaged_app:
        argv = [
            str(repo_root / "Scripts" / "smoke_packaged_mcp_roundtrip.sh"),
            str(packaged_app),
            "Conductor packaged app",
        ]
        if args.get("artifactManifest"):
            argv.append(str(args["artifactManifest"]))
        code, _stdout, _stderr = run_operation_command(
            "packaged app MCP roundtrip",
            argv,
            repo_root,
            env=env,
        )
        return code

    window_id = int(args.get("windowId") or 1)
    workspace = str(args.get("workspace") or "repoprompt-ce")
    operation_timeout = float(args.get("operationTimeout") or MEDIUM_TIMEOUT_SECONDS)
    deadline = now() + operation_timeout

    launched = bool(args.get("launch"))
    if launched:
        code = operation_debug_app_build_then_launch(repo_root, {"appArgs": []})
        if code != 0:
            return code

    if launched:
        try:
            cli = resolve_embedded_helper(debug_app_bundle_path())
        except (ConductorError, FileNotFoundError, OSError) as exc:
            print(f"ERROR: could not resolve exact helper from launched app: {exc}", flush=True)
            return 1
        print(f"Resolved launched app embedded helper: {cli}", flush=True)
    else:
        cli = require_debug_cli()
        if not cli:
            return 1

    if launched:
        print("Polling rpce-cli-debug windows until the app is ready...", flush=True)
        while True:
            code, stdout, stderr = run_operation_command("windows readiness", [cli, "-e", "windows"], repo_root, env=env, allow_exit_codes={0, 1})
            if code == 0:
                break
            if now() >= deadline:
                print("ERROR: timed out waiting for rpce-cli-debug windows after launch", flush=True)
                return code or 1
            time.sleep(2.0)

    stages = [
        ("windows", [cli, "-e", "windows"]),
        ("workspace switch", [cli, "-w", str(window_id), "-e", f"workspace switch {workspace}"]),
        ("tree roots", [cli, "-w", str(window_id), "-e", "tree --type roots"]),
        ("manage_worktree list", [cli, "-w", str(window_id), "-e", "manage_worktree op=list"]),
        (
            "agent_manage roles",
            routed_structured_cli_argv(cli, window_id, "agent_manage", {"op": "list_agents", "roles_only": True}),
        ),
    ]
    for name, argv in stages:
        allow_exit_codes = {0, 1} if name == "workspace switch" else None
        restore_retry_deadline = min(deadline, now() + 8.0)
        while True:
            code, stdout, stderr = run_operation_command(name, argv, repo_root, env=env, allow_exit_codes=allow_exit_codes)
            combined_output = "\n".join(part for part in (stderr, stdout) if part)
            if name == "workspace switch" and code == 1 and is_already_on_workspace(combined_output, workspace):
                print(f'Already on workspace "{workspace}"; continuing smoke flow.', flush=True)
                code = 0
            elif name == "workspace switch" and code == 1 and is_workspace_restore_in_progress(combined_output, workspace):
                if now() < restore_retry_deadline:
                    print(
                        f'Workspace restore for "{workspace}" is still in progress; retrying switch.',
                        flush=True,
                    )
                    time.sleep(0.5)
                    continue
            if code != 0:
                if name == "workspace switch" and code == 1:
                    print(f"FAILED stage '{name}' with status {code}", flush=True)
                return code
            break

    if args.get("executionLocationUI"):
        debug_pids = find_debug_app_pids()
        if len(debug_pids) != 1:
            print(
                "ERROR: execution-location UI smoke requires exactly one running RepoPrompt debug app "
                f"matching {debug_app_executable_path()}; found {len(debug_pids)}.",
                flush=True,
            )
            return 1
        code, _stdout, _stderr = run_operation_command(
            "execution location UI smoke",
            [str(repo_root / "Scripts" / "smoke_agent_execution_location_popover.sh"), debug_pids[0]],
            repo_root,
            env=env,
            timeout=execution_location_ui_smoke_timeout(env),
        )
        if code != 0:
            return code

    if args.get("agentRun"):
        agent_timeout = float(args.get("agentTimeout") or SMOKE_AGENT_WAIT_SECONDS)
        start_payload = {
            "op": "start",
            "model_id": "explore",
            "session_name": "CE debug CLI smoke",
            "message": "Reply exactly with CE_AGENT_RUN_SMOKE_OK and stop. Do not edit files.",
            "detach": True,
        }
        code, stdout, _stderr = run_operation_command(
            "agent_run start",
            routed_structured_cli_argv(cli, window_id, "agent_run", start_payload),
            repo_root,
            env=env,
        )
        if code != 0:
            return code
        session_id = None
        try:
            session_id = find_session_id(json.loads(stdout))
        except json.JSONDecodeError:
            session_id = find_session_id_in_text(stdout)
        if not session_id:
            print("ERROR: Could not parse session_id from agent_run start output.", flush=True)
            print("Manual wait hint: rpce-cli-debug -w 1 -c agent_run -j '{\"op\":\"wait\",\"session_id\":\"<session_id>\",\"timeout\":120}'", flush=True)
            return 1
        wait_payload = {"op": "wait", "session_id": session_id, "timeout": agent_timeout}
        code, _stdout, _stderr = run_operation_command(
            "agent_run wait",
            routed_structured_cli_argv(cli, window_id, "agent_run", wait_payload),
            repo_root,
            env=env,
            timeout=agent_timeout + 10.0,
        )
        if code != 0:
            return code
    return 0


def directory_size_bytes(path: Path) -> Optional[int]:
    try:
        if not path.exists():
            return None
        if path.is_symlink():
            path = path.resolve(strict=True)
    except OSError:
        return None

    # Prefer the platform disk-usage tool for explicit cache diagnostics. It is
    # read-only and much faster than Python-level recursive stat walks for large
    # SwiftPM scratch directories. Fall back to a Python walk for small tests or
    # unusual environments where `du` is unavailable.
    try:
        result = subprocess.run(
            ["du", "-sk", str(path)],
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
            timeout=120,
            check=False,
        )
        if result.returncode == 0:
            first = result.stdout.strip().split()[0]
            return int(first) * 1024
    except (OSError, subprocess.SubprocessError, ValueError, IndexError):
        pass

    total = 0
    stack = [path]
    while stack:
        current = stack.pop()
        try:
            with os.scandir(current) as entries:
                for entry in entries:
                    try:
                        stat_result = entry.stat(follow_symlinks=False)
                    except OSError:
                        continue
                    if entry.is_dir(follow_symlinks=False):
                        stack.append(Path(entry.path))
                    else:
                        total += stat_result.st_size
        except NotADirectoryError:
            try:
                total += current.stat(follow_symlinks=False).st_size
            except OSError:
                pass
        except OSError:
            continue
    return total


def latest_mtime(path: Path) -> Optional[float]:
    try:
        return path.stat(follow_symlinks=False).st_mtime
    except OSError:
        return None


def managed_worktree_container(repo_root: Path) -> Optional[Path]:
    parent = repo_root.parent
    try:
        if parent.parent.name == ".repoprompt-worktrees":
            return parent
    except IndexError:
        return None
    return None


def operation_diagnostics_build_cache(repo_root: Path, args: Dict[str, Any]) -> int:
    limit = int(args.get("limit") or BUILD_CACHE_DIAGNOSTIC_MAX_ROWS)
    limit = max(1, min(limit, 100))
    current_build = repo_root / ".build"

    print("Build cache diagnostics", flush=True)
    if current_build.exists():
        symlink_note = ""
        if current_build.is_symlink():
            with contextlib.suppress(OSError):
                symlink_note = f" -> {current_build.resolve(strict=True)}"
        print(f"Current .build: {format_bytes(directory_size_bytes(current_build))}{symlink_note}", flush=True)
    else:
        print("Current .build: missing", flush=True)

    container = managed_worktree_container(repo_root)
    if container is None or not container.exists():
        print("Managed worktree container: not detected", flush=True)
        return 0

    rows: List[Tuple[int, Optional[float], str]] = []
    for child in sorted(container.iterdir(), key=lambda item: item.name):
        if not child.is_dir():
            continue
        build_dir = child / ".build"
        size = directory_size_bytes(build_dir)
        if size is None:
            continue
        rows.append((size, latest_mtime(build_dir), child.name))

    total = sum(size for size, _mtime, _name in rows)
    print(f"Managed worktree container: {container}", flush=True)
    print(f"Worktree .build total: {format_bytes(total)} across {len(rows)} build director{'y' if len(rows) == 1 else 'ies'}", flush=True)
    if not rows:
        return 0

    print("Top .build directories:", flush=True)
    for size, mtime, name in sorted(rows, key=lambda row: row[0], reverse=True)[:limit]:
        mtime_text = "unknown" if mtime is None else time.strftime("%Y-%m-%d %H:%M", time.localtime(mtime))
        print(f"  {format_bytes(size):>9}  {name}  modified={mtime_text}", flush=True)
    return 0


def operation_diagnostics_agent_mode_on(repo_root: Path, args: Dict[str, Any]) -> int:
    cli = require_debug_cli()
    if not cli:
        return 1
    window_id = int(args.get("windowId") or 1)
    log_file = str(args.get("logFile") or "/tmp/repoprompt-ce-claude-raw-events")
    settings = [
        {"op": "list", "group": "agent_mode", "detailed": True},
        {"op": "set", "key": "agent_mode.claude_raw_event_logging_enabled", "value": True},
        {"op": "set", "key": "agent_mode.claude_raw_event_log_file_path", "value": log_file},
        {"op": "set", "key": "agent_mode.perf_diagnostics_enabled", "value": True},
    ]
    for payload in settings:
        code, _stdout, _stderr = run_operation_command(
            f"app_settings {payload.get('op')} {payload.get('key') or payload.get('group')}",
            routed_structured_cli_argv(cli, window_id, "app_settings", payload),
            repo_root,
        )
        if code != 0:
            return code
    print(f"Agent Mode diagnostics enabled. Raw Claude events log: {log_file}", flush=True)
    return 0


def operation_parallel_root_test(repo_root: Path, args: Dict[str, Any]) -> int:
    run_id = args.get("parallelRunId")
    ticket_id = os.environ.get("REPOPROMPT_CONDUCTOR_JOB_TICKET")
    candidate_value = args.get("parallelCandidate")
    test_list_value = args.get("parallelTestList")
    workdir_value = args.get("parallelWorkdir")
    if not all(
        isinstance(value, str) and value
        for value in (run_id, ticket_id, candidate_value, test_list_value, workdir_value)
    ):
        print("parallel test source/artifact integrity check failed: internal job identity is incomplete", file=sys.stderr)
        return XCTEST_SOURCE_ARTIFACT_INTEGRITY_EXIT_CODE
    try:
        parsed_run_id = str(uuid.UUID(str(run_id)))
    except ValueError:
        parsed_run_id = ""
    if parsed_run_id != run_id:
        print("parallel test source/artifact integrity check failed: run ID is invalid", file=sys.stderr)
        return XCTEST_SOURCE_ARTIFACT_INTEGRITY_EXIT_CODE

    candidate_path = Path(str(candidate_value))
    test_list_path = Path(str(test_list_value))
    workdir = Path(str(workdir_value))
    expected_parent = candidate_path.parent
    names_are_valid = (
        candidate_path.name == f"parallel-xctest-{run_id}-candidate.json"
        and test_list_path.name == f"parallel-xctest-{run_id}-test-list.txt"
        and workdir.name == f"parallel-xctest-{run_id}"
    )
    if (
        not candidate_path.is_absolute()
        or not test_list_path.is_absolute()
        or not workdir.is_absolute()
        or test_list_path.parent != expected_parent
        or workdir.parent != expected_parent
        or not names_are_valid
    ):
        print("parallel test source/artifact integrity check failed: per-job paths are invalid", file=sys.stderr)
        return XCTEST_SOURCE_ARTIFACT_INTEGRITY_EXIT_CODE

    snapshot_s0 = source_snapshot(repo_root, os.environ.copy())
    if snapshot_s0 is None:
        print("parallel test source/artifact integrity check failed: source snapshot S0 is unavailable", file=sys.stderr)
        return XCTEST_SOURCE_ARTIFACT_INTEGRITY_EXIT_CODE

    build_argv = [
        str(repo_root / "Scripts" / "canonical_swift.sh"),
        "build",
        "--build-tests",
    ]
    print("\n==> Build root XCTest artifact", flush=True)
    print(f"$ {format_argv(build_argv)}", flush=True)
    build_started = time.monotonic()
    try:
        build_exit_code = subprocess.run(
            build_argv,
            cwd=str(repo_root),
            stdin=subprocess.DEVNULL,
            check=False,
        ).returncode
    except (OSError, subprocess.SubprocessError) as exc:
        print(f"could not start root test build: {exc}", file=sys.stderr, flush=True)
        return 1
    build_duration = time.monotonic() - build_started
    if build_exit_code != 0:
        return int(build_exit_code)

    snapshot_s1 = source_snapshot(repo_root, os.environ.copy())
    if snapshot_s1 is None:
        print("parallel test source/artifact integrity check failed: source snapshot S1 is unavailable", file=sys.stderr)
        return XCTEST_SOURCE_ARTIFACT_INTEGRITY_EXIT_CODE
    if snapshot_s1 != snapshot_s0:
        print("parallel test source/artifact integrity check failed: source changed during build", file=sys.stderr)
        return XCTEST_SOURCE_ARTIFACT_INTEGRITY_EXIT_CODE

    toolchain = artifact_toolchain_snapshot(repo_root, os.environ.copy())
    if not _valid_parallel_toolchain(toolchain):
        print("parallel test source/artifact integrity check failed: toolchain is unavailable", file=sys.stderr)
        return XCTEST_SOURCE_ARTIFACT_INTEGRITY_EXIT_CODE
    artifact_path = discover_root_test_artifact(repo_root, toolchain["arch"])
    if artifact_path is None:
        print("parallel test source/artifact integrity check failed: built root artifact is missing", file=sys.stderr)
        return XCTEST_SOURCE_ARTIFACT_INTEGRITY_EXIT_CODE
    try:
        artifact_fingerprint = test_artifact_fingerprint(artifact_path)
    except ArtifactUnavailableError as exc:
        print(f"parallel test source/artifact integrity check failed: {exc}", file=sys.stderr)
        return XCTEST_SOURCE_ARTIFACT_INTEGRITY_EXIT_CODE

    filter_value = args.get("filter")
    normalized_filter = str(filter_value) if isinstance(filter_value, str) and filter_value else None
    runner_started_at = now()
    candidate = {
        "schema_version": PARALLEL_TEST_CANDIDATE_SCHEMA_VERSION,
        "fingerprint_version": ARTIFACT_FINGERPRINT_VERSION,
        "kind": PARALLEL_TEST_CANDIDATE_KIND,
        "run_id": run_id,
        "ticket_id": ticket_id,
        "filter": normalized_filter,
        "evidence_scope": parallel_test_evidence_scope(normalized_filter),
        "source_snapshot": snapshot_s0,
        "env_gates": artifact_env_gates(os.environ),
        "worker_runtime_gates": parallel_xctest_runtime_gates(os.environ),
        "toolchain": toolchain,
        "artifact_path": str(artifact_path.resolve()),
        "artifact_fingerprint": artifact_fingerprint,
        "build_duration_seconds": build_duration,
        "runner_started_at": runner_started_at,
    }
    try:
        write_build_ticket(candidate_path, candidate)
    except OSError as exc:
        print(
            f"parallel test source/artifact integrity check failed: "
            f"could not write candidate manifest ({exc})",
            file=sys.stderr,
        )
        return XCTEST_SOURCE_ARTIFACT_INTEGRITY_EXIT_CODE

    runner_argv = [
        sys.executable,
        "-u",
        str(repo_root / "Scripts" / "parallel_xctest_runner.py"),
        "--workers",
        str(args.get("workers", 8)),
        "--bundle",
        candidate["artifact_path"],
        "--test-list",
        str(test_list_path),
        "--generate-test-list",
        "--workdir",
        str(workdir),
        "--exclusive-suite",
        r"^RepoPromptTests\.TabContextRoutingTests$",
    ]
    if normalized_filter is not None:
        runner_argv.extend(["--filter", normalized_filter])
    print("\n==> Run parallel root XCTest suites", flush=True)
    print(f"$ {format_argv(runner_argv)}", flush=True)
    try:
        return int(
            subprocess.run(
                runner_argv,
                cwd=str(repo_root),
                stdin=subprocess.DEVNULL,
                check=False,
            ).returncode
        )
    except (OSError, subprocess.SubprocessError) as exc:
        print(f"could not start parallel XCTest runner: {exc}", file=sys.stderr, flush=True)
        return 1


def run_operation_runner(payload_json: str) -> int:
    payload = json.loads(payload_json)
    # Popped so descendants never inherit (and overwrite) this job's runner file.
    timings_path = os.environ.pop(TIMING_RUNNER_PATH_ENV_KEY, None)
    recorder: Optional[Any] = None
    if timings_path and PIPELINE_METRICS is not None and PIPELINE_METRICS.timing_enabled(os.environ):
        try:
            started = time.monotonic_ns()
            recorder = PIPELINE_METRICS.PipelineRecorder(
                origin_ns=started, process="runner", wall_anchor=(time.time_ns(), started)
            )
        except Exception:
            recorder = None
    if recorder is None:
        return _run_operation_runner(payload)
    start = time.monotonic_ns()
    try:
        with artifact_operation_sink(recorder.operation_sink("runner")):
            return _run_operation_runner(payload)
    finally:
        try:
            recorder.record_operation("runner_operation", time.monotonic_ns() - start, None, "runner")
            PIPELINE_METRICS.atomic_write_json(
                Path(str(timings_path)),
                {
                    "schema": 1,
                    "process": "runner",
                    "kind": str(payload.get("kind")),
                    "ticket": os.environ.get("REPOPROMPT_CONDUCTOR_JOB_TICKET"),
                    "conductorDigest": CONDUCTOR_DIGEST,
                    "phaseMetrics": recorder.finalize(),
                },
            )
        except Exception:
            pass


def _run_operation_runner(payload: Dict[str, Any]) -> int:
    kind = payload.get("kind")
    args = payload.get("args") or {}
    repo_root = Path(payload.get("repoRoot") or resolve_repo_root()).resolve()
    if kind == "swift_build_all":
        return operation_swift_build_all(repo_root)
    if kind == "parallel_root_test":
        return operation_parallel_root_test(repo_root, args)
    if kind == "app_stop":
        return operation_app_stop(repo_root, args)
    if kind == "app_status":
        return operation_app_status(repo_root)
    if kind == "app_launch_existing":
        return operation_app_launch_existing(repo_root, args)
    if kind == "debug_app_build_then_launch":
        return operation_debug_app_build_then_launch(repo_root, args)
    if kind == "smoke":
        return operation_smoke(repo_root, args)
    if kind == "diagnostics_agent_mode_on":
        return operation_diagnostics_agent_mode_on(repo_root, args)
    if kind == "diagnostics_build_cache":
        return operation_diagnostics_build_cache(repo_root, args)
    if kind == "release_preflight_missing":
        return operation_release_preflight_missing(repo_root)
    print(f"unknown internal operation runner kind: {kind}", file=sys.stderr)
    return 2


def client_metrics_sink(collected: List[Dict[str, Any]]) -> Any:
    """Collect bounded client-side operation timings for ``clientMetrics``."""

    def sink(name: str, duration_ns: Optional[int], counters: Optional[Dict[str, int]] = None, **_kwargs: Any) -> None:
        if len(collected) >= CLIENT_METRICS_MAX_ITEMS or duration_ns is None:
            return
        item: Dict[str, Any] = {"name": str(name)[:64], "durationNs": int(duration_ns)}
        if counters:
            item["counters"] = {str(key)[:64]: int(value) for key, value in list(counters.items())[:8]}
        collected.append(item)

    return sink


def enqueue_and_maybe_wait(
    paths: Paths,
    operation: str,
    args: Dict[str, Any],
    global_flags: argparse.Namespace,
    client_metrics: Optional[List[Dict[str, Any]]] = None,
) -> int:
    env_snapshot = OperationRegistry.client_env_snapshot()  # Step 10: validates before any daemon contact
    ensure_daemon(paths, start_if_needed=True)
    request = {
        "type": "enqueue",
        "operation": operation,
        "args": args,
        "requestKey": global_flags.request_key,
        "timeout": global_flags.timeout,
        "verbose": global_flags.verbose,
        "env": env_snapshot,
    }
    if client_metrics:
        # Advisory and outside the fingerprint material (request identity).
        request["clientMetrics"] = list(client_metrics)[:CLIENT_METRICS_MAX_ITEMS]
    enqueue_payload = request_daemon(paths, request, timeout=10.0)
    if global_flags.async_mode:
        if global_flags.json:
            print_json(enqueue_payload)
        else:
            print(f"ticket: {enqueue_payload.get('ticket')}")
            print(f"state:  {enqueue_payload.get('state')}")
            print(f"lanes:  {', '.join(enqueue_payload.get('lanes') or []) or 'none'}")
            print(f"log:    {enqueue_payload.get('logPath')}")
            if enqueue_payload.get("reused"):
                print("reused existing queued/running job for request key")
            render_superseded_jobs(enqueue_payload)
            print(f"wait:   ./conductor job wait {enqueue_payload.get('ticket')}")
        return 0

    ticket = enqueue_payload.get("ticket")
    if global_flags.json:
        final = payload_with_output_summary(wait_for_terminal(paths, ticket, request_key=None, json_mode=True))
        print_json({"enqueue": enqueue_payload, "result": final})
        return terminal_exit_code(final)

    print(f"ticket: {ticket}")
    print(f"log:    {enqueue_payload.get('logPath')}")
    print(f"reconnect: ./conductor job wait {ticket}")
    render_superseded_jobs(enqueue_payload)
    output_mode = "full" if global_flags.full_log else "summary"
    final_payload = wait_for_terminal(paths, ticket, request_key=None, json_mode=False, output_mode=output_mode)
    print_terminal_job_output(final_payload, output_mode=output_mode)
    return terminal_exit_code(final_payload)


def parse_no_args(prog: str, argv: List[str]) -> None:
    parser = argparse.ArgumentParser(prog=prog)
    parser.parse_args(argv)


def handle_real_operation(paths: Paths, operation: str, argv: List[str]) -> int:
    global_flags, rest = split_operation_flags(argv)
    if global_flags.timeout is not None and global_flags.timeout < 0:
        raise ConductorError("timeout must be non-negative")

    args: Dict[str, Any] = {}
    client_metrics: Optional[List[Dict[str, Any]]] = None
    if operation in {
        "doctor",
        "guardrails",
        "install-debug-cli",
        "debug-cli-status",
        "format",
        "format-check",
        "lint",
        "format-tools-status",
        "check-format-tools",
        "install-format-tools",
    }:
        parse_no_args(f"conductor {operation}", rest)
    elif operation == "build":
        parser = argparse.ArgumentParser(prog="conductor build")
        parser.add_argument("--fast", action="store_true")
        parser.add_argument("--optimized", action="store_true")
        parser.add_argument("--optimized-incremental", action="store_true")
        ns = parser.parse_args(rest)
        if ns.optimized and ns.optimized_incremental:
            raise ConductorError(OPTIMIZED_LANES_EXCLUSIVE_REJECTION)
        if ns.fast:
            args["fastPackage"] = True
        if ns.optimized:
            # Only when true: the default request's args and identity stay unchanged.
            args[OPTIMIZED_LANE_ARG] = True
        if ns.optimized_incremental:
            args[OPTIMIZED_INCREMENTAL_LANE_ARG] = True
    elif operation == "swift-build":
        parser = argparse.ArgumentParser(prog="conductor swift-build")
        parser.add_argument("--product", required=True, choices=["RepoPrompt", "repoprompt-mcp", "repoprompt-gateway", "all"])
        ns = parser.parse_args(rest)
        args["product"] = ns.product
    elif operation == "dsym":
        parser = argparse.ArgumentParser(prog="conductor dsym")
        parser.add_argument("--product", default="all", choices=list(DEBUG_DSYM_PRODUCTS))
        ns = parser.parse_args(rest)
        args["product"] = ns.product
    elif operation == "package":
        parser = argparse.ArgumentParser(prog="conductor package")
        parser.add_argument("config", choices=["debug", "release"])
        ns = parser.parse_args(rest)
        args["config"] = ns.config
    elif operation == "test-parallel":
        parser = argparse.ArgumentParser(prog="conductor test-parallel")
        parser.add_argument("--workers", type=int, default=8)
        parser.add_argument("--filter")
        ns = parser.parse_args(rest)
        if ns.workers < 1:
            raise ConductorError("--workers must be at least 1")
        args["workers"] = ns.workers
        if ns.filter:
            args["filter"] = ns.filter
            preflight_test_filter(paths.repo_root, operation, ns.filter)
    elif operation == "test-artifact":
        parser = argparse.ArgumentParser(prog="conductor test-artifact")
        parser.add_argument("--filter", required=True)
        parser.add_argument("--no-xctest-deadlines", action="store_true")
        parser.add_argument("--xctest-stall-seconds", type=float)
        parser.add_argument("--xctest-stall-wake-probe", action="store_true")
        ns = parser.parse_args(rest)
        if ns.xctest_stall_seconds is not None and (
            not math.isfinite(ns.xctest_stall_seconds) or ns.xctest_stall_seconds <= 0
        ):
            raise ConductorError("--xctest-stall-seconds must be greater than zero")
        if ns.xctest_stall_wake_probe and ns.xctest_stall_seconds is None:
            raise ConductorError("--xctest-stall-wake-probe requires --xctest-stall-seconds")
        if ns.no_xctest_deadlines and (ns.xctest_stall_seconds is not None or ns.xctest_stall_wake_probe):
            raise ConductorError("--no-xctest-deadlines cannot be combined with XCTest stall diagnostics")
        args["filter"] = ns.filter
        if ns.no_xctest_deadlines or os.environ.get("REPOPROMPT_DEV_XCTEST_DEADLINES") == "0":
            args["xctestDeadlines"] = False
        if ns.xctest_stall_seconds is not None:
            args["xctestStallSeconds"] = ns.xctest_stall_seconds
        if ns.xctest_stall_wake_probe:
            args["xctestStallWakeProbe"] = True
        preflight_test_filter(paths.repo_root, operation, ns.filter)
        client_sink = None
        if PIPELINE_METRICS is not None and PIPELINE_METRICS.timing_enabled(os.environ):
            client_metrics = []
            client_sink = client_metrics_sink(client_metrics)
        # Step 7: cheap admission only; the daemon evaluates once at execution.
        admit_test_artifact(paths.repo_root, paths.jobs_dir, sink=client_sink)
    elif operation in {"test", "provider-test", "core-test"}:
        parser = argparse.ArgumentParser(prog=f"conductor {operation}")
        mode = parser.add_mutually_exclusive_group()
        mode.add_argument("--list", action="store_true")
        mode.add_argument("--filter")
        parser.add_argument("--test-product")
        parser.add_argument("--no-xctest-deadlines", action="store_true")
        parser.add_argument("--xctest-stall-seconds", type=float)
        parser.add_argument("--xctest-stall-wake-probe", action="store_true")
        parser.add_argument("--benchmark-driver-diagnostics", action="store_true")
        ns = parser.parse_args(rest)
        if ns.xctest_stall_seconds is not None and (
            not math.isfinite(ns.xctest_stall_seconds) or ns.xctest_stall_seconds <= 0
        ):
            raise ConductorError("--xctest-stall-seconds must be greater than zero")
        if ns.xctest_stall_wake_probe and ns.xctest_stall_seconds is None:
            raise ConductorError("--xctest-stall-wake-probe requires --xctest-stall-seconds")
        if ns.no_xctest_deadlines and (ns.xctest_stall_seconds is not None or ns.xctest_stall_wake_probe):
            raise ConductorError("--no-xctest-deadlines cannot be combined with XCTest stall diagnostics")
        if ns.benchmark_driver_diagnostics:
            if operation != "test":
                raise ConductorError("--benchmark-driver-diagnostics is only supported for the root debug test operation")
            if ns.list:
                raise ConductorError("--benchmark-driver-diagnostics cannot be combined with --list")
            if ns.test_product:
                raise ConductorError("--benchmark-driver-diagnostics cannot be combined with --test-product")
        if ns.list and (ns.xctest_stall_seconds is not None or ns.xctest_stall_wake_probe):
            raise ConductorError("--list cannot be combined with XCTest stall diagnostics")
        if ns.list and ns.test_product:
            raise ConductorError("--list cannot be combined with --test-product")
        if ns.list:
            args["list"] = True
        if ns.filter:
            args["filter"] = ns.filter
        if ns.test_product:
            args["testProduct"] = ns.test_product
        deadlines_disabled = ns.no_xctest_deadlines or os.environ.get("REPOPROMPT_DEV_XCTEST_DEADLINES") == "0"
        if deadlines_disabled and not ns.list:
            args["xctestDeadlines"] = False
        if ns.xctest_stall_seconds is not None:
            args["xctestStallSeconds"] = ns.xctest_stall_seconds
        if ns.xctest_stall_wake_probe:
            args["xctestStallWakeProbe"] = True
        if ns.benchmark_driver_diagnostics:
            args[BENCHMARK_DRIVER_DIAGNOSTICS_ARG] = True
        if ns.filter:
            preflight_test_filter(paths.repo_root, operation, ns.filter)
    elif operation == "run":
        # Only a leading --optimized or --optimized-incremental selects a lane; everything after it keeps
        # today's pass-through rule, so `run -- --optimized` and a repeat of the same flag are application
        # arguments. The other lane flag right after the first is a mutually exclusive selection.
        if rest and rest[0] in OPTIMIZED_LANE_FLAGS:
            if len(rest) > 1 and rest[1] in OPTIMIZED_LANE_FLAGS and rest[1] != rest[0]:
                raise ConductorError(OPTIMIZED_LANES_EXCLUSIVE_REJECTION)
            args[OPTIMIZED_LANE_FLAG_ARGS[rest[0]]] = True
            rest = rest[1:]
        app_args = rest[1:] if rest and rest[0] == "--" else rest
        args["appArgs"] = app_args
    elif operation == "app":
        if not rest or rest[0] not in {"status", "stop", "launch-existing", "relaunch"}:
            raise ConductorError(
                "usage: ./conductor app status|stop | launch-existing [-- <app args...>] "
                "| relaunch [--optimized | --optimized-incremental] [-- <app args...>]"
            )
        args["subcommand"] = rest[0]
        trailing = rest[1:]
        if args["subcommand"] in {"status", "stop"} and trailing:
            raise ConductorError(f"app {args['subcommand']} does not accept application arguments")
        if args["subcommand"] in {"launch-existing", "relaunch"}:
            if trailing and trailing[0] in OPTIMIZED_LANE_FLAGS:
                if args["subcommand"] == "launch-existing":
                    raise ConductorError(LAUNCH_EXISTING_OPTIMIZED_REJECTION)
                if len(trailing) > 1 and trailing[1] in OPTIMIZED_LANE_FLAGS and trailing[1] != trailing[0]:
                    raise ConductorError(OPTIMIZED_LANES_EXCLUSIVE_REJECTION)
                # Only a leading lane flag before '--'; `relaunch -- --optimized` is an app argument.
                args[OPTIMIZED_LANE_FLAG_ARGS[trailing[0]]] = True
                trailing = trailing[1:]
            if trailing and trailing[0] != "--":
                raise ConductorError(f"app {args['subcommand']} application arguments must follow '--'")
            args["appArgs"] = trailing[1:] if trailing else []
    elif operation == "smoke":
        parser = argparse.ArgumentParser(prog="conductor smoke")
        launch_group = parser.add_mutually_exclusive_group()
        launch_group.add_argument("--launch", action="store_true")
        launch_group.add_argument("--packaged-app")
        parser.add_argument("--artifact-manifest")
        parser.add_argument("--workspace", default="repoprompt-ce")
        parser.add_argument("--window-id", type=int, default=1)
        parser.add_argument("--agent-run", action="store_true")
        parser.add_argument("--agent-timeout", type=float, default=SMOKE_AGENT_WAIT_SECONDS)
        parser.add_argument("--execution-location-ui", action="store_true")
        ns = parser.parse_args(rest)
        if ns.agent_timeout < 0:
            raise ConductorError("--agent-timeout must be non-negative")
        if ns.artifact_manifest and not ns.packaged_app:
            raise ConductorError("--artifact-manifest requires --packaged-app")
        if ns.packaged_app and ns.agent_run:
            raise ConductorError("--agent-run is not supported with --packaged-app")
        if ns.packaged_app and ns.execution_location_ui:
            raise ConductorError("--execution-location-ui is not supported with --packaged-app")
        args.update(
            {
                "launch": ns.launch,
                "packagedApp": ns.packaged_app,
                "artifactManifest": ns.artifact_manifest,
                "workspace": ns.workspace,
                "windowId": ns.window_id,
                "agentRun": ns.agent_run,
                "agentTimeout": ns.agent_timeout,
                "executionLocationUI": ns.execution_location_ui,
            }
        )
    elif operation == "diagnostics":
        parser = argparse.ArgumentParser(prog="conductor diagnostics")
        subparsers = parser.add_subparsers(dest="subcommand", required=True)

        agent_mode = subparsers.add_parser("agent-mode-on")
        agent_mode.add_argument("--log-file", default="/tmp/repoprompt-ce-claude-raw-events")
        agent_mode.add_argument("--window-id", type=int, default=1)

        build_cache = subparsers.add_parser("build-cache")
        build_cache.add_argument("--limit", type=int, default=BUILD_CACHE_DIAGNOSTIC_MAX_ROWS)

        ns = parser.parse_args(rest)
        args["subcommand"] = ns.subcommand
        if ns.subcommand == "agent-mode-on":
            args.update({"logFile": ns.log_file, "windowId": ns.window_id})
        elif ns.subcommand == "build-cache":
            if ns.limit <= 0:
                raise ConductorError("diagnostics build-cache --limit must be greater than zero")
            args["limit"] = ns.limit
    elif operation == "release":
        parser = argparse.ArgumentParser(prog="conductor release")
        parser.add_argument("subcommand", choices=["preflight", "artifact", "package", "local-install"])
        ns = parser.parse_args(rest)
        args["subcommand"] = ns.subcommand
    else:
        raise ConductorError(f"unknown operation '{operation}'")

    if client_metrics:
        return enqueue_and_maybe_wait(paths, operation, args, global_flags, client_metrics=client_metrics)
    return enqueue_and_maybe_wait(paths, operation, args, global_flags)


def main(argv: List[str]) -> int:
    repo_root = resolve_repo_root()

    if argv and argv[0] == "__operation_runner":
        if len(argv) != 2:
            raise ConductorError("__operation_runner requires one JSON payload argument")
        return run_operation_runner(argv[1])
    if argv and argv[0] == "__daemon":
        parser = argparse.ArgumentParser(prog="conductor.py __daemon")
        parser.add_argument("--repo-root", required=True)
        ns = parser.parse_args(argv[1:])
        daemon_paths = compute_paths(Path(ns.repo_root))
        ensure_state_dirs(daemon_paths)
        return run_daemon(daemon_paths)

    paths = compute_paths(repo_root)
    ensure_state_dirs(paths)

    if not argv or argv[0] in {"-h", "--help"}:
        print(HELP)
        return 0

    command = argv[0]
    if command == "daemon":
        return handle_daemon_command(paths, argv[1:])
    if command == "status":
        return handle_status_command(paths, argv[1:])
    if command == "job":
        return handle_job_command(paths, argv[1:])
    if command == "metrics":
        return handle_metrics_command(paths, argv[1:])
    if command in {"sleep", "fake-sleep"}:
        return handle_sleep_operation(paths, command, argv[1:])
    if command in IMPLEMENTED_OPERATIONS:
        return handle_real_operation(paths, command, argv[1:])
    raise ConductorError(f"unknown command '{command}'. Run './conductor --help' for usage.")


def cli_main(argv: List[str]) -> int:
    """``main`` with the command line's exit-code mapping.

    Shared by direct execution and ``conductor_entry.py``.
    """
    try:
        return main(argv)
    except KeyboardInterrupt:
        return 130
    except FilterPreflightError as exc:
        print(f"conductor: {exc}", file=sys.stderr)
        return 64
    except ArtifactUnavailableError as exc:
        print(f"conductor: {exc}", file=sys.stderr)
        return 65
    except DebugSymbolPolicyError as exc:
        print(f"conductor: {exc}", file=sys.stderr)
        return DEBUG_SYMBOL_POLICY_EXIT_CODE
    except ConductorError as exc:
        print(f"conductor: {exc}", file=sys.stderr)
        return 1
    except BrokenPipeError:
        return 1


if __name__ == "__main__":
    raise SystemExit(cli_main(sys.argv[1:]))
