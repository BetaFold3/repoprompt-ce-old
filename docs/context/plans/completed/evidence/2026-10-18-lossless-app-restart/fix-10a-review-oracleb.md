# Step 10a review: OracleB

Scope: read when the task touches test isolation of the window-session file (WindowSessionStore) or Step 10 of the lossless app restart plan.
Authority: Reference
Last-verified: 2026-10-26
Covers: OracleB review of the window-session test-isolation change

# Step 10a review: keeping XCTest off the live `windowSessions.json`

## Summary

The change splits `WindowSessionStore` into two functions. `productionSessionFileURL()` only computes today's path. `sessionFileURL()` returns a temporary file, made once per process, when XCTest is loaded in a DEBUG build; otherwise it returns the production path and still creates its directory. The XCTest check is the same two-name `NSClassFromString` test that `GlobalSettingsStore.makeSharedStore()` uses. Release builds compile the DEBUG branch out, so their path and behaviour are unchanged. `WindowStatesManager` gets its writer URL from `sessionFileURL()` at `WindowStateManager.swift:351`, which is evaluated once when the singleton is created. Because `xctestSessionFileURL` is a `static let`, every reader and writer in one test process uses the same file. The test now checks the production path's suffix and that the path tests use is outside the production directory.

All three acceptance criteria are met. I found **no P0 or P1 issues**.

## Findings

### P3

**S10a-1: per-process temp directories are never removed** (`WindowStateManager.swift:154-160`)
- **Failure scenario:** each test process leaves a `$TMPDIR/RepoPromptCE-XCTest/<UUID>/` directory behind. The worker saw 43 after one validation pass. The settings code this step copies registers an `atexit_b` cleanup (`GlobalSettingsManager.swift:333-341`); this code doesn't.
- **Impact:** only clutter. macOS clears `$TMPDIR` on its own schedule, and no data is at risk.
- **Smallest fix:** register an `atexit_b` that removes `directory`, as the settings store does. Leaving it deferred is also reasonable.

**S10a-2: a failure to create the temp directory is silent** (`WindowStateManager.swift:158`)
- **Failure scenario:** if `createDirectory` fails, `try?` hides it. Every write to the session file then fails and `writeImmediately` returns `false`. A restore test would fail far from the cause. The settings store calls `preconditionFailure` in the same situation.
- **Impact:** harder diagnosis, test-only. It cannot fall back to the live file, so isolation still holds.
- **Smallest fix:** use `do/catch` with `preconditionFailure("Cannot create isolated XCTest window-session directory")`.

**S10a-3: the XCTest check and the `RepoPromptCE-XCTest` root are copied** (`WindowStateManager.swift:141`, `GlobalSettingsManager.swift:316`, and apparently `WorkspaceStorageRoot` in the other session's work)
- **Failure scenario:** a future change to how XCTest is detected (for example, a new runner class name) gets updated in one copy and not the others. The stores it misses quietly go back to writing live user data under test.
- **Impact:** future drift. The step explicitly asked to match the existing pattern, so copying it is correct for now.
- **Smallest fix (later, not in this step):** a shared `XCTestIsolation.isActive` and `XCTestIsolation.processRoot`, adopted by all three stores in one follow-up.

**S10a-4: the live-file mtime evidence doesn't prove anything either way** (worker validation)
- **Problem:** the live file's mtime changed during the test window while the app was running, so the change can't be attributed to either. Seeing the user's real windows in the file is suggestive, but it isn't proof. The real evidence is the new assertion at `WorkspaceRootSyncTests.swift:222-224` plus the code structure.
- **Smallest fix:** record it in the evidence as "mtime change attributed to running app, not verified". Optionally, run one confirming `WorkspaceRootSyncTests` pass with the app quit and the file's mtime/hash recorded before and after. Don't loop a review round on this.

## Notes checked, no finding
- **Release build:** the `#if DEBUG` block is removed and the code path matches the old code: same URL, and `createDirectory` still runs on every call.
- **Thread safety:** a `static let` closure initialises exactly once, safely across threads, and `URL` is `Sendable`.
- **Test strength:** the new assertion fails loudly if tests ever run without isolation, for example from a release-configuration test build. That is the behaviour we want.
- **Leftover assertion:** `XCTAssertFalse(windowPath.contains(".../RepoPrompt/windowSessions.json"))` at line 221 is redundant after the `hasSuffix` check, but harmless.

## Recommendations
1. **Commit Step 10a as is.** No P0/P1 is open, so a re-review round isn't needed.
2. **Optionally do S10a-1 and S10a-2 now.** Together they are about five lines: copy the settings store's `atexit_b` cleanup and `preconditionFailure`. Otherwise list them under `deferred:`.
3. **Check for other path builders before closing the step.** Run `grep -rn "windowSessions.json" Sources/` to confirm `WindowSessionStore` is the only place that builds this path. This matters especially for the Phase 4 `AppRelaunchCoordinator`. Any other code that builds its own path would skip the isolation.
4. **Note a hosting assumption.** The isolation works because `WindowStatesManager.shared` is created after XCTest is loaded, which holds for SwiftPM/`xctest` runners. If tests ever run hosted inside the app bundle, the singleton could pick up the production URL before XCTest loads. Mention this in the step's evidence.
5. **Leave existing `.sb-*` files alone in code.** Earlier runs left `windowSessions.json.sb-*` files in `~/Library/Application Support/RepoPrompt CE/`. Clean those up by hand, not with code that deletes things in the live directory.
6. **Track S10a-3 as a follow-up.** Once the other session's `WorkspaceStorageRoot` work lands, move all three stores to one shared XCTest-isolation helper.
