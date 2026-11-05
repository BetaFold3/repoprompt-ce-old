# Turn worktree checkpoints — technical spec

Scope: read when the task touches turn-start or turn-end worktree checkpoints, the private checkpoint Git store, "changes during this turn" or interrupted-turn file review, checkpoint retention, or restoring file contents from a checkpoint.
Authority: Reference
Last-verified: 2026-10-18

Status: proposed, not implemented. Drafted with two independent Oracle plans (OracleD and OracleE). This revision includes one review round from each, and the disagreements are resolved below. Lab measurements come from a disposable `git clone --shared` of this repository and disposable temporary repositories. No RepoPrompt code exists for this feature yet.

## Goal

Before each agent turn, RepoPrompt records the on-disk contents of the turn's worktree. After the turn, or after a crash, the user can see exactly which files changed between that checkpoint and a later observation. In a later phase, the user can restore selected files.

The feature observes files only. It does not stop processes, undo remote effects, reconstruct tool history, or prove who made a change. Its scope is the bound worktree path: edits an agent makes elsewhere, such as in the main checkout from a linked worktree or after `cd ..`, are not seen.

## Done when

- Every new provider turn on a Git worktree gets a published turn-start checkpoint before provider dispatch, or has a durable outcome record explaining why not.
- A completed turn shows "N files changed" from its start and end checkpoints. An interrupted turn shows "changes since the turn-start checkpoint" from a fresh recovery observation.
- Nothing is ever written under the user's `.git` directory: no refs, objects, index writes, locks, or config.
- On this repository, a warm turn-start checkpoint has p95 ≤ 500 ms over at least 30 runs. The measured path includes path classification and the manifest.
- Phase 2 only: restoring writes only the approved file paths. It saves an undo checkpoint first. It never deletes a file unless the file's absence at turn start satisfies the positive-absence rule (D9).

## Crash contract

v1 promises recovery from an **app-process crash**: RepoPrompt dies while macOS keeps running. It does not claim survival of power loss or a kernel panic. Git's default durability settings can lose recent writes in an unclean system shutdown. If storage itself fails, the honest result after a restart is "checkpoint status unknown". Stronger durability (`core.fsync` hardening of objects, refs, and journal) is a separately measured Phase 3 decision.

## Measured cost (2026-10-18, Apple Git 2.50.1, APFS, this repository)

The repository has 3,127 tracked files (84 MB), a 117 MB `.git`, and normally no untracked, non-ignored files. Timings are for the Git commands alone; classification and manifest overhead are not yet measured.

| Case | Time | Storage |
|---|---|---|
| First checkpoint, self-contained private store, raw bytes, tracked files | 3.5 s | 31 MB loose; 17.5 MB after repack |
| Repack of that store (idle maintenance) | 2.1 s | — |
| Later checkpoint, no changes (persisted private index) | 0.15 s | about 300 bytes (commit and ref) |
| Later checkpoint, 20 edited source files | 0.17 s | new compressed blobs for those files only |
| Listing tracked and untracked paths in the user's repository | 0.04–0.06 s | — |
| Diffing two checkpoints | 0.02 s | — |
| One 200 MB incompressible untracked file (if captured) | 10.4 s | +200 MB |
| 30,000 small untracked files (if captured) | 18.7 s | about +120 MB, 30,000 loose objects |
| Repeat checkpoint when the index is re-seeded from the real `.git/index` | 3.2 s | — |

Conclusions:

- **Daily cost is about 0.15–0.2 s per checkpoint on this repository, plus storage for changed files only.** Start and end capture roughly double the scan work.
- **Cold cases are expensive:** the first checkpoint per repository (3.5 s, about 18 MB packed), and the first checkpoint of each new linked worktree, which needs its own private index. These must be prepared outside the send path.
- Other risks are budgeted before hashing: large untracked content, large changed tracked binaries, slow storage, and maintenance scratch space. Re-seeding from the real index is never done.
- Writing loose objects into the user's repository would exceed Git's default `gc.auto` heuristic of 6,700 loose objects. That is one reason the store is private.

## Decisions

### D1. Storage: one self-contained private bare repository per source repository

