"""Lab tasks, prompts and graders. Every truth below holds at lab_config.TRUTH_COMMIT (see mechanical_truths).
Kinds (single / multi / heavy) are the plan's §7 gate buckets; `family` marks the understand and edit sets."""
import json, re, subprocess
import lab_config
TASKS = {
 "T1_caps": {"kind": "single", "q": "In Sources/RepoPrompt/Infrastructure/MCP/Policies/MCPToolAdmissionPolicy.swift, what are the configured admission limits?",
   "shape": '{"exclusive": n, "control": n, "smallRead": n, "smallReadPerWindow": n, "gitRead": n, "gitReadPerRepository": n, "fileSearch": n}',
   "truth": {"exclusive": 1, "control": 8, "smallread": 2, "smallreadperwindow": 2, "gitread": 2, "gitreadperrepository": 1, "filesearch": 4}},
 "T2_smallread_wire": {"kind": "multi", "q": "Which MCP tools does MCPToolAdmissionPolicy classify as `.smallRead`? Give their wire names (the actual string tool names such as \"some_tool\", not the Swift constant names).",
   "shape": '["wire_name", ...]', "truth": ["get_code_structure", "get_file_tree", "oracle_chat_log", "read_file"]},
 "T3_opencode_env": {"kind": "single", "q": "Which Swift files in Sources/RepoPrompt/Infrastructure/AI/Providers/OpenCode contain the literal string OPENCODE_CONFIG_CONTENT?",
   "shape": '["FileName.swift", ...]', "truth": ["OpenCodeACPAgentProvider.swift", "OpenCodeAgentConfig.swift", "OpenCodeIntegrationConfiguration.swift"]},
 "T4_policy_lines": {"kind": "multi", "q": "For every Swift file directly inside Sources/RepoPrompt/Infrastructure/MCP/Policies, report its total number of lines.",
   "shape": '{"FileName.swift": lines, ...}', "truth": {"AgentModeMCPToolAdvertisementPolicy.swift": 105, "AgentModeMCPToolPolicy.swift": 127, "DiscoverMCPToolPolicy.swift": 33,
      "MCPContextBuilderGitReviewPolicy.swift": 173, "MCPGitArtifactAdvertisementRegistry.swift": 296, "MCPPolicyGatedTools.swift": 17, "MCPToolAdmissionPolicy.swift": 78,
      "MCPToolCapabilities.swift": 129, "MCPToolExecutionContract.swift": 137}},
 "T5_admission_tests": {"kind": "single", "q": "Which Swift test files under Tests/ reference `MCPToolAdmissionPolicy`?",
   "shape": '["FileName.swift", ...]', "truth": ["MCPToolAdmissionPolicyTests.swift", "MCPToolExecutionWatchdogIntegrationTests.swift"]},
 "T6_ref_counts": {"kind": "multi", "q": "For each identifier smallReadPerWindowLimit, gitReadPerRepositoryLimit, fileSearchConnectionLimit and controlConnectionLimit, how many distinct Swift files under Sources/ and Tests/ reference it (as a whole word)?",
   "shape": '{"smallReadPerWindowLimit": n, "gitReadPerRepositoryLimit": n, "fileSearchConnectionLimit": n, "controlConnectionLimit": n}',
   "truth": {"smallReadPerWindowLimit": 4, "gitReadPerRepositoryLimit": 3, "fileSearchConnectionLimit": 3, "controlConnectionLimit": 3}},
 "T7_top_lines": {"kind": "heavy", "q": "Among the Swift files directly inside Sources/RepoPrompt/Infrastructure/MCP/WindowTools, which five files have the most lines, and how many lines does each have?",
   "shape": '{"FileName.swift": lines, ...} (exactly five entries)',
   "truth": {"MCPGitToolProvider.swift": 1544, "MCPFileToolProvider.swift": 1089, "MCPContextBuilderToolProvider.swift": 939, "MCPWorktreeToolProvider.swift": 801, "MCPSelectionToolProvider.swift": 697}},
 "T8_try_await": {"kind": "heavy", "q": "For the Swift files directly inside Sources/RepoPrompt/Infrastructure/MCP/WindowTools, count the number of LINES containing the text `try await` in each file. Report the three files with the most such lines (with their counts) and how many files contain at least one such line.",
   "shape": '{"top3": {"FileName.swift": n, ...}, "files_with_match": n}',
   "truth": {"top3": {"MCPGitToolProvider.swift": 43, "MCPWorktreeToolProvider.swift": 41, "MCPPromptContextToolProvider.swift": 25}, "files_with_match": 20}},
}

