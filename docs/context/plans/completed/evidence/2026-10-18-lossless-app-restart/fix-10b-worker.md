# Step 10b worker report: quarantine classes C, P and S

Scope: read when the task touches cleanup of leaked unit-test data in the live RepoPrompt CE Application Support store (Step 10b) or Scripts/quarantine_fixture_workspaces.py.
Authority: Reference
Last-verified: 2026-10-28
Covers: the quarantine-script extension, its self-test and read-only live dry runs

## Round 0

The removal tooling for Step 10b is ready. The self-test passes, and a read-only dry run against the live store finds exactly the expected **19,461 / 926 / 83**. I did not run `--apply` or `--restore`, and nothing under Application Support was changed.

## The change
Only one file changed: `Scripts/quarantine_fixture_workspaces.py` (+442 / −33, nothing staged). Three new `--class` values, C, P and S, reuse the existing manifest, lock, app-running refusal, same-volume move, write-ahead journal and `--restore` paths.

- **Constants, `:137–201`:**
  - `FIXTURE_NAME_GROUPS` (`:137`) is the 57 fixture name groups from the classification.
  - Size limits: at most 64 entries per folder and 2 MiB per file.
  - `TEMP_PATH_RE` matches temp paths.
  - `SB_FILE_RE` matches the sb file names.
  - `CLASS_ORDER = A,B,C,P,S` (`:201`), so workspace folders move before their Partitions.
- **Class C, `classify_fixture` (`:740`):** a non-empty fixture workspace folder. It is excluded if any of these holds:
  - its name is not a fixture name group;
  - the index, windowSessions or MCP routing reference it (hard references);
  - AgentRecovery mentions a UUID in its paths;
  - it was modified in the last 24 h;
  - it has more than 64 entries or a file over 2 MiB;
  - it contains a symlink that is absolute or uses `..`, or any other unexpected entry type (`_contained_symlink`, `:829`);
  - a file mentions a user path (`~/…`, ignoring `Library/` and dot-folders);
  - `workspace.json` is unreadable, its id doesn't match the folder, or it is a system or custom-storage workspace;
  - it has no fixture signal (not marked ephemeral and no temp paths).
- **Class P, `classify_partition_dir` (`:840`):** a Partitions folder qualifies only if *every* file in it belongs to a class C candidate in the same run. A folder that mixes in a real workspace's file is excluded.
- **Class S, `classify_sb_file` (`:881`):** a regular `windowSessions.json.sb-*` file under 4 KiB, older than 24 h, whose content is empty or `windows: []`.
- **Run paths:**
  - `_source_parent` and `_valid_entry_name` (`:920`, `:924`) give each class its origin folder.
  - `run_dry` (`:957`).
  - `run_apply` (`:1249`) re-checks each candidate per class before moving it. Class P is re-checked against the C workspaces that have actually been moved (`gone_ids`, `:1281`/`:1301`).
  - `run_restore` (`:1414`) puts each item back only into its class's own origin folder, and checks that sb entries are files.
  - `--class` choices (`:1952`).
- **Self-test:** `_self_test_fixture_classes` (`:1846`) runs on its own temp store. It covers:
  - an OK fixture with a contained symlink;
  - fixtures excluded for index, window, MCP or recovery references, a user path, no fixture signal, a non-fixture name, or an escaping symlink;
  - a P folder that qualifies and a mixed one that doesn't;
  - three sb cases;
  - a P-only apply, which is skipped on re-check;
  - a full C+P+S apply, then a restore of all 4 items with 0 changed and the symlink intact.
- **Mutation checks:** if I revert the fingerprint change, or turn off either the P "all files belong to candidates" rule or the C reference check, the self-test fails.

## Results
- **`--self-test`:** `self-test passed (11 malformed-container cases; classes C, P, S)`, exit 0.
- **`--dry-run`:** read-only, 19,533 entries in 8.4 s. The manifest is at `.agent-artifacts/lossless-restart-10b/manifest-20261028.json` (git-ignored).

| Class | Dry run | Classification | Cross-check |
|---|---|---|---|
| C | 19,461 dirs (39.6 MiB, 115.9 MiB on disk) | F1 19,461 | identical set |
| P | 926 dirs / 926 files | 926 fixture files | identical set; 0 folders shared with real workspaces |
| S | 83 | 83 | match |
| A/B | 0 | – | – |

The exclusions line up with the classification: 60 referenced (28 K1 + 32 K2), 10 `c_user_path` (the 10 F2 dirs), 1 `has_agent_sessions` (H2) and 1 `not_directory` (`workspacesIndex.json`).