- Location: `~/Library/Application Support/<app support dir>/WorktreeCheckpoints/v1/repositories/<repo-id>/store.git`, using the app's existing Application Support resolution.
  - Owner-only permissions (`0700`), excluded from backups.
  - Linked worktrees of one repository share a store and keep separate private indexes.
- **Identity:** `repo-id` and `worktree-id` are RepoPrompt-allocated UUIDs stored in a small registry. Each is bound to the resolved path (`--git-common-dir` or `--show-toplevel`), plus a filesystem identity (volume and inode of the Git directory), plus a creation generation.
  - If a path is deleted and recreated, the identity no longer matches. Its old history stays visible as detached history, and is never attached to the new checkout automatically or used to restore it.
- **No alternates into the user's object store.** OracleD proposed alternates for a cheaper first checkpoint. OracleE rejected them: a user `gc`, an amend or rebase followed by pruning, or deleting the repository can corrupt retained checkpoints, and Git's documentation warns that shared clones break when the source prunes. The design accepts the one-time 18 MB for integrity.
  - Consequence: the store cannot compare a checkpoint with the user's `HEAD`. The feature compares checkpoints only with each other.
- **Ref layout** (all inside the private store):

  | Ref | Content |
  |---|---|
  | `refs/rpce/checkpoints/<worktree-id>/<session-id>/<snapshot-id>` | Snapshot commits |
  | `refs/rpce/cache/<worktree-id>` | The tree last written from the private index (D3) |
  | `refs/rpce/attempts/<session-id>/<attempt-id>` | Metadata-only outcome records (D6) |
  | `refs/rpce/owners/<session-id>` | Session generation and deletion tombstone (D6) |
- A snapshot is a **parentless commit**. Its manifest is the **commit message only**; a blob in the tree would pollute diffs and restore paths. Without parents, nothing a newer checkpoint references keeps an expired one alive, and the user's history is never referenced.
- Store config: `gc.auto=0`, no hooks, no signing, no remotes. Detached maintenance is disabled, and maintenance is explicit (D8).
- Lab-verified: staging, write-tree, commit-tree, update-ref, diff-tree, and restore run against the private store and private index left every file under the user's `.git` unchanged. A plain `git status` in the user's repository rewrites `.git/index`, so read-only observations use `GIT_OPTIONAL_LOCKS=0` (D2).

### D2. Two execution contexts: classify in the user's repository, ingest in the private store

This is the core contract.

**Classification** runs read-only in the user's repository, with `GIT_OPTIONAL_LOCKS=0` and `GIT_NO_LAZY_FETCH=1`, and never writes there:
- `git ls-files -z` gives tracked paths (the source index plus `HEAD`, so staged additions count) and their sparse or skip-worktree state.
- `git ls-files -z --others --exclude-standard` gives untracked, non-ignored paths. This honors in-tree `.gitignore`, `.git/info/exclude`, and the global `core.excludesFile`, none of which the private store can see.
- `git check-attr -z --stdin filter` over the candidate list finds custom-filter paths (LFS, git-crypt), including filters set through the global `core.attributesFile`. The private store cannot detect them, because its own attributes unset every filter.
- Read `core.ignoreCase`, `core.precomposeUnicode`, `core.symlinks`, and `core.fileMode`. The ingestion commands mirror them with `-c`, so case-only renames and NFD filenames don't produce phantom changes.
- Classification also computes an **ignore-inputs hash** for the manifest (D9). The hash covers every `.gitignore` file's contents, `.git/info/exclude`, and the global excludes file.

**Ingestion** runs in the private store context: `--git-dir=<store> --work-tree=<worktree>`, a private `GIT_INDEX_FILE`, and `GIT_LITERAL_PATHSPECS=1`. System and global config are isolated. `core.autocrlf=false`, `core.quotePath=false`, and fsmonitor and untracked cache are off. Every path list is `-z`/NUL-delimited.
- The store's `info/attributes` sets `* -text -eol -crlf -ident -filter -working-tree-encoding`, so **raw on-disk bytes** are captured. Lab check: for a CRLF file under eol attributes, the stored blob equals `git hash-object --no-filters`.
- Only an explicit, literal allowlist of file paths is staged. `add -A`, directory pathspecs, and exclude magic are never used. Cached index entries outside the allowlist are removed before `write-tree`. A test asserts that the tree's leaves equal the manifest's coverage.
- OracleD proposed keeping the user's filters so checkpoints compare cleanly with `HEAD`. Rejected: the feature compares checkpoints with each other and restores on-disk bytes, so raw fidelity is the contract. On LFS-heavy repositories, filtered binaries are shown as "not captured (filter)".