# ---------------------------------------------------------------- understand / edit families
# Truth for U1-U3 was derived by reading the truth commit and then confirmed (2026-10-10, not carried over)
# by compiling those Swift files with small stubs and executing each scenario. E1-E3 are graded by
# edit_grade.py against files materialized from `git show <TRUTH_COMMIT>:<path>`.
U3_RAW = r"""warning: CRLF will be replaced by LF in notes.txt
diff --git a/db/schema.sql b/db/schema.sql
index 1111111..2222222 100644
--- a/db/schema.sql
+++ b/db/schema.sql
@@ -10,4 +10,4 @@ CREATE TABLE users
 id INT,
--- legacy column
-name TEXT,
+full_name TEXT,
+-- added note
 email TEXT
\ No newline at end of file
diff --git "a/docs/caf\303\251.md" "b/docs/caf\303\251 new.md"
similarity index 90%
rename from "docs/caf\303\251.md"
rename to "docs/caf\303\251 new.md"
diff --git a/run.sh b/run.sh
old mode 100644
new mode 100755
"""
TASKS.update({
 "U1_env_build": {"kind": "multi", "family": "understand",
   "q": ("Trace `ProcessEnvironmentBuilder.build(_:)` - the overload WITHOUT a shellEnvironmentProvider argument - in Sources/RepoPrompt/Infrastructure/Process "
         "(read the function bodies it depends on). Assume `CLIEnvironmentCache.shared.environmentSnapshot(...)`, if it is called at all, returns a snapshot whose source is "
         "`.capturedLoginShell` and whose environment is S = {\"PATH\": \"/opt/homebrew/bin:/usr/local/bin\", \"BAR\": \"1\", \"__XPC_DYLD_LIBRARY_PATH\": \"/x\"}. "
         "Assume NSHomeDirectory() returns \"/Users/me\". Evaluate three requests (every ProcessEnvironmentRequest field not listed keeps its default):\n"
         "A: purpose .codexAppServer, inheritedEnvironment {\"TERM\": \"xterm\", \"PATH\": \"/usr/bin:/opt/homebrew/bin\", \"HOME\": \"\", \"DYLD_INSERT_LIBRARIES\": \"/evil.dylib\", \"FOO\": \"inherited\"}, overrides {\"FOO\": \"override\"}, additionalRemovedKeys [\"BAR\"].\n"
         "B: purpose .cliRunner, inheritedEnvironment {\"REPOPROMPT_LAUNCH_SOURCE\": \"launchservices\", \"XCTestSessionIdentifier\": \"7\", \"TERM\": \"xterm-256color\", \"PATH\": \"/usr/bin:/Users/me/bin:/usr/bin\"}.\n"
         "C: purpose .sidebarInteractiveShell, inheritedEnvironment {\"TERM_PROGRAM\": \"iTerm.app\", \"PATH\": \"/usr/bin:/opt/homebrew/bin\", \"SHELL\": \"/bin/zsh\"}.\n"
         "For each request report: launch_source = the result's launchContext.source case; env_source = the result's shellEnvironmentSource case; capture_mode = the "
         "ShellEnvironmentCaptureMode case passed to the cache, or \"none\" if the cache is not called; path = the final environment's PATH value; keys = the sorted list of "
         "keys in the final environment. Also report a_home and a_foo (the final HOME and FOO values for A) and c_term (the final TERM value for C)."),
   "shape": '{"A": {"launch_source": "case", "env_source": "case", "capture_mode": "case or none", "path": "...", "keys": ["..."]}, "B": {...same...}, "C": {...same...}, "a_home": "...", "a_foo": "...", "c_term": "..."}',
   "truth": {"A": {"launch_source": "terminalInherited", "env_source": "capturedLoginShell", "capture_mode": "loginShell", "path": "/opt/homebrew/bin:/usr/local/bin:/usr/bin", "keys": ["FOO", "HOME", "PATH", "TERM"]},
             "B": {"launch_source": "launchServices", "env_source": "capturedLoginShell", "capture_mode": "interactiveLoginShell", "path": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/Users/me/bin",
                   "keys": ["BAR", "HOME", "PATH", "REPOPROMPT_LAUNCH_SOURCE", "TERM", "XCTestSessionIdentifier"]},
             "C": {"launch_source": "terminalInherited", "env_source": "inheritedRichEnvironment", "capture_mode": "none", "path": "/usr/bin:/opt/homebrew/bin", "keys": ["HOME", "PATH", "SHELL", "TERM", "TERM_PROGRAM"]},
             "a_home": "/Users/me", "a_foo": "override", "c_term": "xterm-256color"},
   "enum_keys": ["launch_source", "env_source", "capture_mode"], "set_keys": ["keys"]},
 "U2_slice_math": {"kind": "multi", "family": "understand",
   "q": ("Evaluate the following using the code in Sources/RepoPrompt/Infrastructure/WorkspaceContext/Slices (and any helpers it calls). LineRange arguments are passed exactly as written; "
         "an omitted description means nil.\n"
         "(a) SliceRangeMath.normalize([LineRange(start: 10, end: 20, description: \"A\"), LineRange(start: 21, end: 25, description: \"B\"), LineRange(start: 0, end: 4), LineRange(start: 9, end: 3, description: \"A\")])\n"
         "(b) SliceRangeMath.subtract([LineRange(start: 1, end: 30)], removing: [LineRange(start: 5, end: 7), LineRange(start: 8, end: 8), LineRange(start: 20, end: 40)])\n"
         "(c) SliceAssemblyBuilder.build(from: content, ranges: [LineRange(start: 11, end: 50, description: \"tail\"), LineRange(start: 3, end: 4, description: \"x\"), LineRange(start: 5, end: 5, description: \"y\"), LineRange(start: 40, end: 45)]) "
         "where content is the twelve lines L1 ... L12, each terminated by a single \\n (content = \"L1\\nL2\\n...\\nL12\\n\").\n"
         "(d) SliceAssemblyBuilder.build(from: content, ranges: [LineRange(start: 20, end: 30)]) with the same content.\n"
         "Report: a = the resulting ranges as [start, end, description-or-null]; b = the resulting ranges as [start, end]; for (c) its usedRanges as [start, end], the descriptions of those "
         "usedRanges in order, totalCharacters and isFullFile; for (d) isFullFile, the ranges of its segments as [start, end], its usedRanges as [start, end], and totalCharacters."),
   "shape": '{"a": [[s, e, "desc or null"], ...], "b": [[s, e], ...], "c_used_ranges": [[s, e], ...], "c_descriptions": ["..."], "c_total_characters": n, "c_is_full_file": bool, "d_is_full_file": bool, "d_segment_ranges": [[s, e], ...], "d_used_ranges": [[s, e], ...], "d_total_characters": n}',
   "truth": {"a": [[1, 4, None], [9, 25, "A; B"]], "b": [[1, 4], [9, 19]], "c_used_ranges": [[3, 5], [11, 12]], "c_descriptions": ["x; y", "tail"], "c_total_characters": 17,
             "c_is_full_file": False, "d_is_full_file": True, "d_segment_ranges": [[1, 12]], "d_used_ranges": [], "d_total_characters": 39}},
 "U3_diff_pipeline": {"kind": "heavy", "family": "understand",
   "q": ("Questions about the git-diff pipeline in Sources/RepoPrompt/Infrastructure/VCS/GitDiff (read the function bodies involved; the answers depend on exact control flow). "
         "Let RAW be exactly the bytes between the ~~~ fences below (UTF-8; every line, including the last, ends with \\n; backslashes are literal characters):\n~~~\n" + U3_RAW + "~~~\n"
         "Let P1, P2, P3 be the spans returned by GitRawDiffFileSplitter.split(RAW) in order, each decoded as UTF-8. Let D1 = DiffLineProjector.project(patch: P1, fileKey: \"db/schema.sql\", contextLevel: .lines(3)), "
         "D2 = DiffLineProjector.project(patch: P2, fileKey: \"docs/café new.md\", contextLevel: .lines(3)), D3 = DiffLineProjector.project(patch: P3, fileKey: \"run.sh\", contextLevel: .lines(3)), "
         "and T1 = the same call as D1 but with maxLines: 3. Report:\n"
         "split_count = number of spans returned by split(RAW); d1_change, d2_change, d3_change = the FileDiffProjection.FileChange case name of each document (case name only, e.g. \"added\"); "
         "d2_old_path = D2.oldPath; d1_additions, d1_deletions = D1.additions, D1.deletions; d1_heading = D1.hunks[0].heading; d1_line_count = D1.hunks[0].lines.count; "
         "legacy_line_id, legacy_line_old = the id and oldLine of the D1 line whose text is \"-- legacy column\"; added_note_new = the newLine of the D1 line whose text is \"-- added note\"; "
         "tsv_rows = number of data rows (excluding the header row) in GitDiffPatchParsing.buildChangedLinesTsv(from: [\"db/schema.sql\": P1]); tsv_name_line = the line_number in that TSV of the row whose content is \"name TEXT,\"; "
         "count_changes = GitDiffPatchParsing.countChanges(in: P1) as [insertions, deletions]; split_rows = SplitDiffRowProjector.rows(for: D1.hunks[0]).count; "
         "marker_side = \"old\" or \"new\": the side occupied by the row holding the no-newline marker line in those rows; t1_projected, t1_total = T1.truncation's projectedLines and totalLines; "
         "gaps_20 = DiffContextSplicer.gaps(in: D1, sourceLineCount: 20, sourceSide: .new).count, with gap_before_hidden and gap_after_hidden = the hiddenLineCount of its beforeFirst and afterLast gaps; "
         "gaps_nil = DiffContextSplicer.gaps(in: D1, sourceLineCount: nil, sourceSide: .new).count; gaps_t1 = DiffContextSplicer.gaps(in: T1, sourceLineCount: 20, sourceSide: .new).count; "
         "spec_back0 = GitDiffCompareSpec.parse(\"Back: 0\").rawKey; spec_mergebase_raw and spec_mergebase_display = rawKey and displayString of GitDiffCompareSpec.parse(\"  MergeBase:  \")."),
   "shape": '{"split_count": n, "d1_change": "case", "d2_change": "case", "d3_change": "case", "d2_old_path": "...", "d1_additions": n, "d1_deletions": n, "d1_heading": "...", "d1_line_count": n, "legacy_line_id": "...", "legacy_line_old": n, "added_note_new": n, "tsv_rows": n, "tsv_name_line": n, "count_changes": [ins, del], "split_rows": n, "marker_side": "old|new", "t1_projected": n, "t1_total": n, "gaps_20": n, "gap_before_hidden": n, "gap_after_hidden": n, "gaps_nil": n, "gaps_t1": n, "spec_back0": "...", "spec_mergebase_raw": "...", "spec_mergebase_display": "..."}',
   "truth": {"split_count": 3, "d1_change": "modified", "d2_change": "renamed", "d3_change": "modeOnly", "d2_old_path": "docs/café.md", "d1_additions": 2, "d1_deletions": 2,
             "d1_heading": "CREATE TABLE users", "d1_line_count": 7, "legacy_line_id": "db/schema.sql#0#1", "legacy_line_old": 11, "added_note_new": 12, "tsv_rows": 3, "tsv_name_line": 11,
             "count_changes": [2, 1], "split_rows": 5, "marker_side": "old", "t1_projected": 3, "t1_total": 7, "gaps_20": 2, "gap_before_hidden": 9, "gap_after_hidden": 7, "gaps_nil": 1, "gaps_t1": 0,
             "spec_back0": "revspec:Back: 0", "spec_mergebase_raw": "uncommitted-mergebase:HEAD", "spec_mergebase_display": "mergebase:HEAD"},
   "enum_keys": ["d1_change", "d2_change", "d3_change", "marker_side"]},
 "E1_rename_subtract": {"kind": "multi", "family": "edit",
   "q": ("Rename the second parameter of `SliceRangeMath.subtract` (Sources/RepoPrompt/Infrastructure/WorkspaceContext/Slices/SliceRangeMath.swift) from `removing` to `excluding` - both the argument "
         "label and the internal parameter name - and update every call site under Sources/ and Tests/. Keep the local variable `removingNormalized` and all other code exactly as it is.")},
 "E2_env_source_case": {"kind": "multi", "family": "edit",
   "q": ("Add a new case `persistedSnapshotFallback` to the `ShellEnvironmentSource` enum, declared on the line immediately after `case previousCapturedFallback`. Then handle the new case in every "
         "`switch` over ShellEnvironmentSource under Sources/ so the project still compiles: the CLI launch-diagnostics fallback hint must return exactly the string "
         "\"Environment was restored from a persisted shell snapshot because login-shell capture failed or timed out; PATH may be stale.\" for the new case (as its own `case` label), and the Sentry "
         "telemetry formatter must return \"persisted_snapshot_fallback\" for it. Do not change the behaviour of any existing case and do not modify any other code.")},
 "E3_label_cap": {"kind": "multi", "family": "edit",
   "q": ("In Sources/RepoPrompt/Infrastructure/VCS/GitWorktreeDisplayLabelHumanizer.swift, `cappedSessionLabel` uses a local `let limit = 24`. Replace it with a type-level constant "
         "`static let sessionLabelCharacterLimit = 32` (it may be `private`), declared immediately above `cappedSessionLabel` with a one-line `///` doc comment, and use that constant everywhere "
         "`limit` was used. Leave the 12-character minimum-boundary rule unchanged. Then update the existing unit test under Tests/ that asserts a capped session label so it passes with the new "
         "limit - change only that expected string literal.")},
})

