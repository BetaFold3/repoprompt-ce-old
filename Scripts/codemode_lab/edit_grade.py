"""Grader for E-family (edit) tasks.

grade_edit(tid, text) -> {"correct", "score", "parse", "applied", "apply_strict", "failed_checks", "diff_block_count"}

Pipeline: require exactly one ```diff block (the prompts demand it; none -> no_diff_block, more than one ->
multiple_diff_blocks, both before any fixture, git or swiftc work) -> collect touched paths -> reject paths outside the
task's allowed set -> materialize allowed files from `git show <TRUTH_COMMIT>:<path>` into a temp dir ->
`git apply --check` (strict; fallback `--recount` for wrong hunk-header counts, recorded as
apply_strict=False) -> apply -> task checks (regexes, bounded line churn, swiftc typecheck/run).
correct = applied AND every check passes; score = passed checks / total checks (0 if not applied).
"""
import difflib, functools, os, re, subprocess, tempfile

import lab_config

SWIFTC = lab_config.SWIFTC

P_SLICE = "Sources/RepoPrompt/Infrastructure/WorkspaceContext/Slices/SliceRangeMath.swift"
P_LINERANGE = "Sources/RepoPrompt/Infrastructure/WorkspaceContext/Slices/LineRange.swift"
P_PARTITION = "Sources/RepoPrompt/Infrastructure/WorkspaceContext/Slices/PartitionStore.swift"
P_WSMS = "Sources/RepoPrompt/Infrastructure/WorkspaceContext/Selection/WorkspaceSelectionMutationService.swift"
P_PEB = "Sources/RepoPrompt/Infrastructure/Process/ProcessEnvironmentBuilder.swift"
P_PLC = "Sources/RepoPrompt/Infrastructure/Process/ProcessLaunchContext.swift"
P_PES = "Sources/RepoPrompt/Infrastructure/Process/ProcessEnvironmentSanitizer.swift"
P_ACP = "Sources/RepoPrompt/Infrastructure/AI/Providers/ACPLaunchEnvironmentDiagnostics.swift"
P_SENTRY = "Sources/RepoPrompt/Infrastructure/Telemetry/SentryTelemetryModel.swift"
P_HUM = "Sources/RepoPrompt/Infrastructure/VCS/GitWorktreeDisplayLabelHumanizer.swift"
P_HUMTEST = "Tests/RepoPromptTests/AgentMode/AgentWorkspaceRootsSidebarStoreTests.swift"

NEW_HINT = ("Environment was restored from a persisted shell snapshot because login-shell capture "
            "failed or timed out; PATH may be stale.")


@functools.lru_cache(maxsize=None)
def head(path):
    return lab_config.show_at_truth(path)


def churn(before, after):
    """(removed, added) line counts between two texts."""
    rem = add = 0
    for l in difflib.ndiff(before.splitlines(), after.splitlines()):
        if l.startswith("- "): rem += 1
        elif l.startswith("+ "): add += 1
    return rem, add


def within(p, f, max_removed, max_added):
    r, a = churn(head(p), f[p])
    return r <= max_removed and a <= max_added


def swift_run(files, out_dir, timeout=240):
    exe = os.path.join(out_dir, "a.out")
    r = subprocess.run([SWIFTC, "-o", exe] + files, capture_output=True, text=True, timeout=timeout)
    if r.returncode != 0: return False, r.stderr[-2000:]
    r = subprocess.run([exe], capture_output=True, text=True, timeout=60, cwd=out_dir)
    return r.returncode == 0, r.stdout


def swift_parse(path):
    return subprocess.run([SWIFTC, "-parse", path], capture_output=True, text=True, timeout=120).returncode == 0


def extract_static_func(src, name):
    """Text of `static func <name>` through its closing brace at the same indentation."""
    lines = src.splitlines()
    for i, l in enumerate(lines):
        if re.search(rf"\bstatic func {re.escape(name)}\b", l):
            indent = l[: len(l) - len(l.lstrip())]
            for j in range(i + 1, len(lines)):
                if lines[j] == indent + "}":
                    return "\n".join(lines[i: j + 1])
            return None
    return None