**Runner guard:** the checkpoint runner in `GitService` refuses any ingestion or maintenance command that lacks the explicit store `--git-dir`, the private `GIT_INDEX_FILE`, and `GIT_LITERAL_PATHSPECS=1`. A future call site therefore cannot target the user's `.git` by mistake.

### D3. A persisted private index per worktree, never seeded from the real index

- One index per worktree identity, shared by every session on that worktree. Capture works on a temporary copy, which replaces the cached index only after a successful `write-tree`. A killed capture leaves the previous cache intact.
- Each time the cache is replaced, `refs/rpce/cache/<worktree-id>` is updated to the tree just written. Pruning then can never remove a blob the cache still points to. This lease is released when the worktree is retired or its retention age expires (D8).
- The first index starts empty (the cold 3.5 s case). It is never seeded from the user's `.git/index`, whose entries carry normalized object IDs and whose stat data can suppress a needed rehash.
- If `write-tree` still reports a missing object, or the identity or representation version changed, the cache is discarded and rebuilt cold in the background. That turn's checkpoint is marked unavailable.

### D4. Scope and budgets

| Category | Behavior |
|---|---|
| Tracked files | Captured, subject to the per-file limit |
| Untracked, non-ignored files | **Captured by default within budgets** (O1, owner-decided) |
| Untracked ignored files (`.gitignore`, `info/exclude`, global excludes) | Never captured; never enumerated |
| Secret-pattern paths: `.env`, `.env.*` (except `.example`, `.sample`, `.template`), `.git-credentials`, `.netrc`, `.npmrc`, `.pypirc`, `*.pem`, `*.key`, `*.p12`, `*.pfx`, `*.jks`, `*.kdbx`, `id_rsa*`, `id_ed25519*`, `*.keychain-db`, `*.tfstate*` | Excluded even if tracked; listed as "not captured (sensitive)". This reduces exposure but does not detect arbitrary secrets. |
| Custom-filter paths (LFS, git-crypt), as detected by D2 classification | Excluded; listed as "not captured (filter)" |
| Submodules and nested repositories | Contents excluded; the gitlink or `HEAD` is recorded as metadata. App-managed worktrees nested under the main checkout are excluded explicitly. |
| Symlinks | The target string is stored; links are never followed |
| Sparse paths that aren't present on disk | Recorded as `notMaterialized`, not deleted |
| Sockets, devices, FIFOs, and paths that can't be encoded | Excluded with a reason |

Default limits are constants in a `CheckpointPolicy` type:
- 100,000 tracked candidate paths. Above that, the worktree is skipped as `countBudget`. Measured time is the real limiter (Phase 3 auto-disable).
- 20 MiB per file, tracked or untracked, applied first. A larger file is excluded and listed individually.
- 1,000 untracked paths or 64 MiB of untracked bytes, checked after the per-file rule. Exceeding either excludes the whole untracked group; RepoPrompt never keeps an arbitrary first 1,000.
- New-content bound: 256 MiB, estimated before hashing as the summed sizes of paths that are new to the private index or whose stat data changed.
- At least 512 MiB of free disk plus the estimated new bytes and repack scratch space.

Over-budget behavior:
- A per-path exclusion still yields an available checkpoint with its exclusions listed.
- A tracked count overrun, a new-content overrun, a timeout, or an I/O failure yields an `unavailable(reason)` outcome for that worktree.
- After a budget or timeout failure, automatic retries for that worktree pause for 5 minutes unless its scope changes or the user retries.

A file that was not captured must never be shown as "unchanged". Exclusions at either endpoint are treated as **unknown coverage**, not as additions or deletions.

