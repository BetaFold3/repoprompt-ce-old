# Step 10b dry-run classification of leaked test data (worker, read-only)

Scope: read when the task touches cleanup of leaked unit-test data in the live RepoPrompt CE Application Support store (Step 10b) or test storage isolation.
Authority: Reference
Last-verified: 2026-10-27
Covers: read-only classification of Workspaces, Partitions, globalSettings, AgentRecovery and windowSessions.json.sb-* leftovers, leak status after 81e9cf67 and a13f2e7d, and a proposed (unbuilt) removal method. Per-directory lists stay local.

I've classified everything read-only; nothing under Application Support was changed and no `--apply` or `--restore` was run. Of the 19,532 workspace directories, 19,471 are leaked test fixtures and 60 are in `workspacesIndex.json`. The Workspaces leak has stopped, but a second one into `Partitions/` is still happening today.

The full lists are in `.agent-artifacts/lossless-restart-10b/ (local, untracked; copied from /tmp/rpce-10b/)`: `workspaces-classified.csv` (one row per directory, with every signal), `workspace-groups.csv`, `partitions-classified.csv`, `globalsettings-classified.csv`, `agentrecovery-classified.csv`, `classification-summary.json` and `report.md`. The classifier I wrote is `tools/classify.py`.

**Context:** two earlier quarantine runs today (`Workspaces-Quarantine-20261027T014719Z` and `…T021143Z`) already moved 80,458 empty fixtures aside. That is why the dry run matched 0: what's left all has content.

## 1. Workspace directories

| Group | Dirs | Size | Confidence | Basis | Samples |
|---|---|---|---|---|---|
| **K1 real** | 28 | 602.5 MB | keep | in index, real repo paths, `ephemeralFlag:false` | Default (2F156FE2…), infra, repoprompt-ce-personal-touch, NewGeneric, ripple |
| **K2 indexed benchmark/live-script** | 32 | 67 KB | keep, owner decides | in index, but repo paths under `/tmp` | RPCE Search Bench Codemap Authority … (×29), Codemap E2E 20261004 Fixture/Canonical Control, cxns, omp-qualification-20260814-0756 |
| **H2 hold** | 1 | 264 KB | hold | not in index, but repo `~/workspace/dotfiles` exists, `ephemeralFlag:false`, June | `Workspace-dotfiles-5FA36F32…` (a real workspace that seems to have dropped out of the index) |
| **F1 fixture** | 19,461 | 41.5 MB, 29,226 files | high | see below | Remote Naming 6,232; Distinct MCP Connection A 3,146 / B 382; Agent Mode Chat Switch 2,716; Project Alpha 1,390; Agent Run Worktree Start 716; Persistent Agent Mode MCP Read 710; Steer Resume 547; Resume Ownership 520; Worktree API Smoke 410; Default 205; 30 smaller groups |
| **F2 fixture** | 10 | 26 KB | medium | test name and `ephemeralFlag:true`, but repo path is the real `~/workspace/repoprompt-ce-remote-control` (July) | Remote Workspace ×9, Project Alpha ×1 |

Every F1 directory meets all of these:
- Its name group appears in `Tests/` (for example `RemoteAgentSessionTests`, `AgentModeChatSwitchActivationTests`, `PersistentMCPDistinctConnectionConcurrencyTests`).
- It is not in the index, `windowSessions.json` or MCP routing.
- It has no AgentRecovery record and no reference to a user repo path.
- It is ephemeral, has `/var/folders` repo paths, or has no `workspace.json` (18,799 have none).

Creation dates run from 2026-07-02 to 2026-10-26 05:37.

## 2. Other stores

