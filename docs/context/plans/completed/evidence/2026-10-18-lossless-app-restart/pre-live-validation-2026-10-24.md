# Lossless app restart — pre-live non-disruptive validation (2026-10-24)

Scope: read when the task touches the full-suite and scratch-package validation before lossless restart live acceptance.
Authority: Reference
Last-verified: 2026-10-24

The owner asked for full-suite tests and packaging before any app stop or relaunch. This is source-test and packaging evidence only. **Live acceptance is NOT claimed.** No app was launched, stopped or relaunched, no provider was prompted, and no settings, config or signing identity changed. During the worker run, no code, tests or frozen ledger changed and nothing was staged or committed. The installed CLI symlink and live helper were not touched; the packaging compatibility-link side effect was restored as recorded below. Main subsequently prepared the documentation checkpoint.

## Provenance

- HEAD `e7ac41e44ca8ce0d07034fd93b339a0d960ef300`, branch `dev/v1.0.29-remote-client-models`.
- Pre-existing dirt was preserved; `git status --short` was identical before and after:
  - modified: `.gitignore`, `AGENTS.md`, `Tests/RepoPromptTests/Helpers/CodemapSeamTestSupport.swift`, `docs/context/code-mode-measurements.md`, `docs/context/plans/2026-10-03-code-mode-readiness-and-git-narrowing-plan.md`;
  - untracked: `docs/context/plans/2026-10-18-turn-worktree-checkpoints-spec.md`, `docs/context/plans/completed/2026-10-18-codemap-wait-fix-plan.md`.
- Dirty-file coverage: SwiftPM compiles the working tree. The only dirty Swift file is the test helper `CodemapSeamTestSupport.swift`. It adds two defaulted fixture parameters (`capabilityHooks: .none`, `capabilityGitService ?? GitService()`), plus hook forwarding. Main inspected that diff; preserving behavior for default callers is an inference, not a clean-baseline comparison. It was compiled into the root test bundle. No production Swift is dirty, so the packaged products are HEAD sources; package provenance still reports `dirty: true`.
- Environment: `RPCE_DEBUG_DSYM=off`. The shell had `REPOPROMPT_DEBUG_APP_BUNDLE=/Applications/RepoPrompt CE Dev.app`; it was overridden only for the packaging command (see below).
- Raw logs are local and git-ignored, under `.agent-artifacts/lossless-restart-prelive-2026-10-24/`, plus the conductor jobs directory.

## Results

| Lane | Command | Ticket | Result |
|---|---|---|---|
| Full root (unfiltered, 8 workers) | `make dev-test-parallel` | `576fbd13-f553-4b79-862a-82f304c18ccc` | **FAIL** (exit 1). 657/657 suites, 7782/7782 tests executed (parity 0 mismatches), 1 failing suite, wall 805 s, exec 13m34s. No serial fallback was needed: the parallel run completed. No artifact-provenance ticket was recorded (failed run). |
| Core package | `make dev-core-test` | `7abcb013-398d-4eef-b660-b0752839fb0d` | PASS, 66 XCTest tests, 0 failures (Swift Testing: 0 tests). |
| Provider package | `make dev-provider-test` | `b768582f-9dd4-4fc2-a285-35639c451056` | PASS, 35 XCTest tests, 0 failures (Swift Testing: 0 tests). |
| Debug packaging (isolated) | `REPOPROMPT_DEBUG_APP_BUNDLE=<scratch>/RepoPrompt.app make dev-build` | `ca442b97-4d51-4343-9757-5a19c7e76e64` | PASS, exec 11.8 s, `outcome=fresh`. |
| Diagnosis only | `make dev-test FILTER=MCPCodeStructureWorktreeTests` | `8e6887c8-41f3-400f-b26c-0ddeacaab33d` | FAIL: 58 executed, 1 failure (same test). |

Parallel retries: five suites passed on retry: `CodemapAutomaticSelectionColdTests` (crash), `CodemapBindingEngineProjectionTests` (crash), `CodemapGraphFreezeQueryTests` (timeout), `OMPAgentModeSmokeScriptTests` (timeout) and `PromptContextAccountingServiceTests` (timeout). One failed after retry: `MCPCodeStructureWorktreeTests`.

### `MCPCodeStructureWorktreeTests` failure