def _w(d, name, text):
    p = os.path.join(d, name)
    with open(p, "w") as fh: fh.write(text)
    return p


# ---------------------------------------------------------------- task checks
# Each check: (name, fn(files: dict[path->text], tmp: str) -> bool)

def _e1_checks():
    def sig(f, _): return re.search(r"static func subtract\(_ base: \[LineRange\], excluding: \[LineRange\]\) -> \[LineRange\]", f[P_SLICE]) is not None
    def body(f, _): return "let removingNormalized = normalize(excluding)" in f[P_SLICE]
    def no_removing(f, _): return re.search(r"\bremoving\b", f[P_SLICE]) is None
    def call_partition(f, _): return "SliceRangeMath.subtract(current.ranges, excluding: normalized)" in f[P_PARTITION] and "removing:" not in f[P_PARTITION]
    def call_wsms(f, _): return "SliceRangeMath.subtract(baseRanges, excluding: removal)" in f[P_WSMS] and not re.search(r"subtract\([^)]*removing:", f[P_WSMS])
    def bounded(f, _): return within(P_SLICE, f, 3, 3) and within(P_PARTITION, f, 1, 1) and within(P_WSMS, f, 1, 1)
    def compiles_and_runs(f, tmp):
        d = os.path.join(tmp, "_swift"); os.makedirs(d, exist_ok=True)
        files = [_w(d, "LineRange.swift", head(P_LINERANGE)), _w(d, "SliceRangeMath.swift", f[P_SLICE]), _w(d, "main.swift",
            'let r = SliceRangeMath.subtract([LineRange(start: 1, end: 30)], excluding: [LineRange(start: 5, end: 8), LineRange(start: 20, end: 40)])\n'
            'print(r.map { "\\($0.start)-\\($0.end)" }.joined(separator: ","))\n')]
        ok, out = swift_run(files, d)
        return ok and out.strip() == "1-4,9-19"
    def parses(f, tmp): return all(swift_parse(os.path.join(tmp, p)) for p in (P_PARTITION, P_WSMS))
    return [("signature", sig), ("body_uses_excluding", body), ("no_removing_left", no_removing),
            ("call_partition", call_partition), ("call_wsms", call_wsms), ("bounded_churn", bounded),
            ("slice_math_compiles_runs", compiles_and_runs), ("callsites_parse", parses)]


