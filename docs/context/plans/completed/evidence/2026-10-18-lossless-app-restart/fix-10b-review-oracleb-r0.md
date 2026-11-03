# Step 10b review round 0: OracleB

Scope: read when the task touches cleanup of leaked unit-test data in the live RepoPrompt CE Application Support store (Step 10b) or Scripts/quarantine_fixture_workspaces.py.
Authority: Reference
Last-verified: 2026-10-28
Covers: OracleB round-0 review of the quarantine-script extension

# Step 10b review: quarantine classes C, P and S

The diff adds three classes to `Scripts/quarantine_fixture_workspaces.py`:
- **C** is a non-empty fixture workspace. It must have a listed name group, no reference other than Partitions, a contained tree, no user path and a fixture signal.
- **P** is a Partitions repo-key folder whose every file belongs to a C workspace. A folder only moves after its workspaces have left `Workspaces/`.
- **S** is a stale `windowSessions.json.sb-*` file with no windows in it.

All three reuse the existing pieces: lock, app-running refusal, start-of-run reference collection, per-item re-check against the manifest's file list, write-ahead journal and `--restore`. Restore now finds each entry's origin from the journaled `class`. Old journals have no `class` and still go back to `Workspaces/`, which matters for the two earlier quarantine folders. I traced every path that can rename a real item and found no P0 or P1.

The main protection for real workspaces is **not in `workspacesIndex.json`** plus **no user path**. The name list and the fixture signal are weaker. The P2 findings are cases where one of those two main checks quietly turns off or is looser than the classification it is meant to reproduce. Every move is reversible, and the current dry-run set matches the classification exactly. So these are P2, but most are one-line fixes and worth doing before the live `--apply`.

## Answers to the specific questions

- **Can a real or referenced workspace be moved?** Not through workspacesIndex, windowSessions, MCP routing or AgentRecovery. Each apply re-checks against references collected at its own start, so a stale manifest can't override them. The remaining gaps are 10b-02 (no index file means no index protection) and 10b-03/04/05 (the user-path and fixture-signal layers).
- **Can a real Partitions file be moved?** No. P needs every file's workspace ID to be a manifest C ID whose folder is already gone from `Workspaces/`. A C folder that was skipped or failed to rename stays in place, so its P folder is skipped too. Mixed folders are never moved. One caveat is 10b-08 (the second UUID in the file name is ignored).
- **Can restore fail to put everything back?** Entries are only left in quarantine, never lost, in two cases:
  - The original location exists again (`destination_exists`). For P this can happen if leaking tests recreate the same `Partitions/<key>` (10b-08).
  - `Partitions/` itself is gone (`rename_failed:ENOENT`).

  Restore also reports false changes for any C or P folder with more than 32 entries (10b-01).
- **What if the app starts mid-run?** The process check runs every ≤5 s or 100 moves and stops with exit 3. Everything moved so far is in the journal. Inside that window, revalidation still uses the start-of-run reference set. Even so, the only things that can move are unindexed fixture folders, their partition folders and stale temp files, none of which a freshly started app opens. After a stop, finishing P needs the *original* manifest (10b-06).
- **Do the loosened rules open a hole?**
  - **Symlinks:** sound. A relative target with no `..` can't climb above the folder, and every symlink it passes through is itself in the scanned tree and must pass the same test.
  - **Dot-folder / `~/Library` exemption:** broader than needed (10b-04).
  - **Dropped Partitions re-read:** negligible. Revalidation never used the periodic re-read; it is a tripwire that fires at the same moment as the process check. P re-checks also catch new files through the `files` comparison (10b-07).

## P2

**10b-01: restore reports false "changed while quarantined" for C and P folders with more than 32 entries**
- **Where:** `quarantine_fixture_workspaces.py` ~1469, `tree, _ = scan_tree(target)` in `run_restore`.
- **Scenario:** `scan_tree` still uses its default limit, `MAX_TREE_ENTRIES = 32`. C and P allow up to 64 entries. For a folder with 33–64 entries, `scan_tree` returns a truncated, unsorted list, which never equals `record["files"]`. The 64 limit was presumably raised because live fixtures exceed 32 (for example `_git_data/repos/...` trees), so a live restore will very likely hit this.
- **Impact:** the data is restored correctly, but `changedCount > 0` and `changedWhileQuarantined` show wrong answers. That is the very signal the owner would use to check a restore. The self-test misses it because its folder has about 11 entries.
- **Fix:** use `scan_tree(target, MAX_FIXTURE_TREE_ENTRIES if klass in ("C", "P") else MAX_TREE_ENTRIES)` and count overflow as changed. Add a self-test C fixture with about 40 entries.

