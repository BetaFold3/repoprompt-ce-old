#!/usr/bin/env python3
"""Quarantine leaked XCTest fixture workspaces from the RepoPrompt CE workspace store.

Modes (stdlib only, Python 3):

  --dry-run (default)    Scan <app-support>/Workspaces read-only, write a JSON manifest
                         (refuses to write it inside <app-support>), print a summary.
  --apply                Re-validate every manifest candidate of the selected --class
                         values immediately before moving it, then atomically rename it into
                         <app-support>/Workspaces-Quarantine-<UTC timestamp>/ (same volume,
                         never deletes). restore-manifest.jsonl there is a write-ahead journal:
                         an fsynced "moving" intent record precedes every rename and a "moved"
                         (or "failed") record follows it. A failed rename is counted and skipped.
  --restore FILE         Move the entries listed in a restore-manifest.jsonl back. Reconciles
                         interrupted runs (an intent whose target exists and whose origin does
                         not is restored), skips a truncated/corrupt trailing line (reported),
                         and refuses any entry whose original location exists again.
  --self-test            Exercise dry-run/apply/restore against a temporary fake store.

--apply and --restore refuse to run while any RepoPrompt CE app (Dev, release, or an
unbundled SwiftPM .build product), its repoprompt-mcp / CLI helpers, `swift run`, or a
RepoPrompt XCTest bundle is running. There is no override. The app and its helpers MUST stay
quit for the whole run: the script re-checks processes and re-collects the hard-reference set
at start, every 100 moves and at least every ~5 s, and stops cleanly (exit 3) if a process
appears or the references change, but it cannot prevent a launch mid-run (an in-app maintenance
lock is out of scope). After exit 3, quit whatever caused it and re-run --apply with the SAME
manifest and the same --class values (C, P and S together): entries already moved are skipped
because their origin is gone. Class P folders whose workspaces the stopped run had already moved
then stay in Partitions/ (skipped as p_not_all_candidates); to move them as well, --restore the
stopped run's journal first and then re-run --apply. On such a re-run, entries the stopped run
already moved are expected as skipped revalidation:c_not_workspace_dir (C), :not_directory (P),
:scan_failed (S) and :missing (A/B). An exclusive lock file <app-support>/.rpce-quarantine.lock prevents two
--apply/--restore runs from overlapping.

Candidate classes (a directory must match one exactly; everything else is kept):

  A  index-only fixture: name parses as Workspace-<name>-<UUID>; contents are exactly
     AgentSessions/AgentSessionIndex.json plus optional truly-empty Chats/ and _git_data/;
     the index is an empty AgentSessionMetadataIndex; nothing modified in the last 24 h.
  B  ephemeral fixture: as A, plus workspace.json with ephemeralFlag == true whose id/name
     reproduce the directory name; the empty index is optional. Needs separate approval.
  C  non-empty fixture (Step 10b, owner decision O41), tried when A/B do not match: name group in
     FIXTURE_NAME_GROUPS (names unit tests created); not referenced by workspacesIndex.json,
     windowSessions.json, MCP routing or AgentRecovery, by workspace ID or by any session/chat
     UUID in its file names; at most 64 entries, only files, dirs and relative symlinks without a
     ".." component (they stay inside the dir and move with it), each file <= 2 MiB; no path
     under the store owner's home except the prefixes in USER_PATH_EXEMPT; a fixture signal (no
     workspace.json, ephemeralFlag true, or a workspace.json repoPaths entry under /var/folders);
     a workspace.json, if any, is a regular file carrying the directory's id, isSystemWorkspace
     false and no customStoragePath; nothing modified in the last 24 h. A Partitions reference
     does not exclude it (see P). Needs a present, readable workspacesIndex.json.
  P  <app-support>/Partitions/<repo-key> directory whose files are all filepartitions files of
     class C candidates (never a directory that also holds another workspace's file) whose tab
     UUIDs are unreferenced; nothing modified in the last 24 h. --apply moves it only when this
     same invocation has just moved every one of its workspaces as class C, so --class P needs
     --class C and a P-only run moves nothing.
  S  <app-support>/windowSessions.json.sb-* leftover atomic-write file: regular file <= 4 KiB,
     empty or a window-session document without windows, not modified in the last 24 h.

--apply moves every class into the same flat quarantine directory and journals each entry's
origin, so --restore returns Workspaces/, Partitions/ and app-support-root entries to where they
were. The periodic reference re-check tracks Partitions file by file (repo folder + file name) and
expects only the exact files of the class P folders this run has moved or restored to disappear or
reappear; any other Partitions change stops the run.
The home directory for the user-path rule is the app-support folder owner's; the run refuses unless
it runs as that owner and that home is $HOME (sudo, another user, launchd, HOME override), and the
manifest records it.

Workspaces referenced by app state (workspacesIndex.json, windowSessions.json, MCP routing
state, AgentRecovery/v1, Partitions) are always excluded from A and B. Settings/globalSettings.json
per-workspace maps are a soft reference: flagged and counted, not excluded. Any reference
store that exists but is unreadable or has an unknown shape aborts the run (fail closed); a
reference container (MCP, AgentRecovery, AgentRecovery/v1/*, Partitions, Settings) that exists
but is not a real directory (regular file, symlink, dangling symlink, unreadable) also aborts.
"""

from __future__ import annotations

import argparse
import collections
import datetime as _dt
import errno
import fcntl
import json
import os
import pwd
import re
import shutil
import stat
import subprocess
import sys
import tempfile
import time
import unicodedata

MANIFEST_SCHEMA = "rpce-fixture-workspace-quarantine-manifest/v1"
RESTORE_SCHEMA = "rpce-fixture-workspace-quarantine-restore/v1"
DEFAULT_APP_SUPPORT = os.path.expanduser("~/Library/Application Support/RepoPrompt CE")
MIN_AGE_NS = 24 * 3600 * 1_000_000_000
LOCK_NAME = ".rpce-quarantine.lock"
CHECK_EVERY_MOVES = 100
CHECK_EVERY_SECONDS = 5.0

UUID_RE = re.compile(r"^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$")
UUID_ANY_RE = re.compile(r"[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}")
NAME_GROUP_SUFFIX_RE = re.compile(r"[ -][0-9A-Fa-f]{8}$")
PARTITION_FILE_RE = re.compile(
    r"^filepartitions-([0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12})"
    r"(?:-([0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}))?\.json$"
)

DIR_PREFIX = "Workspace-"  # WorkspaceDirectoryName.prefix
INDEX_DIR = "AgentSessions"
INDEX_REL = "AgentSessions/AgentSessionIndex.json"
WORKSPACE_JSON = "workspace.json"
ALLOWED_EMPTY_DIRS = ("Chats", "_git_data")
MAX_TREE_ENTRIES = 32
MAX_INDEX_BYTES = 64 * 1024
MAX_WORKSPACE_JSON_BYTES = 4 * 1024 * 1024

# AgentSessionMetadataIndex (Sources/RepoPromptAgentCore/AgentMode/Runtime/AgentSessionMetadataIndex.swift).
INDEX_KEYS = {"schemaVersion", "generatedAt", "lastReconciledAt", "entries", "quarantinedFiles"}
INDEX_MAX_SCHEMA = 8  # AgentSessionMetadataIndex.currentSchemaVersion
# WorkspaceIndexEntry (WorkspaceManagerViewModel.swift).
WORKSPACE_INDEX_KEYS = {"id", "name", "customStoragePath", "isSystemWorkspace", "isHiddenInMenus"}
# WindowSessionSnapshot / WindowSessionEntry (WindowStateManager.swift); written with version 4.
WINDOW_SESSION_MAX_VERSION = 4
WINDOW_ENTRY_KEYS = {
    "windowKind", "workspaceID", "workspaceName", "isSystemWorkspace", "isEphemeral",
    "primaryRepoPath", "lastFocused", "workspaceInstanceNumber",
}
# MCPRoutingState.ClientRecord (MCPRoutingState.swift); file names from MCPFilesystemIdentity.
ROUTING_FILES = ("mcp-routing.json", "mcp-routing_debug.json")
ROUTING_RECORD_KEYS = {
    "clientID", "lastTransport", "sessionKey", "lastWindowID", "lastWorkspaceID",
    "lastWorkspaceInstanceNumber", "lastConnectionUUID", "lastSeenAt",
}
# GlobalSettingsDocument (GlobalSettingsDocument.swift).
GLOBAL_SETTINGS_KEYS = {
    "schemaVersion", "schemaLineage", "updatedAt", "copySettingsByWorkspaceID",
    "chatSettingsByWorkspaceID", "agentModelsSettingsByWorkspaceID", "globalDefaults",
    "scalarPreferences",
}
GLOBAL_SETTINGS_MAX_SCHEMA = 5
GLOBAL_SETTINGS_LINEAGE = "repoprompt-ce.global-settings"
GLOBAL_SETTINGS_MAPS = ("copySettingsByWorkspaceID", "chatSettingsByWorkspaceID", "agentModelsSettingsByWorkspaceID")
RECOVERY_V1_ENTRIES = {"launch-state.json", "ordinary-exit-settlement.json", "sessions", "tombstones", "attachments"}
IGNORABLE_NAMES = {".DS_Store"}

# Class C name groups: every fixture workspace name group the Step 10b classification found in the
# live store whose name also appears in Tests/ (2026-10-27, owner decision O41).
FIXTURE_NAME_GROUPS = frozenset({
    'Active Workspace',
    'Agent Mode Chat Switch',
    'Agent Run Worktree Start',
    'Cleanup Origin',
    'Code Structure Worktree',
    'Context Builder OMP readiness',
    'Context Builder follow-up timeline test',
    'Cursor Parameter Metadata',
    'D7 Deferral',
    'Default',
    'Delegation Boundary',
    'Displayed Title',
    'Distinct MCP Connection A',
    'Distinct MCP Connection B',
    'Explicit window overrides sticky binding',
    'Fork Session',
    'Lifecycle Contract',
    'List Agents',
    'List Sessions',
    'Loaded workspace',
    'Newer Canonical Selection',
    'Next Readiness Target',
    'OMP Public Start',
    'OMP Qualification Authorized Failure',
    'OMP Qualification Context Replacement',
    'OMP Qualification Fence Replacement',
    'OMP Qualification Fingerprinted',
    'OMP Qualification Frozen Workspace',
    'OMP Qualification Pre-Dispatch Replacement',
    'OMP Qualification Single Deadline',
    'OMP Qualification Start Wait',
    'OMP Qualification Startup Reason',
    'Owning Notice Target',
    'Persistent Agent Mode MCP Read',
    'Phase Target',
    'Policy blank state',
    'Project Alpha',
    'Readiness Target',
    'Remote Naming',
    'Remote Workspace',
    'Removed Listener Target',
    'Resume Ownership',
    'Same ID Cancellation',
    'Second Bootstrap Project',
    'Selection Replay B',
    'Selection Reply',
    'Source',
    'Steer Resume',
    'Suspended blank apply',
    'Titlebar Safety',
    'Unrelated Notice Target',
    'Verified Clear Auto Reset',
    'Watcher Failure Slices',
    'Worktree API Smoke',
    'immediate',
    'oracle-packaging',
    'shared-path',
})
MAX_FIXTURE_TREE_ENTRIES = 64
MAX_FIXTURE_FILE_BYTES = 2 * 1024 * 1024
TEMP_REPO_PATH_RE = re.compile(r"^(?:/private)?/var/folders/")  # class C signal: workspace.json repoPaths only
# Home paths that leaked fixtures mention without naming a real repo (live store 2026-10-28: the
# app-support store, plain and percent-encoded, and Codex state). Any other home path excludes C.
USER_PATH_EXEMPT = (
    "Library/Application Support/RepoPrompt CE/", "Library/Application%20Support/RepoPrompt%20CE/",
    ".codex/", ".codex-auth-switcher/",
)
SB_FILE_RE = re.compile(r"^windowSessions\.json\.sb-[0-9A-Za-z]{8}-[0-9A-Za-z]{6}$")
SB_MAX_BYTES = 4096
CLASS_ORDER = ("A", "B", "C", "P", "S")  # apply order: workspaces before their partitions

APP_PROCESS_PATTERNS = (
    r"RepoPrompt[^/]*\.app/Contents/MacOS/",
    r"repoprompt-mcp",
    r"repoprompt_ce_cli",
    r"repoprompt-gateway",
    r"RepoPrompt[A-Za-z]*Tests\.xctest",
    r"RepoPromptPackageTests",
    r"/\.build/[^ ]*/RepoPrompt( |$)",  # unbundled SwiftPM dev build
    r"swift-run",
)


class ReferenceStoreError(Exception):
    """A reference store exists but cannot be read or has an unknown shape."""


# --------------------------------------------------------------------------------------
# Name grammar (mirrors WorkspaceDirectoryName / WorkspaceManagerViewModel.directoryName)
# --------------------------------------------------------------------------------------

def is_uuid(value) -> bool:
    return isinstance(value, str) and UUID_RE.match(value) is not None


def parse_dir_name(dir_name: str):
    """Mirror of WorkspaceDirectoryName.parse; returns (name, UUID upper) or None when no id."""
    if not dir_name.startswith(DIR_PREFIX):
        return None
    components = dir_name[len(DIR_PREFIX):].split("-")
    for i in range(len(components) - 1, 0, -1):
        potential = "-".join(components[i:])
        if UUID_RE.match(potential):
            name_part = "-".join(components[:i])
            return (name_part if name_part else dir_name), potential.upper()
    return None


def _swift_is_whitespace_or_newline(ch: str) -> bool:
    # CharacterSet.whitespacesAndNewlines: Unicode Z* categories, U+0009...U+000D, U+0085.
    return ch in "\t\n\v\f\r\x85" or unicodedata.category(ch) in ("Zs", "Zl", "Zp")


def swift_trim(value: str) -> str:
    start, end = 0, len(value)
    while start < end and _swift_is_whitespace_or_newline(value[start]):
        start += 1
    while end > start and _swift_is_whitespace_or_newline(value[end - 1]):
        end -= 1
    return value[start:end]