def prompt(tid, root=None):
    t = TASKS[tid]; root = root or lab_config.REPO or "<CMLAB_REPO>"
    if t.get("family") == "edit":
        return (f"Prepare a code change for the repository at {root} using ONLY the `rp` MCP tools (RepoPrompt read-only tools; a code_mode tool may also be available). "
                "Do not run shell commands and do not use any other file tools. You cannot modify files: output the change as a patch instead. Paths are relative to the repository root.\n\n"
                f"Change: {t['q']}\n\nFinish with exactly one fenced ```diff block containing a git-style unified diff (`--- a/<path>` / `+++ b/<path>` headers, paths relative to the repository root, "
                "correct context lines) that implements the whole change; it will be applied with `git apply` to the files as they are at HEAD.")
    return (f"Answer a question about the repository at {root} using ONLY the `rp` MCP tools (RepoPrompt read-only tools; a code_mode tool may also be available). "
            "Do not run shell commands and do not use any other file tools. Paths are relative to the repository root.\n\n"
            f"Question: {t['q']}\n\nFinish with exactly one fenced ```json block containing only the answer, in this shape: {t['shape']}")
def norm(s): return re.sub(r"[^a-z0-9]", "", str(s).lower())
def base(s): return str(s).strip().split("/")[-1]
def _flat(d, prefix=""):
    out = {}
    for k, v in d.items():
        if isinstance(v, dict): out.update(_flat(v, f"{prefix}{k}."))
        else: out[f"{prefix}{k}"] = v
    return out
