# Step 10b review round 0: OracleA

Scope: read when the task touches cleanup of leaked unit-test data in the live RepoPrompt CE Application Support store (Step 10b) or Scripts/quarantine_fixture_workspaces.py.
Authority: Reference
Last-verified: 2026-10-28
Covers: OracleA round-0 review of the quarantine-script extension

## Summary

The change adds quarantine classes for non-empty fixture workspaces, their exclusive Partitions directories, and abandoned window-session temp files, extending journaling and restore across all three locations. The reported live dry-run matches the approved sets, but apply has a stale-manifest hole and weakens existing reference-change detection. This review is static; the supplied validation results were not independently executed.

## P1 — Should fix

### F1 — Missing workspace paths are treated as successfully quarantined workspaces
**File:** `Scripts/quarantine_fixture_workspaces.py:1300–1303`

- **Scenario:** After dry-run, a C workspace is renamed and becomes indexed under the same UUID. At apply, its old directory is absent, so `gone_ids` includes it—even though C revalidation never succeeded and the workspace is now real/referenced. Its unchanged Partitions directory still qualifies for P. The newly indexed reference is already in the guard’s starting baseline, so no reference-change stop occurs.
- **Impact:** Real workspace partition state can be quarantined. A P-only invocation can also move entries when their old workspace paths disappeared, contrary to the stated “C candidate in the same run” restriction.
- **Smallest fix:** Track workspace UUIDs only after successful C renames in this invocation, and use that set for P eligibility. Add a test where the old C path disappears and the UUID becomes indexed before apply.

### F2 — Expected P moves disable detection of unrelated partition-reference changes
**File:** `Scripts/quarantine_fixture_workspaces.py:1190–1195`

- **Scenario:** During an A/B apply, a briefly launched app or test creates a partition reference to a pending workspace and exits before the next process check. `collect_references()` still reads Partitions, but the fingerprint now discards those references entirely. Classification continues using the original `hard` map.
- **Impact:** The script can move an A/B workspace that has become referenced, even after a periodic check. This also regresses runs that do not select P.
- **Smallest fix:** Preserve Partitions change detection, allowing only the exact additions/removals caused by this run’s successful P restore/apply operations. At minimum, retain the original fingerprint for runs without P. Test an unexpected partition addition separately from expected P moves.

## P2 — Consider

### F3 — Every hidden home directory is exempted from real-path protection
**File:** `Scripts/quarantine_fixture_workspaces.py:777–793`

- **Scenario:** An unindexed workspace with an allowed name contains real repository paths under `~/.config`, `~/.local`, or another hidden directory and otherwise satisfies a fixture signal.
- **Impact:** Its real paths do not prevent C classification. The reported matching live set limits the immediate concern, but evidence that 165 fixtures mention `~/.codex*` does not establish that all hidden directories are fixture-safe.
- **Smallest fix:** Narrow the exemption to the observed, justified fixture paths; keep other hidden-home paths excluded. Add a negative test using a real-looking `~/.config/...` repository.

### F4 — A non-regular `workspace.json` bypasses descriptor validation
**File:** `Scripts/quarantine_fixture_workspaces.py:764–803`

- **Scenario:** `workspace.json` is a contained relative symlink or a directory. Both entry types are accepted, but only regular files named exactly `workspace.json` are parsed. Consequently, `workspace` stays `None`.
- **Impact:** An existing descriptor is treated as absent, bypassing identity, system-workspace, custom-storage, and fixture-signal checks. For example, a symlinked descriptor can contain `isSystemWorkspace: true` without triggering rejection.
- **Smallest fix:** If an entry named `workspace.json` exists, require it to be a regular file before classification. Keep contained-symlink support for `_git_data/CURRENT`. Add symlink and directory descriptor tests.

### F5 — Restore uses the old, smaller tree limit
**File:** `Scripts/quarantine_fixture_workspaces.py:1468–1473`

- **Scenario:** A valid C or P candidate contains 33–64 tree entries.
- **Impact:** Restore moves it back, but its default `scan_tree()` call truncates the verification at the old 32-entry limit. An unchanged tree is falsely reported as changed while quarantined.
- **Smallest fix:** Use the applicable class limit during restore and handle `overflow` explicitly. Add an unchanged round-trip test exceeding 32 entries.

## Recommendations

- Fix **F1 and F2 before live apply**; the matching dry-run does not exercise either failure.
- Address the inexpensive P2 fixes and rerun the focused self-tests and live read-only manifest comparison.
- Keep the app and helpers quit throughout apply and restore. Periodic polling cannot guarantee detection of a launch between checks; that residual limitation remains even after F2 is fixed.
- Retain the quarantine and journal until restore verification and the owner’s soak period are complete.