def expected_dir_name(name: str, workspace_id: str) -> str:
    safe_name = swift_trim(name.replace("/", "_"))
    return f"{DIR_PREFIX}{safe_name}-{workspace_id.upper()}"


def name_group(name: str) -> str:
    return NAME_GROUP_SUFFIX_RE.sub("", name)


# --------------------------------------------------------------------------------------
# Reference stores
# --------------------------------------------------------------------------------------

def _load_json(path: str, what: str, max_bytes: int | None = None):
    try:
        st = os.lstat(path)
        if not stat.S_ISREG(st.st_mode):
            raise ReferenceStoreError(f"{what}: {path} is not a regular file")
        if max_bytes is not None and st.st_size > max_bytes:
            raise ReferenceStoreError(f"{what}: {path} is larger than {max_bytes} bytes")
        with open(path, "rb") as handle:
            data = handle.read()
        return json.loads(data.decode("utf-8")), data, st
    except ReferenceStoreError:
        raise
    except (OSError, UnicodeDecodeError, ValueError) as error:
        raise ReferenceStoreError(f"{what}: cannot read {path}: {error}") from error


def _container(path: str, what: str, required: bool = False) -> bool:
    """Return True for a readable real directory, False when absent; raise otherwise (fail closed)."""
    try:
        st = os.lstat(path)
    except FileNotFoundError:
        if required:
            raise ReferenceStoreError(f"{what}: {path} does not exist") from None
        return False
    except OSError as error:
        raise ReferenceStoreError(f"{what}: cannot stat {path}: {error}") from error
    if stat.S_ISLNK(st.st_mode):
        raise ReferenceStoreError(f"{what}: {path} is a symlink (unsupported)")
    if not stat.S_ISDIR(st.st_mode):
        raise ReferenceStoreError(f"{what}: {path} exists but is not a directory")
    try:
        with os.scandir(path):
            pass
    except OSError as error:
        raise ReferenceStoreError(f"{what}: cannot read directory {path}: {error}") from error
    return True


def _require(condition: bool, what: str, message: str):
    if not condition:
        raise ReferenceStoreError(f"{what}: unknown schema: {message}")


def _store_record(path, kind, strength, ids, st=None, extra=None):
    record = {
        "path": path,
        "kind": kind,
        "strength": strength,
        "workspaceIDs": len(ids),
    }
    if st is not None:
        record["size"] = st.st_size
        record["mtime_ns"] = st.st_mtime_ns
    if extra:
        record.update(extra)
    return record


def _collect_workspaces_index(workspaces_dir, hard, stores):
    path = os.path.join(workspaces_dir, "workspacesIndex.json")
    if not os.path.lexists(path):
        stores.append({"path": path, "kind": "workspacesIndex", "strength": "hard", "present": False})
        return
    what = "workspacesIndex.json"
    data, _, st = _load_json(path, what)
    _require(isinstance(data, list), what, "top level is not an array")
    ids = set()
    for entry in data:
        _require(isinstance(entry, dict), what, "entry is not an object")
        _require(set(entry) <= WORKSPACE_INDEX_KEYS, what, f"unexpected keys {sorted(set(entry) - WORKSPACE_INDEX_KEYS)}")
        _require(is_uuid(entry.get("id")), what, "entry id is not a UUID")
        _require(isinstance(entry.get("name"), str), what, "entry name is not a string")
        _require(isinstance(entry.get("isSystemWorkspace"), bool), what, "isSystemWorkspace is not a bool")
        _require(isinstance(entry.get("isHiddenInMenus"), bool), what, "isHiddenInMenus is not a bool")
        _require(entry.get("customStoragePath") is None or isinstance(entry.get("customStoragePath"), str), what, "customStoragePath is not a string")
        ids.add(entry["id"].upper())
    for workspace_id in ids:
        hard[workspace_id].add("workspacesIndex")
    stores.append(_store_record(path, "workspacesIndex", "hard", ids, st, {"present": True, "entries": len(data)}))


def _collect_window_sessions(app_support, hard, stores):
    path = os.path.join(app_support, "windowSessions.json")
    if not os.path.lexists(path):
        stores.append({"path": path, "kind": "windowSessions", "strength": "hard", "present": False})
        return
    what = "windowSessions.json"
    data, _, st = _load_json(path, what)
    _require(isinstance(data, dict) and set(data) == {"version", "windows"}, what, "expected {version, windows}")
    version = data["version"]
    _require(isinstance(version, int) and not isinstance(version, bool) and 1 <= version <= WINDOW_SESSION_MAX_VERSION, what, f"unsupported version {version!r}")
    _require(isinstance(data["windows"], list), what, "windows is not an array")
    ids = set()
    for window in data["windows"]:
        _require(isinstance(window, dict), what, "window entry is not an object")
        _require(set(window) <= WINDOW_ENTRY_KEYS, what, f"unexpected keys {sorted(set(window) - WINDOW_ENTRY_KEYS)}")
        workspace_id = window.get("workspaceID")
        _require(workspace_id is None or is_uuid(workspace_id), what, "workspaceID is not a UUID")
        if workspace_id:
            ids.add(workspace_id.upper())
    for workspace_id in ids:
        hard[workspace_id].add("windowSessions")
    stores.append(_store_record(path, "windowSessions", "hard", ids, st, {"present": True, "version": version}))


def _collect_mcp_routing(app_support, hard, stores):
    mcp_dir = os.path.join(app_support, "MCP")
    if _container(mcp_dir, "MCP"):
        try:
            names = os.listdir(mcp_dir)
        except OSError as error:
            raise ReferenceStoreError(f"MCP: cannot list {mcp_dir}: {error}") from error
        unknown = sorted(n for n in names if n.startswith("mcp-routing") and n.endswith(".json") and n not in ROUTING_FILES)
        if unknown:
            raise ReferenceStoreError(f"MCP routing: unknown routing-state files {unknown}")
    for file_name in ROUTING_FILES:
        path = os.path.join(mcp_dir, file_name)
        if not os.path.lexists(path):
            stores.append({"path": path, "kind": "mcpRouting", "strength": "hard", "present": False})
            continue
        what = f"MCP/{file_name}"
        data, _, st = _load_json(path, what)
        _require(isinstance(data, dict) and set(data) == {"records"}, what, "expected {records}")
        _require(isinstance(data["records"], dict), what, "records is not an object")
        ids = set()
        for client_records in data["records"].values():
            _require(isinstance(client_records, list), what, "client records is not an array")
            for record in client_records:
                _require(isinstance(record, dict), what, "record is not an object")
                _require(set(record) <= ROUTING_RECORD_KEYS, what, f"unexpected keys {sorted(set(record) - ROUTING_RECORD_KEYS)}")
                workspace_id = record.get("lastWorkspaceID")
                _require(workspace_id is None or is_uuid(workspace_id), what, "lastWorkspaceID is not a UUID")
                if workspace_id:
                    ids.add(workspace_id.upper())
        for workspace_id in ids:
            hard[workspace_id].add("mcpRouting")
        stores.append(_store_record(path, "mcpRouting", "hard", ids, st, {"present": True}))


def _scan_recovery_json_dir(directory, what, ids, require_session_id):
    count = 0
    with os.scandir(directory) as entries:
        for entry in entries:
            if entry.name in IGNORABLE_NAMES:
                continue
            stem, ext = os.path.splitext(entry.name)
            _require(entry.is_file(follow_symlinks=False) and ext == ".json" and is_uuid(stem), what, f"unexpected entry {entry.name!r}")
            data, raw, _ = _load_json(entry.path, what)
            _require(isinstance(data, dict), what, f"{entry.name} is not an object")
            _require(data.get("schemaVersion") == 1, what, f"{entry.name} schemaVersion {data.get('schemaVersion')!r}")
            if require_session_id:
                _require(isinstance(data.get("sessionID"), str) and data["sessionID"].upper() == stem.upper(), what, f"{entry.name} sessionID mismatch")
            ids.update(match.upper() for match in UUID_ANY_RE.findall(raw.decode("utf-8")))
            count += 1
    return count


def _collect_agent_recovery(app_support, hard, stores):
    root = os.path.join(app_support, "AgentRecovery")
    if not _container(root, "AgentRecovery"):
        stores.append({"path": root, "kind": "agentRecovery", "strength": "hard", "present": False})
        return
    what = "AgentRecovery"
    try:
        top = [n for n in os.listdir(root) if n not in IGNORABLE_NAMES]
        _require(set(top) <= {"v1"}, what, f"unknown versions {sorted(set(top) - {'v1'})}")
        v1 = os.path.join(root, "v1")
        ids = set()
        counts = {}
        if _container(v1, "AgentRecovery/v1"):
            v1_names = [n for n in os.listdir(v1) if n not in IGNORABLE_NAMES]
            _require(set(v1_names) <= RECOVERY_V1_ENTRIES, what, f"unknown v1 entries {sorted(set(v1_names) - RECOVERY_V1_ENTRIES)}")
            launch = os.path.join(v1, "launch-state.json")
            if os.path.lexists(launch):
                data, raw, _ = _load_json(launch, what)
                _require(isinstance(data, dict) and data.get("schemaVersion") == 1, what, "launch-state.json schemaVersion")
                ids.update(m.upper() for m in UUID_ANY_RE.findall(raw.decode("utf-8")))
            for sub, needs_session in (("sessions", True), ("tombstones", True)):
                path = os.path.join(v1, sub)
                if _container(path, f"AgentRecovery/v1/{sub}"):
                    counts[sub] = _scan_recovery_json_dir(path, f"AgentRecovery/v1/{sub}", ids, needs_session)
            attachments = os.path.join(v1, "attachments")
            if _container(attachments, "AgentRecovery/v1/attachments"):
                n = 0
                for name in os.listdir(attachments):
                    if name in IGNORABLE_NAMES:
                        continue
                    _require(is_uuid(name) and stat.S_ISDIR(os.lstat(os.path.join(attachments, name)).st_mode), what, f"unexpected attachment entry {name!r}")
                    ids.add(name.upper())
                    n += 1
                counts["attachments"] = n
    except OSError as error:
        raise ReferenceStoreError(f"{what}: cannot read {root}: {error}") from error
    for workspace_id in ids:
        hard[workspace_id].add("agentRecovery")
    stores.append(_store_record(root, "agentRecovery", "hard", ids, None, {"present": True, "files": counts, "note": "every UUID string in recovery data counts"}))


def _collect_partitions(app_support, hard, stores, entries_out=None):
    root = os.path.join(app_support, "Partitions")
    if not _container(root, "Partitions"):
        stores.append({"path": root, "kind": "partitions", "strength": "hard", "present": False})
        return
    what = "Partitions"
    ids = set()
    files = 0
    try:
        with os.scandir(root) as repos:
            for repo in repos:
                if repo.name in IGNORABLE_NAMES:
                    continue
                _require(repo.is_dir(follow_symlinks=False), what, f"unexpected entry {repo.name!r}")
                with os.scandir(repo.path) as entries:
                    for entry in entries:
                        if entry.name in IGNORABLE_NAMES:
                            continue
                        match = PARTITION_FILE_RE.match(entry.name)
                        _require(match is not None and entry.is_file(follow_symlinks=False), what, f"unexpected file {repo.name}/{entry.name}")
                        ids.add(match.group(1).upper())
                        files += 1
                        if entries_out is not None:
                            entries_out.add(f"{repo.name}/{entry.name}")
    except OSError as error:
        raise ReferenceStoreError(f"{what}: cannot read {root}: {error}") from error
    for workspace_id in ids:
        hard[workspace_id].add("partitions")
    stores.append(_store_record(root, "partitions", "hard", ids, None, {"present": True, "files": files}))


def _collect_global_settings(app_support, soft, stores):
    path = os.path.join(app_support, "Settings", "globalSettings.json")
    if not _container(os.path.dirname(path), "Settings") or not os.path.lexists(path):
        stores.append({"path": path, "kind": "globalSettings", "strength": "soft", "present": False})
        return
    what = "Settings/globalSettings.json"
    data, _, st = _load_json(path, what)
    _require(isinstance(data, dict), what, "top level is not an object")
    _require(set(data) <= GLOBAL_SETTINGS_KEYS, what, f"unexpected keys {sorted(set(data) - GLOBAL_SETTINGS_KEYS)}")
    version = data.get("schemaVersion")
    _require(isinstance(version, int) and not isinstance(version, bool) and 1 <= version <= GLOBAL_SETTINGS_MAX_SCHEMA, what, f"unsupported schemaVersion {version!r}")
    lineage = data.get("schemaLineage")
    _require(lineage == GLOBAL_SETTINGS_LINEAGE or (lineage is None and version <= 2), what, f"unknown lineage {lineage!r}")
    ids = set()
    for key in GLOBAL_SETTINGS_MAPS:
        mapping = data.get(key)
        if mapping is None and key == "agentModelsSettingsByWorkspaceID":
            continue
        _require(isinstance(mapping, dict), what, f"{key} is not an object")
        for workspace_id in mapping:
            _require(is_uuid(workspace_id), what, f"{key} has non-UUID key")
            ids.add(workspace_id.upper())
    for workspace_id in ids:
        soft[workspace_id].add("globalSettings")
    stores.append(_store_record(path, "globalSettings", "soft", ids, st, {"present": True, "schemaVersion": version}))


def collect_references(app_support: str, workspaces_dir: str, partition_entries=None):
    hard = collections.defaultdict(set)
    soft = collections.defaultdict(set)
    stores = []
    _container(app_support, "app support", required=True)
    _container(workspaces_dir, "Workspaces", required=True)
    _collect_workspaces_index(workspaces_dir, hard, stores)
    _collect_window_sessions(app_support, hard, stores)
    _collect_mcp_routing(app_support, hard, stores)
    _collect_agent_recovery(app_support, hard, stores)
    _collect_partitions(app_support, hard, stores, partition_entries)
    _collect_global_settings(app_support, soft, stores)
    return hard, soft, stores