Two fixes came out of the first dry run:
1. **Symlinks.** It found only 19,150, because 311 "Distinct MCP Connection A" folders contain relative `_git_data/.../CURRENT` symlinks. I now allow symlinks that stay inside the folder.
2. **User-path rule.** It would have excluded 165 "Resume Ownership" fixtures that mention `~/.codex*`, so it now ignores dot-folders. All 10 F2 dirs and H2 are still caught.

**`make guardrails`:** exit 0. The only warning is the existing one about AGENTS.md having too many routes.

## Commands for the owner's quit window
Quit the app and its helpers first. All commands run in `/Users/tnguyen/workspace/repoprompt-ce-personal-touch`.

1. Take a fresh dry run and confirm the counts are still 19,461 / 926 / 83:
   ```
   python3 Scripts/quarantine_fixture_workspaces.py --dry-run --manifest .agent-artifacts/lossless-restart-10b/manifest-$(date -u +%Y%m%dT%H%M%SZ).json
   ```
2. Apply, using the manifest written in step 1:
   ```
   python3 Scripts/quarantine_fixture_workspaces.py --apply --manifest .agent-artifacts/lossless-restart-10b/<that manifest>.json --class C --class P --class S
   ```
3. Restore, only if needed:
   ```
   python3 Scripts/quarantine_fixture_workspaces.py --restore "$HOME/Library/Application Support/RepoPrompt CE/Workspaces-Quarantine-<UTC stamp>/restore-manifest.jsonl"
   ```

Exit code 3 means the apply stopped early, and everything moved up to that point is in the journal and can be restored.

**Expected duration:** about 20,470 moves, each with its journal entry written to disk, plus about 205 periodic safety checks (a process check and a reload of the reference stores) at a few seconds each. My estimate is **10–20 minutes**, but I haven't measured it at full scale.

## What I did not do
- I did not run `--apply` or `--restore` on the live store, and modified nothing under Application Support.
- I did not stage or commit, run `make dev-format`, or touch the app.
- I left `docs/testing.md` unchanged, because line 86 mentions the script but not its classes.
- I didn't touch F2, K1, K2, H2, the 1,243 orphan Partitions files, the `task-cb-*` files, AgentRecovery or globalSettings.

**Trade-off to note:** the periodic safety check no longer re-reads Partitions. Without that change, the P moves would trip it in the middle of the run. Workspace folders that Partitions references are still excluded by the check at the start of the run, and the app-process check is unchanged.

## Round 1 (round-0 review fixes)

All eight must-fix items and the three cheap ones are in `Scripts/quarantine_fixture_workspaces.py`. The self-test passes and the new live dry run selects exactly the same items as before. One gap in the recovery-after-a-stop advice needs your decision (see the end). I did not run `--apply` or `--restore`, nothing is staged or committed, and nothing under Application Support was changed.

## Fixes (file:line)
1. **P only after a C move in the same run (A F1, B 10b-06).**
   - P now qualifies only against `moved_c_ids`, the workspaces whose C rename succeeded in this run (`:1359`, `:1378`, `:1416`). The "folder is missing" set is gone, so a P-only run moves nothing.
   - The docstring (`:26`, `:54`) and the exit-3 message (`:1440`) now say: re-run `--apply` with the same manifest and the same classes.
   - Test `:2032`: the C folder is renamed away and its UUID indexed before apply. Result: 0 moved, C skipped as `c_not_workspace_dir`, P skipped as `p_not_all_candidates`.
2. **Partitions stay in the periodic check (A F2, B 10b-07).**
   - `_reference_fingerprint(…, expected)` (`:1251`) leaves out only the Partitions references of the manifest's C IDs, plus a count of Partitions files belonging to any other workspace (`:482`, `:512`).
   - This applies only when C and P are both selected (`:1339`). Restore does the same for the IDs in its P entries (`:1516`, `:1525`). All other runs use the original check.
   - Test `:2044`: adding another workspace's file mid-run stops the apply, and so does swapping one in at the same file count. The expected P moves in the main run don't stop it.
3. **Restore tree limit (B 10b-01, A F5):** C and P use the 64-entry limit, and overflow counts as changed (`:1557`). Test: a C fixture with 42 entries restores with changedCount 0 (`:2014`).
4. **`workspacesIndex.json` required:**
   - The dry run raises (exit 2) if it finds C candidates and the index is absent (`:1040`). Apply with C or P refuses before creating a quarantine folder (`:1342`).
   - A present but unreadable index already failed closed. Test `:2078`.
5. **Home from the store:**
   - `_store_home` (`:562`) takes the folder owner's home from `pwd` and the part of the path before `/Library/Application Support/`, and refuses unless both equal `$HOME`.
   - The manifest records it (`"home"`, `:1057`). Apply with C refuses if the manifest's home differs (`:1334`).
   - Test: `HOME` overridden makes the dry run refuse (`:2018`).