def _nfc(v):
    import unicodedata
    if isinstance(v, str): return unicodedata.normalize("NFC", v.strip())
    if isinstance(v, (list, tuple)): return [_nfc(x) for x in v]
    return v
def _same(key, truth, got, t):
    leaf = key.split(".")[-1]
    if leaf in t.get("enum_keys", ()):
        return isinstance(got, str) and norm(got.split("(")[0]) == norm(truth)
    if leaf in t.get("set_keys", ()):
        return isinstance(got, list) and sorted(map(str, got)) == sorted(truth)
    if isinstance(truth, bool) or truth is None: return got is truth
    if isinstance(truth, (int, float)): return not isinstance(got, bool) and got == truth
    return _nfc(got) == _nfc(truth)
def grade_understand(tid, text):
    blocks = re.findall(r"```json\s*(.*?)```", text or "", re.S)
    if not blocks: return {"correct": False, "score": 0.0, "parse": False}
    try: ans = json.loads(blocks[-1])
    except Exception: return {"correct": False, "score": 0.0, "parse": False}
    if not isinstance(ans, dict): return {"correct": False, "score": 0.0, "parse": True}
    t = TASKS[tid]; truth = _flat(t["truth"]); got = _flat(ans)
    wrong = [k for k, v in truth.items() if not (k in got and _same(k, v, got[k], t))]
    return {"correct": not wrong, "score": round(1 - len(wrong) / len(truth), 3), "parse": True, "failed_checks": wrong}