**10b-02: a missing `workspacesIndex.json` turns off index protection for C**
- **Where:** `_collect_workspaces_index` (~line 325), the `if not os.path.lexists(path)` branch records `present: False` and adds no IDs.
- **Scenario:** the index is missing at dry-run and apply time, for example after an interrupted app write, a manual move or a botched restore. Every real workspace then counts as unreferenced for C. This was harmless for A/B, which only take empty folders. C takes non-empty ones, and its index check is the step the classification says "cannot over-match real workspaces" because of.
- **Impact:** a real workspace with a listed name (`Default`, `Source`, `Project Alpha`, …), no user-home path in its files and some `/tmp` mention would be quarantined. That outcome is reversible.
- **Fix:** when `C` (or `P`) is selected, or whenever C candidates are produced, require the index. Pass `required=True`, or refuse if `present` is false.

**10b-03: the C fixture signal is looser than the F1 rule it claims to reproduce**
- **Where:** ~795, `temp_hits += len(TEMP_PATH_RE.findall(text))`; ~814; and `TEMP_PATH_RE` at line 198.
- **Scenario:** F1 says the folder is "ephemeral, has `/var/folders` repo paths, or has no workspace.json". The code instead accepts any `/tmp/` or `/var/folders/` string in **any file**, including chat and session transcripts, and even inside URLs. A real, index-dropped workspace (like the H2 dotfiles case) with `ephemeralFlag:false` and a listed name would pass this check. Any agent transcript that ran a shell command mentioning `/tmp/` is enough.
- **Impact:** for folders that have a `workspace.json`, the only remaining safeguards are the name and the user-path check. Today's set is unchanged, so this is about future drift and the next re-run.
- **Fix:** count temp hits only in `workspace.json` `repoPaths` (or the parsed workspace document) and drop `/tmp`, so the rule matches F1. Re-run the dry run and confirm the count is still 19,461.

**10b-04: the user-path exemption covers more than the observed false positives**
- **Where:** ~778, `r"/(?!Library/|\.)"`.
- **Scenario:** the loosening was justified by `~/.codex*` (165 fixtures) and app-support paths. The pattern exempts **all** of `~/Library/` and **every** dot-folder. Real repositories commonly live in `~/Library/CloudStorage/...`, `~/Library/Mobile Documents/...`, `~/.dotfiles` or `~/.config/...`. A workspace whose only user path is one of these would lose its strongest protection.
- **Impact:** a real workspace could pass the user-path layer. It still needs a listed name and a fixture signal, which overlaps with 10b-03.
- **Fix:** exempt only the observed prefixes, for example `(?!Library/Application Support/RepoPrompt CE/|Library/Caches/|\.codex)`. Re-run the dry run and confirm the C set and the 10 user-path exclusions are unchanged.

**10b-05: the home directory comes from `$HOME`, not from the store being cleaned**
- **Where:** ~778, `home or os.path.expanduser("~")`.
- **Scenario:** apply is run with `--app-support "/Users/tnguyen/Library/…"` under a different `HOME` (sudo, a launchd or cron environment, a shell with `HOME` overridden). The user-path regex then looks for the wrong prefix and never matches. The 10 F2 folders the owner chose to keep (`Remote Workspace`/`Project Alpha`, `ephemeralFlag:true`, real repo path) are excluded *only* by this check. Apply only moves manifest entries, so the dry run must also be affected. Running both from the same unusual shell is plausible.
- **Impact:** owner-held F2 folders get quarantined. Reversible.
- **Fix:** derive home from the app-support path (`app_support.split("/Library/Application Support/")[0]`) or from `pwd.getpwuid(os.stat(app_support).st_uid).pw_dir`. Refuse if it differs from `expanduser("~")`, and record it in the manifest.

