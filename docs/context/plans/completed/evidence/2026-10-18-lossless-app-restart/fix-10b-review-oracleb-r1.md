# Step 10b re-review round 1: OracleB

Scope: read when the task touches cleanup of leaked unit-test data in the live RepoPrompt CE Application Support store (Step 10b) or Scripts/quarantine_fixture_workspaces.py.
Authority: Reference
Last-verified: 2026-10-28
Covers: OracleB round-1 re-review of the quarantine-script fixes (chat untitled-chat-44FD01)

## Summary

The delta closes every round-0 finding: 10b-01 through 10b-05, plus 10b-06/07, 10b-08 and 10b-09. It also handles the other lane's two P1s:

- **P now depends on C moves in the same run.** Class P counts as eligible only against workspaces whose class C rename succeeded in this invocation (`moved_c_ids`).
- **The periodic check keeps Partitions.** It leaves out only the Partitions references of the C IDs involved, and it now counts Partitions files that belong to any other workspace.

I traced the new fingerprint through each class combination:

| Class combination | `expected` | Partitions record | Behaviour |
|---|---|---|---|
| `{C, P, S}` | the manifest's C IDs | reduced form, plus `filesOfOtherWorkspaces` | moving P leaves the fingerprint unchanged (P files are a subset of `expected`) |
| `{C}`, `{C, S}` | `None` | full record | C moves don't touch any reference store |
| `{P}` alone | `None` | full record | moves nothing |
| `{C, P}` with no C candidates | empty frozenset | full record (the `if expected and …` check is false) | no `KeyError` on `filesOfOtherWorkspaces` |
| restore with P entries | `p_ids` from the journaled file names | reduced form | restored P files only re-add `p_ids` references |

The two self-test changes (1c: another workspace's file added; 1d: a file swapped for a new workspace's file) are both caught: 1c by `filesOfOtherWorkspaces`, 1d by the per-ID kinds. Restore's 64-entry limit, the overflow-means-changed rule, S-file restore and the per-class parent checks are all consistent with apply.

**No P0 or P1.** One P2: the new `$HOME` guard doesn't actually catch a typical `sudo` run, even though the docstring says it does. A few P3s follow.

## P2

### 10b-r1-01: The `$HOME` check doesn't detect `sudo`, despite the docstring

- **Where:** `Scripts/quarantine_fixture_workspaces.py:562-570` (`_store_home`). The claim is in the docstring at lines 62-63.
- **Scenario:** The owner runs `sudo python3 Scripts/quarantine_fixture_workspaces.py --apply …`. macOS sudo commonly keeps `HOME` (stock `env_keep`), and `sudo -E` always does. So `$HOME`, the folder owner's home and the path prefix all equal `/Users/tnguyen`, the check passes, and the run continues as root.
- **Impact:**
  - The run creates a root-owned 0600 lock file at `<app-support>/.rpce-quarantine.lock`. From then on, every `--apply` and `--restore` run as the owner fails with "cannot open lock file".
  - It also creates a root-owned `Workspaces-Quarantine-*` directory. A non-root `--restore` can't rename entries out of it and gets `rename_failed:EACCES` for every entry.
  - No data is lost, and both failures are loud, but the docstring promises a refusal that doesn't happen.
- **Smallest fix:** In `_store_home`, also refuse when `os.geteuid() != os.stat(app_support).st_uid`. Alternatively, drop "sudo" from the docstring. The uid check is one line and also covers launchd jobs running as a different user.

## P3

### 10b-r1-02: Partitions folders that overflow can go unreported in the dry run

- **Where:** line 907 (`touchesCandidate` is computed before the overflow check).
- **Scenario:** A Partitions folder has more than 64 entries, and a C candidate's file is not in the first 65 that `scan_tree` reads before it stops. `touchesCandidate` comes out `False`, so the folder is left out of `excluded` instead of being listed as `p_too_many_entries`.
- **Impact:** Reporting only. Such a folder is never a P candidate, so nothing is moved wrongly.
- **Fix:** Set `touchesCandidate = True` whenever `overflow` is true.

### 10b-r1-03: The user-path rule only matches the home path exactly as written

- **Where:** line 819.
- **Scenario:** Some file spells the home directory differently, for example `/System/Volumes/Data/Users/tnguyen/...` or `/users/TNguyen/...` (APFS is case-insensitive). The regex misses it, so a C folder that mentions a real repo isn't excluded.
- **Impact:** Unlikely, since the app writes standardized paths. The validation saw no such case among the live C folders.
- **Fix:** Optional. Compile the pattern with `re.IGNORECASE`, and add a second alternative for the `/System/Volumes/Data` + home spelling.