def grade(tid, text):
    fam = TASKS[tid].get("family")
    if fam == "edit":
        from edit_grade import grade_edit
        return grade_edit(tid, text)
    if fam == "understand": return grade_understand(tid, text)
    blocks = re.findall(r"```json\s*(.*?)```", text or "", re.S)
    if not blocks: return {"correct": False, "score": 0.0, "parse": False}
    try: ans = json.loads(blocks[-1])
    except Exception: return {"correct": False, "score": 0.0, "parse": False}
    truth = TASKS[tid]["truth"]
    if isinstance(truth, list):
        got = {base(x) for x in ans} if isinstance(ans, list) else set()
        tp = len(got & set(truth)); score = tp / max(len(truth), len(got) or 1)
        return {"correct": got == set(truth), "score": round(score, 3), "parse": True}
    if not isinstance(ans, dict): return {"correct": False, "score": 0.0, "parse": True}
    if tid == "T1_caps":
        g = {norm(k): v for k, v in ans.items()}
        ok = sum(1 for k, v in truth.items() if g.get(k) == v)
    elif tid == "T7_top_lines":
        g = {base(k): v for k, v in ans.items()}
        ok = sum(1 for k, v in truth.items() if isinstance(g.get(k), int) and abs(g[k] - v) <= 1)
        if len(g) != 5: ok = min(ok, 4)
    elif tid == "T8_try_await":
        top = {base(k): v for k, v in (ans.get("top3") or {}).items()} if isinstance(ans.get("top3"), dict) else {}
        ok = sum(1 for k, v in truth["top3"].items() if top.get(k) == v) + (ans.get("files_with_match") == truth["files_with_match"])
        return {"correct": ok == 4, "score": round(ok / 4, 3), "parse": True}
    elif tid == "T4_policy_lines":
        g = {base(k): v for k, v in ans.items()}
        ok = sum(1 for k, v in truth.items() if isinstance(g.get(k), int) and abs(g[k] - v) <= 1)
        if set(g) - set(truth): ok = min(ok, len(truth) - 1)
    else:
        ok = sum(1 for k, v in truth.items() if ans.get(k) == v)
    return {"correct": ok == len(truth), "score": round(ok / len(truth), 3), "parse": True}

