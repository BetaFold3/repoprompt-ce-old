"""Paths, pins and preflight checks for the code-mode lab.

Every machine-specific value comes from the environment (see README.md). Nothing here reads credentials.
"""
from __future__ import annotations

import os
import shutil
import subprocess
from pathlib import Path

LAB_DIR = Path(__file__).resolve().parent
HARNESS_REPO = LAB_DIR.parents[1]

# The ground truth in tasks.py and edit_grade.py was derived from this commit. The repository that the
# CE debug app answers for (CMLAB_REPO) must be a checkout of it, or every task grades against stale facts.
TRUTH_COMMIT = "d4cbd9d152fedd79a62dbc5e270270d0b141db92"

# Price weights relative to uncached input (Sonnet list prices): uncached x1, cache write x1.25,
# cache read x0.1, output x5. Plan §3.4 "price-weighted tokens".
WEIGHTS = {"unc": 1.0, "cw": 1.25, "cr": 0.1, "out": 5.0}


def _path(name: str, default: Path | str | None) -> Path | None:
    """Absolute path (resolved at load time, before any run directory becomes the working directory)."""
    value = os.environ.get(name) or default
    return Path(value).expanduser().absolute() if value is not None else None


REPO = _path("CMLAB_REPO", None)
SCRATCH = _path("CMLAB_SCRATCH", HARNESS_REPO / ".build" / "codemode-lab")
CLI = _path("CMLAB_CLI", "~/Library/Application Support/RepoPrompt CE/repoprompt_ce_cli_debug")
QJS_HOST = _path("CMLAB_QJS_HOST", SCRATCH / "bin" / "cm_host_v2")
CODEX_HOME = _path("CODEX_HOME", "~/.codex")
CLAUDE = os.environ.get("CMLAB_CLAUDE", "claude")
CODEX = os.environ.get("CMLAB_CODEX", "codex")
SWIFTC = os.environ.get("CMLAB_SWIFTC", "/usr/bin/swiftc")
PYTHON = os.environ.get("CMLAB_PYTHON", "python3")
# Environment variables removed before launching Claude (for example a wrapper's bypass switch).
CLAUDE_STRIP_ENV = [x for x in os.environ.get("CMLAB_CLAUDE_STRIP_ENV", "").split(",") if x]
# MCP servers from your own Codex config to disable for lab runs (comma-separated names), so the model
# cannot reach RepoPrompt or other tools around the proxy. Names must exist in your config.
CODEX_DISABLE_SERVERS = [x for x in os.environ.get("CMLAB_CODEX_DISABLE_SERVERS", "").split(",") if x]


def git_dir() -> Path:
    """Repository used to read files at TRUTH_COMMIT for grading: the pinned checkout if set, else this clone."""
    return REPO if REPO else HARNESS_REPO


def show_at_truth(path: str) -> str:
    return subprocess.run(["git", "-C", str(git_dir()), "show", f"{TRUTH_COMMIT}:{path}"],
                          capture_output=True, text=True, check=True).stdout


def row_is_usable(r: dict) -> bool:
    """A run whose usage can be compared: the host exited normally, reported usage, and the RepoPrompt upstream never failed.
    Correctness is still counted for every attempted row."""
    return r.get("rc") == 0 and r.get("wtok", 0) > 0 and not r.get("upstream_errors")


def probe_upstream(timeout: float = 20) -> str | None:
    """Connect to the CE debug MCP helper and bind CMLAB_REPO, as the proxy will. None = ok, else the problem."""
    from upstream import Upstream, UpstreamError, connect_and_bind
    up = None
    try:
        up = Upstream(CLI)
        connect_and_bind(up, str(REPO), client="cm-experiment-preflight", timeout=timeout)
        return None
    except UpstreamError as e:
        return f"RepoPrompt upstream probe failed: {e}"
    finally:
        if up: up.close()


def links_homebrew_qjs(host: Path) -> bool:
    """True when the host binary links Homebrew's libqjs dylib (the test build, which bundles quickjs-libc)."""
    r = subprocess.run(["otool", "-L", str(host)], capture_output=True, text=True)
    return r.returncode == 0 and "libqjs" in r.stdout


def preflight(need_hosts: set[str], need_codemode: bool, need_swiftc: bool = False) -> list[str]:
    """Problems that would make a paid run meaningless, each with its recovery step. Empty list = ready."""
    problems = []
    if not REPO:
        problems.append("CMLAB_REPO is unset. Create a detached checkout of the truth commit "
                        f"(git worktree add --detach <dir> {TRUTH_COMMIT[:8]}), open it as a workspace in the "
                        "CE debug app, and set CMLAB_REPO=<dir>.")
    elif not REPO.is_dir():
        problems.append(f"CMLAB_REPO={REPO} does not exist.")
    else:
        head = subprocess.run(["git", "-C", str(REPO), "rev-parse", "HEAD"], capture_output=True, text=True)
        dirty = subprocess.run(["git", "-C", str(REPO), "status", "--porcelain", "--untracked-files=no"],
                               capture_output=True, text=True)
        if head.returncode != 0 or head.stdout.strip() != TRUTH_COMMIT:
            problems.append(f"CMLAB_REPO HEAD is {head.stdout.strip() or 'unknown'}, not {TRUTH_COMMIT[:8]}. "
                            f"Run: git -C {REPO} checkout --detach {TRUTH_COMMIT[:8]}")
        elif dirty.stdout.strip():
            problems.append(f"CMLAB_REPO has tracked modifications; task truths assume a clean {TRUTH_COMMIT[:8]}.")
    if not CLI or not os.access(CLI, os.X_OK):
        problems.append(f"CE debug MCP helper not executable at {CLI}. Set CMLAB_CLI (see "
                        "docs/context/workflows/development.md, 'Use the CE debug CLI').")
    if need_codemode and (not QJS_HOST or not os.access(QJS_HOST, os.X_OK)):
        problems.append(f"QuickJS-ng host missing at {QJS_HOST}. Build it with Scripts/codemode_lab/build_qjs_host.sh.")
    elif need_codemode and links_homebrew_qjs(QJS_HOST):
        problems.append(f"{QJS_HOST} is the Homebrew test build (links libqjs, which bundles quickjs-libc). Build the gate host "
                        "with QJS_SRC=<quickjs-ng v0.17.0 checkout> Scripts/codemode_lab/build_qjs_host.sh.")
    if need_swiftc and not (os.access(SWIFTC, os.X_OK) or shutil.which(SWIFTC)):
        problems.append(f"swiftc not found at {SWIFTC} (edit tasks E1-E3 compile their checks). Set CMLAB_SWIFTC or drop E tasks.")
    for host, exe in (("claude", CLAUDE), ("codex", CODEX)):
        if host in need_hosts and not shutil.which(exe):
            problems.append(f"{host} CLI '{exe}' not found on PATH (set CMLAB_{host.upper()}).")
    return problems