### 10b-r1-04: Re-running after exit 3 reports noisy skip reasons

- **Where:** the stop message at lines 1438-1442, and the docstring at lines 26-30.
- **Scenario:** The owner re-runs `--apply` with the same manifest. Entries the first run already moved now show up as `revalidation:c_not_workspace_dir` and `revalidation:scan_failed` (for S), next to `p_not_all_candidates`.
- **Impact:** The summary can look like a failure even though the behaviour is correct.
- **Fix:** Docs only. Add one sentence saying these reasons are expected on a re-run. Or skip candidates whose origin is missing with a dedicated `already_moved` counter.

### 10b-r1-05: Some Partitions changes still escape the narrowed fingerprint

- **Where:** lines 1262-1263 and 504-505.
- **Scenario:** The fingerprint compares only which workspaces have Partitions files and how many files belong to other workspaces. A change that keeps both the same goes unnoticed, for example deleting `X-tab1` and adding `Y-tab2` when X and Y each still have other files.
- **Impact:** Contrived. Only a running app would do this, and the process check covers that case separately. The full fingerprint used before round 0 had a similar blind spot for content-only rewrites.
- **Fix:** Optional. Replace the count with a sorted tuple of other-workspace file names (`repo/name`) for files outside `expected`.

### 10b-r1-06: Some refusals show a Python traceback instead of a message

- **Where:** line 564.
- **Scenario:** `pwd.getpwuid` raises `KeyError` when the folder owner's uid has no passwd entry. `os.stat` raises `FileNotFoundError` when a wrong `--app-support` is passed to `--apply`, because `run_apply` calls `_store_home` before `collect_references`.
- **Impact:** Each of these still stops the run before anything moves. The user just sees a traceback instead of a refusal message.
- **Fix:** Wrap both calls and raise `SystemExit("refusing: …")`.

## Status of round-0 findings

| ID | Status | Evidence |
|---|---|---|
| 10b-01 restore entry limit | Resolved | Restore uses the 64-entry limit for C/P and treats overflow as changed; the 42-entry C round-trip test checks `MAX_TREE_ENTRIES < len(ok_files)` |
| 10b-02 missing `workspacesIndex.json` | Resolved | Dry run raises; apply refuses after `guard.start()` and before `mkdir`; the test confirms no quarantine dir is left |
| 10b-03 fixture signal | Resolved | Only workspace.json (ephemeral, or a `/var/folders` repoPath); text-only and `/tmp` cases are tested negatively |
| 10b-04 user-path exemption | Resolved | Narrowed to the 4 observed prefixes; `.config` and `CloudStorage` tested negatively |
| 10b-05 home source | Resolved for HOME overrides; `sudo` gap in 10b-r1-01 | Owner, path prefix and `$HOME` must agree; recorded in the manifest; apply checks it |
| 10b-06 recovery after a stop | Resolved (owner decision) | Documented in the docstring and stop message; behaviour matches (`p_not_all_candidates`) |
| 10b-07 fingerprint ignored Partitions | Resolved | Partitions excluded only for `expected` IDs, plus the other-workspace file count; tests 1c and 1d |
| 10b-08 P reference checks | Resolved | Tab UUIDs and non-Partitions workspace references are both checked; `p_tab` test |
| 10b-09 P reporting, `.DS_Store` | Resolved | Folders that fail early are reported; `.DS_Store` is skipped (any `.DS_Store` that differs from the manifest still fails the `files` match, which is the safe direction) |
| 10b-12 cosmetics | Resolved | Summary shows file counts; per-class print handling is fixed |

## Recommendations

1. **Fix 10b-r1-01 before the live `--apply`.** Add the euid-equals-owner check to `_store_home` (one line), or at least fix the docstring. It is cheap, and a root run would leave a lock file that blocks every later owner-run `--apply`/`--restore`.
2. **10b-r1-02 through 10b-r1-06 can be deferred.** 10b-r1-04's doc sentence is worth adding now, because the owner will read that output during the 19k-move recovery path.
3. **Rehearse `--apply`/`--restore` on a copy of the live store first.** They have not been run against live data, so a full C+P+S apply, a restore, and a re-apply on a copy (made with `ditto` or a clone) would confirm the periodic fingerprint stays stable over about 200 checks. It would also confirm that APFS rename keeps the directory's own mtime at live scale, which the manifest `files` match relies on. Only after that should the real store be touched.
4. After that, Step 10b can be committed under the policy: no P0/P1 is open.