def _e2_checks():
    def enum_case(f, _): return re.search(r"case previousCapturedFallback[ \t]*\n[ \t]*case persistedSnapshotFallback[ \t]*\n", f[P_PEB]) is not None
    def hint(f, _): return re.search(r"case \.persistedSnapshotFallback:\s*\n\s*(return\s+)?\"" + re.escape(NEW_HINT) + "\"", f[P_ACP]) is not None
    def sentry(f, _): return re.search(r"case \.persistedSnapshotFallback:\s*\n\s*return \"persisted_snapshot_fallback\"", f[P_SENTRY]) is not None
    def bounded(f, _): return within(P_PEB, f, 0, 1) and within(P_ACP, f, 0, 4) and within(P_SENTRY, f, 0, 3)
    def behaviour(f, tmp):
        d = os.path.join(tmp, "_swift"); os.makedirs(d, exist_ok=True)
        h = extract_static_func(f[P_ACP], "fallbackEnvironmentHint")
        s = extract_static_func(f[P_SENTRY], "formatShellEnvironmentSource")
        if not h or not s: return False
        files = [_w(d, "peb.swift", f[P_PEB]), _w(d, "plc.swift", head(P_PLC)), _w(d, "pes.swift", head(P_PES)),
                 _w(d, "stub.swift",
                    "actor CLIEnvironmentCache { static let shared = CLIEnvironmentCache()\n"
                    "  func environmentSnapshot(enableLogging: Bool, forceRefresh: Bool, captureMode: ShellEnvironmentCaptureMode) async -> CLIEnvironmentSnapshot {\n"
                    "    CLIEnvironmentSnapshot(environment: [:], source: .enrichedFallback) } }\n"
                    "enum AgentCLILaunchDiagnostics {\n" + h + "\n}\nenum SentryTelemetryValue {\n" + s + "\n}\n"),
                 _w(d, "main.swift",
                    "let all: [ShellEnvironmentSource?] = [.inheritedRichEnvironment, .capturedLoginShell, .previousCapturedFallback, .persistedSnapshotFallback, .enrichedFallback, nil]\n"
                    "for s in all { print(AgentCLILaunchDiagnostics.fallbackEnvironmentHint(for: s) ?? \"nil\"); print(SentryTelemetryValue.formatShellEnvironmentSource(s) ?? \"nil\") }\n")]
        ok, out = swift_run(files, d)
        expected = [
            "nil", "inherited_rich_environment",
            "nil", "captured_login_shell",
            "Environment reused the last captured shell PATH because login-shell capture failed or timed out; PATH may be stale.", "previous_captured_fallback",
            NEW_HINT, "persisted_snapshot_fallback",
            "Environment was built from RepoPrompt's fallback PATH because login-shell capture failed or timed out; PATH may not match Terminal.", "enriched_fallback",
            "nil", "nil"]
        return ok and out.strip().splitlines() == expected
    def parses(f, tmp): return all(swift_parse(os.path.join(tmp, p)) for p in (P_PEB, P_ACP, P_SENTRY))
    return [("enum_case_after_previous", enum_case), ("acp_hint_case", hint), ("sentry_case", sentry),
            ("bounded_churn", bounded), ("switches_compile_and_behave", behaviour), ("files_parse", parses)]


def _e3_checks():
    def decl(f, _):
        return re.search(r"\n[ \t]*///[^\n]*\n[ \t]*(private[ \t]+)?static let sessionLabelCharacterLimit(\s*:\s*Int)?\s*=\s*32[ \t]*\n(\s*\n)*[ \t]*private static func cappedSessionLabel\(", f[P_HUM]) is not None
    def no_local(f, _): return re.search(r"\blet limit\s*=", f[P_HUM]) is None and f[P_HUM].count("sessionLabelCharacterLimit") >= 3
    def test_expect(f, _):
        rem, add = churn(head(P_HUMTEST), f[P_HUMTEST])
        return rem == 1 and add == 1 and re.search(r'\n[ \t]*"Implement login polish for"[ \t]*\n', f[P_HUMTEST]) is not None
    def bounded(f, _): return within(P_HUM, f, 4, 7)
    def behaviour(f, tmp):
        d = os.path.join(tmp, "_swift"); os.makedirs(d, exist_ok=True)
        files = [_w(d, "hum.swift", f[P_HUM]), _w(d, "main.swift",
            'func s(_ n: String) -> String { GitWorktreeDisplayLabelHumanizer.seededVisualIdentityLabel(sessionName: n, worktreeName: nil, branch: nil, isMain: false) ?? "nil" }\n'
            'print(s("  Implement login polish for sidebar  "))\n'
            'print(s("abcdefghijklmnopqrstuvwxyz0123456789"))\n'
            'print(s("Short label"))\n'
            'print(GitWorktreeDisplayLabelHumanizer.displayLabel(for: "rp-agent-1a98df1a-fix-login-abcdef12-2") ?? "nil")\n')]
        ok, out = swift_run(files, d)
        return ok and out.strip().splitlines() == ["Implement login polish for", "abcdefghijklmnopqrstuvwxyz012345", "Short label", "fix-login"]
    def parses(f, tmp): return swift_parse(os.path.join(tmp, P_HUMTEST))
    return [("documented_constant_above_func", decl), ("local_limit_replaced", no_local), ("test_expectation", test_expect),
            ("bounded_churn", bounded), ("compiles_and_behaves", behaviour), ("test_parses", parses)]


