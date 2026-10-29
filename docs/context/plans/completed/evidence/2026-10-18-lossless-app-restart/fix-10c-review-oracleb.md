# Step 10c review: OracleB

Scope: read when the task touches test isolation of the Partitions store (PartitionStore) or Step 10 of the lossless app restart plan.
Authority: Reference
Last-verified: 2026-10-27
Covers: OracleB review of the Partitions test-isolation change

# Step 10c review: XCTest redirect for the default partitions root

## Summary

The change adds an XCTest-only redirect to the default partitions root. `partitionsBaseURL()` used to be a private, plain path computation. It is now a package-visible switch: in DEBUG builds with XCTest loaded, it returns a per-process root, `$TMPDIR/RepoPromptCE-XCTest/<UUID>/Partitions`. Otherwise it returns `productionPartitionsBaseURL()`, which is the same path as before and still creates no directory. The temporary root is built once by a thread-safe `static let`. It is created up front (`preconditionFailure` if that fails) and removed by an `atexit_b` handler, which deletes only this process's `<UUID>` folder. This matches the reviewed `WindowSessionStore` pattern line for line, apart from the extra `Partitions` level.

Release builds compile the redirect out. A DEBUG app launched normally doesn't load XCTest, so it keeps today's path. Explicit `baseURL`s skip the default. I couldn't see `init` in the attached slice, so this assumes it uses something like `baseURL ?? Self.partitionsBaseURL()`. The worker's live-folder count and newest-file check support that. A new test checks the production path and the redirect.

I found no P0 or P1 issues.

## P2

**10c-1: The new test doesn't cover the code path that leaked.**
- **Evidence:** `SelectionSlicePersistenceAndRebaseTests.swift:10-23` only calls the two static functions. Nothing in it builds a `PartitionStore` without a `baseURL`.
- **Failure scenario:** someone later changes how `init` (or a save helper) picks its default root. For example, it calls `productionPartitionsBaseURL()` directly or computes the path from `MCPFilesystemConstants` again. Tests would start writing into the live `Partitions` store again, and this test would still pass. The guard protects the function, not the behaviour the owner asked for.
- **Impact:** the leak could come back silently. It is test-only, but it touches the owner's live data folder.
- **Smallest fix:** in the same test (or a sibling), create a store with no `baseURL` and save one slice for a temporary workspace root. Then assert the partition file appears under `testRoot`, and that `productionRoot` has no `<leaf>-<hash>` entry for that root.

## P3

**10c-2: The XCTest isolation block is now duplicated.**
- **Evidence:** `PartitionStore.swift:61-91` copies `WindowStateManager.swift:139-174`: the class-name probe, the UUID temp folder, the precondition, and the `atexit_b` cleanup. `AgentWorkflowStore` would be a third copy.
- **Impact:** if the detection or cleanup changes, every copy has to be updated together.
- **Fix:** later, add one helper in `RepoPromptPlatform` (for example `XCTestIsolation.isRunningUnderXCTest` and `XCTestIsolation.makeProcessScopedDirectory(_:)`) and use it at all sites. It isn't needed for this step, so list it as deferred.

**10c-3: The validation checked only `Partitions`, not the rest of Application Support.**
- **Evidence:** the worker's file count and newest-file check covered `.../Partitions` only. `AgentWorkflowStore` (`Workflows/`) uses the same unredirected default.
- **Failure scenario:** O35 is to stop tests writing to Application Support. A suite that builds an `AgentWorkflowStore` (or another default-rooted store) without an explicit root would still write to the live folder, and this step's checks wouldn't notice.
- **Fix:** no code change in this step. Run the broader check in Recommendations, and record `AgentWorkflowStore` as deferred under O35 in the status line.

**10c-4: A save that runs after the exit cleanup could leave temp files behind.**
- **Evidence:** `PartitionStore.swift:82-85`. `atexit` handlers run while other threads may still be busy.
- **Failure scenario:** a detached save is still running when the process exits. If the save path calls `createDirectory(withIntermediateDirectories: true)`, it rebuilds `<UUID>/Partitions/...` after the cleanup deleted it, leaving an orphan under `$TMPDIR`.
- **Impact:** only harmless temp clutter. The worker saw none.
- **Fix:** accept it, the same as for `WindowSessionStore`.

## Recommendations

1. **Commit Step 10c.** The change meets every acceptance point: stable per-process root, created up front with a loud failure, removed on normal exit, same production path, explicit `baseURL` unaffected (assuming `init` falls back as described above), and a test exists. No P0 or P1 is open.
2. **Fix 10c-1 if it's quick to do.** It is a few lines and makes the test cover the real behaviour. Otherwise list it as deferred.
3. **Run one broader check before calling O35 done.** Run `touch "$TMPDIR/o35-marker"` before a full test run. Afterwards, run `find ~/Library/Application\ Support/RepoPrompt\ CE -newer "$TMPDIR/o35-marker" -type f` and look for test-named entries (for example `PolicyBlankTab-*` or `poll-suspended-*`, or anything under `Workflows/`). This also tightens the current count-plus-newest-file method, which can't attribute files when the running app writes at the same time.
4. **Status line:** `deferred: 10c-2 (shared XCTest isolation helper), 10c-3 (AgentWorkflowStore / other App Support writers), 10c-4`.