def _index_present(stores) -> bool:
    return any(s.get("kind") == "workspacesIndex" and s.get("present") for s in stores)


def _store_home(app_support: str) -> str:
    """The app-support owner's home; refuses unless this process runs as that owner and it is $HOME."""
    try:
        owner = os.stat(app_support).st_uid
    except OSError as error:
        raise SystemExit(f"refusing: cannot read app support {app_support!r}: {error}") from None
    if os.geteuid() != owner:
        raise SystemExit(f"refusing: running as uid {os.geteuid()}, but {app_support!r} belongs to uid {owner}")
    try:
        owner_home = pwd.getpwuid(owner).pw_dir.rstrip("/")
    except KeyError:
        raise SystemExit(f"refusing: the owner uid {owner} of {app_support!r} has no passwd entry") from None
    marker = "/Library/Application Support/"
    path_home = app_support.split(marker)[0] if marker in app_support else owner_home
    user_home = os.path.expanduser("~").rstrip("/")
    if len({os.path.realpath(p) for p in (owner_home, path_home, user_home)}) != 1:
        raise SystemExit(f"refusing: store home {owner_home!r} (path {path_home!r}) is not $HOME {user_home!r}")
    return owner_home


# --------------------------------------------------------------------------------------
# Directory classification
# --------------------------------------------------------------------------------------

def _kind(mode: int) -> str:
    if stat.S_ISLNK(mode):
        return "symlink"
    if stat.S_ISDIR(mode):
        return "dir"
    if stat.S_ISREG(mode):
        return "file"
    return "other"


def scan_tree(path: str, limit: int = MAX_TREE_ENTRIES):
    """Return ([rel, kind, size, mtime_ns, allocated], overflow) for path ('.') and descendants."""
    st = os.lstat(path)
    out = [[".", _kind(st.st_mode), st.st_size, st.st_mtime_ns, st.st_blocks * 512]]
    if out[0][1] != "dir":
        return out, False
    stack = [(path, "")]
    while stack:
        directory, prefix = stack.pop()
        with os.scandir(directory) as entries:
            for entry in entries:
                est = entry.stat(follow_symlinks=False)
                rel = prefix + entry.name
                kind = _kind(est.st_mode)
                out.append([rel, kind, est.st_size, est.st_mtime_ns, est.st_blocks * 512])
                if len(out) > limit:
                    return out, True
                if kind == "dir":
                    stack.append((entry.path, rel + "/"))
    out.sort(key=lambda item: item[0])
    return out, False


def validate_index(path: str, size: int):
    """Return (ok, reason, schemaVersion) for an AgentSessionIndex.json that must be empty."""
    if size > MAX_INDEX_BYTES:
        return False, "index_too_large", None
    try:
        with open(path, "rb") as handle:
            data = json.loads(handle.read().decode("utf-8"))
    except (OSError, UnicodeDecodeError, ValueError):
        return False, "index_unreadable", None
    if not isinstance(data, dict) or not set(data) <= INDEX_KEYS:
        return False, "index_unsupported_shape", None
    version = data.get("schemaVersion")
    if not isinstance(version, int) or isinstance(version, bool) or not 1 <= version <= INDEX_MAX_SCHEMA:
        return False, "index_unsupported_schema", version
    generated = data.get("generatedAt")
    if not isinstance(generated, (int, float)) or isinstance(generated, bool):
        return False, "index_unsupported_shape", version
    reconciled = data.get("lastReconciledAt")
    if reconciled is not None and (not isinstance(reconciled, (int, float)) or isinstance(reconciled, bool)):
        return False, "index_unsupported_shape", version
    if "entries" not in data or not isinstance(data["entries"], list):
        return False, "index_unsupported_shape", version
    quarantined = data.get("quarantinedFiles", [])
    if not isinstance(quarantined, list):
        return False, "index_unsupported_shape", version
    if data["entries"] or quarantined:
        return False, "index_not_empty", version
    return True, None, version


def validate_workspace_json(path: str, size: int, dir_name: str, dir_uuid: str):
    """Return (ok, reason, info) for class B workspace.json."""
    if size > MAX_WORKSPACE_JSON_BYTES:
        return False, "workspace_json_too_large", None
    try:
        with open(path, "rb") as handle:
            data = json.loads(handle.read().decode("utf-8"))
    except (OSError, UnicodeDecodeError, ValueError):
        return False, "workspace_json_unreadable", None
    if not isinstance(data, dict):
        return False, "workspace_json_unreadable", None
    if data.get("ephemeralFlag") is not True:
        return False, "workspace_not_ephemeral", None
    workspace_id, name = data.get("id"), data.get("name")
    if not is_uuid(workspace_id) or not isinstance(name, str):
        return False, "workspace_identity_mismatch", None
    if workspace_id.upper() != dir_uuid or expected_dir_name(name, workspace_id) != dir_name:
        return False, "workspace_identity_mismatch", None
    if data.get("isSystemWorkspace") is not False:
        return False, "workspace_system_or_unknown", None
    if data.get("customStoragePath") is not None:
        return False, "workspace_custom_storage", None
    repo_paths = data.get("repoPaths") if isinstance(data.get("repoPaths"), list) else []
    info = {
        "repoPaths": [p for p in repo_paths if isinstance(p, str)][:8],
        "repoPathsExisting": sum(1 for p in repo_paths if isinstance(p, str) and os.path.exists(p)),
    }
    return True, None, info


def classify(workspaces_dir: str, dir_name: str, now_ns: int, hard, soft):
    """Classify one entry of the Workspaces directory. Never mutates anything."""
    path = os.path.join(workspaces_dir, dir_name)
    result = {"dir": dir_name, "class": None, "reason": None}
    try:
        top = os.lstat(path)
    except OSError:
        result["reason"] = "missing"
        return result
    if stat.S_ISLNK(top.st_mode):
        result["reason"] = "symlink_entry"
        return result
    if not stat.S_ISDIR(top.st_mode):
        result["reason"] = "not_directory"
        return result
    parsed = parse_dir_name(dir_name)
    if parsed is None:
        result["reason"] = "name_unparsed"
        return result
    name, workspace_id = parsed
    result.update({"workspaceID": workspace_id, "name": name, "nameGroup": name_group(name)})
    if workspace_id in hard:
        result["reason"] = "referenced"
        result["detail"] = sorted(hard[workspace_id])
        return result
    try:
        tree, overflow = scan_tree(path)
    except OSError as error:
        result["reason"] = "scan_failed"
        result["detail"] = str(error)
        return result
    if overflow:
        result["reason"] = "unexpected_content"
        result["detail"] = "more than %d entries" % MAX_TREE_ENTRIES
        return result
    entries = {item[0]: item for item in tree}
    expected_kinds = {".": "dir", INDEX_DIR: "dir", INDEX_REL: "file", WORKSPACE_JSON: "file"}
    expected_kinds.update({d: "dir" for d in ALLOWED_EMPTY_DIRS})
    unexpected = sorted(rel for rel in entries if rel not in expected_kinds)
    if unexpected:
        if any(rel.startswith(INDEX_DIR + "/AgentSession-") for rel in unexpected):
            result["reason"] = "has_agent_sessions"
        elif any(rel.startswith("Chats/") for rel in unexpected):
            result["reason"] = "chats_not_empty"
        elif any(rel.startswith("_git_data/") for rel in unexpected):
            result["reason"] = "git_data_not_empty"
        else:
            result["reason"] = "unexpected_content"
        result["detail"] = unexpected[:5]
        return result
    wrong_kind = sorted(rel for rel, item in entries.items() if item[1] != expected_kinds[rel])
    if wrong_kind:
        result["reason"] = "unexpected_entry_type"
        result["detail"] = wrong_kind
        return result
    has_index = INDEX_REL in entries
    has_workspace_json = WORKSPACE_JSON in entries
    if INDEX_DIR in entries and not has_index:
        result["reason"] = "agentsessions_without_index"
        return result
    if not has_index and not has_workspace_json:
        result["reason"] = "no_index_no_workspace_json"
        return result
    too_recent = sorted(rel for rel, item in entries.items() if now_ns - item[3] < MIN_AGE_NS)
    if too_recent:
        result["reason"] = "too_recent"
        result["detail"] = too_recent
        return result
    index_version = None
    if has_index:
        ok, reason, index_version = validate_index(os.path.join(path, INDEX_REL), entries[INDEX_REL][2])
        if not ok:
            result["reason"] = reason
            return result
    workspace_info = None
    if has_workspace_json:
        ok, reason, workspace_info = validate_workspace_json(
            os.path.join(path, WORKSPACE_JSON), entries[WORKSPACE_JSON][2], dir_name, workspace_id
        )
        if not ok:
            result["reason"] = reason
            return result
    klass = "B" if has_workspace_json else "A"
    empty_dirs = [d for d in ALLOWED_EMPTY_DIRS if d in entries]
    files = [item[:4] for item in tree]
    result.update({
        "class": klass,
        "emptyDirs": empty_dirs,
        "files": files,
        "bytes": sum(item[2] for item in tree if item[1] == "file"),
        "allocatedBytes": sum(item[4] for item in tree),
        "indexSchemaVersion": index_version,
        "softReferences": sorted(soft.get(workspace_id, ())),
    })
    parts = ["ephemeral workspace.json matching dir name" if klass == "B" else "index-only"]
    if has_index:
        parts.append(f"empty AgentSessionIndex (schemaVersion {index_version})")
    if empty_dirs:
        parts.append("empty " + "+".join(d + "/" for d in empty_dirs))
    parts.append("all mtimes > 24h")
    parts.append("unreferenced")
    result["reason"] = "; ".join(parts)
    if workspace_info is not None:
        result["workspaceJSON"] = workspace_info
    return result


def classify_fixture(workspaces_dir: str, dir_name: str, now_ns: int, hard, soft, home: str | None = None):
    """Class C: a non-empty leaked unit-test fixture workspace. Never mutates anything."""
    path = os.path.join(workspaces_dir, dir_name)
    result = {"dir": dir_name, "class": None, "reason": None}
    parsed = parse_dir_name(dir_name)
    if parsed is None or not _is_real_dir(path):
        result["reason"] = "c_not_workspace_dir"
        return result
    name, workspace_id = parsed
    result.update({"workspaceID": workspace_id, "name": name, "nameGroup": name_group(name)})
    if result["nameGroup"] not in FIXTURE_NAME_GROUPS:
        result["reason"] = "c_name_not_fixture"
        return result
    kinds = hard.get(workspace_id, set()) - {"partitions"}
    if kinds:
        result.update(reason="referenced", detail=sorted(kinds))
        return result
    try:
        tree, overflow = scan_tree(path, MAX_FIXTURE_TREE_ENTRIES)
    except OSError as error:
        result.update(reason="scan_failed", detail=str(error))
        return result
    if overflow:
        result["reason"] = "c_too_many_entries"
        return result
    wrong_kind = [item[0] for item in tree if item[1] not in ("dir", "file") and not _contained_symlink(path, item)]
    if wrong_kind:
        result.update(reason="unexpected_entry_type", detail=wrong_kind[:5])
        return result
    if any(item[0] == WORKSPACE_JSON and item[1] != "file" for item in tree):
        result["reason"] = "workspace_json_not_regular"
        return result
    recovery = sorted({m.upper() for item in tree for m in UUID_ANY_RE.findall(item[0])
                       if "agentRecovery" in hard.get(m.upper(), ())})
    if recovery:
        result.update(reason="c_recovery_referenced", detail=recovery[:5])
        return result
    too_recent = [item[0] for item in tree if now_ns - item[3] < MIN_AGE_NS]
    if too_recent:
        result.update(reason="too_recent", detail=too_recent[:5])
        return result
    exempt = "|".join(re.escape(prefix) for prefix in USER_PATH_EXEMPT)
    user_path = re.compile(re.escape((home or os.path.expanduser("~")).rstrip("/")) + f"/(?!{exempt})")
    temp_hits, workspace = 0, None
    for rel, kind, size, _, _ in tree:
        if kind != "file":
            continue
        if size > MAX_FIXTURE_FILE_BYTES:
            result.update(reason="c_file_too_large", detail=rel)
            return result
        try:
            with open(os.path.join(path, rel), "rb") as handle:
                text = handle.read().decode("utf-8", "replace").replace("\\/", "/")
        except OSError as error:
            result.update(reason="scan_failed", detail=str(error))
            return result
        if user_path.search(text):
            result.update(reason="c_user_path", detail=rel)
            return result
        if rel == WORKSPACE_JSON:
            try:
                workspace = json.loads(text)
            except ValueError:
                workspace = None
            if not isinstance(workspace, dict):
                result["reason"] = "workspace_json_unreadable"
                return result
    if workspace is not None:
        if not is_uuid(workspace.get("id")) or workspace["id"].upper() != workspace_id:
            result["reason"] = "workspace_identity_mismatch"
            return result
        if workspace.get("isSystemWorkspace") is not False:
            result["reason"] = "workspace_system_or_unknown"
            return result
        if workspace.get("customStoragePath") is not None:
            result["reason"] = "workspace_custom_storage"
            return result
        repo_paths = workspace.get("repoPaths") if isinstance(workspace.get("repoPaths"), list) else []
        temp_hits = sum(1 for p in repo_paths if isinstance(p, str) and TEMP_REPO_PATH_RE.match(p))
        if workspace.get("ephemeralFlag") is not True and temp_hits == 0:
            result["reason"] = "c_no_fixture_signal"
            return result
    result.update({
        "class": "C",
        "files": [item[:4] for item in tree],
        "bytes": sum(item[2] for item in tree if item[1] == "file"),
        "allocatedBytes": sum(item[4] for item in tree),
        "tempRepoPaths": temp_hits,
        "softReferences": sorted(soft.get(workspace_id, ())),
        "reason": "fixture name group; unreferenced; no user path; fixture signal; all mtimes > 24h",
    })
    return result