EDIT_TASKS = {
    "E1_rename_subtract": {"allowed": [P_SLICE, P_PARTITION, P_WSMS], "checks": _e1_checks},
    "E2_env_source_case": {"allowed": [P_PEB, P_ACP, P_SENTRY], "checks": _e2_checks},
    "E3_label_cap": {"allowed": [P_HUM, P_HUMTEST], "checks": _e3_checks},
}


def _touched(diff):
    paths = set()
    for l in diff.splitlines():
        m = re.match(r"^(?:\+\+\+|---) (\S+)", l)
        if m and m.group(1) != "/dev/null":
            paths.add(re.sub(r"^[ab]/", "", m.group(1)))
    return paths


def _with_git_headers(diff):
    """For header-less unified diffs, insert `diff --git` lines before each ---/+++ pair so that
    `git apply --recount` knows where a file's last hunk ends (otherwise the next file's `--- a/`
    header is read as a deletion line)."""
    if re.search(r"^diff --git ", diff, re.M): return diff
    lines = diff.split("\n"); out = []
    for i, l in enumerate(lines):
        if l.startswith("--- ") and i + 1 < len(lines) and lines[i + 1].startswith("+++ "):
            a, b = l[4:].split("\t")[0].strip(), lines[i + 1][4:].split("\t")[0].strip()
            out.append(f"diff --git {a if a != '/dev/null' else b} {b if b != '/dev/null' else a}")
        out.append(l)
    return "\n".join(out)


def grade_edit(tid, text):
    blocks = re.findall(r"```diff[^\n]*\n(.*?)```", text or "", re.S)
    fail = {"correct": False, "score": 0.0, "applied": False, "apply_strict": False, "diff_block_count": len(blocks)}
    if not blocks:
        return {**fail, "parse": False, "failed_checks": ["no_diff_block"]}
    if len(blocks) > 1:
        return {**fail, "parse": False, "failed_checks": ["multiple_diff_blocks"]}
    diff = blocks[0]
    if not diff.endswith("\n"): diff += "\n"
    spec = EDIT_TASKS[tid]
    touched = _touched(diff)
    if not touched:
        return {**fail, "parse": False, "failed_checks": ["no_paths"]}
    extra = touched - set(spec["allowed"])
    if extra:
        return {**fail, "parse": True, "failed_checks": ["unintended_files:" + ",".join(sorted(extra))]}
    with tempfile.TemporaryDirectory(prefix="editgrade-") as tmp:
        for p in spec["allowed"]:
            os.makedirs(os.path.dirname(os.path.join(tmp, p)), exist_ok=True)
            _w(tmp, p, head(p))
        pfile = _w(tmp, "_answer.patch", diff)
        plus = [l for l in diff.splitlines() if l.startswith("+++ ") and "/dev/null" not in l]
        strip = "-p1" if plus and all(l[4:].startswith("b/") for l in plus) else "-p0"
        applied = strict = False
        rfile = _w(tmp, "_answer_recount.patch", _with_git_headers(diff))
        for flags, is_strict, patch in (([], True, pfile), (["--recount"], False, rfile)):
            cmd = ["git", "apply", strip] + flags
            if subprocess.run(cmd + ["--check", patch], cwd=tmp, capture_output=True).returncode == 0:
                applied = subprocess.run(cmd + [patch], cwd=tmp, capture_output=True).returncode == 0
                strict = is_strict and applied
                if applied: break
        if not applied:
            return {**fail, "parse": True, "failed_checks": ["apply_failed"]}
        files = {}
        for p in spec["allowed"]:
            with open(os.path.join(tmp, p)) as fh: files[p] = fh.read()
        checks = spec["checks"]()
        failed = []
        for name, fn in checks:
            try: ok = fn(files, tmp)
            except Exception as e: ok, name = False, f"{name}:{type(e).__name__}"
            if not ok: failed.append(name)
    score = round((len(checks) - len(failed)) / len(checks), 3)
    return {"correct": not failed, "score": score, "parse": True, "applied": True, "apply_strict": strict, "failed_checks": failed,
            "diff_block_count": 1}