### D5. When to capture, ordering, and the send-path budget

- **Turn start: always, before provider dispatch, awaited with a 2 s deadline across all of the turn's worktrees.**
  - If the deadline passes, that worktree's outcome is `unavailable(timeBudget)` and the send proceeds. The capture keeps running in the background **only to warm the private index; it never publishes a snapshot.** That prevents a slow worktree from timing out on every turn without making progress.
  - **No late baselines.** A baseline captured after dispatch can already contain the new turn's edits, which makes it misleading as a restore point.
- **Cold preparation off the send path.** When a session binds a worktree with no warm private index (session open or workspace load), RepoPrompt builds the cache in the background and records only `refs/rpce/cache/<worktree-id>`, with no turn attribution. Every dispatch still runs its own bounded, fresh capture.
- **Turn end: its queue position is reserved inside the terminal path, before the next turn on that worktree can be admitted.** The capture itself runs asynchronously after `AgentRunTerminalCommitBarrier.commit` publishes and must never affect the terminal commit.
  - If the end capture can't finish before the next turn's dispatch, it is invalidated and recorded as a missing end observation.
  - End captures use the same hard timeout, so one huge dump can't starve the next turn. On back-to-back queued follow-ups, the end capture's time counts against the next start's 2 s deadline.
- **Covered routes:** every path that starts a new provider turn. That includes manual sends, scheduled sends, queued follow-ups, Codex fallback successors, `agent_run` child starts, a resume that starts new execution, and retries that create a new attempt. Mid-turn steering, transcript reconciliation, compaction, cancellation, and startup-failure attempts get no new baseline.
- **Gate placement:** `beginRunAttempt` (`AgentTabSession.swift:1733`) has 10 call sites. They live in the provider runners, `CodexAgentModeCoordinator.swift`, `AgentModeRunService.swift`, and `ContextBuilderAgentViewModel.swift`, and several don't start a user turn.
  - So the gate is one shared step before runner dispatch (around `AgentModeViewModel.startAgentRun`, `AgentModeViewModel.swift:17956`, or the run service's start path), not code in each runner.
  - A required preparation argument is an optional compile-time enforcement, decided during implementation.
- Cancelling during preparation cancels the send. Just before dispatch, the gate rechecks that the session generation and cancellation state are unchanged. A late capture can never send a message or attach to a reset session.
- There is no checkpoint before each `apply_edits` in v1. Provider-native edits and shell commands can't be hooked the same way, so per-tool checkpoints would cover only RepoPrompt's own tools.

### D6. Manifest and durable records

Durable state lives only in the private store's refs. Session JSON keeps an optional cached summary for fast rendering and is never relied on after a crash; it can lag by the 1 s save debounce at `AgentModeViewModel.swift:14092`.

**The snapshot manifest** (the commit message, schema version 1) contains:
- Identity: snapshot ID; `kind` (`start`, `end`, `recovery`, `undo`, or `cache`); `scope` (`full` or `partial`, where `undo` snapshots are always `partial`); session ID and generation; run-attempt ID; and repository and worktree IDs, path, and filesystem identity.
- Timing: capture start and finish times.
- Source state: `HEAD` (if any), branch, and object format.
- Coverage: captured path count and bytes, exclusions with reasons, and a completeness flag for the untracked enumeration.
- Absence evidence: the ignore-inputs hash (D2).
- Overlap flags:
  - `knownConcurrentRun`: another RepoPrompt session was active on the worktree.
  - `unresolvedPriorExecution`: from the planned process registry.
  - `changesDetectedDuringCapture`: a non-empty `diff-files` against the fresh index after `write-tree`.

**Attempt outcome refs** (`refs/rpce/attempts/<session-id>/<attempt-id>`) point to a metadata-only commit, updated with old-value checks. Each records the start and end outcomes for every binding: `available(snapshotID)`, `unavailable(reason)`, or `missing`. The failure reason of a timed-out capture therefore survives a crash. A terminal turn with a failed end capture is also distinguishable from an interrupted one. A separate `preparing` record is not needed for best-effort capture.

**Owner refs** (`refs/rpce/owners/<session-id>`) record the session generation:
- Session reset advances the generation.
- Session delete writes a tombstone first, then deletes that session's snapshot and attempt refs, which is a prefix delete.
- Publication and launch-time indexing reject anything whose generation doesn't match or is tombstoned.

At launch, one `for-each-ref --format=…` per store rebuilds the in-memory index. The persisted turn record gains an optional summary field; old session JSON decodes it as nil.

### D7. Comparison and honest attribution

- A completed turn compares the start tree with the end tree. An interrupted turn compares the start tree with a new `recovery` observation, captured when the card opens. Comparisons are pinned to fixed snapshot IDs and never diff a live worktree under a dialog.
- Required labels: "Changes between the saved start and end observations", "Changes since the turn-start checkpoint, observed at <time>", and "May include edits made by you or other processes". The card also names the observed worktree path and lists "not captured" categories and overlap flags.
- Renames appear as a deletion plus an addition. External diff and textconv are disabled. *Export as patch* uses `--binary`.
- **Interrupted-turn card:** the capture window, changed files with line counts, "not captured" items, whether `HEAD` moved, and the actions *Review changes*, *Export as patch*, and (Phase 2) *Restore selected…*.
  - Resuming execution and restoring files stay separate actions.
  - With no checkpoint, the card shows the recorded outcome reason, or "checkpoint status unknown". A missing checkpoint is never shown as "no files changed".
- Holding scheduled sends while an interrupted turn is unresolved is **not part of this feature**. It belongs to the explicit Continue/Dismiss decision in the restart-recovery spec (`2026-10-18-lossless-app-restart-spec.md`, R8–R9), so file review never becomes a hidden prerequisite.

### D8. Retention and maintenance

| Policy | Default |
|---|---|
| Completed turns kept | The latest 50 start/end pairs per worktree, at most 7 days old |
| Store size target | 512 MiB per repository (soft: warn and keep capturing); 2 GiB globally (hard: skip automatic capture and explain) |
| Undo checkpoints from a restore | 24 hours |
| Pinned | Active turns, unresolved interrupted turns, unfinished restores, snapshots in an open comparison, and each live worktree's `cache` ref (released when the worktree is retired or its age expires) |

- **Locking:** captures take a shared OS-level lock on the store; maintenance takes an exclusive one. The lock is held by a file descriptor inherited by the Git child processes, so it lasts as long as any surviving Git writer, even after a RepoPrompt crash.
  - Inheritance must be verified on macOS before release. Until then, maintenance is skipped whenever a store-side `index.lock` or temporary object file is younger than one hour.
- **Maintenance** runs 60 s after launch, every 24 h, and when the store exceeds its target:
  1. Expire refs in one `update-ref --stdin` batch.
  2. Run `repack -a -d` (measured 2.1 s here).
  3. Run `prune --expire=1.hour.ago`, never `now`, so concurrent or surviving writers are safe.
- Stores whose repository identity no longer resolves are swept after 30 days. A worktree's index cache is deleted when the worktree is retired, since it can be rebuilt.
- Disk full produces `unavailable(lowDisk)`, and the turn always proceeds.

### D9. Restoring files (Phase 2)

Definitions: S is the start observation, E is the end or recovery observation, and C is the current disk state. Two states are equal when their bytes, file type, and executable bit match.

- **Restoring is a per-file action, or an explicit selection.** There is no whole-turn "undo everything".
- **A path is eligible only if:**
  - its current state equals its state in E (otherwise the plan is blocked and must be refreshed);
  - it is a regular file or symlink at both S and C, so directory/file transitions are blocked;
  - it has no symlink ancestor.
- **Restore is blocked while:**
  - a RepoPrompt run is active on that worktree;
  - a Git merge, rebase, or cherry-pick is in progress;
  - `unresolvedPriorExecution` is set, unless the user explicitly confirms.
- **Positive-absence rule for deletion.** A path is removed only if all of these hold:
  - it is not in S's tree and not among S's exclusions;
  - S's scope is `full` and its untracked enumeration was complete;
  - it was not ignored under S's rules;
  - S's ignore-inputs hash equals E's.

  If the hashes differ (for example, the turn edited `.gitignore`), deletion is disabled for that plan and the reason is shown. `undo` snapshots are `partial` and are never a source of absence evidence.
- **Order of operations:**
  1. Freeze the plan.
  2. Verify every selected source object (`cat-file --batch-check`, plus an integrity read) and materialize it before any write.
  3. Capture and publish a `partial` `undo` snapshot of every selected path's current state into a disposable operation index. It must not replace the worktree cache.
  4. Write the restore journal.
  5. For each path: recheck it, write it, record progress. Stop at the first conflict.

  If verification, the undo capture, or the journal fails, nothing is restored. After a crash, an interrupted restore is shown with its journal and is never resumed automatically.
- **Mechanism.** One shared helper restores one path at a time with `git restore --source=<S> --worktree`. It runs against the private store, with a disposable index and `GIT_LITERAL_PATHSPECS=1`. Lab results (Apple Git 2.50.1):
  - It restores modified and deleted files, removes files absent from S, stages nothing, and refuses the whole command, with zero writes, if any listed path is unknown.
  - **Without `GIT_LITERAL_PATHSPECS=1`, a file literally named `*.txt` also restored `other.txt`.**
  - **Restoring a path that is now a directory deleted an uncaptured file inside it.**

  Hence the mandatory literal pathspecs and the directory/file block. If any other case misbehaves, write raw blobs directly through RepoPrompt's atomic file writer (`FileSystemService+FileOperations.swift:544`) instead.
- **The user's index, `HEAD`, and branches are never touched.** If `HEAD` moved during the turn, the card says that restoring changes files only.
- **Limitation:** a check-then-write sequence can't fully guard against an IDE saving in between, and the undo snapshot can't recover an IDE save made after the undo capture but before the replacement. RepoPrompt does not promise protection from concurrent writers.

### D10. Non-Git workspaces, partial clones, and very large repositories

- Non-Git workspaces return `unavailable(nonGit)`. RepoPrompt never runs `git init` in the user's directory.
- In a partial clone, missing objects are never fetched (`GIT_NO_LAZY_FETCH=1`). Paths that need them are listed as "not captured".
- Repositories over the tracked-path budget are skipped visibly. A scoped-subtree mode is the future option for repositories with 100,000 or more files. v1 does not enable fsmonitor or the untracked cache for the private index.

## Owner decisions

- **O1 — untracked files in v1: captured by default within the D4 budgets. Decided by the owner on 2026-10-18.** Both Oracles concurred after review. OracleE originally proposed tracked-only, then accepted this default once Phase 1 includes the opt-out. New files the agent creates are the main thing a turn review should show. The budgets reject the 200 MB and 30,000-file cases before hashing, and the positive-absence rule keeps restore safe.

## Phasing

1. **Phase 1: observe.**
   - The D2 two-context runner with its guard.
   - Private store, private index, and cache ref; start capture (awaited, 2 s) and end capture (with the reserved queue position); background cold preparation.
   - Snapshot, attempt, and owner refs; launch-time index; retention, locking, and session-delete cleanup.
   - UI: the turn footer "N files changed · Review", the interrupted-turn card, and *Export as patch*.
   - Settings: enable/disable, untracked opt-out, and clear history.
   - No restore.
2. **Phase 2: restore.** Per-file and selected restore, with object verification, the undo snapshot, the journal, interrupted-restore recovery, and undo of a restore.
3. **Phase 3: tune.** Budget and deny-list settings, auto-disable on consistently slow repositories, a scoped-subtree mode, manual "checkpoint now", and a measured durability-hardening decision.

## Validation

Focused XCTest suites use fixture repositories built in a temporary directory. The fixtures cover tracked, untracked, ignored (`.gitignore`, `info/exclude`, global excludes), symlink, executable, eol-attributed, LFS- and git-crypt-filtered, embedded-repository, linked-worktree, partial-clone, sparse, case-only-rename, and NFD-filename cases. Paths include spaces, newlines, leading dashes, and glob characters (`*`, `?`, `[`, `:`).

- **Isolation:** the user's `.git` file tree (sizes and mtimes), `git status --porcelain` run with `GIT_OPTIONAL_LOCKS=0`, `for-each-ref`, and the index bytes are identical before and after classification, capture, comparison, maintenance, and failures. A runner-guard test refuses commands that lack the store context.
- **Fidelity:** cold and warm captures equal `hash-object --no-filters` for CRLF and mixed EOL, UTF-16/BOM, `ident`, and `working-tree-encoding` fixtures. No filter or hook process runs.
- **Scope:** files ignored only through `info/exclude` or global excludes are never captured. Filter paths from the global attributes file are excluded. A capture, then a new ignore or filter rule, then a recapture removes the stale cache entry. Tree leaves equal manifest coverage.
- **Source-GC independence:** retained checkpoints stay readable after amend, rebase, reflog expiry, `gc --prune=now`, and deletion of the source repository.
- **Identity:** a deleted and recreated worktree at the same path gets a new identity, and the old history stays detached.
- **Cache correctness:** same-size edits, rapid rewrites, atomic IDE-style saves, executable-bit flips, symlink changes, and branch switches. A capture killed mid-`add` leaves the cache intact. The cache ref prevents missing objects after pruning.
- **Budgets:** an over-limit file is excluded individually; more than 1,000 untracked files excludes the group; a tracked count overrun returns `countBudget`; a timeout warms the cache but publishes nothing.
- **Dispatch ordering:**
  - every new-turn route waits for a published checkpoint or a durable outcome;
  - steering creates no baseline;
  - cancelling during preparation prevents dispatch;
  - turn N's end capture is ordered before turn N+1's start capture, or is recorded as missing.
- **Crash cuts:**
  - Kill RepoPrompt after objects are written, after the snapshot ref, after the attempt ref, and after dispatch. Relaunch must show the correct association and outcome.
  - Kill during capture or repack, then relaunch immediately and attempt maintenance. The surviving writer must be respected.
  - Delete a session during a capture; the publication must be rejected by the tombstone.
- **Phase 2 restore:**
  - Glob-named paths restore only themselves.
  - A directory/file transition is blocked.
  - A changed current file blocks the plan.
  - An ignore-rule change disables deletion.
  - A verification or undo failure means zero writes.
  - Binaries, symlinks, and modes round-trip.
  - Crash cuts after the undo snapshot, after the journal, and mid-restore leave the restore recoverable.
  - The user's index and `HEAD` are unchanged.
- **Performance:** re-run the measured-cost matrix end to end, including classification and the manifest, for 30 or more warm runs. Acceptance: p95 ≤ 500 ms warm start capture on this repository. Record the cold baseline time, the cold time for a new linked worktree, and the packed store size.

## Owning seams (for implementation)

- New, under `Sources/RepoPromptWorkspace/VCS/Checkpoints/`:
  - `WorktreeCheckpointModels.swift`: manifest, policy, outcomes, identities, and turn summary.
  - `WorktreeCheckpointService.swift`: an app-scoped actor that owns the registry, stores, per-worktree queues, classification and capture, comparison, and retention.
  - later, `WorktreeCheckpointService+Restore.swift`.
- `Sources/RepoPromptWorkspace/VCS/GitService.swift` gains a checkpoint runner with:
  - the two contexts from D2 and the runner guard;
  - environment and config isolation;
  - NUL-safe stdin path lists;
  - timeouts and process-group kill;
  - store-lock descriptor inheritance.

  Existing Git calls are unchanged.
- App layer: a new `AgentModeViewModel+WorktreeCheckpoints.swift` for orchestration and UI projection, and the shared pre-dispatch gate from D5.
- `AgentRunTerminalCommitBarrier.swift`: reserve the end-capture queue position in the terminal path, and enqueue the capture after publication.
- `AgentSessionRestoreSupport.swift`: attach checkpoint outcomes to turns that a cold restore closes as interrupted.
- The persisted session construction (`AgentModeViewModel.swift:14478-14515`) carries the optional turn summary.
- UI: the turn footer, the interrupted-turn card, and a review sheet. Reuse the existing diff presentation if one fits.
