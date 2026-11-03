# Coordinated development workflow

Scope: read when the task touches local setup, builds, tests, packaging, the debug app, MCP CLI, or developer-daemon coordination.
Authority: Authoritative
Last-verified: 2026-08-10

## Choose the coordinated path

Follow the [pinned coordination invariants](../../../AGENTS.md#invariants-pinned--apply-always), then use the `make dev-*` targets shown by [`make help`](../../../Makefile). The conductor daemon auto-starts, serializes jobs that share lanes, admits Swift/Xcode-heavy work through machine-wide slots, and protects the singleton debug app with a machine-wide live-app lock.

Heavy admission defaults to one job; change `REPOPROMPT_DEV_HEAVY_SLOTS=N` only when concurrent heavy work is intentional. Run-only `dev-test-artifact` jobs use a separate machine-wide `xctest` slot (`REPOPROMPT_DEV_XCTEST_SLOTS`, default 1) instead of the heavy slot. Source-validating `dev-test-parallel` holds the local `build` lane plus both machine-wide heavy and XCTest slots across its build and runner phases. A job that holds its local lanes while waiting for a machine-wide slot reports `waiting-heavy-slot` or `waiting-xctest-slot` for its slot class.

Coordinated test jobs default to bounded execution: a filter must resolve against the curated ledger or a source suite before any build starts (exit 64 otherwise), a filtered serial run that executes zero tests fails (exit 66), source/artifact integrity failures in the parallel lane fail closed (exit 67), and serial XCTest phase deadlines contain hangs (exit 70; startup 90s after `Build complete!`, active-method budget `max(90s, 4×ledger runtime+30s)` — 180s for methods without ledger runtime — between-method 60s). The parallel runner applies its own ledger-derived per-suite deadlines. Successful root serial and parallel jobs record a compatible artifact-provenance ticket; `make dev-test-artifact FILTER=<SuiteName>` re-runs that recorded bundle in seconds via `swift test --skip-build`, reporting `artifact_scope: current` or a prominent stale label. See the [validation workflow](validation.md#fast-test-loop-semantics) for the exit-code contract and evidence rules.

All coordinated and packaging SwiftPM invocations construct the same minimal environment through `Scripts/canonical_swift.sh` for a given effective configuration and debug-symbol policy. Queries, listings and no-build invocations use that same policy environment; switching between full and skip intentionally changes it. Per-job values such as the conductor job ticket are excluded because SwiftPM keys its manifest-evaluation and build-plan caches on the exact child environment. The daemon runs as a launchd Interactive agent so coordinated jobs are not QoS-clamped; `REPOPROMPT_DEV_DAEMON_LAUNCHD=0` forces the legacy direct spawn.

`Scripts/canonical_swift.sh` explicitly selects `--build-system native` for build and test commands, including test listing, artifact re-runs, and `--show-bin-path`. Xcode 27 / Swift 6.4 otherwise defaults to `swiftbuild`, which uses a different `.build/out` layout and can replay stale XCFramework errors from its on-disk build description even after the vendor plist is fixed. Keep the engine consistent with the native SwiftPM artifact paths used by packaging and the test runner; removing an absent `DebugSymbolsPath` from Sparkle metadata alone does not invalidate that other engine's cached description. No whole-cache deletion is needed for the coordinated native path. The same branch also pins `--no-color-diagnostics`. SwiftPM's default diagnostic color depends on whether output is a TTY. Watchdog test jobs run under a PTY and builds run through a pipe, so without the pin the compiler argv differed and every build↔test switch re-emitted modules. Compiler diagnostics are therefore uncolored. `debug_dsym.py` must recognize every flag the wrapper injects, or ordinary debug builds classify as `configuration_unknown`.

### Debug symbols

The debug policy is `RPCE_DEBUG_DSYM=on|off`, unset `off`; invalid values including empty fail before mutation. Effective debug skip adds `SWIFT_DRIVER_DSYMUTIL_EXEC=/usr/bin/true` consistently across builds and queries; release, ambiguous configuration and nonempty Sentry keep full symbols. `on` affects future links, while coordinated `make dev-dsym PRODUCT=all|RepoPrompt|repoprompt-mcp|repoprompt-gateway|root-tests` regenerates symbols for existing binaries without building. Symbols remain outside fingerprint-v2 compatibility. The new operation and policy forwarding require the current conductor protocol: its normal upgrade path replaces only an idle older daemon and refuses replacement while jobs are active or queued.

The index store policy is `RPCE_INDEX_STORE=on|off`, unset `off` (opt in with `on`); invalid values including empty exit 2 before Swift. Off adds `--disable-index-store` to every qualified debug build/test invocation, including listing and `--show-bin-path`, independent of `RPCE_DEBUG_DSYM`; release, ambiguous configuration and nonempty Sentry are untouched, and no known consumer reads the store. Only argv changes, so toggling costs one full rebuild; direct SwiftPM calls bypass this flag policy and switching back can cost another full rebuild. Forwarding needs conductor protocol 17: an idle older daemon is replaced on the next command; a busy one refuses until idle.

Regeneration is in place, with no staging/swap framework or automatic stale-symbol cleanup. On the qualified Apple LLDB 2100 / Xcode 26.4.1 toolchain, a UUID-mismatched adjacent dSYM was ignored during normal lookup; debug-map objects still supported test file:line breakpoints and local values in off mode. Preserve those objects for debugging. In-place failure can leave incomplete symbols; UUID verification reports that instead of promising backup restoration. Roll back with `RPCE_DEBUG_DSYM=on` for future builds and `make dev-dsym` for existing products. Requalify the undocumented driver hook and debugging after toolchain changes.

The 2026-10-08 lean rollout used ten alternating warmed one-file test edits per mode in one CE tree: on median 18.655 s, off 11.654 s (7.001 s / 37.5% faster). Null medians were 1.641 / 1.645 s (off +0.004 s). Default-off packaging and focused `AgentContextRatioDisplayTests` passed, as did 954 conductor selftests. In a minimal SwiftPM XCTest fixture using the candidate wrapper, conductor, helper and Makefile, a live test breakpoint showed values; a deliberate crash named the function before regeneration and its adjusted non-top-frame call-site address resolved to file:line against matching regenerated DWARF. The raw return PC was compiler-generated:0 both before and after, and the debug map already supplied the adjusted line. This does not prove unfiltered-root tests or quiet-host statistics. No automated `dev-dsym-check`, calibration, bootstrap or thermal admission gate applies.

### Performance investigation boundaries

Per-job `phaseMetrics.segments[].dsymPolicy` records the observed wrapper policy, not a filesystem inference. The legacy calibrated Swift build harness (`make dev-bench`) works only on revisions before the Step 10 helper/default-skip policy. It refuses later target refs before mutating worktrees because its historical unset-policy full/full labels would be wrong. Its current error mentions an ignored private recipe unavailable in other clones; that pointer and the Makefile help wording remain nonblocking follow-up. For current revisions, use an explicit on/off same-tree comparison and report the edited file, filter, timing boundary, alternation and medians; do not label the legacy harness as usable for future pipeline qualification. Explicitly setting `on` in future full-symbol harness arms is backlog, not implemented here.

The bounded 2026-10-08 pre-test investigation found an edit-associated interval after `Build complete!` and before the first suite about 2.7 s longer than a null run; it did not identify its process or cause. Both arms in that historical full/full capture generated full symbols, regardless of their `ab-on` / `ab-skip` location labels. Cold residuals include other intervals; do not describe all historical residual time as test startup. No speculative fix was landed. Debug packaging runs one product-less `swift build` for its three products (host-native release keeps three `--product` builds) and executes the bin-path query once; printing that command is not a second execution. No duplicate query or cheap reuse fix was found. Process tracing and unexplained residuals remain optional follow-up, not build gates. Earlier accepted startup-target misses and contamination-inconclusive hashing gains remain evidence limitations, not claims of clean qualification.

The 2026-10-08 Swift compile follow-ups measured the `RepoPromptApp` emit-module bottleneck on a noisy host. In one cold build, among bodies warned at ≥200 ms, only `WindowRoutingService.updateCachedTools()` appeared in the emit-module job (525 ms; cause unconfirmed). Its visible type-check warnings totalled 807 ms (282 ms declaration-only), which identifies a marginal candidate lever from visible warnings, not an upper bound on total work; incremental savings are unverified. No hotspot was fixed and no code was extracted. An interface-neutral body-only `RepoPromptShared` edit can leave that shared `.swiftmodule` unchanged, so the app's emit-module job is skipped (3/3; full focused conductor-test medians, n=3 each: Core edit 11.151 s vs app edit 19.856 s). Commit-weighted savings estimates for a split are only an optimistic interface-locality proxy. With the index store off, app edits showed no measurable speed gain (n=2 per setting). On 2026-10-09 that build↔test emit-only rework was traced to the PTY/pipe diagnostic-color argv difference and fixed by the wrapper pin above. Measurement was advisory, with single samples: settled build→test→build reran with 0 production module emissions (12.1 s / 13.1 s, previously 32.9 s / 34.2 s).

The 2026-10-09 module-split assessment closes splitting `RepoPromptApp` as a build-speed project. All findings are advisory, from a noisy host.

The baseline is a focused `make dev-test` after a body-only app edit: about 23.5 s (median of 3).
- About 13.8 s is RepoPromptApp's emit-module job, the critical path.
- The rest is fixed overhead a split would not remove:
  - planning: about 3.9 s, of which about 2.8 s is app-driver planning that may partly scale with module size;
  - linking: about 1.6 s;
  - `swiftpm-xctest-helper` on the freshly linked bundle: about 2.8–3.1 s;
  - the null-run floor: about 2.1 s.

Cheap levers are exhausted:
- The emit-module job already passes `-experimental-skip-non-inlinable-function-bodies-without-types`.
- There is no bridging PCH to tune: the Objective-C bridging header is retired, and C code is reached through module imports.
- `make dev-test-parallel WORKERS=1` is slower than `make dev-test` for a focused edit loop: about 30.8 s vs 23.9 s, and 9.7 s vs 2.2 s null. It still runs the helper via `swift test list`, and it re-plans SwiftPM in both its build and list steps. Running `make dev-test` right after it costs one re-plan (about 4 s); nothing recompiles.

At the time, extraction was blocked by coupling. A name-reference inventory found one file-level dependency cycle covering about 561 files and 457k lines, about two-thirds of the app, spanning AgentMode, AI, MCP, WorkspaceContext, VCS, App, Settings and others.
- Neither `Infrastructure/AI` nor `Features/AgentMode` can be extracted mechanically. `AgentProviderKind`, for example, is declared in AgentMode but used throughout AI.
- Only small leaf areas such as `Infrastructure/AI/Prompts` and `Infrastructure/AI/Pricing` are separable, and they offer little build-time gain.

That cycle was later broken as deliberate architecture work: the app is now split into the Platform, Workspace, AgentCore, UI and App targets described in [source layout](../../architecture/source-layout.md), with no expected build-speed or runtime-speed gain. Raw evidence stays local under `.agent-artifacts/swift-compile-time/`.

### Parallel source-validating root tests

`make dev-test-parallel` is the promoted full-root contribution lane (`WORKERS=8` by default; `FILTER=<suite-regex>` is optional). It needs no prior ticket: the conductor invalidates any old root ticket, snapshots source, runs `Scripts/canonical_swift.sh build --build-tests`, rejects source drift, fingerprints the discovered root XCTest artifact, and then runs the direct-`xctest` worker pool. After the runner exits it rechecks source, environment gates, toolchain, artifact path, and artifact fingerprint before atomically recording a compatible artifact-provenance ticket. Per-job workdirs, test censuses, and strict candidate manifests live under the conductor jobs directory.

An unfiltered green run is full-root contribution evidence. Any `FILTER` is prominently labeled filtered and never satisfies full-root PR-ready evidence. The acceptance gate passed on 2026-08-07 with 10/10 consecutive green 8-worker runs (p50 about 166s, p90 about 194s, versus about 798s serial); the residual crash-retry tail sits in gateway/remote-session suites and is auto-retried by the runner. Serial `make dev-test` remains supported as the focused iteration path and fallback.

Daemon lanes coordinate submitted jobs, not source edits. Don't edit inputs during a build; wait for the build or edit activity to settle, then retry failures caused by concurrent modification. Mutating format jobs also claim the `build` lane; non-mutating format-check and lint use `style`, while format-tools status is unlaned.

For reconnectable work, use a stable request key:

```bash
./conductor build --async --request-key debug-package
./conductor job wait --request-key debug-package
```

Inspect queued or active work with `./conductor job list`; use `job status`, `job wait`, and `job cancel` with the returned ticket or request key. Add `--full-log` when concise failure highlights are insufficient; use `--verbose` only when delegated scripts need to capture extra diagnostics.

## Handle the debug app deliberately

Use `make dev-run` for the ordinary queued build/package/launch path. Use `make dev-launch-existing` only when the shared debug bundle already exists and no rebuild is needed. Use `./conductor app relaunch` only for a user-directed newest lifecycle action; it may supersede older queued lifecycle work. Follow the just-in-time approval invariant in [`AGENTS.md`](../../../AGENTS.md) before any visible launch, relaunch, stop, or other protected action.

A build/package failure before lifecycle activation does not replace or stop the running bundle. Don't assume an in-flight run or smoke job survives an overriding stop or relaunch; inspect its ticket.

Debug signing and secure-storage behavior are documented in the [local-build README](../../../README.md#build-and-launch-locally). An explicit `DEBUG_SECURE_STORAGE_BACKEND=keychain` is supported only for a strictly verified Apple Development debug signature with the exact debug bundle ID and a source-authorized team (`648A27MST5` or `AM9B9Y6HBV`). A package marker alone does not authorize persistence. The original team retains its existing debug Keychain service; `AM9B9Y6HBV` uses a separate `.team.AM9B9Y6HBV` service. Official release trust remains pinned to `648A27MST5`. Ad-hoc, unapproved, or mismatched signatures use ephemeral in-memory storage; keys saved there must be re-entered after restarting into an authorized build. Release builds follow the [release workflow](../../releasing.md).

The generated Xcode workspace is disposable. Follow the [Xcode workspace workflow](../../architecture/xcode-workspace.md); don't edit or commit `.build/xcode`.

### Debug packaging

**Destination.** A debug package is published to `REPOPROMPT_DEBUG_APP_BUNDLE`, default `~/Library/Application Support/RepoPrompt CE/DebugApps/RepoPrompt.app`. By default, `.build/debug/RepoPrompt.app` is only a compatibility link to it; conductor's staged run repairs that link after activation. SwiftPM products live under `.build/<architecture>-apple-macosx/debug/`. For a compile-only check without packaging, use `make dev-swift-build PRODUCT=RepoPrompt`.

**Publish.** Packaging assembles, signs and verifies in a hidden `.rpce-package-*` sibling of the destination. It publishes only after every check passes, by an atomic `renamex_np` swap or, where swap is unsupported, two renames with rollback. A package that fails before publish leaves the destination unchanged; if a fallback restore fails, the previous bundle is retained (see `.retain` below). A symlink or file destination is rejected.

Quit a running debug app normally before an ordinary `make dev-build` / `./conductor build` into its destination. Publishing swaps out the running bundle, which leaves that process on a deleted executable; a later stop step cannot detect such a process, so it keeps running. `make dev-run` / `./conductor run` packages into staging instead and stops the app before replacing it. Quitting, stopping or relaunching the app is still a visible lifecycle action that needs the user's just-in-time approval; nothing here grants it automatically.

**Outcomes.** The plan line (`Debug package plan: outcome=…`) picks one:
- `fresh`: assemble, sign the outer app, and sign nested components on a cache miss.
- `noop-dest` (`PACKAGE NO-OP`): the destination still matches its stamp. No assembly, signing or publish; it still runs every check, refreshes the compatibility link and prints `Created:`.
- `noop-clone` (`PACKAGE REUSE`): the destination is absent and a distinct `REPOPROMPT_DEBUG_APP_REUSE_SOURCE` matches its stamp. The source is cloned into the hidden sibling, checked, published and stamped by its new inode. Conductor's staged package names the live bundle as the source and only reads it.

**Checks.** Every outcome and mode runs the full checks: required SwiftPM resource bundles, `plutil -lint`, Sparkle vendor verification, provenance JSON, `codesign --verify --deep --strict`, signed identity, post-sign architecture, MCP helper layout and the helper `--version` smoke. No post-sign check is ever proportional or skipped. The pre-sign architecture check runs only when the bundle is assembled; on reuse, the post-sign architecture check covers it. `make dev-build FAST=1` / `package_app.sh debug fast` is an accepted alias that changes nothing; release ignores it.

**Caches.** These live under `.build/debug/package-cache/v1/` and are used only with the cache on and a uniquely resolved signing identity:
- `components/` holds signed Sparkle and helper copies (`CACHE HIT` / `CACHE MISS`), keyed on the signing policy, the control scripts and the build-output stat records.
  - A miss signs the unsigned build output in a private temp entry, deep-strict verifies it and commits an immutable entry.
  - Entries are cloned in with `cp -c -R -p`. Only if that fails is `cp -R -p` retried (`clone unavailable; copied`). Entries are never hard-linked.
  - A run that added entries keeps the two newest per component plus the ones it used.
- `stamps/<dev>-<inode>.json` is named by the published root inode. A stamp holds the input key and an inventory of every child's path, type, mode, size, mtime, inode and link target; ctime, xattrs and the root's own timestamps are excluded.
  - Any of these gives `fresh`: a touched, added or removed file, a new inode, a different input key, or a corrupt stamp, which warns and is deleted.
  - Recording keeps the eight newest stamps plus the reuse source's, and a matching destination or source stamp has its age refreshed. A failed stamp write only warns.
  - Stamps are also off under `REPOPROMPT_ENABLE_SENTRY=1` or a truthy `REPOPROMPT_UPLOAD_SENTRY_SYMBOLS`.
- With the cache `off` or an unresolved identity, every nested component is signed, and the cache is never read, written, evicted or pruned.

**Provenance.** The plan reads Git once (branch, commit, dirty); that snapshot feeds both the input key and `RepoPromptDebugProvenance.json`. Its build time is the assembly time. A reused bundle keeps its provenance bytes, so the build time is unchanged on `noop-dest` and `noop-clone`. A commit or dirty-flag flip changes the key, so the next package is `fresh`. The file also names its lane (`"version"` stays 1; readers check only the fields they need): `buildLane` (`debug`, `debug-optimized` or `debug-optimized-incremental`), `swiftConfiguration` (`debug` / `release`), `optimization` (`Onone` / `O`), `assertConfiguration` (`Debug` / `Release`) and `laneFlagsVerified` (`null` / `true`). The launch report and `app status` print `build lane: <buildLane>`, or `unknown (pre-lane provenance)` for an older bundle.

**Failure and recovery.**
- There is no in-run retry. A failed check exits non-zero and evicts every component entry it used and every destination or source stamp it consulted, matching or not, so the next package assembles and signs again.
- `REPOPROMPT_DEBUG_PACKAGE_CACHE=on|off` (unset `on`) is the escape. Any other value, including empty, fails before any build or mutation; `off` computes no keys and reuses nothing; release ignores it.
- For persistent trouble, `rm -rf .build/debug/package-cache` while no package job runs; this affects speed only.
- If a fallback restore fails, the sibling keeps the previous bundle next to `.retain`, and the error prints the exact `mv` that restores it; quit the app first if needed. Stale siblings older than one hour are removed at the next package, unless they hold `.retain`.
- Conductor forwards `REPOPROMPT_DEBUG_PACKAGE_CACHE` from protocol 18. An idle older daemon is replaced on the next command; a busy one refuses until idle.

Concurrent direct `package_app.sh` runs are unsupported; the conductor heavy slot is the supported serialization. Release, local self-signed and universal packaging are unchanged, because every reuse path is gated on debug (`IS_RELEASE=0`).

**Measured** on 2026-10-16. This is advisory: one noisy host (1-minute load 3.3–4.5), seven alternating cache on/off pairs in the same worktree after a discarded warm-up, and script `[package-timing]` medians. The off arm is not the pre-plan baseline.
- A no-change package into an existing destination took 2.43 s with the cache on versus 7.65 s off.
- After a relinking one-file app edit, non-compile time was 7.20 s versus 7.32 s (paired median −0.53 s; 1 versus 8 signs).
- A staged package into empty staging took 5.05 s versus 9.32 s. This used conductor's real staging and activation functions, not `./conductor run`.

**Live acceptance** passed on 2026-10-16 with the owner's approval. It ran into `/Applications/RepoPrompt CE Dev.app` with the Apple Development identity, and was two successful `./conductor run`s:
- The first was a `fresh` package that stopped the running app and launched the new one.
- The second was a `noop-clone` that stopped and relaunched again. The staged root inode became the installed inode.

A no-change `./conductor build` after launch was then `noop-dest`, with no signing. Every run passed the full checks, and the relaunched app answered `rpce-cli-debug` `windows`. Repeated clone-after-clone reuse was covered only by isolated non-launching runs, not by a third restart. An earlier attempt failed because a `./conductor build` had replaced the bundle under a running app (see the caution under Publish). After a normal quit and reopen, the retries above succeeded.

The raw evidence is local working evidence. It lives only in the main checkout's git-excluded `.agent-artifacts/debug-packaging-incremental/`, is not tracked, and is absent from other clones.

If the daemon is unavailable and direct packaging fails or hangs, capture traced output with `VERBOSE=1 ./Scripts/package_app.sh debug 2>&1 | tee /tmp/repoprompt-build.log`.

### Optimized diagnostics lane (opt-in)

The lane packages the same Dev app from an optimized build. SwiftPM builds `-c release` (`-O`, whole-module optimization, no `-enable-testing`) in its own scratch folder, `.build/optimized-diagnostics/`. `DEBUG` and the lane marker `RPCE_OPTIMIZED_DIAGNOSTICS` are defined only on the first-party Swift modules listed in `FIRST_PARTY_MODULES` in `Scripts/verify_build_lane_flags.py`; third-party and C modules build as plain release. A new first-party Swift target needs the manifest's first-party debug settings and an entry in that list. The verifier rejects an unlisted module only if its name starts with `RepoPrompt`; any other new name is checked as third-party, so it would build without `DEBUG` unnoticed. Packaging takes the debug path, so the bundle ID `com.pvncher.repoprompt.ce.debug`, the `repoprompt-ce-debug` URL scheme, Apple Development signing, the secure-storage marker, the destination, staging and user data are unchanged. The debug lane stays the default, with unchanged compiler arguments and environment. Release, local-production and public-release packaging never use the lane.

**Select it per invocation.** Conductor keeps no lane state: each command chooses, and the same command without the flag returns to the debug lane. `make` is the exception noted below.

```bash
SIGN_IDENTITY='Apple Development: …' make dev-build OPTIMIZED=1           # ./conductor build --optimized
SIGN_IDENTITY='Apple Development: …' make dev-run OPTIMIZED=1             # ./conductor run --optimized
SIGN_IDENTITY='Apple Development: …' ./conductor app relaunch --optimized
```

`make dev-run OPTIMIZED=1` / `./conductor run --optimized` and `./conductor app relaunch --optimized` stop and relaunch the visible Dev app. Like their plain forms, each needs the user's just-in-time approval immediately before it runs. `make dev-build OPTIMIZED=1` / `./conductor build --optimized` into a scratch `REPOPROMPT_DEBUG_APP_BUNDLE` launches nothing.

- The lane requires an explicit `SIGN_IDENTITY` beginning with `Apple Development:` (no auto-detected or ad-hoc signing), no `BUNDLE_ID` / `DEBUG_BUNDLE_ID` override, and `REPOPROMPT_ENABLE_SENTRY` and `REPOPROMPT_UPLOAD_SENTRY_SYMBOLS` unset. Packaging fails before building otherwise.
- `make` treats only the value `1` as the lane. It also takes `OPTIMIZED` from the environment, so an exported `OPTIMIZED=1` makes every `make dev-build` and `make dev-run` use the lane; pass it on the command line instead. `make dev-launch-existing` ignores `OPTIMIZED`.
- Only a leading `--optimized` selects the lane. To pass `--optimized` to the app itself, put it after `--` (`./conductor run -- --optimized`).
- `app launch-existing` never builds and rejects `--optimized`; it launches whatever lane the bundle was packaged with. Direct `make build` stays debug-only, and `./conductor package` has no lane.
- `--optimized` needs conductor protocol 19 or later (`--optimized-incremental` needs 20). An idle older daemon is replaced on the next command; a busy one refuses until idle instead of silently dropping the flag.
- Plain and lane requests never share a request key, so they never merge.

**What changes relative to the debug Dev app.**
- Kept: all first-party `#if DEBUG` code, including `AgentModePerfDiagnostics`, the main-thread stall watchdog, `__repoprompt_debug_diagnostics` (used by `rpce-cli-debug`), the EditFlowPerf capture recorder, debug-only `app_settings` keys, and the debug app-support, socket and CLI paths.
- Changed: `assert` and `assertionFailure` are not evaluated (release semantics); `precondition`, `fatalError`, overflow and exclusivity traps still trap. Third-party `#if DEBUG` paths behave as in the shipped app. Every link produces full dSYMs regardless of `RPCE_DEBUG_DSYM`, and no index store is written. Timing diagnostics should fire less often if the app is faster.
- Lost: assertion checks, and lldb stepping and variable-inspection quality. Crash backtraces still symbolicate through the dSYMs, but inlined frames collapse.
- This is release code generation plus first-party debug extras, not a shipping-performance claim; first-party `DEBUG` work still runs.

**Proof on every lane package.** After the build and before the package keys are computed, including on `noop-dest` and `noop-clone`, `Scripts/verify_build_lane_flags.py` reads `.build/optimized-diagnostics/release.yaml`. Every first-party compile command must carry `-DDEBUG`, `-DRPCE_OPTIMIZED_DIAGNOSTICS`, `-O` and `-whole-module-optimization`, without `-Onone` or `-enable-testing`. No other module may carry either define. A missing first-party module or an unclassified `RepoPrompt*` module fails closed, and any failure fails packaging. Its selftest runs in `make conductor-selftest`. The package log prints `*** OPTIMIZED DIAGNOSTICS LANE … ***`.

**Costs.** Measured on 2026-10-16 with probe bundles (advisory: one noisy host at 1-minute load about 3–4.6, single samples):
- cold build: about 13 m 17 s (797 s, including about 100 s of first dependency resolution, checkout and patching);
- one-line `RepoPromptApp` edit: 5 m 13 s (one whole-module `RepoPromptApp` compile plus relink, symbols and packaging);
- no-change rebuild: 2.6 s (`noop-dest`);
- disk: `.build/optimized-diagnostics/` grew to 7.0 GiB, mostly from a second copy of dependency repositories and binary artifacts. Check free space before a cold build.

Edits to `RepoPromptShared` or `RepoPromptAgentCore` cascade and were not measured. An exploratory same-revision comparison on 2026-10-17 observed the 2,161-item session's first publication at 589 ms optimized versus 936 ms debug, and SwiftUI observation at 756 ms versus 1,103 ms. These are single first-open observations, not completed drawing or a causal speedup estimate: host load and sidebar search state differed. Repeated, controlled runtime qualification was not completed; the owner accepted closure without further manual testing on 2026-10-17.

**Heavy slot.** Lane packaging runs in the machine-wide heavy slot and holds it for minutes. Meanwhile every other job on the machine that needs that slot waits: builds, packaging and source-validating tests (`make dev-test`, `dev-core-test`, `dev-provider-test`, `dev-test-parallel`), including other agents' loops. Daemon-admitted jobs report `waiting-heavy-slot`. Artifact-only `make dev-test-artifact` uses the separate XCTest slot and is not blocked. Keep debug for edit-build loops; build the lane at natural break points, when no agents are mid-test.

**Live-app lane and supersession.** `run --optimized` and `app relaunch --optimized` package into staging inside the same job that later stops and launches the app, so that job holds the `liveApp` lane for the whole build. The running app stays usable meanwhile. A queued `app launch-existing` or a later FIFO `run` waits for the whole build. A newer `app relaunch` or `app stop` supersedes it (the newest relaunch intent wins); each is a visible lifecycle action that needs the user's just-in-time approval at that moment.

**Timeout and interruption.** A lane `build`, `run` or `app relaunch` without `--timeout` gets the ordinary 3600 s limit. The lane floor, twice the measured cold build (1594 s), is lower, so it doesn't raise it. Pass a longer limit with `./conductor <command> --optimized --timeout <seconds>`; the `make` targets can't pass `--timeout`. What the clock counts differs by command:
- `build`: the daemon takes the heavy slot before it starts the packaging process, and the clock starts with that process, so waiting for the slot doesn't count.
- `run` and `app relaunch`: the clock starts when the job's process starts, and that process waits for the heavy slot itself, so time spent waiting behind other heavy jobs counts against the limit.

Waiting in the queue for a local lane such as `liveApp` doesn't count for any of them. A timed-out lane job's message names the `--timeout` rerun. Whole-module compiles keep no partial results: a timeout, or a stop or relaunch that supersedes the job mid-compile, discards the interrupted module's progress, and the retry compiles it from zero. A failure before activation leaves the live bundle untouched.

**Running app.** The caution under Publish applies unchanged: don't `build --optimized` into a running app's destination; use `run` or `app relaunch` for the live app.

**Package cache and the compatibility link.** The lane shares `.build/debug/package-cache/v1/` and the `fresh` / `noop-dest` / `noop-clone` outcomes. The input key includes the lane, so reuse never crosses lanes: switching lanes at a destination always packages `fresh`, and a staged lane `run` clones the live bundle only when it is a lane bundle with the same inputs. Alternating lanes can evict the other lane's signed helper entries, which costs only a re-sign. Both lanes use the `.build/debug/RepoPrompt.app` compatibility link. A probe `build --optimized` with `REPOPROMPT_DEBUG_APP_BUNDLE` set to a scratch path points that link at the probe until the next `app relaunch` or `launch-existing` repairs it; launch through conductor rather than opening the link.

**Labels and the evidence rule.** The bundle's provenance records the lane (see Provenance above). The running process reports its compiled-in lane as `buildLane` (`debug`, `debug-optimized` or `debug-optimized-incremental`) in the diagnostics `ping`: `rpce-cli-debug -w <window-id> -c __repoprompt_debug_diagnostics -j '{"op":"ping"}'`.
- Record `buildLane` from the running process with every timing sample.
- Take `commit` and `dirty` from the bundle's provenance only once the process is bound to that bundle, by the rule `Scripts/live_codemap_authority_e2e.py` applies at capture start and again at capture end:
  - `ps -o pid=,lstart=,comm=` must name the bundle's own `Contents/MacOS/RepoPrompt` for that PID.
  - The process start time must be strictly later than the provenance `buildTimeEpoch` and the executable's mtime and ctime. `lstart` has whole-second precision and is treated as a lower bound, so a same-second or newer bundle is unproven. This catches a bundle replaced after launch but before the capture started.
  - Then compare the process identity (PID and start time), the executable's stat record (device, inode, mode, size, mtime, ctime), its SHA-256 and the provenance bytes between start and end.
  - Any failure or difference invalidates the capture, including a bundle replaced during it. The binding is a conservative timestamp rule, not a hash of the mapped executable.
- Never pool samples from different lanes or commits.
- `./conductor metrics` rows carry no lane. Identify lane jobs by joining a row's `ticket` to its job record (`./conductor job status <ticket> --json` shows `args.optimized: true`, or `args.optimizedIncremental: true` for the App-only incremental lane; both keys are absent for the debug lane) while that record is retained, and never pool minutes-long lane builds with debug builds.

**Stale local-package source list (observed once).** One lane build compiled against a cached plan that lacked a source file newly added to the local `Packages/RepoPromptCore` package, so app code using the new declaration failed with `cannot find '<name>' in scope`. Touching the root manifest (`touch Package.swift`, which changes only its mtime) and retrying the coordinated build recovered. Use this only for that symptom. Don't touch the manifest on every edit; equivalent staleness in the debug lane has not been reproduced.

**Fresh worktrees (anticipated, not reproduced).** In a checkout that has never had a default debug build, lane packaging may create `.build/debug` as a real directory (package-cache root and compatibility link) where SwiftPM normally keeps a symlink, and a later default debug build might then fail or replace it. Run one default debug build first. If a default debug build later fails in such a checkout, check `ls -ld .build/debug` first. Only if it is a real directory, not a symlink, remove it while no conductor job runs (`rm -rf .build/debug`; this costs only package-cache speed).

**Rollback.**
1. Relaunch without `--optimized`, with the user's approval at that moment. This restores the plain Dev app with the same data and Keychain service.
2. Revert the lane's commits, newest first. Steps 1–6 are `1d19255c` (manifest gate) through `7e349c6a` (running build lane), followed by the commit that added this subsection and the Makefile `OPTIMIZED` switch. Check `git log` for later commits that touch the same files before reverting.
3. Optionally reclaim disk with `rm -rf .build/optimized-diagnostics`, only when `./conductor job list` shows no queued or running job and no direct packaging runs; the next lane build is cold again.

No data migration is involved.

**Live acceptance** passed on 2026-10-17. An owner-approved `app relaunch --optimized` installed clean commit `6c1129d0` into `/Applications/RepoPrompt CE Dev.app`; the staged job completed in 8.95 s with warm build outputs and fresh packaging. Lane-flag verification, deep-strict signature verification, the Dev identity and the compatibility link passed. The running process reported `buildLane: debug-optimized`, and the performance diagnostics settings remained enabled. The owner confirmed existing workspaces and sessions and configured-provider use without re-entering API keys. The subsequent exploratory comparison is described under Costs; it does not satisfy the repeated, controlled comparison. Native trace finalization failed, so no native hang/hitch or completed-frame result is claimed. The owner closed this lane work on 2026-10-17 with those qualification limits accepted and the optimized Dev app restored. The recorded minor review follow-ups, plain-release equivalence/invalid-flag-arm checks and full repeated/native qualification remain deferred, not passed. Daily operation follows the commands above; no further manual acceptance round is required for this workstream.

### Optimized-incremental App lane (opt-in)

A separate fast-iteration variant of the optimized lane. It is not performance-accepted: performance acceptance and timing evidence stay on the WMO `--optimized` lane above, which is unchanged and kept for comparison. Everything in the optimized lane applies unless this subsection says otherwise.

```bash
SIGN_IDENTITY='Apple Development: …' make dev-build OPTIMIZED_INCREMENTAL=1   # ./conductor build --optimized-incremental
SIGN_IDENTITY='Apple Development: …' make dev-run OPTIMIZED_INCREMENTAL=1     # ./conductor run --optimized-incremental
SIGN_IDENTITY='Apple Development: …' ./conductor app relaunch --optimized-incremental
```

`run` and `app relaunch` stop and relaunch the visible Dev app and need the user's just-in-time approval, as above.

**Contract.**
- Same `-c release`, first-party `DEBUG` and `RPCE_OPTIMIZED_DIAGNOSTICS` marker, signing and identity preconditions, debug bundle identity, destination, staging, user data and full-dSYM policy as the optimized lane.
- Own scratch folder `.build/optimized-incremental/`; it never shares compiler outputs with `.build/optimized-diagnostics/`.
- `Scripts/canonical_swift.sh --rpce-optimized-incremental` sets both `RPCE_OPTIMIZED_DIAGNOSTICS=1` and `RPCE_OPTIMIZED_INCREMENTAL=1` in the canonical environment; inherited values never reach Swift, and release packaging unsets both. The manifests honor `RPCE_OPTIMIZED_INCREMENTAL` only together with the diagnostics gate.
- Every first-party Swift module also gets the label define `RPCE_OPTIMIZED_INCREMENTAL`, so `RepoPromptBuildLane.current` reports `debug-optimized-incremental` in the `ping`; provenance records the same `buildLane` (`swiftConfiguration` `release`, `optimization` `O`, `assertConfiguration` `Release`, `laneFlagsVerified` `true`).
- Only the root manifest's `RepoPromptApp` target appends `-no-whole-module-optimization -incremental -enable-batch-mode` (release configuration, this lane only). The driver honors the last WMO flag, so the App override follows SwiftPM's own `-whole-module-optimization`. Every other module, including `RepoPromptWorkspace`, `RepoPromptAgentCore` and all third-party modules, stays `-O` whole-module. Parallelism is SwiftPM's normal `-j`, which uses the host's available CPUs; no job count is hardcoded.
- Selection: a leading `--optimized-incremental` on `build`, `run` or `app relaunch` (request key `optimizedIncremental`, never merged with plain or `--optimized` requests). `build` rejects `--optimized` together with `--optimized-incremental`; `run` and `app relaunch` reject the other lane flag right after the leading one, in either order. As with `--optimized`, a later lane flag on `run` is an application argument, and on `relaunch` application arguments must follow `--`. `app launch-existing` rejects it. `make` rejects `OPTIMIZED=1` together with `OPTIMIZED_INCREMENTAL=1`, and, as with `OPTIMIZED`, also reads `OPTIMIZED_INCREMENTAL` from the environment, so pass it on the command line.
- Timeout floor, heavy slot, `liveApp` supersession, package cache and compatibility-link behavior are as above. The lane is part of the package input key (`debug-optimized-incremental`), so reuse never crosses any lane. A timed-out job names the `--optimized-incremental --timeout` rerun; every module except `RepoPromptApp` still compiles whole-module without partial results.

**Proof on every lane package.** `Scripts/verify_build_lane_flags.py --lane optimized-incremental` reads `.build/optimized-incremental/release.yaml` and fails closed unless:
- every first-party module carries `-DDEBUG`, `-DRPCE_OPTIMIZED_DIAGNOSTICS`, `-DRPCE_OPTIMIZED_INCREMENTAL` and `-O`, without `-Onone` or `-enable-testing`;
- `RepoPromptApp` carries SwiftPM's `-whole-module-optimization` followed by `-no-whole-module-optimization` (effectively non-WMO), plus `-incremental` and effective `-enable-batch-mode`;
- every other first-party module is effectively whole-module, without `-incremental` or batch-mode flags;
- third-party and test modules carry none of the three defines and none of the App-only flags, and must be effectively whole-module too (the WMO lane's verifier doesn't check their WMO; this one does, so a dependency or test module that SwiftPM builds without WMO fails this lane closed).

The default `--lane optimized-diagnostics` contract is unchanged and also rejects the incremental label define. The package log prints `*** OPTIMIZED INCREMENTAL APP LANE … ***`.

**Tradeoff and measurements (lab, advisory).** Measured with real full SwiftPM builds of the frozen source at `0a6df8f3` (source digest `15e4…8b19`) in the ignored `.agent-artifacts/optimized-build-lab-20261019/native/`. That lab manifest hardcoded `-j28`; the production manifest does not. These numbers do not prove production-selector integration; the production-selector build below does.
- cold build of all products: 472.88 s;
- `RepoPromptApp` body edit: 18.58 s, and 18.13 s to restore it, both including link and dSYM (versus 5 m 13 s for the WMO lane's one-line App edit under Costs above; different runs and dates on the same Mac);
- settled no-op rebuilds: 0.4–0.5 s;
- switching back to a WMO App rebuild: 337.12 s (a lane switch, not a matched edit);
- 28 concurrent App frontends ran in the candidate.

UI audit (`.agent-artifacts/optimized-build-lab-20261020/ui/analysis/final-summary-20261020.json` and `final-audit*.json`): the installed WMO app, n=2, ran about 42.6% busy with 34–39 hitches; the incremental candidate, n=3, ran a median 44.7% busy with 78–140 hitches. Max stall was similar (about 0.5 s) and none reached 1 s. Read this as additional small hitches, not runtime equivalence. Qualifications: non-randomized runs on a noisy host; the installed WMO app and the frozen lab build share the commit but differ in root and dirty provenance, so build inputs are not proved identical; CLI warm 20-switch runs bypass click markers; strict session fingerprints differed only in `savedAt`.

**Production-selector build (2026-10-20).** `./conductor build --optimized-incremental` from commit `0a6df8f3` with the uncommitted lane change, into a scratch `REPOPROMPT_DEBUG_APP_BUNDLE` (no launch), with dependency repositories, checkouts, artifacts and workspace state APFS-cloned from `.build/optimized-diagnostics/`: exit 0 in 514 s (SwiftPM `Build complete! (489.12s)`; packaging `fresh`). The verifier passed for 13 of 13 first-party, 97 third-party and 2 test modules. In `release.yaml`, `RepoPromptApp` carries `-whole-module-optimization` at argv 10 and 19, then `-no-whole-module-optimization -incremental -enable-batch-mode` at 229–231; `RepoPromptWorkspace` and `RepoPromptAgentCore` carry WMO only. SwiftPM supplied `-j28` from the host's 28 logical CPUs; the manifests contain no job count. The driver printed `warning: ignoring -num-threads argument; cannot multithread batch mode` once (expected: SwiftPM still passes its WMO `-num-threads` to the App) and no "incremental compilation has been disabled" message; the log shows 596 per-file `Compiling RepoPromptApp` progress lines versus one whole-module line each for `RepoPromptWorkspace` and `RepoPromptAgentCore`. The bundle passed deep-strict signature verification, kept `com.pvncher.repoprompt.ce.debug` with Apple Development signing, recorded `buildLane: debug-optimized-incremental` with `laneFlagsVerified: true`, and the `RepoPrompt.dSYM` UUID matched the executable. (Every lane's executable contains all `RepoPromptBuildLane` raw values, so a `strings` match proves nothing about the compiled lane.) `.build/optimized-incremental/` reached 7.0 GiB (mostly the cloned dependency state, which shares blocks); minimum free space during the build was 2.25 GiB. The build repointed the compatibility link to the scratch bundle, as documented above. It was not launched, so no running `ping` label or runtime result was captured.

**Warm production-selector loop (2026-10-20, same tree and scratch bundle, single advisory samples).** After the cold build and a whitespace-only manifest fix, the next build was already `noop-dest` (15 s total, SwiftPM 6.50 s, no compiles); a settled no-op was `noop-dest` in 5 s (SwiftPM 0.41 s). A one-literal body edit in a private `RepoPromptApp` function (`AppQuitPolicy.swift`) rebuilt in 35 s total (SwiftPM 21.14 s; one compile line, `Compiling RepoPromptApp AppQuitPolicy.swift`; packaging `fresh` because the executable changed), and restoring it took 30 s (SwiftPM 19.64 s, one compile line); the source hash matched the original afterwards. Each build passed the verifier, printed the `-num-threads` warning once and no "incremental compilation has been disabled" message; the restored bundle passed deep-strict signing with matching executable and dSYM UUIDs. Edits outside `RepoPromptApp`, edits to non-private declarations, and cascades from `RepoPromptShared` or `RepoPromptAgentCore` were not measured; those modules recompile whole-module. Every run left `.build/optimized-diagnostics/` (`build.db`, `release.yaml`, `workspace-state.json`) byte- and inode-identical. The cache-key separation of the three debug lanes is covered by `test_debug_package_cache.py`; a real staged `noop-clone` needs `run` / `app relaunch` and was not exercised.

**Regression builds of the same tree (2026-10-20, scratch bundles, no launch).** `./conductor build --optimized` passed its unchanged default verifier (13/97/2, 0 failing) in 688 s (SwiftPM 675.41 s; this tree changes `RepoPromptShared`, so the first-party modules recompiled whole-module), with provenance `debug-optimized`, no `-num-threads` warning, deep-strict signing and matching UUIDs. A plain `make dev-build` passed in 86 s with provenance `debug` / `Onone` / `laneFlagsVerified: null`, no lane verifier, and a plan without lane defines or `-no-whole-module-optimization`. The compatibility link was restored after each build.

**Not yet observed for this lane:** a live launch (`run` / `app relaunch --optimized-incremental`) and a running process reporting `buildLane: debug-optimized-incremental` in the diagnostics `ping`. The label is proved only at compile time: the verifier requires the define on every first-party compile. The lab UI audit above used the lab candidate, not a production-selector bundle.

**Rollback.** Rebuild or relaunch without the flag (relaunch needs the user's approval at that moment). Optionally reclaim disk with `rm -rf .build/optimized-incremental` when no conductor job or direct packaging runs. No data migration is involved.

## Use the CE debug CLI

Use `rpce-cli-debug`, not production `rp-cli` or `rp-cli-debug`, when validating this app. Inspect or install it with:

```bash
make debug-cli-status
make install-debug-cli
./Scripts/doctor.sh --install-debug-cli
```

If the PATH link is unavailable, use:

```bash
"$HOME/Library/Application Support/RepoPrompt CE/repoprompt_ce_cli_debug" -e 'windows'
```

For a non-disruptive live check against an already-running CE debug app, start with `make dev-smoke`. Use `./conductor smoke --agent-run` only when provider credentials and model access are available. A manual MCP probe can use:

```bash
rpce-cli-debug -e 'windows'
rpce-cli-debug -w 1 -e 'workspace switch repoprompt-ce'
rpce-cli-debug -w 1 -e 'tree --type roots'
rpce-cli-debug -w 1 -c agent_manage -j '{"op":"list_agents","roles_only":true}'
```

### Enable Codex computer use for one explicit turn

Codex computer use is a persisted, default-off opt-in exposed through `app_settings` key `agent_mode.codex_computer_use_enabled`; there is no Settings-screen toggle. Enabling the key only makes an explicit `/computer-use` turn eligible:

```bash
rpce-cli-debug -w <window-id> -c app_settings -j '{"op":"set","key":"agent_mode.codex_computer_use_enabled","value":true}'
```

The production admission path rejects `/computer-use` in Safe Managed and Knowledge sessions and independently clamps the controller capability off for both. See the [computer-use implementation report](../../technical_implementation_reports/2026-09-03-codex-computer-use-enablement-report.html) for the implementation, safety, and validation record.

### Diagnose missing native Codex MCP tools

If every RepoPrompt tool is missing, inspect the Codex MCP startup error before
changing tool permissions or Oracle presets. Codex 0.154.0-alpha.6.2 advertises
`experimental: {"codex/auth-change": {}}`; the pinned Swift MCP SDK's
`Client.Capabilities.experimental` accepts only string values and rejects that
initialize request before tool discovery.

`MCPInitializeCompatibility` adapts only incoming initialize requests at the
app's UNIX socket boundary, ignoring unsupported non-string experimental entries
while retaining standard capabilities, client identity and string entries.
Wire diagnostics retain the original frame, and the existing initialization
approval hook still runs. Remove this adapter when the SDK supports arbitrary
JSON experimental values. Validate this boundary with
`make dev-test FILTER=MCPInitializeCompatibilityTests`.

### Run the transient OMP DEBUG smoke

`Scripts/smoke_omp_agent_mode.sh` is the one-command OMP post-relaunch smoke. Use it only after one coordinated relaunch has installed the current DEBUG binary, with fresh explicit approval obtained immediately before that relaunch. The script itself requires an already-running current DEBUG app and never launches, stops, relaunches, switches workspaces, or resumes a session.

For the first smoke, obtain only the target window's positive ID before running the script. Use the known catalog sentinel exact model ID `ohMyPi:default` (`AgentModel.defaultModel.rawValue == "default"`):

```bash
Scripts/smoke_omp_agent_mode.sh \
  --window-id <positive-window-id> \
  --model-id 'ohMyPi:default' \
  --output-parent /tmp
```

Ordinary `list_agents` discovery includes OMP only after the window has a successfully connected OMP provider. The qualification script does not depend on that public connection state: it acquires the strict transient lease first and then verifies the exact supplied ID through `list_agents`. For a later smoke with an explicit discovered OMP model, copy its exact ID from the private `list_agents.json` evidence produced by the first script run, or obtain it from a connected window.

The script acquires one hidden DEBUG-only process-owned qualification lease through `__repoprompt_debug_diagnostics`, verifies the supplied exact model ID through `list_agents`, and supplies the lease UUID only through the dedicated DEBUG `_omp_qualification_lease_id` start parameter. The lease is exclusive, process-local, expiring, non-persistent, absent from RELEASE, and transactionally bound by the app to the created session/run; discovery availability is not authorization. The script requires terminal exact-connection zero raw tool calls/in-flight calls/scopes, unchanged target-workspace identity and bounded no-follow content snapshots of tracked/index/existing-untracked state for every active root (Git-ignored paths are excluded), one strictly ordered post-baseline route with a distinct launched OMP ancestor and bundled helper descendant correlated by executable and process-start identity, and terminal expected-PID/policy cleanup. Every CLI call is output-bounded and process-group-owned with TERM/KILL/reap; failure cleanup cancels the exact nonterminal session, releases the exact lease, and verifies the lease inactive. The script never launches, stops, relaunches, switches workspaces, or resumes. This remains a qualification-only path independent of normal public availability and resume. The lease authorizes only its exact hidden DEBUG transaction; ordinary connected OMP starts and exact-or-error resume use the public production path without a lease. Treat the private evidence directory as temporary sensitive working evidence; do not publish or stage its raw JSON.

Use `agent_run` for an end-to-end provider probe only when credentials and model access are available:

```bash
rpce-cli-debug -w 1 -c agent_run -j '{"op":"start","model_id":"explore","session_name":"CE debug CLI smoke","message":"Reply exactly with CE_AGENT_RUN_SMOKE_OK and stop. Do not edit files.","detach":true}'
rpce-cli-debug -w 1 -c agent_run -j '{"op":"wait","session_id":"<session_id>","timeout":120}'
```

Before a live Agent Mode or Claude investigation, enable the DEBUG-only diagnostics through `app_settings`:

```bash
rpce-cli-debug -w 1 -c app_settings -j '{"op":"list","group":"agent_mode","detailed":true}'
rpce-cli-debug -w 1 -c app_settings -j '{"op":"set","key":"agent_mode.claude_raw_event_logging_enabled","value":true}'
rpce-cli-debug -w 1 -c app_settings -j '{"op":"set","key":"agent_mode.claude_raw_event_log_file_path","value":"/tmp/repoprompt-ce-claude-raw-events"}'
rpce-cli-debug -w 1 -c app_settings -j '{"op":"set","key":"agent_mode.perf_diagnostics_enabled","value":true}'
```

If a key is unavailable, verify `rpce-cli-debug --version` resolves to the current CE debug build. Treat raw CLI responses and diagnostic logs as private working evidence; don't stage them unless the task intentionally distills them into a durable document.

## Enable the optional local hook

CI is authoritative. To use the repository hook as a local accelerator, first inspect any existing hook configuration, then opt in:

```bash
git config --get core.hooksPath
git config core.hooksPath .githooks
```

Don't overwrite an intentional hook setup; compose `.githooks/pre-commit` into the existing manager instead. The hook checks current working-tree structure through the same script as CI; CI remains authoritative, and the hook does not replace staged-index contribution preflight.

Use `make clean` to remove `.build` only after coordinated jobs have stopped; don't delete build state underneath an active conductor job.