- **AgentRecovery: nothing to remove.** All 57 session records and 3 attachments belong to real indexed workspaces (51 repoprompt-ce\*, 6 infra, 3 NewGeneric). The 60 tombstones are real deletions from Oct 25–27 and must stay. The store has been isolated from tests since c9138767 (Oct 21). The script's 1,293 "IDs" are every UUID in those records, not workspace references.
- **Partitions:** 3,431 files in 2,200 directories.
  - Keep 1,262 files in 31 directories that belong to real workspaces (infra, nsone_\* roles, repoprompt-ce\*, ripple and others). No directory mixes real and fixture files.
  - 926 files belong to fixture workspaces, and 1,243 to workspaces that no longer exist anywhere. They are named after test temp roots (LoadFolderWatcherFailureRetention, Apply/HydrateEmptySlices, SelectionSlice\*, PolicyBlankTab, poll-suspended-blank, WatcherFailureSliceHydration). There are also 134 July `task-cb-*` files from a harness that is no longer in the repo; I'd rate those medium confidence.
- **globalSettings:**

  | Map | Total keys | Real | Already quarantined | Fixture | No directory |
  |---|---|---|---|---|---|
  | chat | 21,596 | 55 | 17,863 | 2,608 | 1,070 |
  | copy | 21,299 | 55 | 17,764 | 2,467 | 1,013 |
  | agentModels | 1,205 | 1 | 1,024 | 131 | 49 |

  Only the real IDs must stay.
- **`windowSessions.json.sb-*` (83 files):** these are leftover temp files from interrupted atomic writes. 46 are empty and 37 are 41 bytes of `{"version":4,"windows":[]}`. None names a workspace, and the newest is from 2026-10-18. All are safe to remove.

## 3. Has the leak stopped?

- **Workspaces: yes.** 0 fixture directories were created after a13f2e7d (10-26 22:27) and 0 after 81e9cf67 (10-27 08:28). The newest is from 10-26 05:37, even though tests clearly ran afterwards (Partitions shows them). The only new files since 08:28 are inside real workspaces.
- **Partitions: no.** Of the 41 files created after a13f2e7d, 34 come from tests (33 of them after 81e9cf67, the latest at 18:11 today). The rest are real.
  - The cause is `PartitionStore.partitionsBaseURL()`, which uses `applicationSupportRootURL()` with no test redirect. The `WorkspaceStorageRoot` fix only redirects `Workspaces/`.
  - The tests still writing there:
    - `MCPAgentPolicyAdmissionRaceTests` (`PolicyBlankTab-*`)
    - `TabContextRoutingTests` (`poll-suspended-blank`)
    - `WorkspaceSwitchRecoveryTests` (`WatcherFailureSliceHydration`)
    - `PersistentAgentModeMCPReadFileConnectionTests` (the tab ID ending `…-22222222-…`)
  - `AgentWorkflowStore` (`Workflows/`) has the same unredirected path pattern. I saw no fixture output from it.

## 4. Recommended removal method (proposal only, nothing built)

1. **Fix the Partitions leak first**, with the same kind of test redirect `AgentRecoveryStore.defaultRootURL()` uses. Otherwise new fixture files keep arriving after the cleanup.
2. **Extend the existing quarantine script with a new class (C)** using exactly the F1 rule and the Tests-derived name list. The existing script only moves fixtures that are empty.
   - Keep its safeguards: refuse to run while the app is up, a 24-hour minimum age, a lock, a restore journal, same-volume moves, and never deleting.
   - Run F2 (10 dirs) only if you approve it separately. Leave K1, K2 and H2 alone.
3. **Partitions:** quarantine whole directories only when every file belongs to a fixture or to a workspace with no directory, the name matches a test pattern, and the directory is under the same age cutoff. Never touch the 31 real directories.
4. **sb-\* files:** move all 83 into the same quarantine folder.
5. **globalSettings:** the lowest-risk choice is to leave it. If you want it pruned, do it with the app quit, keep a byte-for-byte backup next to it, and drop only the quarantined and fixture keys; the 1,070 keys with no directory could be workspaces you deleted long ago.
6. Delete the quarantine folders after a soak period that you choose.

**Risks:**
- The apply step needs the app quit, so you'd have to choose that window.
- If the Tests name list goes stale it could under-match; it cannot over-match real workspaces because the index check overrides it.
- A real workspace that dropped out of the index (like dotfiles) would look like a fixture if it had a test name; the rule requiring no user repo paths covers this, and H2 is held anyway.
- Editing globalSettings while the app is running would be overwritten by the app's next save.