**10b-06: after an interrupted apply, a fresh dry run silently loses the P folders**
- **Where:** ~983–989 (`candidate_ids`, then `if result.pop("touchesCandidate") or result["class"]`).
- **Scenario:** apply stops with exit 3 after moving C folders but before P. The natural next step, a new dry run then apply, no longer sees those C IDs as candidates because their folders are gone. Their P folders get `touchesCandidate=False` and are **left out of the report** rather than excluded with a reason. Only re-applying the *original* manifest with `--class P` still works, because `gone_ids` comes from that manifest's C list.
- **Impact:** the 926 fixture partition entries stay behind with no visible trace in the new manifest.
- **Fix:** smallest is to document "after a stop, re-run `--apply` with the same manifest" in the docstring and the exit-3 message. Alternatively, when a stopped apply leaves P items unprocessed, print the manifest path to reuse.

## P3

**10b-07: the fingerprint drops all Partitions IDs, not just the ones P moves**
- **Where:** ~1193–1195.
- **Scenario:** an unmatched writer, such as a test runner whose name the process patterns miss, adds a Partitions reference mid-run. This is no longer noticed, although revalidation would not have used it anyway.
- **Fix (optional):** subtract `"partitions"` only for IDs in the manifest's C set.

**10b-08: P ignores the second UUID in the file name, and restore can't merge into a recreated folder**
- **Where:** ~859–863 and the `destination_exists` branch in `run_restore`.
- **Second UUID:** `filepartitions-<ws>-<tab>.json` is judged only by its first UUID. A cheap extra guard would also require the second UUID to be absent from `hard`.
- **Restore:** if the Partitions test leak isn't fixed yet and a test recreates the same `Partitions/<key>`, restore leaves the quarantined folder in place.
- **Fix:** confirm the leak fix landed before applying, as step 1 of the worker's proposal says.

**10b-09: the dry run hides P folders that fail an early check**
- **Where:** ~844–863. `not_directory`, `scan_failed`, `p_too_many_entries` and `p_unexpected_entry` (for example a stray `.DS_Store`, since `IGNORABLE_NAMES` isn't applied here) all return before `touchesCandidate` is set. These folders are silently left out rather than reported as excluded.
- **Fix:** compute IDs from the files that do match before the early returns, or skip `IGNORABLE_NAMES` inside the loop.

**10b-10: self-test gaps.** None of these is tested:
- a C folder with more than 32 entries, through restore (would catch 10b-01);
- a missing index with a C candidate;
- a C folder with `workspace.json` whose only signal is a temp path;
- a P folder whose C move was skipped *within the same* apply;
- restoring a legacy journal with no `class` after this change.

**10b-11: the evidence count needs a unit.** The classification says "926 **files** belong to fixture workspaces". The dry-run summary counts P **folders**, yet the worker reports "P 926 (identical)". If every fixture root holds one file the numbers match, but the evidence should say which unit was compared.

**10b-12: cosmetic.**
- `for combo, count in … .items() if klass in ("A", "B") else ():` (~1069) is valid but hard to read; a plain `if` reads better.
- `print_summary` says "dirs" for class S files.

## Recommendations

1. Before the live `--apply`, fix **10b-01** (one line plus a test), **10b-02** (require the index), and **10b-05** (anchor home to the app-support path). These are cheap and close the ways the two main protections can quietly turn off.
2. Tighten **10b-03** and **10b-04** to the classification's exact F1 rule and the observed exemptions. Then re-run the read-only dry run and confirm C = 19,461, P = 926 (state the unit), S = 83, and the same 60 / 10 / 1 exclusions. If the sets are unchanged, the tightening costs nothing.
3. Confirm the Partitions test-leak fix has landed (10b-08). Otherwise tests keep recreating Partitions entries, and a restore could hit `destination_exists`.
4. Run apply in one sitting: `--class C --class P --class S` with the original manifest. If it exits 3, re-run with the **same** manifest (10b-06) rather than a new dry run. Keep the manifest, the quarantine folder and both earlier quarantine folders until the soak period ends.
5. After apply, run one test restore on a copy, or check `changedCount` once 10b-01 is fixed, and save the apply and restore summaries in the Step 10b evidence folder.
