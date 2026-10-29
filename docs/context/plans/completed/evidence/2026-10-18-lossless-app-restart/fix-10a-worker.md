# Step 10a worker report: window-session test isolation

Scope: read when the task touches test isolation of the window-session file (WindowSessionStore) or Step 10 of the lossless app restart plan.
Authority: Reference
Last-verified: 2026-10-26
Covers: the worker's change, validation and observations, plus the main agent's follow-up fix

Tests no longer write the live `windowSessions.json`. Under XCTest in a DEBUG build, `WindowSessionStore.sessionFileURL()` now returns a temporary file, one per process. All 49 suites passed, and lint and guardrails pass. Nothing is staged or committed, and I touched no other lines.

## Diff
```diff
--- a/Sources/RepoPrompt/App/WindowStateManager.swift
+++ b/Sources/RepoPrompt/App/WindowStateManager.swift
@@ -125,13 +125,40 @@ struct WindowSessionRestorePersistenceGate {
 enum WindowSessionStore {
-    static func sessionFileURL() -> URL {
-        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
+    /// The live app's window-session file. Pure path computation; creates no directory.
+    static func productionSessionFileURL() -> URL {
+        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
             .first!
             .appendingPathComponent("RepoPrompt CE", isDirectory: true)
-        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
-        return base.appendingPathComponent("windowSessions.json")
+            .appendingPathComponent("windowSessions.json")
     }
+
+    /// The file `WindowStatesManager` reads and writes. DEBUG builds running under
+    /// XCTest use a per-process temporary file so tests never overwrite the user's
+    /// live `windowSessions.json` or leave interrupted atomic-write siblings beside it.
+    static func sessionFileURL() -> URL {
+        #if DEBUG
+            if NSClassFromString("XCTestCase") != nil || NSClassFromString("XCTest.XCTestCase") != nil {
+                return xctestSessionFileURL
+            }
+        #endif
+        let url = productionSessionFileURL()
+        try? FileManager.default.createDirectory(
+            at: url.deletingLastPathComponent(),
+            withIntermediateDirectories: true
+        )
+        return url
+    }
+
+    #if DEBUG
+        private static let xctestSessionFileURL: URL = {
+            let directory = FileManager.default.temporaryDirectory
+                .appendingPathComponent("RepoPromptCE-XCTest", isDirectory: true)
+                .appendingPathComponent(UUID().uuidString, isDirectory: true)
+            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
+            return directory.appendingPathComponent("windowSessions.json")
+        }()
+    #endif
 }
--- a/Tests/RepoPromptTests/WorkspaceRootSyncTests.swift  (only the window lines are mine)
-        let windowPath = WindowSessionStore.sessionFileURL().path
-        XCTAssertTrue(windowPath.contains("/Application Support/RepoPrompt CE/windowSessions.json"), windowPath)
+        let windowPath = WindowSessionStore.productionSessionFileURL().path
+        XCTAssertTrue(windowPath.hasSuffix("/Application Support/RepoPrompt CE/windowSessions.json"), windowPath)
         XCTAssertFalse(windowPath.contains("/Application Support/RepoPrompt/windowSessions.json"), windowPath)
+        let testWindowPath = WindowSessionStore.sessionFileURL().path
+        let productionWindowDirectory = WindowSessionStore.productionSessionFileURL().deletingLastPathComponent().path
+        XCTAssertFalse(testWindowPath.hasPrefix(productionWindowDirectory + "/"), testWindowPath)
```
The other session's uncommitted edits in that test (`productionRootURL`, `defaultRootURL` and the comment) are still there and unchanged.

Release builds and the running app take the non-DEBUG branch, so they get the same path as before and still create the directory on first use. The manager's writer is a stored property, so `sessionFileURL()` is still called once per manager.

## Suites run (all exit 0, 0 failures)
- **`make dev-test` (source builds):**
  - `WorkspaceRootSyncTests`: 15 tests
  - `WindowSessionRestorePersistenceGateTests`: 7 tests