6. **Fixture signal from `workspace.json` only:** the signal is now ephemeral, or a `repoPaths` entry under `/var/folders` (`:209`, `:855`). `/tmp` is dropped, and the field is renamed `tempRepoPaths`. On the live store, all 662 C folders that have a `workspace.json` are ephemeral, so none needed a temp path or `/tmp`.
7. **User-path exemption narrowed:**
   - `USER_PATH_EXEMPT` (`:212`, `:818`) holds only the forms seen in the live store: the app-support store path written plainly (327 folders) and percent-encoded (10,608), `~/.codex-auth-switcher/` (164) and `~/.codex/` (1).
   - `~/Library/Caches/` never appears, so I left it out.
   - Tests: `~/.config/real-repo` and `~/Library/CloudStorage/Dropbox/repo` both give `c_user_path`.
8. **`workspace.json` must be a regular file:** otherwise the folder is excluded as `workspace_json_not_regular` (`:807`). Tests cover a directory and a contained symlink that points at a descriptor with `isSystemWorkspace: true`.

**The cheap ones:**
- **10b-08:** the tab UUID in a P file name must not be referenced, and the workspace UUID must have no reference other than Partitions (`p_referenced`, `:921`, test `:1989`/`:2013`).
- **10b-09:** P folders that fail a scan are now reported, and `.DS_Store` is skipped (`:882`, `:907`).
- **10b-12:** a plain `if` for the empty-dir combos, `files` as the unit for S, and a per-class file count (`:1080`, `:1124`).

Unit tests for fixes 6–8 call `classify_fixture` directly (`:2086`).

## Results
- **`--self-test`:** `self-test passed (11 malformed-container cases; classes C, P, S)`, exit 0.
- **Mutation checks:** I reverted each new rule in turn, 11 variants in all; each one makes the self-test fail. The first version of the Partitions-change test let one through, so I added the swap case. Patches and mutants are in `/tmp/rpce-10b/10b-tool/r3/`.
- **Fresh dry run:** `.agent-artifacts/lossless-restart-10b/manifest-20261028-r3.json`, 19,533 entries in 3.9–6.5 s, exit 0.

| | Dry run | Classification |
|---|---|---|
| C | 19,461 dirs (29,226 files) | F1 19,461 dirs, same set |
| P | 926 dirs, 926 files | 926 fixture files in 926 dirs, same set |
| S | 83 files | 83 |
| Excluded | 60 referenced (K1 28 + K2 32), 10 `c_user_path` (F2), 1 `has_agent_sessions` (H2), 1 `not_directory` | same |

The candidate and exclusion sets are identical to the previous manifest's, and the recorded home is `/Users/tnguyen`. The AgentRecovery ID count went from 1,369 to 1,395 since the last run, so the app is still writing to the store.

**`make guardrails`:** exit 2, only from the agent-context reachability check. It flags three evidence docs I didn't write and that nothing links to yet: `fix-10b-review-oraclea-r0.md`, `fix-10b-review-oracleb-r0.md` and `fix-10b-worker.md`. Source layout, the allowlist and the notice checks pass.

## Not done
- No `--apply` or `--restore` on the live store; nothing under Application Support modified; no staging, commit or dev-format.
- `docs/testing.md` is unchanged because it doesn't list the classes.
- The apply and restore commands are the same as last round. Use a fresh manifest, because apply now refuses older manifests that don't record the home. The duration estimate is unchanged at about 10–20 minutes.

## Decision needed: re-running after a stop
With fix 1 as specified, a plain re-run with the same manifest skips the C folders the stopped run already moved. It also leaves those workspaces' P folders in `Partitions/`, because nothing in the new run moved them. I documented the workaround in the docstring and the exit-3 message: `--restore` the stopped run's journal, then re-run `--apply`.

If you'd rather a re-run picked these up, a small addition could count C moves recorded as "moved" by an earlier journal of the same manifest whose folder is still in quarantine. The new hard-reference check on P would still apply. That would loosen your "this invocation only" rule, so I haven't added it.

## Round 2 (round-1 review fixes and rehearsal on a clone)

All five fixes are in `Scripts/quarantine_fixture_workspaces.py`, and the rehearsal on a cloned copy of the store went cleanly. Apply moved 20,470 items in 38 s, restore put every one back with changedCount 0, and a full before/after comparison found nothing changed apart from the expected quarantine folder, lock file and three parent-folder mtimes. Nothing ran against the live store except read-only dry runs, and nothing is staged or committed.