- `testRetainedProjectionPreloadStopsAfterIndexAdvanceAndForegroundRecoversOnce` fails at `MCPCodeStructureWorktreeTests.swift:1805`: `XCTUnwrap … "Projection preload never observed the staged index change."` It failed **3/3**: parallel attempt 1 on w7, the parallel retry, and the quiet focused serial run. The focused reproduction means the observed failure is not confined to the parallel run; three failures do not prove determinism or rule out timing sensitivity.
- Parallel attempt 1 alone also failed `testSelectedScopeRejectsAtLimitPlusOneWithoutContentOrCodemapWork` (lines 1153–1154: `"unavailable"` ≠ `"budget"`). That test passed on the retry and in the serial run, so it looks load-sensitive.
- Classification: **likely an existing codemap-domain failure, not a lossless-restart regression. Not proven by bisect.** The test exercises codemap projection preload against a staged Git index change. The only restart-series change in `Sources/RepoPromptWorkspace/WorkspaceContext/` is `76057942`, a `WorkspaceFileMutationService` create-path resolve refactor that this path doesn't use. Codemap commits after the test was last edited (`cf704272`, 2026-10-03) include `d76d2939`, `5507c3fa`, `4d420021`, `c53c7f52`, `0256f36c` ("derive index generation from index entries") and `0a6df8f3` (2026-10-19/20). There is no earlier unfiltered-run baseline for this suite in the local conductor history. Confirming the cause needs a run on a pre-codemap-series commit, which was not done.
- Nothing was fixed.

### Isolated packaging

- Safety check before any mutation: conductor forwards `REPOPROMPT_DEBUG_APP_BUNDLE` from the **client** request env (`OperationRegistry.DEBUG_ENV_KEYS`, `_request_env_snapshot`), not the daemon env. So the scratch override was honored, and the running bundle was not a publish target.
- Destination: `/var/folders/05/h5dklt3s7nnbc4kf4r_153_40000gn/T/rpce-prelive-pkg.nX1Ney/RepoPrompt.app`. It was a fresh `mktemp -d` and absent before the run. It was assembled in a hidden `.rpce-package-*` sibling and published there.
- Signing: Apple Development "Yen Nguyen (CXWL8XSULT)", team `AM9B9Y6HBV`, `Ad-hoc signing active: 0`, bundle ID `com.pvncher.repoprompt.ce.debug`. `codesign --verify --deep --strict` passed both in-script and on a re-check afterwards.
- Script checks all passed: valid on disk, satisfies DR, pre- and post-sign arm64 architecture, MCP helper layout, and helper `--version` smoke (`rpce-cli-debug (repoprompt-mcp) 1.0.29`).
- Package caches were **disabled**: `WARNING: SIGN_IDENTITY was not found by exact text …` → `signing identity not uniquely resolved; package caches disabled`, `cert=unresolved bundle_reuse=0`. The detected identity text differs in case from the keychain's. This is pre-existing environment behavior and was left unchanged. As documented, the shared package cache was not read, written or pruned; the stamp directory listing was identical before and after.
- Package provenance: commit `e7ac41e4…`, `dirty: true`, `buildLane: debug`, `Onone`, built `2026-10-24T17:35:52+07:00`. Product compile was `Build complete! (4.17s)`: products were already current from the same-tree test build.
- Side effect, reverted: packaging repoints the compatibility link `.build/debug/RepoPrompt.app` to its destination. It was restored right away to its previous target, `/Applications/RepoPrompt CE Dev.app`. The only in-repo reader of that link is `Scripts/xcode_developer_workflow.sh`; the running app and conductor resolve the bundle via `REPOPROMPT_DEBUG_APP_BUNDLE`.
- Live bundle was unchanged by this lane:
  - `/Applications/RepoPrompt CE Dev.app` root inode `279370704`, executable inode `279371219`, mtime 2026-10-23 13:12, the same before and after;
  - PID 8017 still running.

## Observation for live-gate owners (read-only, not investigated)

The running app (PID 8017) started 2026-10-20 20:18:57. Its bundle was republished 2026-10-23 13:12 (provenance commit `8033b458`, dirty), after that process started. Per the development guide's Publish caution, the running process may be on a replaced executable. It may not reflect the bundle on disk or HEAD `e7ac41e4`. Main independently confirmed the PID/start/path and live lane (`debug-optimized-incremental`), which differs from the installed bundle's `debug` provenance. The documented running-build binding fails; live connectivity is not qualification of HEAD.

## Not run / not claimed

- Live acceptance, lifecycle (stop/relaunch/run), `dev-smoke` (main owns it), provider prompts, lint/format, guardrails, `dev-swift-build`.
- A bisect of the codemap failure.
