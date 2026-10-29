# Step 10b live apply (2026-10-28)

Scope: read when the task touches cleanup of leaked unit-test data in the live RepoPrompt CE Application Support store (Step 10b), its quarantine folder, or restoring from it.
Authority: Reference
Last-verified: 2026-10-28
Covers: the owner's live dry run and apply of classes C, P and S (decision O41), and the main agent's read-only check afterwards

## How it was run

The owner quit the app and ran, in the repository root, the commands from the Step 10b hand-off: a fresh `--dry-run` writing `.agent-artifacts/lossless-restart-10b/manifest-20261028T043926Z.json` (local, untracked), then `--apply --manifest <that manifest> --class C --class P --class S`. Output pasted by the owner.

## Dry run (live, before apply)

- Scanned 19,533 entries in 4.64 s.
- Hard references: workspacesIndex 60, windowSessions 1, mcpRouting 1 + 2 (debug), agentRecovery 1,364, partitions 2,192; soft: globalSettings 21,605.
- Class C 19,461 dirs (29,226 files, 39.6 MiB logical, 115.9 MiB allocated); class P 926 dirs (926 files); class S 83 files; classes A and B 0.
- Excluded: 60 referenced, 10 `c_user_path`, 6 `p_too_many_entries`, 1 `has_agent_sessions`, 1 `not_directory` — identical to the reviewed dry runs.

## Apply

```
"quarantineDir": "/Users/tnguyen/Library/Application Support/RepoPrompt CE/Workspaces-Quarantine-20261028T052352Z",
"moved": 20470, "skipped": {}, "stopped": null, "periodicChecks": 204
```

## Check afterwards (main agent, read-only, app running again)

- `--dry-run` to `.agent-artifacts/lossless-restart-10b/manifest-post-apply.json`: 72 entries scanned in `Workspaces/`; classes A, B, C, P and S all 0; exclusions unchanged (60 / 10 / 6 / 1 / 1), so every kept workspace and Partitions folder is still in place.
- Quarantine folder: 138 MB; `restore-manifest.jsonl` has 40,941 lines.

## Restore, if ever needed

Quit the app, then: `python3 Scripts/quarantine_fixture_workspaces.py --restore "<quarantineDir>/restore-manifest.jsonl"`. The quarantine folder and the two earlier ones (`Workspaces-Quarantine-20261027T014719Z`, `…T021143Z`) can be deleted after the owner's soak period.