- **`make dev-test-artifact` (one filter per run, 47 suites):** these re-ran the test bundle built after my edits.
  - **Why these suites:** the class is actually `WindowStatesManager` and tests use `WindowStatesManager.shared` rather than constructing it, so I picked every suite whose file references `WindowStatesManager`.
  - **Freshness:** the first 14 reported `artifact_scope: current`. From `AgentRunMCPToolServiceWaitTests` onward they reported `stale` because other sessions changed the source mid-run. My change is in that bundle, but those 33 runs are not a validation of the current source.
  - **Results:**
    - `AgentChatTitlebarSafety` 6, `AgentDelegationServiceBoundary` 26, `AgentLifecycleExecutionContract` 9, `AgentLifecycleShutdownCoordinator` 51
    - `AgentManageListAgentsCursorParameterMetadata` 5, `AgentManageMCPToolServiceFork` 4, `…ListAgents` 3, `…ListSessions` 6, `…Resume` 5
    - `AgentModeChatSwitchActivation` 48, `AgentProviderContextBuilder` 9, `AgentRecoveryStartupComposition` 17
    - `AgentRunLiveSessionFallback` 4, `AgentRunMCPToolServiceSteerResume` 8, `AgentRunMCPToolServiceWait` 54, `AgentRunSnapshotPrecedence` 3, `AgentRunWaitDrainIntegration` 5, `AgentRunWaitStatusUpdate` 9, `AgentRunWorktreeStart` 41
    - `AgentSessionCleanupOrigin` 3, `AgentTranscriptBackgroundRefreshDeferral` 13, `AppPlatformUtilityRecovery` 13, `AsyncLimiter` 69
    - `ContextBuilderMCPProgressTimeline` 11, `ContextBuilderRunLifecycle` 14, `ContextBuilderSelectionTransaction` 6
    - `MCPAgentPolicyAdmissionRace` 31, `MCPAskOracleClaudeShimIntegration` 3, `MCPAskOracleLifecycle` 49, `MCPAskOracleWorktree` 38, `MCPBootstrapLease` 11, `MCPCodeStructureWorktree` 58, `MCPReadSearchLatencyDiagnosticsGuard` 23, `MCPRequestIdempotencyAgentRunService` 5, `MCPRunRoutingDiagnostics` 9, `MCPSelectionContentPackaging` 3, `MCPSelectionReplyFreshness` 25
    - `PersistentAgentModeMCPReadFileConnection` 28, `PersistentMCPDistinctConnectionConcurrency` 6, `PromptCanonicalCodemapPackaging` 3
    - `RemotePairingApprovalRouter` 3, `TabContextRouting` 57, `WindowCloseCoordinatorLifecycle` 7, `WindowCloseCoordinatorPolicy` 3, `WindowRoutingWorkspaceOpen` 10, `WindowStateDisplayedTitle` 2, `WorktreeAPISmokeHarness` 5
- `make dev-lint` passed with 0 formatting findings. `make guardrails` passed, with the existing AGENTS.md route-count warning.

## Before and after
| | before (22:03:14) | after (22:14:12) |
|---|---|---|
| `windowSessions.json` mtime / size | 1793026975 (22:02:55) / 418 | 1793027247 (22:07:27) / 419 |
| `windowSessions.json.sb-*` count | 83 | 83 |

- **Real file:** its mtime changed during the test window. Its content is the user's real window (workspace `repoprompt-ce-personal-touch`, instance 3), which looks like a write by the running app. Test snapshots look different: they are `{"version":4,"windows":[]}`.
- **Temp files:** 43 new `windowSessions.json` files appeared under `$TMPDIR/RepoPromptCE-XCTest/<UUID>/` during the runs. That shows test writes now land there.
- **Leftovers:** no new `.sb-*` files appeared. The newest existing ones date from Oct 18.

## Step 3: other tests
Nothing else in `Tests/` uses `WindowSessionStore` or the real `windowSessions.json` path.
- The other `sessionFileURL` hits are unrelated helpers for agent-session files: `AgentUsageRuntimeIntegrationTests` fixture, `AgentRecoveryStartupReconciliationTests` private helper, and local variables in `AgentScheduledSendDispatchTests` and `AgentToolResultPersistencePolicyTests`.
- `WindowSessionRestorePersistenceGateTests` only mentions the file in a comment and tests the gate struct.

## Unsure about
- **Leftover temp directories:** each test process leaves a `RepoPromptCE-XCTest/<UUID>/` directory in `$TMPDIR`, as `GlobalSettingsStore` already does. I added no cleanup.
- **Spec status line:** `docs/context/plans/2026-10-18-lossless-app-restart-spec.md` line 19 still lists 10a as open ("no test branch"). I left it alone because it wasn't in scope; you may want to update it.
- **Mid-run source changes:** see the note on the 33 stale suites under "Suites run".

## Main agent follow-up (after review)

- The doc comment's `WindowStatesManager` is the real class name (`WindowStateManager.swift:250`), not a typo.
- Applied OracleB S10a-1 and S10a-2 (cheap P3s): the per-process directory is now created with `preconditionFailure` on error and removed on normal exit through `atexit_b`, matching `GlobalSettingsStore.makeSharedStore()`.
- `grep -rn windowSessions Sources` finds no other path builder outside `WindowStateManager.swift`.
- Hosting assumption (OracleB): isolation relies on `WindowStatesManager.shared` being created after XCTest is loaded, which holds for SwiftPM/xctest runners. A test run hosted inside the app bundle could create the singleton with the production URL first; `GlobalSettingsStore` has the same limitation.
- The live file's mtime change during the worker's runs is attributed to the running app, not verified.
- Existing `windowSessions.json.sb-*` files are left for the owner-approved dry-run list (Step 10b); no code deletes anything in the live directory.
