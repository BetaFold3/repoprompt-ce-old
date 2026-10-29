# Step 10b re-review round 1: OracleA

Scope: read when the task touches cleanup of leaked unit-test data in the live RepoPrompt CE Application Support store (Step 10b) or Scripts/quarantine_fixture_workspaces.py.
Authority: Reference
Last-verified: 2026-10-28
Covers: OracleA round-1 re-review of the quarantine-script fixes (chat untitled-chat-E27C6A)

The delta fixes F1 by admitting P workspaces only after successful C renames in the same invocation. It also addresses F3–F5, tightens fixture classification, and adds targeted tests. F2’s original A/B failure scenario is fixed, but its exemption remains broader than the requested operation-specific allowance. Review below is static; validation results are worker-reported.

## P1 — Should fix

### F2 — Partition-change exemptions still include untouched files

**File:** `Scripts/quarantine_fixture_workspaces.py:1335–1339`, `1251–1267`

- **Scenario:** Selecting C and P exempts every manifest C UUID before any rename succeeds. In the supplied fixture, UUID 101 occurs in both `p_ok` and the retained mixed folder `p_mixed`. After C moves, an external writer can add another `filepartitions-101-<tab>.json` to `p_mixed` and exit before the next process check. The fingerprint ignores that workspace’s partition references and excludes its files from `filesOfOtherWorkspaces`, so the periodic check passes. This change was not caused by a successful P operation.
- **Impact:** Apply continues after an unexpected reference-store mutation, contrary to the promised stop behavior. Revalidation of `p_ok` cannot detect a change in the retained mixed folder. The new tests demonstrate detection for **other workspace IDs**, not for untouched files belonging to exempt IDs.
- **Smallest fix:** Track partition references by repository directory and filename, and adjust the expected snapshot only for the exact entries successfully moved or restored. Do not blanket-exempt manifest C UUIDs. Add a periodic-check test that modifies UUID 101’s partition files in retained `p_mixed` and requires `stopped_references_changed`.

## Recommendations

- **Close F1 and F3–F5.**
- **Keep F2 open:** its original A/B regression is repaired, but unrelated changes sharing an exempt C UUID remain invisible.
- Before live apply, narrow that exemption and verify both unexpected-change stops and uninterrupted expected P apply/restore operations.