def _contained_symlink(root: str, item) -> bool:
    """A relative symlink without ".." components: it cannot point outside root (e.g. _git_data CURRENT)."""
    if item[1] != "symlink":
        return False
    try:
        target = os.readlink(os.path.join(root, item[0]))
    except OSError:
        return False
    return bool(target) and not os.path.isabs(target) and ".." not in target.split("/")


def classify_partition_dir(partitions_dir: str, name: str, now_ns: int, candidate_ids, hard=None):
    """Class P: a Partitions/<repo-key> dir whose every file belongs to one of candidate_ids.

    The dry run passes its class C candidates; --apply passes only the workspaces it has just moved."""
    path = os.path.join(partitions_dir, name)
    result = {"dir": name, "class": None, "reason": None, "store": "Partitions", "touchesCandidate": True}
    if not _is_real_dir(path):
        result["reason"] = "not_directory"
        return result
    try:
        tree, overflow = scan_tree(path, MAX_FIXTURE_TREE_ENTRIES)
    except OSError as error:
        result.update(reason="scan_failed", detail=str(error))
        return result
    ids, tabs, unexpected = set(), set(), None
    for rel, kind, *_ in tree:
        if rel == "." or os.path.basename(rel) in IGNORABLE_NAMES:
            continue
        match = PARTITION_FILE_RE.match(rel)
        if kind != "file" or match is None:
            unexpected = unexpected or rel
            continue
        ids.add(match.group(1).upper())
        if match.group(2):
            tabs.add(match.group(2).upper())
    result["touchesCandidate"] = bool(ids & candidate_ids)
    if overflow:
        result.update(reason="p_too_many_entries", touchesCandidate=True)  # unscanned files may be candidates
        return result
    if unexpected:
        result.update(reason="p_unexpected_entry", detail=unexpected)
        return result
    others = sorted(ids - candidate_ids)
    if not ids or others:
        result.update(reason="p_not_all_candidates", detail=others[:5])
        return result
    hard = hard or {}
    referenced = sorted(i for i in ids if hard.get(i, set()) - {"partitions"}) + sorted(t for t in tabs if t in hard)
    if referenced:
        result.update(reason="p_referenced", detail=referenced[:5])
        return result
    too_recent = [item[0] for item in tree if now_ns - item[3] < MIN_AGE_NS]
    if too_recent:
        result.update(reason="too_recent", detail=too_recent[:5])
        return result
    result.update({
        "class": "P", "workspaceIDs": sorted(ids), "files": [item[:4] for item in tree],
        "bytes": sum(item[2] for item in tree if item[1] == "file"), "allocatedBytes": sum(item[4] for item in tree),
        "reason": "every file belongs to a class C candidate; all mtimes > 24h",
    })
    return result


def classify_sb_file(app_support: str, name: str, now_ns: int):
    """Class S: an interrupted atomic-write sibling of windowSessions.json that names no window."""
    path = os.path.join(app_support, name)
    result = {"dir": name, "class": None, "reason": None, "store": "appSupport"}
    if not SB_FILE_RE.match(name):
        result["reason"] = "s_name"
        return result
    try:
        tree, _ = scan_tree(path)
        if tree[0][1] != "file":
            result["reason"] = "not_regular_file"
            return result
        if tree[0][2] > SB_MAX_BYTES:
            result["reason"] = "s_too_large"
            return result
        if now_ns - tree[0][3] < MIN_AGE_NS:
            result["reason"] = "too_recent"
            return result
        with open(path, "rb") as handle:
            raw = handle.read()
    except OSError as error:
        result.update(reason="scan_failed", detail=str(error))
        return result
    if raw.strip():
        try:
            document = json.loads(raw.decode("utf-8"))
        except (UnicodeDecodeError, ValueError):
            result["reason"] = "s_unreadable"
            return result
        if not isinstance(document, dict) or document.get("windows") != []:
            result["reason"] = "s_references_windows"
            return result
    result.update({
        "class": "S", "files": [item[:4] for item in tree], "bytes": tree[0][2], "allocatedBytes": tree[0][4],
        "reason": "empty or window-less windowSessions.json atomic-write leftover; mtime > 24h",
    })
    return result


def _source_parent(klass, app_support: str) -> str:
    return {"P": os.path.join(app_support, "Partitions"), "S": app_support}.get(klass, os.path.join(app_support, "Workspaces"))


def _valid_entry_name(klass, name: str) -> bool:
    if not isinstance(name, str) or name in ("", ".", "..") or os.path.basename(name) != name:
        return False
    if klass == "P":
        return True
    if klass == "S":
        return SB_FILE_RE.match(name) is not None
    return name.startswith(DIR_PREFIX)


# --------------------------------------------------------------------------------------
# Dry run
# --------------------------------------------------------------------------------------

def _is_within(path: str, root: str) -> bool:
    path, root = os.path.realpath(path), os.path.realpath(root)
    return path == root or path.startswith(root.rstrip(os.sep) + os.sep)


def _atomic_write_json(path: str, payload) -> None:
    directory = os.path.dirname(os.path.abspath(path)) or "."
    fd, tmp = tempfile.mkstemp(prefix=".tmp-", suffix=".json", dir=directory)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            json.dump(payload, handle, indent=1, sort_keys=False)
            handle.write("\n")
        os.replace(tmp, path)
    except BaseException:
        if os.path.exists(tmp):
            os.unlink(tmp)
        raise


def run_dry(app_support: str, manifest_path: str, now_ns: int | None = None, quiet: bool = False):
    started = time.monotonic()
    app_support = os.path.abspath(app_support)
    workspaces_dir = os.path.join(app_support, "Workspaces")
    if _is_within(manifest_path, app_support):
        raise SystemExit(f"refusing to write the manifest inside {app_support}")
    hard, soft, stores = collect_references(app_support, workspaces_dir)
    home = _store_home(app_support)
    now_ns = time.time_ns() if now_ns is None else now_ns
    candidates, excluded = [], []
    scanned = 0

    def add(result):
        if result["class"]:
            candidates.append(result)
        else:
            excluded.append({key: result[key] for key in ("dir", "reason", "detail", "store") if key in result})

    with os.scandir(workspaces_dir) as entries:
        for entry in entries:
            scanned += 1
            result = classify(workspaces_dir, entry.name, now_ns, hard, soft)
            if not result["class"]:
                fixture = classify_fixture(workspaces_dir, entry.name, now_ns, hard, soft, home)
                if fixture["class"] or fixture["reason"] not in ("c_name_not_fixture", "c_not_workspace_dir"):
                    result = fixture
            add(result)
    candidate_ids = {c["workspaceID"] for c in candidates if c["class"] == "C"}
    if candidate_ids and not _index_present(stores):
        raise ReferenceStoreError("workspacesIndex.json is missing; classes C and P need it to protect indexed workspaces")
    partitions_dir = os.path.join(app_support, "Partitions")
    if _is_real_dir(partitions_dir):
        for name in sorted(n for n in os.listdir(partitions_dir) if n not in IGNORABLE_NAMES):
            result = classify_partition_dir(partitions_dir, name, now_ns, candidate_ids, hard)
            if result.pop("touchesCandidate") or result["class"]:
                add(result)  # report partition dirs holding a class C candidate's file or failing to scan
    for name in sorted(n for n in os.listdir(app_support) if n.startswith("windowSessions.json.sb-")):
        add(classify_sb_file(app_support, name, now_ns))
    candidates.sort(key=lambda c: c["dir"])
    excluded.sort(key=lambda c: c["dir"])
    summary = summarize(candidates, excluded, stores, scanned, time.monotonic() - started)
    manifest = {
        "schema": MANIFEST_SCHEMA,
        "generatedAt": _dt.datetime.fromtimestamp(now_ns / 1e9, _dt.timezone.utc).isoformat(),
        "generatedAtNs": now_ns,
        "appSupport": app_support,
        "home": home,
        "workspacesDir": workspaces_dir,
        "workspacesDev": os.stat(workspaces_dir).st_dev,
        "minAgeHours": MIN_AGE_NS / 3.6e12,
        "allowedEmptyDirs": list(ALLOWED_EMPTY_DIRS),
        "referenceStores": stores,
        "summary": summary,
        "candidates": candidates,
        "excluded": excluded,
    }
    _atomic_write_json(manifest_path, manifest)
    if not quiet:
        print_summary(summary, manifest_path)
    return manifest


def summarize(candidates, excluded, stores, scanned, seconds):
    by_class = {}
    for klass in CLASS_ORDER:
        members = [c for c in candidates if c["class"] == klass]
        combos = collections.Counter("+".join(c.get("emptyDirs", ())) or "(none)" for c in members)
        by_class[klass] = {
            "count": len(members),
            "files": sum(1 for c in members for item in c.get("files", ()) if item[1] == "file"),
            "bytes": sum(c["bytes"] for c in members),
            "allocatedBytes": sum(c["allocatedBytes"] for c in members),
            "softReferencedGlobalSettings": sum(1 for c in members if "globalSettings" in c.get("softReferences", ())),
            "emptyDirCombos": dict(combos.most_common()),
        }
    groups = collections.defaultdict(collections.Counter)
    for c in candidates:
        if "nameGroup" in c:
            groups[c["nameGroup"]][c["class"]] += 1
    top = sorted(groups.items(), key=lambda kv: (-sum(kv[1].values()), kv[0]))[:30]
    reasons = collections.Counter(e["reason"] for e in excluded)
    referenced_by = collections.Counter()
    for e in excluded:
        if e["reason"] == "referenced":
            for store in e.get("detail", []):
                referenced_by[store] += 1
    return {
        "scanned": scanned,
        "runtimeSeconds": round(seconds, 2),
        "classes": by_class,
        "excludedByReason": dict(reasons.most_common()),
        "referencedByStore": dict(referenced_by.most_common()),
        "topNameGroups": [{"group": g, "A": v["A"], "B": v["B"], "C": v["C"], "total": sum(v.values())} for g, v in top],
        "referenceStores": [{k: s[k] for k in ("kind", "strength", "path", "workspaceIDs", "present") if k in s} for s in stores],
    }


def _human(n: int) -> str:
    for unit in ("B", "KiB", "MiB", "GiB"):
        if n < 1024 or unit == "GiB":
            return f"{n:.1f} {unit}" if unit != "B" else f"{n} B"
        n /= 1024
    return str(n)


def print_summary(summary, manifest_path):
    print(f"Manifest: {manifest_path}")
    print(f"Scanned {summary['scanned']} entries in {summary['runtimeSeconds']} s")
    print("Reference stores:")
    for store in summary["referenceStores"]:
        state = f"{store.get('workspaceIDs', 0)} workspace IDs" if store.get("present", True) else "absent"
        print(f"  [{store['strength']}] {store['kind']}: {state}  ({store['path']})")
    for klass, info in summary["classes"].items():
        count = f"{info['count']} files" if klass == "S" else f"{info['count']} dirs ({info['files']} files)"
        print(
            f"Class {klass}: {count}, {_human(info['bytes'])} logical, "
            f"{_human(info['allocatedBytes'])} allocated, {info['softReferencedGlobalSettings']} also in globalSettings"
        )
        if klass in ("A", "B"):
            for combo, count in info["emptyDirCombos"].items():
                print(f"    empty dirs {combo}: {count}")
    print("Excluded by reason:")
    for reason, count in summary["excludedByReason"].items():
        print(f"  {count:7d}  {reason}")
    if summary["referencedByStore"]:
        print("  referenced, by store: " + ", ".join(f"{k}={v}" for k, v in summary["referencedByStore"].items()))
    print("Top name groups (candidates):")
    for group in summary["topNameGroups"]:
        print(f"  {group['total']:7d}  A={group['A']:<6d} B={group['B']:<5d} C={group['C']:<6d} {group['group']}")


# --------------------------------------------------------------------------------------
# Apply / restore
# --------------------------------------------------------------------------------------

def running_app_processes():
    """Return matching process descriptions; raise RuntimeError when listing fails."""
    own = {os.getpid(), os.getppid()}
    found = {}
    combined = re.compile("|".join(APP_PROCESS_PATTERNS))
    for pattern in APP_PROCESS_PATTERNS:
        proc = subprocess.run(["pgrep", "-f", pattern], capture_output=True, text=True)
        if proc.returncode not in (0, 1):
            raise RuntimeError(f"pgrep failed: {proc.stderr.strip()}")
        for line in proc.stdout.split():
            if line.isdigit() and int(line) not in own:
                found.setdefault(int(line), f"pgrep -f {pattern}")
    # pgrep -f can miss processes whose arguments it cannot read; cross-check with ps.
    proc = subprocess.run(["ps", "-axww", "-o", "pid=,comm=,args="], capture_output=True, text=True)
    if proc.returncode != 0:
        raise RuntimeError(f"ps failed: {proc.stderr.strip()}")
    for line in proc.stdout.splitlines():
        parts = line.strip().split(None, 1)
        if len(parts) == 2 and parts[0].isdigit() and int(parts[0]) not in own and combined.search(parts[1]):
            found[int(parts[0])] = parts[1][:160]
    return [f"{pid}: {desc}" for pid, desc in sorted(found.items())]


def refuse_if_app_running(process_check):
    try:
        running = process_check()
    except RuntimeError as error:
        raise SystemExit(f"refusing: cannot verify that RepoPrompt CE is quit ({error})")
    if running:
        listing = "\n  ".join(running[:20])
        raise SystemExit(f"refusing: RepoPrompt CE / repoprompt-mcp processes are running:\n  {listing}\nQuit them and retry.")


def _errno_name(error: OSError) -> str:
    return errno.errorcode.get(error.errno, str(error.errno)) if error.errno is not None else "unknown"


def _is_real_dir(path: str) -> bool:
    try:
        return stat.S_ISDIR(os.lstat(path).st_mode)
    except OSError:
        return False


def _fsync_dir(path: str) -> None:
    """Best-effort fsync of a directory so renames/creations in it are durable."""
    try:
        fd = os.open(path, os.O_RDONLY)
    except OSError:
        return
    try:
        os.fsync(fd)
    except OSError:
        pass
    finally:
        os.close(fd)