def mechanical_truths(commit=None):
    """Recompute the truths of the mechanical tasks (T3-T8) from git at `commit` (default: the truth commit).
    T1, T2 and the understand/edit families need code reading and are not recomputed here."""
    c = commit or lab_config.TRUTH_COMMIT; g = ["git", "-C", str(lab_config.git_dir())]
    def run(*a): return subprocess.run(g + list(a), capture_output=True, text=True, check=True).stdout
    def grep_files(pattern, *paths, word=False):
        r = subprocess.run(g + ["grep", "-l", "-F"] + (["-w"] if word else []) + ["-e", pattern, c, "--"] + list(paths), capture_output=True, text=True)
        if r.returncode not in (0, 1): raise RuntimeError(r.stderr.strip())
        return sorted({l.split(":", 1)[1] for l in r.stdout.splitlines() if l.endswith(".swift")})
    def direct_swift(d): return [p for p in run("ls-tree", "--name-only", c, d.rstrip("/") + "/").splitlines() if p.endswith(".swift")]
    def text(p): return run("show", f"{c}:{p}")
    wt = {base(p): text(p) for p in direct_swift("Sources/RepoPrompt/Infrastructure/MCP/WindowTools")}
    by_lines = sorted(wt.items(), key=lambda kv: -kv[1].count("\n"))
    tries = {k: sum("try await" in l for l in v.splitlines()) for k, v in wt.items()}
    top_tries = sorted(tries.items(), key=lambda kv: -kv[1])
    return {
        "T3_opencode_env": sorted(base(p) for p in grep_files("OPENCODE_CONFIG_CONTENT", "Sources/RepoPrompt/Infrastructure/AI/Providers/OpenCode")),
        "T4_policy_lines": {base(p): text(p).count("\n") for p in direct_swift("Sources/RepoPrompt/Infrastructure/MCP/Policies")},
        "T5_admission_tests": sorted(base(p) for p in grep_files("MCPToolAdmissionPolicy", "Tests/")),
        "T6_ref_counts": {i: len(grep_files(i, "Sources/", "Tests/", word=True)) for i in TASKS["T6_ref_counts"]["truth"]},
        "T7_top_lines": {k: v.count("\n") for k, v in by_lines[:5]},
        "T8_try_await": {"top3": dict(top_tries[:3]), "files_with_match": sum(1 for v in tries.values() if v)},
    }
