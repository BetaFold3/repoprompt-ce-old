# Step 10b re-review round 2: OracleB

Scope: read when the task touches cleanup of leaked unit-test data in the live RepoPrompt CE Application Support store (Step 10b) or Scripts/quarantine_fixture_workspaces.py.
Authority: Reference
Last-verified: 2026-10-28
Covers: OracleB round-2 (final) re-review of the quarantine-script fixes (chat untitled-chat-2FB245), condensed by the main agent; full text in that chat

## Summary

No regressions; no P0, P1 or P2 open. Checked by reading the delta alongside the full script and tracing the new self-test sequences by hand (nothing run). Round-1 items addressed: Partitions file-by-file tracking (replaces the C-UUID exemption, the other lane's P1, and supersedes 10b-r1-05); 10b-r1-01 (refuse when the effective uid isn't the store owner); 10b-r1-06 (clean `refusing:` messages); 10b-r1-04 (re-run skip reasons documented); 10b-r1-02 (overflowing Partitions folders always reported). The new tracking is stricter than round 1 in every traced case, including A/B-only runs.

Verified for the new tracking:
- Name format matches on both sides (`_collect_partitions` records `<repo>/<name>` except `.DS_Store`; `note_partition_dir` builds the same strings, keeping only `file` items matching `PARTITION_FILE_RE`).
- Ordering: on apply `poll()` runs before classification and `note_partition_dir` only after a successful rename; on restore `poll()` before the rename and the note after it. The snapshot matches exactly the renames that happened.
- No coverage lost: the fingerprint keeps the Partitions store's `path` and `present`; workspaces referenced only by Partitions are covered by the file-set comparison; classification still gets the full `hard` map, so A/B exclusion is unchanged.
- The new self-test sequences match the documented reasons (apply stops at `moved == 2`; re-runs skip with `c_not_workspace_dir`, `not_directory`, `scan_failed ×2`; restore stops after 1, then finishes with `destination_exists: 1` and `changedCount 0`).
- `_store_home` runs before the lock in `run_apply`, so a uid mismatch refuses before anything is created.
- Overflow reporting affects only the dry-run report.

## P3 (optional)

- **10b-r2-01** (`:1567-1575`): a restored P folder that overflows or fails its scan after the rename makes the next check stop as `stopped_references_changed` rather than naming the real cause (the entry changed in quarantine). Safe; it is listed in `changedWhileQuarantined` and a re-run finishes. Fix: skip `note_partition_dir` in that case or set `guard.detail` to name the folder.
- **10b-r2-02** (`:62-64`): the docstring says restore tracks "exact files"; it actually takes them from the restored folder's scan. Differences from the journal are still reported as `changedWhileQuarantined`. Fix: reword.
- **10b-r2-03** (`:32`): one overlong docstring line. Re-wrap.

Checked, not regressions: the classification-to-rename race for a P folder (pre-existing, app quit, reported by restore's `files` comparison); `run_restore` not calling `_store_home` (unchanged; restore only renames journaled entries back).

## Recommendations

1. Step 10b can be committed under the review policy; 10b-r2-01 to 03 can be deferred as P3.
2. If the file is touched again, consider the one-line `guard.detail` fix for 10b-r2-01.
3. Keep the round-1 rehearsal procedure (APFS clone apply → restore → compare everything); re-run it only if the script changes again.
4. On the live run, use one `--class C --class P --class S` invocation; on exit 3, follow the printed recovery text.