def _journal_append(handle, record, sync: bool) -> None:
    handle.write(json.dumps(record) + "\n")
    handle.flush()
    if sync:
        os.fsync(handle.fileno())


class _SimulatedCrash(BaseException):
    """Self-test only: simulates the process dying at an injected point (not caught as Exception)."""


class _ExclusiveLock:
    """Non-blocking exclusive flock on <app-support>/.rpce-quarantine.lock (never unlinked)."""

    def __init__(self, app_support: str):
        self.path = os.path.join(app_support, LOCK_NAME)
        self.fd = None

    def __enter__(self):
        try:
            fd = os.open(self.path, os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
        except OSError as error:
            raise SystemExit(f"refusing: cannot open lock file {self.path}: {error}")
        try:
            if not stat.S_ISREG(os.fstat(fd).st_mode):
                raise SystemExit(f"refusing: lock file {self.path} is not a regular file")
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError as error:
            os.close(fd)
            if error.errno in (errno.EWOULDBLOCK, errno.EAGAIN):
                raise SystemExit(f"refusing: another quarantine run holds the lock {self.path}")
            raise SystemExit(f"refusing: cannot lock {self.path}: {error}")
        except BaseException:
            os.close(fd)
            raise
        self.fd = fd
        return self

    def __exit__(self, *exc_info):
        try:
            fcntl.flock(self.fd, fcntl.LOCK_UN)
        finally:
            os.close(self.fd)
            self.fd = None
        return False


def _reference_fingerprint(hard, stores):
    """Hard references and store metadata except Partitions, which _RunGuard compares file by file."""
    ids = tuple(sorted((workspace_id, tuple(sorted(kinds - {"partitions"})))
                       for workspace_id, kinds in hard.items() if kinds - {"partitions"}))
    records = []
    for store in stores:
        if store.get("kind") == "partitions":
            store = {k: v for k, v in store.items() if k not in ("workspaceIDs", "files")}
        records.append(json.dumps(store, sort_keys=True))
    return ids, tuple(sorted(records))


class _RunGuard:
    """Process exclusion and reference-set stability, checked at start and periodically."""

    def __init__(self, app_support, workspaces_dir, process_check, check_every, check_seconds, hooks):
        self.app_support = app_support
        self.stores = None
        self.partition_entries = None
        self.workspaces_dir = workspaces_dir
        self.process_check = process_check
        self.check_every = check_every
        self.check_seconds = check_seconds
        self.hooks = hooks
        self.baseline = None
        self.last_count = 0
        self.last_time = 0.0
        self.checks = 0
        self.detail = None

    def start(self):
        refuse_if_app_running(self.process_check)
        entries = set()
        hard, soft, self.stores = collect_references(self.app_support, self.workspaces_dir, entries)
        self.baseline = _reference_fingerprint(hard, self.stores)
        self.partition_entries = entries  # expected Partitions files; only note_partition_dir changes it
        self.last_count, self.last_time = 0, time.monotonic()
        return hard, soft

    def note_partition_dir(self, dir_name, files, present: bool):
        """This run moved (present=False) or restored (present=True) exactly these files of Partitions/dir_name."""
        names = {f"{dir_name}/{item[0]}" for item in files or ()
                 if item[1] == "file" and PARTITION_FILE_RE.match(str(item[0]))}
        if present:
            self.partition_entries |= names
        else:
            self.partition_entries -= names

    def poll(self, count: int):
        """Run the periodic check when due (every check_every moves or check_seconds); return a stop reason or None."""
        if count - self.last_count < self.check_every and time.monotonic() - self.last_time < self.check_seconds:
            return None
        self.last_count = count
        self.checks += 1
        try:
            hook = self.hooks.get("periodic_check")
            if hook:
                hook(count)
            try:
                if self.process_check():
                    return "stopped_app_started"
            except RuntimeError as error:
                self.detail = str(error)
                return "stopped_process_check_failed"
            try:
                entries = set()
                hard, _, stores = collect_references(self.app_support, self.workspaces_dir, entries)
            except ReferenceStoreError as error:
                self.detail = str(error)
                return "stopped_reference_store_error"
            if _reference_fingerprint(hard, stores) != self.baseline or entries != self.partition_entries:
                return "stopped_references_changed"
            return None
        finally:
            self.last_time = time.monotonic()


def run_apply(app_support, manifest_path, classes, process_check=running_app_processes, quiet=False,
              check_every=CHECK_EVERY_MOVES, check_seconds=CHECK_EVERY_SECONDS, hooks=None):
    hooks = hooks or {}
    app_support = os.path.abspath(app_support)
    workspaces_dir = os.path.join(app_support, "Workspaces")
    with open(manifest_path, encoding="utf-8") as handle:
        manifest = json.load(handle)
    if manifest.get("schema") != MANIFEST_SCHEMA:
        raise SystemExit("refusing: unknown manifest schema")
    if os.path.abspath(manifest.get("appSupport", "")) != app_support:
        raise SystemExit(f"refusing: manifest is for {manifest.get('appSupport')!r}, not {app_support!r}")
    home = _store_home(app_support)
    if "C" in classes and manifest.get("home") != home:
        raise SystemExit(f"refusing: manifest home {manifest.get('home')!r} is not {home!r}; run a fresh --dry-run")
    rename = hooks.get("rename", os.rename)
    with _ExclusiveLock(app_support):
        guard = _RunGuard(app_support, workspaces_dir, process_check, check_every, check_seconds, hooks)
        hard, soft = guard.start()
        if set(classes) & {"C", "P"} and not _index_present(guard.stores):
            raise SystemExit("refusing: workspacesIndex.json is missing; classes C and P need it")
        stamp = hooks.get("stamp") or _dt.datetime.now(_dt.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
        quarantine_dir = os.path.join(app_support, f"Workspaces-Quarantine-{stamp}")
        os.mkdir(quarantine_dir)  # FileExistsError aborts; never reuses a quarantine directory
        if os.stat(quarantine_dir).st_dev != os.stat(workspaces_dir).st_dev:
            os.rmdir(quarantine_dir)
            raise SystemExit("refusing: quarantine directory is on a different volume")
        restore_path = os.path.join(quarantine_dir, "restore-manifest.jsonl")
        moved, skipped, stopped = 0, collections.Counter(), None
        now_ns = time.time_ns()
        with open(restore_path, "x", encoding="utf-8") as journal:
            _journal_append(journal, {
                "schema": RESTORE_SCHEMA, "appSupport": app_support, "workspacesDir": workspaces_dir,
                "quarantineDir": quarantine_dir, "sourceManifest": os.path.abspath(manifest_path),
                "classes": sorted(classes), "startedAt": stamp,
            }, sync=True)
            _fsync_dir(quarantine_dir)
            moved_c_ids = set()  # class P needs every workspace of the folder moved as C by this invocation
            selected = [c for c in manifest.get("candidates", []) if c.get("class") in classes]
            for candidate in sorted(selected, key=lambda c: CLASS_ORDER.index(c["class"])):
                klass, dir_name = candidate["class"], candidate.get("dir", "")
                if not _valid_entry_name(klass, dir_name):
                    skipped["invalid_manifest_entry"] += 1
                    continue
                stopped = guard.poll(moved)
                if stopped:
                    skipped[stopped] += 1
                    break
                parent = _source_parent(klass, app_support)
                if klass in ("A", "B"):
                    fresh = classify(parent, dir_name, now_ns, hard, soft)
                elif klass == "C":
                    fresh = classify_fixture(parent, dir_name, now_ns, hard, soft, home)
                elif klass == "S":
                    fresh = classify_sb_file(parent, dir_name, now_ns)
                else:
                    fresh = classify_partition_dir(parent, dir_name, now_ns, moved_c_ids, hard)
                if fresh["class"] is None:
                    skipped["revalidation:" + str(fresh["reason"])] += 1
                    continue
                if fresh["class"] != candidate["class"] or fresh["files"] != candidate.get("files"):
                    skipped["revalidation:changed_since_manifest"] += 1
                    continue
                source = os.path.join(parent, dir_name)
                target = os.path.join(quarantine_dir, dir_name)
                if os.path.lexists(target):
                    skipped["target_exists"] += 1
                    continue
                try:
                    # Write-ahead: the intent is durable before the rename can happen.
                    _journal_append(journal, {
                        "dir": dir_name, "class": fresh["class"], "from": source, "to": target,
                        "files": fresh["files"], "state": "moving", "intentAtNs": time.time_ns(),
                    }, sync=True)
                except OSError as error:
                    stopped = f"stopped_journal_write_failed:{_errno_name(error)}"
                    skipped[stopped] += 1
                    break
                if "after_intent" in hooks:
                    hooks["after_intent"](dir_name)
                try:
                    rename(source, target)
                except OSError as error:
                    code = _errno_name(error)
                    skipped[f"rename_failed:{code}"] += 1
                    try:
                        _journal_append(journal, {"dir": dir_name, "state": "failed", "errno": code}, sync=False)
                    except OSError as journal_error:
                        stopped = f"stopped_journal_write_failed:{_errno_name(journal_error)}"
                        skipped[stopped] += 1
                        break
                    continue
                moved += 1
                if klass == "C":
                    moved_c_ids.add(fresh["workspaceID"])
                elif klass == "P":
                    guard.note_partition_dir(dir_name, fresh["files"], present=False)
                if "after_rename" in hooks:
                    hooks["after_rename"](dir_name)
                try:
                    _journal_append(journal, {"dir": dir_name, "state": "moved", "movedAtNs": time.time_ns()}, sync=False)
                except OSError as error:
                    stopped = f"stopped_journal_write_failed:{_errno_name(error)}"
                    skipped[stopped] += 1
                    break
            try:
                journal.flush()
                os.fsync(journal.fileno())
            except OSError as error:
                skipped[f"final_journal_fsync_failed:{_errno_name(error)}"] += 1
        _fsync_dir(quarantine_dir)
        for parent in {workspaces_dir} | {_source_parent(klass, app_support) for klass in classes}:
            _fsync_dir(parent)
        result = {"quarantineDir": quarantine_dir, "restoreManifest": restore_path, "moved": moved,
                  "skipped": dict(skipped), "stopped": stopped, "periodicChecks": guard.checks}
        if guard.detail:
            result["stopDetail"] = guard.detail
        _atomic_write_json(os.path.join(quarantine_dir, "apply-summary.json"), result)
    if stopped and not quiet:
        print(f"stopping early ({stopped}); everything moved so far is journaled in {restore_path}.\n"
              f"Quit the cause, then re-run --apply --manifest {os.path.abspath(manifest_path)} with the same --class values;"
              " class P folders of workspaces this run moved stay put unless you --restore this journal first."
              " Expect what this run moved to be skipped as revalidation:c_not_workspace_dir / :not_directory /"
              " :scan_failed / :missing.",
              file=sys.stderr)
    if not quiet:
        print(json.dumps(result, indent=1))
    return result


def _read_journal(restore_path: str):
    """Return (records, bad_trailing). A corrupt final line is skipped and reported; any other corrupt line refuses."""
    with open(restore_path, "rb") as handle:
        raw = handle.read()
    lines = [(number, line) for number, line in enumerate(raw.split(b"\n"), 1) if line.strip()]
    records, bad_trailing = [], None
    for position, (number, line) in enumerate(lines):
        try:
            record = json.loads(line.decode("utf-8"))
            if not isinstance(record, dict):
                raise ValueError("not an object")
        except (UnicodeDecodeError, ValueError) as error:
            if position == len(lines) - 1 and position > 0:
                bad_trailing = {"line": number, "bytes": len(line), "error": str(error)[:120]}
                break
            raise SystemExit(f"refusing: restore manifest line {number} is corrupt and is not the trailing line ({error})")
        records.append(record)
    return records, bad_trailing


def _journal_entries(records, skipped):
    """Fold intent/moved/failed records (and legacy post-rename records) into per-dir entries, in order."""
    entries, order = {}, []
    for record in records:
        dir_name, state = record.get("dir"), record.get("state")
        if not isinstance(dir_name, str):
            skipped["invalid_record"] += 1
            continue
        is_legacy = state is None and "from" in record and "to" in record
        if state == "moving" or is_legacy:
            if not isinstance(record.get("from"), str) or not isinstance(record.get("to"), str):
                skipped["invalid_record"] += 1
                continue
            if dir_name not in entries:
                order.append(dir_name)
            entries[dir_name] = {"record": record, "state": "moved" if is_legacy else "moving"}
        elif state in ("moved", "failed"):
            if dir_name in entries:
                entries[dir_name]["state"] = state
            else:
                skipped["orphan_record"] += 1
        else:
            skipped["invalid_record"] += 1
    return entries, order


def run_restore(restore_path, process_check=running_app_processes, quiet=False,
                check_every=CHECK_EVERY_MOVES, check_seconds=CHECK_EVERY_SECONDS, hooks=None):
    hooks = hooks or {}
    records, bad_trailing = _read_journal(restore_path)
    if not records or records[0].get("schema") != RESTORE_SCHEMA:
        raise SystemExit("refusing: unknown restore manifest schema")
    header = records[0]
    if not all(isinstance(header.get(key), str) for key in ("appSupport", "workspacesDir", "quarantineDir")):
        raise SystemExit("refusing: restore manifest header is incomplete")
    app_support = os.path.abspath(header["appSupport"])
    workspaces_dir = os.path.abspath(header["workspacesDir"])
    quarantine_dir = os.path.abspath(header["quarantineDir"])
    if workspaces_dir != os.path.join(app_support, "Workspaces") or os.path.dirname(quarantine_dir) != app_support:
        raise SystemExit("refusing: restore manifest header paths are inconsistent")
    if os.path.dirname(os.path.abspath(restore_path)) != quarantine_dir:
        raise SystemExit("refusing: restore manifest is not inside its quarantine directory")
    skipped = collections.Counter()
    entries, order = _journal_entries(records[1:], skipped)
    if bad_trailing and not quiet:
        print(f"warning: skipped a truncated/corrupt trailing line in {restore_path}: {bad_trailing}", file=sys.stderr)
    rename = hooks.get("rename", os.rename)
    restored, reconciled, changed, stopped = 0, 0, [], None
    with _ExclusiveLock(app_support):
        guard = _RunGuard(app_support, workspaces_dir, process_check, check_every, check_seconds, hooks)
        guard.start()
        for dir_name in order:
            entry = entries[dir_name]
            record, state = entry["record"], entry["state"]
            source, target = os.path.abspath(record["to"]), os.path.abspath(record["from"])
            klass = record.get("class")
            if (os.path.dirname(source) != quarantine_dir or os.path.dirname(target) != _source_parent(klass, app_support)
                    or os.path.basename(source) != dir_name or os.path.basename(target) != dir_name
                    or not _valid_entry_name(klass, dir_name)):
                skipped["path_outside_stores"] += 1
                continue
            if os.path.lexists(target):
                # Intent-only/failed entries whose origin is still in place were never moved.
                skipped["destination_exists" if state == "moved" or os.path.lexists(source) else "not_moved"] += 1
                continue
            if not ((os.path.isfile(source) and not os.path.islink(source)) if klass == "S" else _is_real_dir(source)):
                skipped["quarantined_entry_missing"] += 1
                continue
            stopped = guard.poll(restored)
            if stopped:
                skipped[stopped] += 1
                break
            try:
                rename(source, target)
            except OSError as error:
                skipped[f"rename_failed:{_errno_name(error)}"] += 1
                continue
            restored += 1
            if state != "moved":
                reconciled += 1
            tree = record.get("files")
            try:
                tree, overflow = scan_tree(target, MAX_FIXTURE_TREE_ENTRIES if klass in ("C", "P") else MAX_TREE_ENTRIES)
                if overflow or [item[:4] for item in tree] != record.get("files"):
                    changed.append(dir_name)
            except OSError:
                changed.append(dir_name)
            if klass == "P":
                guard.note_partition_dir(dir_name, tree, present=True)
        for parent in {workspaces_dir} | {_source_parent(entries[d]["record"].get("class"), app_support) for d in order}:
            _fsync_dir(parent)
    result = {"restored": restored, "reconciledInterrupted": reconciled, "skipped": dict(skipped),
              "changedWhileQuarantined": changed[:50], "changedCount": len(changed),
              "truncatedTrailingLine": bad_trailing, "stopped": stopped, "periodicChecks": guard.checks}
    if guard.detail:
        result["stopDetail"] = guard.detail
    if stopped and not quiet:
        print(f"stopping early ({stopped}); re-run --restore after fixing the cause", file=sys.stderr)
    if not quiet:
        print(json.dumps(result, indent=1))
    return result


# --------------------------------------------------------------------------------------
# Self-test (temporary fake store only)
# --------------------------------------------------------------------------------------

class SelfTestFailure(Exception):
    """Raised by _check; unlike assert, it is not stripped by python3 -O."""


def _check(condition, message="self-test check failed") -> None:
    if not condition:
        raise SelfTestFailure(message)


def _expect_raises(exc_types, func, message):
    try:
        func()
    except exc_types as error:
        return error
    raise SelfTestFailure(message)


def _self_test() -> int:
    old_ns = time.time_ns() - 3 * MIN_AGE_NS
    empty_index = {"generatedAt": 813960026.5, "quarantinedFiles": [], "schemaVersion": 7, "lastReconciledAt": 813960026.5, "entries": []}

    def uid(n):
        return f"{n:08X}-0000-4000-8000-{n:012X}"

    with tempfile.TemporaryDirectory(prefix="rpce-quarantine-selftest-") as tmp:
        app = os.path.join(tmp, "RepoPrompt CE")
        ws = os.path.join(app, "Workspaces")
        os.makedirs(ws)
        layouts = {}

        def make(name, files, dirs=(), recent=False):
            root = os.path.join(ws, name)
            os.makedirs(root)
            for d in dirs:
                os.makedirs(os.path.join(root, d), exist_ok=True)
            for rel, payload in files.items():
                os.makedirs(os.path.dirname(os.path.join(root, rel)), exist_ok=True)
                with open(os.path.join(root, rel), "w", encoding="utf-8") as handle:
                    handle.write(payload if isinstance(payload, str) else json.dumps(payload))
            if not recent:
                for current, _, names in os.walk(root, topdown=False):
                    for n in names:
                        os.utime(os.path.join(current, n), ns=(old_ns, old_ns))
                    os.utime(current, ns=(old_ns, old_ns))
            layouts[name] = root
            return name

        idx = {INDEX_REL: empty_index}
        a1 = make(f"Workspace-Request Idempotency E7677C37-{uid(1)}", idx, ("Chats",))
        a2 = make(f"Workspace-Default-{uid(2)}", idx)
        a3 = make(f"Workspace-Lookup-{uid(3)}", idx, ("Chats", "_git_data"))
        make(f"Workspace-DSStore-{uid(4)}", {**idx, "Chats/.DS_Store": "x"})
        make(f"Workspace-Recent-{uid(5)}", idx, ("Chats",), recent=True)
        make(f"Workspace-NonEmpty-{uid(6)}", {INDEX_REL: {**empty_index, "entries": [{}]}})
        make(f"Workspace-Session-{uid(7)}", {**idx, f"AgentSessions/AgentSession-{uid(70)}.json": "{}"})
        make(f"Workspace-Referenced-{uid(8)}", idx)
        make(f"Workspace-Partitioned-{uid(9)}", idx)
        make("Workspace-NoUUID", idx)
        b_name = "Agent Mode Chat Switch 07A925F5"
        b1 = make(f"Workspace-{b_name}-{uid(10)}", {**idx, WORKSPACE_JSON: {"id": uid(10), "name": b_name, "ephemeralFlag": True, "isSystemWorkspace": False, "repoPaths": []}}, ("Chats", "_git_data"))
        make(f"Workspace-Wrong Name-{uid(11)}", {WORKSPACE_JSON: {"id": uid(11), "name": "Other", "ephemeralFlag": True, "isSystemWorkspace": False}})
        make(f"Workspace-Real-{uid(12)}", {**idx, WORKSPACE_JSON: {"id": uid(12), "name": "Real", "ephemeralFlag": False, "isSystemWorkspace": False}})
        make(f"Workspace-Soft-{uid(13)}", idx)
        with open(os.path.join(ws, "workspacesIndex.json"), "w") as handle:
            json.dump([{"id": uid(8), "name": "Referenced", "isSystemWorkspace": False, "isHiddenInMenus": False}], handle)
        with open(os.path.join(app, "windowSessions.json"), "w") as handle:
            json.dump({"version": 4, "windows": [{"windowKind": "standard", "workspaceID": uid(12), "isSystemWorkspace": False, "isEphemeral": False, "lastFocused": True}]}, handle)
        os.makedirs(os.path.join(app, "Partitions", "repo-abc"))
        open(os.path.join(app, "Partitions", "repo-abc", f"filepartitions-{uid(9).lower()}.json"), "w").close()
        os.makedirs(os.path.join(app, "Settings"))
        with open(os.path.join(app, "Settings", "globalSettings.json"), "w") as handle:
            json.dump({"schemaVersion": 5, "schemaLineage": GLOBAL_SETTINGS_LINEAGE, "updatedAt": 1.0, "copySettingsByWorkspaceID": {uid(13): {}}, "chatSettingsByWorkspaceID": {}, "globalDefaults": {}}, handle)

        manifest_path = os.path.join(tmp, "manifest.json")
        manifest = run_dry(app, manifest_path, quiet=True)
        got = {c["dir"]: c["class"] for c in manifest["candidates"]}
        reasons = {e["dir"]: e["reason"] for e in manifest["excluded"]}
        expected = {a1: "A", a2: "A", a3: "A", b1: "B", f"Workspace-Soft-{uid(13)}": "A"}
        _check(got == expected, (got, reasons))
        _check(reasons[f"Workspace-DSStore-{uid(4)}"] == "chats_not_empty", reasons)
        _check(reasons[f"Workspace-Recent-{uid(5)}"] == "too_recent", reasons)
        _check(reasons[f"Workspace-NonEmpty-{uid(6)}"] == "index_not_empty", reasons)
        _check(reasons[f"Workspace-Session-{uid(7)}"] == "has_agent_sessions", reasons)
        _check(reasons[f"Workspace-Referenced-{uid(8)}"] == "referenced", reasons)
        _check(reasons[f"Workspace-Partitioned-{uid(9)}"] == "referenced", reasons)
        _check(reasons["Workspace-NoUUID"] == "name_unparsed", reasons)
        _check(reasons[f"Workspace-Wrong Name-{uid(11)}"] == "workspace_identity_mismatch", reasons)
        _check(reasons[f"Workspace-Real-{uid(12)}"] == "referenced", reasons)
        _check(reasons["workspacesIndex.json"] == "not_directory", reasons)
        soft_flag = [c for c in manifest["candidates"] if c["softReferences"]]
        _check([c["workspaceID"] for c in soft_flag] == [uid(13)], soft_flag)
        _check(parse_dir_name(f"Workspace-a-b-{uid(1)}") == ("a-b", uid(1)), "parse_dir_name a-b")
        _check(parse_dir_name(f"Workspace--{uid(1)}") == (f"Workspace--{uid(1)}", uid(1)), "parse_dir_name empty name")
        _check(name_group("List Sessions 5D314EF2") == "List Sessions", "name_group")
        process_re = re.compile("|".join(APP_PROCESS_PATTERNS))
        for line in ("/Users/x/repo/.build/arm64-apple-macosx/debug/RepoPrompt",
                     "/Users/x/repo/.build/debug/RepoPrompt --flag",
                     "/usr/bin/swift-run RepoPrompt",
                     "/x/swiftpm-testing-helper --test-bundle-path RepoPromptPackageTests.xctest/Contents/MacOS/RepoPromptPackageTests"):
            _check(process_re.search(line) is not None, f"process pattern missed {line!r}")
        _check(process_re.search("/Users/x/repo/.build/debug/RepoPromptCore.swiftmodule") is None, "process pattern overmatched")

        no_proc = lambda: []  # noqa: E731
        counter = [0]

        def stamp():
            counter[0] += 1
            return f"selftest-{counter[0]:03d}"

        def quarantine_dirs():
            return sorted(n for n in os.listdir(app) if n.startswith("Workspaces-Quarantine-"))

        def qpaths(stamp_value):
            qdir = os.path.join(app, f"Workspaces-Quarantine-{stamp_value}")
            return os.path.join(qdir, "restore-manifest.jsonl"), os.path.join(qdir, "apply-summary.json")

        def journal_states(path):
            with open(path, encoding="utf-8") as handle:
                return [json.loads(line).get("state") for line in handle.read().splitlines()[1:]]

        def fresh_a():
            names = sorted(c["dir"] for c in run_dry(app, manifest_path, quiet=True)["candidates"] if c["class"] == "A")
            _check(len(names) == 3, names)
            _check(all_in_place(names), names)
            return names

        def all_in_place(names):
            return all(_is_real_dir(os.path.join(ws, n)) for n in names)

        def apply_a(stamp_value, **kwargs):
            kwargs.setdefault("process_check", no_proc)
            hooks = kwargs.pop("hooks", {})
            hooks["stamp"] = stamp_value
            return run_apply(app, manifest_path, {"A"}, quiet=True, hooks=hooks, **kwargs)

        def restore(path, **kwargs):
            kwargs.setdefault("process_check", no_proc)
            return run_restore(path, quiet=True, **kwargs)

        # Refusal when an app process is reported.
        _expect_raises(SystemExit, lambda: apply_a(stamp(), process_check=lambda: ["1: RepoPrompt"]),
                       "apply did not refuse while app is running")
        _check(not quarantine_dirs(), quarantine_dirs())

        # A candidate modified after the manifest is not moved.
        with open(os.path.join(layouts[a2], "Chats-extra"), "w"):
            pass
        result = apply_a(stamp())
        _check(result["moved"] == 3 and result["stopped"] is None and result["periodicChecks"] == 0, result)
        _check(os.path.isdir(layouts[a2]) and os.path.isdir(layouts[b1]), "unmoved dirs missing")
        _check(not os.path.exists(layouts[a1]), "a1 not moved")
        _check(journal_states(result["restoreManifest"]) == ["moving", "moved"] * 3, journal_states(result["restoreManifest"]))
        restored = restore(result["restoreManifest"])
        _check(restored["restored"] == 3 and restored["changedCount"] == 0 and restored["truncatedTrailingLine"] is None, restored)
        _check(os.path.isdir(layouts[a1]) and os.path.isdir(layouts[a3]), "restore incomplete")

        # Restore refuses when the destination exists again.
        result = run_apply(app, manifest_path, {"B"}, process_check=no_proc, quiet=True, hooks={"stamp": stamp()})
        _check(result["moved"] == 1, result)
        os.makedirs(layouts[b1])
        restored = restore(result["restoreManifest"])
        _check(restored["restored"] == 0 and restored["skipped"] == {"destination_exists": 1}, restored)

        # Interruption between the fsynced intent and the rename: the second entry was never moved.
        names = fresh_a()
        s = stamp()
        seen = []

        def crash_before_rename(dir_name):
            seen.append(dir_name)
            if len(seen) == 2:
                raise _SimulatedCrash()

        _expect_raises(_SimulatedCrash, lambda: apply_a(s, hooks={"after_intent": crash_before_rename}), "intent crash not raised")
        journal, summary_path = qpaths(s)
        _check(not os.path.exists(summary_path), "summary written despite crash")
        _check(not os.path.lexists(os.path.join(ws, names[0])) and all_in_place(names[1:]), "unexpected moves before crash")
        _check(journal_states(journal) == ["moving", "moved", "moving"], journal_states(journal))
        restored = restore(journal)
        _check(restored["restored"] == 1 and restored["reconciledInterrupted"] == 0 and restored["skipped"] == {"not_moved": 1}, restored)
        _check(all_in_place(names), "intent-crash restore incomplete")

        # Interruption between the rename and its "moved" record: reconciled from the intent alone.
        names = fresh_a()
        s = stamp()
        seen.clear()
        _expect_raises(_SimulatedCrash, lambda: apply_a(s, hooks={"after_rename": crash_before_rename}), "rename crash not raised")
        journal, summary_path = qpaths(s)
        _check(not os.path.exists(summary_path), "summary written despite crash")
        _check(journal_states(journal) == ["moving", "moved", "moving"], journal_states(journal))
        _check(not os.path.lexists(os.path.join(ws, names[1])), "second entry not renamed")
        restored = restore(journal)
        _check(restored["restored"] == 2 and restored["reconciledInterrupted"] == 1 and restored["skipped"] == {}, restored)
        _check(all_in_place(names), "rename-crash restore incomplete")

        # Per-entry rename failure (apply and restore) is counted, does not abort, and keeps the summary.
        names = fresh_a()
        s = stamp()

        def failing_rename_for(victim):
            def rename(src, dst):
                if os.path.basename(src) == victim:
                    raise OSError(errno.EACCES, "injected failure", src)
                os.rename(src, dst)
            return rename

        result = apply_a(s, hooks={"rename": failing_rename_for(names[1])})
        journal, summary_path = qpaths(s)
        _check(result["moved"] == 2 and result["skipped"] == {"rename_failed:EACCES": 1} and result["stopped"] is None, result)
        _check(os.path.isfile(summary_path), "apply-summary.json missing after rename failure")
        _check(journal_states(journal) == ["moving", "moved", "moving", "failed", "moving", "moved"], journal_states(journal))
        restored = restore(journal, hooks={"rename": failing_rename_for(names[0])})
        _check(restored["restored"] == 1 and restored["skipped"] == {"rename_failed:EACCES": 1, "not_moved": 1}, restored)
        restored = restore(journal)
        _check(restored["restored"] == 1 and restored["skipped"] == {"not_moved": 1, "destination_exists": 1}, restored)
        _check(all_in_place(names), "rename-failure restore incomplete")

        # A truncated trailing journal line is skipped and reported without losing earlier entries.
        names = fresh_a()
        s = stamp()
        result = apply_a(s)
        journal, _ = qpaths(s)
        with open(journal, "a", encoding="utf-8") as handle:
            handle.write('{"dir": "Workspace-Trunc')
        restored = restore(journal)
        _check(restored["restored"] == 3 and restored["skipped"] == {} and restored["truncatedTrailingLine"] is not None, restored)
        _check(all_in_place(names), "truncated-journal restore incomplete")

        # A corrupt line that is not the trailing line refuses the whole restore.
        names = fresh_a()
        s = stamp()
        apply_a(s)
        journal, _ = qpaths(s)
        with open(journal, encoding="utf-8") as handle:
            lines = handle.read().splitlines(True)
        with open(journal, "w", encoding="utf-8") as handle:
            handle.writelines(lines[:2] + ["{corrupt\n"] + lines[2:])
        _expect_raises(SystemExit, lambda: restore(journal), "mid-file corruption accepted")
        _check(not any(os.path.lexists(os.path.join(ws, n)) for n in names), "restore ran despite corruption")
        with open(journal, "w", encoding="utf-8") as handle:
            handle.writelines(lines)
        _check(restore(journal)["restored"] == 3, "repaired journal did not restore")

        # Lock contention: a second run refuses while the lock is held.
        names = fresh_a()
        before = quarantine_dirs()
        with _ExclusiveLock(app):
            error = _expect_raises(SystemExit, lambda: apply_a(stamp()), "apply ran despite held lock")
            _check("lock" in str(error), str(error))
            error = _expect_raises(SystemExit, lambda: restore(journal), "restore ran despite held lock")
            _check("lock" in str(error), str(error))
        _check(quarantine_dirs() == before and all_in_place(names), "lock contention mutated the store")

        # Reference-set change mid-run stops apply cleanly (summary written, journal restorable).
        names = fresh_a()
        s = stamp()
        index_path = os.path.join(ws, "workspacesIndex.json")
        with open(index_path, encoding="utf-8") as handle:
            original_index = handle.read()

        def add_reference(_count):
            entries = json.loads(original_index)
            entries.append({"id": uid(99), "name": "New", "isSystemWorkspace": False, "isHiddenInMenus": False})
            with open(index_path, "w", encoding="utf-8") as handle:
                json.dump(entries, handle)

        result = apply_a(s, check_every=1, hooks={"periodic_check": add_reference})
        journal, summary_path = qpaths(s)
        _check(result["moved"] == 1 and result["stopped"] == "stopped_references_changed"
               and result["skipped"] == {"stopped_references_changed": 1} and result["periodicChecks"] == 1, result)
        _check(os.path.isfile(summary_path), "apply-summary.json missing after reference change")
        with open(index_path, "w", encoding="utf-8") as handle:
            handle.write(original_index)
        _check(restore(journal)["restored"] == 1 and all_in_place(names), "reference-change restore incomplete")

        # A process appearing mid-run stops apply at the next periodic check; restore also stops on reference change.
        names = fresh_a()
        s = stamp()
        calls = [0]

        def process_appears():
            calls[0] += 1
            return [] if calls[0] <= 2 else ["4242: /Applications/RepoPrompt CE.app/Contents/MacOS/RepoPrompt CE"]

        result = apply_a(s, check_every=1, process_check=process_appears)
        journal, _ = qpaths(s)
        _check(result["moved"] == 2 and result["stopped"] == "stopped_app_started" and result["periodicChecks"] == 2, result)
        restored = restore(journal, check_every=1, hooks={"periodic_check": add_reference})
        _check(restored["restored"] == 1 and restored["stopped"] == "stopped_references_changed", restored)
        with open(index_path, "w", encoding="utf-8") as handle:
            handle.write(original_index)
        restored = restore(journal)
        _check(restored["restored"] == 1 and restored["skipped"] == {"destination_exists": 1}, restored)
        _check(all_in_place(names), "process-start restore incomplete")

        # Malformed reference containers fail closed instead of reading as empty.
        elsewhere = os.path.join(tmp, "elsewhere")
        os.makedirs(elsewhere)
        missing = os.path.join(tmp, "missing")
        mcp, recovery = os.path.join(app, "MCP"), os.path.join(app, "AgentRecovery")
        partitions, settings = os.path.join(app, "Partitions"), os.path.join(app, "Settings")

        def write_file(path):
            os.makedirs(os.path.dirname(path), exist_ok=True)
            with open(path, "w", encoding="utf-8") as handle:
                handle.write("{}")

        def swap_aside(path, replacement):
            def setup():
                os.rename(path, path + ".bak")
                replacement()
            def teardown():
                os.remove(path)
                os.rename(path + ".bak", path)
            return setup, teardown

        cases = [
            ("MCP regular file", lambda: write_file(mcp), lambda: os.remove(mcp)),
            ("MCP dangling symlink", lambda: os.symlink(missing, mcp), lambda: os.remove(mcp)),
            ("MCP symlink to directory", lambda: os.symlink(elsewhere, mcp), lambda: os.remove(mcp)),
            ("AgentRecovery dangling symlink", lambda: os.symlink(missing, recovery), lambda: os.remove(recovery)),
            ("AgentRecovery/v1 regular file", lambda: write_file(os.path.join(recovery, "v1")), lambda: shutil.rmtree(recovery)),
            ("AgentRecovery/v1/sessions regular file", lambda: write_file(os.path.join(recovery, "v1", "sessions")), lambda: shutil.rmtree(recovery)),
            ("AgentRecovery attachment symlink", lambda: (os.makedirs(os.path.join(recovery, "v1", "attachments")),
                                                          os.symlink(elsewhere, os.path.join(recovery, "v1", "attachments", uid(50)))),
             lambda: shutil.rmtree(recovery)),
            ("Partitions dangling symlink", *swap_aside(partitions, lambda: os.symlink(missing, partitions))),
            ("Partitions symlink to directory", *swap_aside(partitions, lambda: os.symlink(partitions + ".bak", partitions))),
            ("Settings regular file", *swap_aside(settings, lambda: write_file(settings))),
        ]
        if os.geteuid() != 0:
            cases.append(("MCP unreadable", lambda: (os.mkdir(mcp), os.chmod(mcp, 0)),
                          lambda: (os.chmod(mcp, 0o700), os.rmdir(mcp))))
        for label, setup, teardown in cases:
            setup()
            try:
                _expect_raises(ReferenceStoreError, lambda: run_dry(app, manifest_path, quiet=True),
                               f"dry run accepted malformed container: {label}")
            finally:
                teardown()
        fresh_a()  # store is valid again after every teardown

        # Unknown reference-store schema fails closed.
        with open(os.path.join(app, "windowSessions.json"), "w") as handle:
            json.dump({"version": 99, "windows": []}, handle)
        _expect_raises(ReferenceStoreError, lambda: run_dry(app, manifest_path, quiet=True), "dry run did not fail closed")
        # Manifest inside app support is refused.
        _expect_raises((SystemExit, ReferenceStoreError), lambda: run_dry(app, os.path.join(app, "m.json"), quiet=True),
                       "manifest inside app support accepted")
    _self_test_fixture_classes()
    print(f"self-test passed ({len(cases)} malformed-container cases; classes C, P, S)")
    return 0


def _self_test_fixture_classes() -> None:
    """Classes C, P and S on their own temporary store (moved, excluded, restored)."""
    old_ns = time.time_ns() - 3 * MIN_AGE_NS
    home = os.path.expanduser("~")

    def uid(n):
        return f"{n:08X}-0000-4000-8000-{n:012X}"

    def write(path, payload):
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w", encoding="utf-8") as handle:
            handle.write(payload if isinstance(payload, str) else json.dumps(payload))

    with tempfile.TemporaryDirectory(prefix="rpce-quarantine-selftest-cps-") as tmp:
        app = os.path.join(tmp, "RepoPrompt CE")
        ws, parts = os.path.join(app, "Workspaces"), os.path.join(app, "Partitions")
        temp_doc = {"fileURL": "file:///var/folders/xy/T/fixture"}

        def session(n):
            return {f"AgentSessions/AgentSession-{uid(n)}.json": temp_doc}

        # Exempt home paths only; 30 chats push the tree past MAX_TREE_ENTRIES (restore must still match).
        exempt_doc = {"store": home + "/Library/Application%20Support/RepoPrompt%20CE/Workspaces/x",
                      "plain": home + "/Library/Application Support/RepoPrompt CE/Partitions/y",
                      "auth": home + "/.codex-auth-switcher/a", "codex": home + "/.codex/sessions/b"}
        chats = {f"Chats/Chat-{n:02d}.json": exempt_doc for n in range(30)}
        dirs = {
            "ok": (f"Workspace-Remote Naming-{uid(101)}", {**session(201), INDEX_REL: {"entries": [{}]}, **chats}),
            "index": (f"Workspace-Project Alpha-{uid(102)}", session(202)),
            "window": (f"Workspace-Project Alpha-{uid(103)}", session(203)),
            "mcp": (f"Workspace-Project Alpha-{uid(104)}", session(204)),
            "recovery": (f"Workspace-Project Alpha-{uid(105)}", session(205)),
            "user": (f"Workspace-Remote Workspace-{uid(106)}", {WORKSPACE_JSON: {
                "id": uid(106), "ephemeralFlag": True, "isSystemWorkspace": False, "repoPaths": [home + "/workspace/real"]}}),
            "real": (f"Workspace-Remote Naming-{uid(107)}", {WORKSPACE_JSON: {
                "id": uid(107), "ephemeralFlag": False, "isSystemWorkspace": False, "repoPaths": []}}),
            "name": (f"Workspace-My Project-{uid(108)}", session(208)),
            "escape": (f"Workspace-Remote Naming-{uid(109)}", session(209)),
        }
        for name, files in dirs.values():
            for rel, payload in files.items():
                write(os.path.join(ws, name, rel), payload)
        write(os.path.join(ws, dirs["ok"][0], "_git_data", "repos", "r", "2026-07-02", "1059", "HEAD"), "x")
        os.symlink("2026-07-02/1059", os.path.join(ws, dirs["ok"][0], "_git_data", "repos", "r", "CURRENT"))
        os.symlink("../../outside", os.path.join(ws, dirs["escape"][0], "CURRENT"))
        write(os.path.join(ws, "workspacesIndex.json"),
              [{"id": uid(102), "name": "Project Alpha", "isSystemWorkspace": False, "isHiddenInMenus": False}])
        write(os.path.join(app, "windowSessions.json"), {"version": 4, "windows": [
            {"windowKind": "standard", "workspaceID": uid(103), "isSystemWorkspace": False, "isEphemeral": False, "lastFocused": True}]})
        write(os.path.join(app, "MCP", "mcp-routing.json"), {"records": {"client": [{"lastWorkspaceID": uid(104)}]}})
        write(os.path.join(app, "AgentRecovery", "v1", "sessions", f"{uid(205)}.json"), {"schemaVersion": 1, "sessionID": uid(205)})
        p_ok, p_mixed = "fixture-root-aaaaaaaaaaaa", "shared-root-bbbbbbbbbbbb"
        write(os.path.join(parts, p_ok, f"filepartitions-{uid(101).lower()}.json"), "{}")
        write(os.path.join(parts, p_mixed, f"filepartitions-{uid(101).lower()}-{uid(301).lower()}.json"), "{}")
        write(os.path.join(parts, p_mixed, f"filepartitions-{uid(102).lower()}.json"), "{}")
        p_tab = "tab-root-cccccccccccc"  # a fixture's file whose tab UUID is window-referenced
        write(os.path.join(parts, p_tab, f"filepartitions-{uid(101).lower()}-{uid(103).lower()}.json"), "{}")
        sb_empty, sb_no_windows, sb_windows = (f"windowSessions.json.sb-1234abcd-{s}" for s in ("Ab12Cd", "Ef34Gh", "Ij56Kl"))
        write(os.path.join(app, sb_empty), "")
        write(os.path.join(app, sb_no_windows), {"version": 4, "windows": []})
        write(os.path.join(app, sb_windows), {"version": 4, "windows": [{"workspaceID": uid(103)}]})
        for current, subdirs, names in os.walk(app, topdown=False):
            for n in names:
                os.utime(os.path.join(current, n), ns=(old_ns, old_ns), follow_symlinks=False)
            for n in subdirs:  # also the symlink to a directory, which os.walk lists here
                os.utime(os.path.join(current, n), ns=(old_ns, old_ns), follow_symlinks=False)
            os.utime(current, ns=(old_ns, old_ns))

        manifest_path = os.path.join(tmp, "manifest.json")
        manifest = run_dry(app, manifest_path, quiet=True)
        got = {c["dir"]: c["class"] for c in manifest["candidates"]}
        reasons = {e["dir"]: e["reason"] for e in manifest["excluded"]}
        _check(got == {dirs["ok"][0]: "C", p_ok: "P", sb_empty: "S", sb_no_windows: "S"}, (got, reasons))
        for key, reason in (("index", "referenced"), ("window", "referenced"), ("mcp", "referenced"),
                            ("recovery", "c_recovery_referenced"), ("user", "c_user_path"),
                            ("real", "c_no_fixture_signal"), ("name", "has_agent_sessions"),
                            ("escape", "unexpected_entry_type")):
            _check(reasons[dirs[key][0]] == reason, (key, reasons))
        _check(reasons[p_mixed] == "p_not_all_candidates" and reasons[sb_windows] == "s_references_windows", reasons)
        _check(reasons[p_tab] == "p_referenced", reasons)
        ok_files = next(c["files"] for c in manifest["candidates"] if c["dir"] == dirs["ok"][0])
        _check(MAX_TREE_ENTRIES < len(ok_files) <= MAX_FIXTURE_TREE_ENTRIES, len(ok_files))
        _check(manifest["home"] == home.rstrip("/"), manifest.get("home"))
        _expect_raises(SystemExit, lambda: _store_home(os.path.join(tmp, "missing")), "missing app support accepted")
        real_geteuid, real_getpwuid = os.geteuid, pwd.getpwuid
        try:
            os.geteuid = lambda: real_geteuid() + 1
            _expect_raises(SystemExit, lambda: _store_home(app), "store of another uid accepted (sudo)")
            os.geteuid = real_geteuid

            def no_entry(uid_):
                raise KeyError(uid_)

            pwd.getpwuid = no_entry
            _expect_raises(SystemExit, lambda: _store_home(app), "owner without passwd entry accepted")
        finally:
            os.geteuid, pwd.getpwuid = real_geteuid, real_getpwuid
        saved_home = os.environ.get("HOME")
        os.environ["HOME"] = tmp
        try:
            _expect_raises(SystemExit, lambda: run_dry(app, os.path.join(tmp, "m2.json"), quiet=True),
                           "dry run accepted a $HOME that is not the store owner's home")
        finally:
            if saved_home is None:
                os.environ.pop("HOME", None)
            else:
                os.environ["HOME"] = saved_home

        no_proc = lambda: []  # noqa: E731
        # A partitions dir is not moved while its fixture workspace is still in Workspaces/.
        result = run_apply(app, manifest_path, {"P"}, process_check=no_proc, quiet=True, hooks={"stamp": "selftest-cps-1"})
        _check(result["moved"] == 0 and result["skipped"] == {"revalidation:p_not_all_candidates": 1}, result)
        # The C workspace is renamed away and its UUID indexed before apply: its partitions do not move.
        ok_path, renamed = os.path.join(ws, dirs["ok"][0]), os.path.join(ws, f"Workspace-Renamed-{uid(101)}")
        index_path = os.path.join(ws, "workspacesIndex.json")
        with open(index_path, encoding="utf-8") as handle:
            index = json.load(handle)
        os.rename(ok_path, renamed)
        write(index_path, index + [{"id": uid(101), "name": "Renamed", "isSystemWorkspace": False, "isHiddenInMenus": False}])
        result = run_apply(app, manifest_path, {"C", "P"}, process_check=no_proc, quiet=True, hooks={"stamp": "selftest-cps-1b"})
        _check(result["moved"] == 0 and result["skipped"] == {"revalidation:c_not_workspace_dir": 1,
                                                               "revalidation:p_not_all_candidates": 1}, result)
        os.rename(renamed, ok_path)
        write(index_path, index)
        # Unexpected Partitions changes mid-run stop the apply: another workspace's file is added, or
        # swapped for a file of a new workspace (same file count).
        real_file = os.path.join(parts, p_mixed, f"filepartitions-{uid(102).lower()}.json")
        extra = os.path.join(parts, p_mixed, f"filepartitions-{uid(102).lower()}-{uid(302).lower()}.json")
        swapped = os.path.join(parts, p_mixed, f"filepartitions-{uid(303).lower()}.json")
        for stamp, change, undo in (("1c", lambda: write(extra, "{}"), lambda: os.unlink(extra)),
                                    ("1d", lambda: os.rename(real_file, swapped), lambda: os.rename(swapped, real_file))):
            done = []

            def change_once(count, change=change, done=done):
                if count >= 1 and not done:
                    done.append(change())

            result = run_apply(app, manifest_path, {"C", "P", "S"}, process_check=no_proc, quiet=True, check_every=1,
                               hooks={"stamp": "selftest-cps-" + stamp, "periodic_check": change_once})
            _check(result["stopped"] == "stopped_references_changed" and result["moved"] == 1, (stamp, result))
            restored = run_restore(result["restoreManifest"], process_check=no_proc, quiet=True)
            _check(restored["restored"] == 1 and restored["changedCount"] == 0 and restored["skipped"] == {}, restored)
            undo()
        # Moved fixture UUID 101 gains a file in the retained mixed folder after its own P folder moved.
        tab_file = os.path.join(parts, p_mixed, f"filepartitions-{uid(101).lower()}-{uid(304).lower()}.json")
        tab_file2 = os.path.join(parts, p_mixed, f"filepartitions-{uid(101).lower()}-{uid(305).lower()}.json")

        def add_once(path, at_count):
            def hook(count):
                if count >= at_count and not os.path.exists(path):
                    write(path, "{}")
            return hook

        first = run_apply(app, manifest_path, {"C", "P", "S"}, process_check=no_proc, quiet=True, check_every=1,
                          hooks={"stamp": "selftest-cps-1e", "periodic_check": add_once(tab_file, 2)})
        _check(first["stopped"] == "stopped_references_changed" and first["moved"] == 2, first)
        # Re-runs with the same manifest skip what the stopped run moved, with the documented reasons.
        second = run_apply(app, manifest_path, {"C", "P", "S"}, process_check=no_proc, quiet=True, hooks={"stamp": "selftest-cps-1f"})
        _check(second["moved"] == 2 and second["skipped"] == {"revalidation:c_not_workspace_dir": 1,
                                                              "revalidation:not_directory": 1}, second)
        third = run_apply(app, manifest_path, {"C", "P", "S"}, process_check=no_proc, quiet=True, hooks={"stamp": "selftest-cps-1g"})
        _check(third["moved"] == 0 and third["skipped"] == {"revalidation:c_not_workspace_dir": 1, "revalidation:not_directory": 1,
                                                            "revalidation:scan_failed": 2}, third)
        _check(run_restore(second["restoreManifest"], process_check=no_proc, quiet=True)["restored"] == 2, "sb restore")
        # The same kind of change during restore stops it; a re-run finishes the restore.
        restored = run_restore(first["restoreManifest"], process_check=no_proc, quiet=True, check_every=1,
                               hooks={"periodic_check": add_once(tab_file2, 1)})
        _check(restored["stopped"] == "stopped_references_changed" and restored["restored"] == 1, restored)
        os.unlink(tab_file2)
        restored = run_restore(first["restoreManifest"], process_check=no_proc, quiet=True)
        _check(restored["restored"] == 1 and restored["changedCount"] == 0 and restored["skipped"] == {"destination_exists": 1}, restored)
        os.unlink(tab_file)

        moved = [os.path.join(ws, dirs["ok"][0]), os.path.join(parts, p_ok), os.path.join(app, sb_empty), os.path.join(app, sb_no_windows)]
        kept = [os.path.join(ws, d) for key, (d, _) in dirs.items() if key != "ok"]
        kept += [os.path.join(parts, p_mixed), os.path.join(app, sb_windows)]
        # Periodic checks on every move must not read the class P moves as a reference change.
        result = run_apply(app, manifest_path, {"C", "P", "S"}, process_check=no_proc, quiet=True, check_every=1,
                           hooks={"stamp": "selftest-cps-2"})
        _check(result["moved"] == 4 and result["skipped"] == {} and result["stopped"] is None and result["periodicChecks"] >= 3, result)
        _check(not any(os.path.lexists(p) for p in moved) and all(os.path.lexists(p) for p in kept), "C/P/S apply moved the wrong entries")
        restored = run_restore(result["restoreManifest"], process_check=no_proc, quiet=True, check_every=1)
        _check(restored["restored"] == 4 and restored["changedCount"] == 0 and restored["skipped"] == {}
               and restored["stopped"] is None, restored)
        _check(_is_real_dir(moved[0]) and _is_real_dir(moved[1]) and all(os.path.isfile(p) for p in moved[2:]),
               "C/P/S restore incomplete")
        _check(os.path.isfile(os.path.join(moved[0], "_git_data", "repos", "r", "CURRENT", "HEAD")), "restored symlink broken")
        # Without workspacesIndex.json, classes C and P refuse (dry run and apply).
        os.unlink(index_path)
        _expect_raises(ReferenceStoreError, lambda: run_dry(app, os.path.join(tmp, "m3.json"), quiet=True),
                       "dry run produced class C without workspacesIndex.json")
        _expect_raises(SystemExit, lambda: run_apply(app, manifest_path, {"C"}, process_check=no_proc, quiet=True,
                                                     hooks={"stamp": "selftest-cps-4"}), "apply ran without workspacesIndex.json")
        _check(not os.path.exists(os.path.join(app, "Workspaces-Quarantine-selftest-cps-4")), "refused apply left a quarantine dir")

        # Single-directory class C rules, classified directly.
        unit_ws = os.path.join(tmp, "unit", "Workspaces")

        def descriptor(n, ephemeral, repo_paths, **extra):
            return {WORKSPACE_JSON: {"id": uid(n), "ephemeralFlag": ephemeral, "isSystemWorkspace": False,
                                     "repoPaths": repo_paths, **extra}}

        units = {
            "var_folders": (401, descriptor(401, False, ["/private/var/folders/xy/T/repo"]), None, "C"),
            "tmp_repo": (402, descriptor(402, False, ["/tmp/repo"]), None, "c_no_fixture_signal"),
            "temp_in_text_only": (403, {**descriptor(403, False, []), **session(403)}, None, "c_no_fixture_signal"),
            "dot_config": (404, descriptor(404, True, [home + "/.config/real-repo"]), None, "c_user_path"),
            "cloud_storage": (405, descriptor(405, True, [home + "/Library/CloudStorage/Dropbox/repo"]), None, "c_user_path"),
            "json_dir": (406, {WORKSPACE_JSON + "/inner.json": "{}"}, None, "workspace_json_not_regular"),
            "json_symlink": (407, {"real.json": descriptor(407, True, [], isSystemWorkspace=True)[WORKSPACE_JSON]},
                             "real.json", "workspace_json_not_regular"),
        }
        for key, (n, files, link_target, _) in units.items():
            root = os.path.join(unit_ws, f"Workspace-Remote Naming-{uid(n)}")
            for rel, payload in files.items():
                write(os.path.join(root, rel), payload)
            if link_target:
                os.symlink(link_target, os.path.join(root, WORKSPACE_JSON))
        for current, subdirs, names in os.walk(unit_ws, topdown=False):
            for n in names + subdirs:
                os.utime(os.path.join(current, n), ns=(old_ns, old_ns), follow_symlinks=False)
        for key, (n, _, _, expected) in units.items():
            fresh = classify_fixture(unit_ws, f"Workspace-Remote Naming-{uid(n)}", time.time_ns(), {}, {}, home)
            _check((fresh["class"] or fresh["reason"]) == expected, (key, fresh["reason"], fresh.get("detail")))


# --------------------------------------------------------------------------------------
# CLI
# --------------------------------------------------------------------------------------

def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--dry-run", action="store_true", help="scan and write a manifest (default)")
    mode.add_argument("--apply", action="store_true", help="move manifest candidates of --class into quarantine")
    mode.add_argument("--restore", metavar="RESTORE_MANIFEST", help="move entries of a restore-manifest.jsonl back")
    mode.add_argument("--self-test", action="store_true", help="run the built-in self-test on a temporary store")
    parser.add_argument("--manifest", help="dry-run output / apply input manifest path")
    parser.add_argument("--class", dest="classes", action="append", choices=CLASS_ORDER,
                        help="apply only: candidate class to move (repeatable; required)")
    parser.add_argument("--app-support", default=DEFAULT_APP_SUPPORT, help="RepoPrompt CE app-support root")
    args = parser.parse_args(argv)

    if args.self_test:
        try:
            return _self_test()
        except SelfTestFailure as error:
            print(f"self-test FAILED: {error}", file=sys.stderr)
            return 1
    try:
        if args.restore:
            return 3 if run_restore(args.restore)["stopped"] else 0
        if args.apply:
            if not args.manifest or not args.classes:
                parser.error("--apply requires --manifest and at least one --class")
            return 3 if run_apply(args.app_support, args.manifest, set(args.classes))["stopped"] else 0
        manifest = args.manifest or os.path.join(
            tempfile.gettempdir(),
            "rpce-fixture-quarantine-" + _dt.datetime.now(_dt.timezone.utc).strftime("%Y%m%dT%H%M%SZ") + ".json",
        )
        run_dry(args.app_support, manifest)
        return 0
    except ReferenceStoreError as error:
        print(f"aborting (fail closed): {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