## Fixes (file:line)
1. **OracleA F2 / OracleB 10b-r1-05 (Partitions changes are now tracked file by file):**
   - The collector can record every Partitions file by folder and name (`:509`).
   - The run takes a snapshot at start and changes it only for the exact files of a P folder after its rename succeeds: removed on apply (`:1433`), re-added from the restored folder's scan on restore (`:1575`).
   - Each periodic check compares the actual files with that snapshot (`:1331`); the method that adjusts it is at `:1300`. The rest of the reference check ignores Partitions (`:1261`), and no C UUID is exempted any more.
   - This now applies to every run, A/B included. It is stricter than the original check.
   - Test `:2091`: after its own P folder has moved, UUID 101 gains a file in the retained p_mixed folder; the apply stops with `stopped_references_changed` after 2 moves. A second test (`:2112`) makes the same kind of change during restore; restore stops, and a re-run finishes the job.
2. **10b-r1-01 (sudo / other users):** refuse when `os.geteuid()` differs from the store folder's owner (`:569`). The docstring now says this (`:66`).
3. **10b-r1-06:** a missing or unreadable app-support folder (`:568`) and an owner without a passwd entry (`:573`) now give `SystemExit("refusing: …")` messages. Tests at `:2032` patch `os.geteuid` and `pwd.getpwuid` and test a missing path.
4. **10b-r1-04:** the docstring (`:31`) and the stop message (`:1459`) list the skip reasons to expect on a re-run:
   - C: `c_not_workspace_dir`
   - P: `not_directory`
   - S: `scan_failed`
   - A/B: `missing`
   
   The test at `:2104` checks these exact reasons on two re-runs after a stop.
5. **10b-r1-02:** a Partitions folder that overflows is always reported (`:919`). I didn't add a test, because which files the scan sees before overflowing depends on directory order.

## Test results
- **`--self-test`:** passed, exit 0.
- **Mutation checks:** 7 variants, each reverting or loosening one fix, and every one fails the self-test. One of them re-creates the reviewer's blanket exemption for UUID 101; the p_mixed test catches it.
- **Live dry run:** read-only, manifest at `.agent-artifacts/lossless-restart-10b/manifest-20261028-r4.json`.
  - C is 19,461 dirs (29,226 files), P is 926 dirs (926 files), S is 83 files.
  - The candidate set is identical to the previous round's.
  - Exclusions are 60 / 10 / 1 / 1 as before, plus 6 new `p_too_many_entries`. These are a direct result of fix 5: six real repositories' Partitions folders holding 69–333 files each, all from indexed workspaces and none from a C candidate. Before, they were left out of the report silently; now they are listed and kept.
- **`make guardrails`:** fails only on the agent-context reachability check. It now flags five unlinked evidence docs, none of them mine: `fix-10b-review-oracle{a,b}-r{0,1}.md` and `fix-10b-worker.md`. The other checks pass.

## Rehearsal
I cloned only the parts the script reads, not the whole store: Workspaces/, Partitions/, MCP/, AgentRecovery/, Settings/, windowSessions.json and the 83 sb files. That is 96,804 entries and 747 MB, cloned in 24 s into `/tmp/rpce-10b/rehearsal-20261028T021516Z/`. The whole store is 4.2 GB and 586k entries, mostly the two old quarantine folders and caches, and the disk is 99% full.

The clone was made with `cp -c -R -p` and kept every mtime. Three files differed from the live store, and those were written by the running app after the clone. The harness `/tmp/rpce-10b/rehearsal-harness.py` imports the script and stubs only the process check and `_store_home`. The script itself was not changed.

| Step | Result |
|---|---|
| Dry run 1 | Same counts as the live store (C 19,461 / P 926 / S 83, same exclusions), 3.8 s |
| Apply (C, P, S) | 20,470 moved, 0 skipped, exit 0, 204 periodic checks, none tripped, 37.6 s |
| Restore | 20,470 restored, 0 skipped, changedCount 0, exit 0, 33.6 s |
| Before/after comparison | 96,804 entries compared (file hashes, sizes, modes, symlink targets, mtimes, including the moved folders' own mtimes). Nothing removed or changed. The only differences: the lock file, the quarantine folder (journal and summary), and new mtimes on the clone root, `Workspaces/` and `Partitions/` |
| Fresh dry run 2 | Same candidate set as dry run 1 |
| Second apply | 20,470 moved, exit 0, 38.1 s. A dry run afterwards finds 0 candidates |

The clone has been deleted. The results are in `/tmp/rpce-10b/rehearsal-result.json`.

**Expected live apply time:** about 2–3 minutes, not the 10–20 I estimated before. The rehearsal took 38 s with the process check stubbed. The real check took 0.4 s when I timed it read-only, and 204 checks add about 80 s. Restore should take about the same.

## Not done
- No `--apply` or `--restore` on the live store; nothing under Application Support modified; no staging, commit or dev-format.
- 10b-r1-03 left as you asked.
- `docs/testing.md` is unchanged.
- The restore-then-re-apply caveat from last round still holds. On a re-run after a stop, any P folder whose workspaces the stopped run had already moved stays in Partitions/ unless that run's journal is restored first.
