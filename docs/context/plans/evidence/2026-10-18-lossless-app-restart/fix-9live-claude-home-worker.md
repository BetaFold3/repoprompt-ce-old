# 9-live fix 4: Claude history location (O42)
Scope: read when the task touches where recovery finds a Claude conversation's history, Claude process classification in the process registry, or the Claude dispatch baseline.
Authority: Reference
Last-verified: 2026-10-28
Covers: the Step 4 source and test changes

## What changed

Implements Step 4 of [plan-9live-fixes-oracled.md](plan-9live-fixes-oracled.md) (§2 Step 4, §4), under owner decisions O42 and O44 (first-message crashes stay refused; no `--session-id` preallocation) and plan recommendation D5 (fallback roots are recorded homes, the app's `CLAUDE_CONFIG_DIR` and `~/.claude`; no `~/.claude-rotator/profiles/*` scan).

### (a) The native-installer CLI is the writer — `AgentProcessRegistry.swift`

- `classifyNewMember` (≈592–599): after the basename rule, a member is `.writer` when the family is Claude (`isClaude`: native or headless), its executable path ends `…/claude/versions/<anything>` (`isClaudeNativeInstallerExecutable`, ≈607–613), and its readable environment carries **this record's own marker** (`RPCE_RUNTIME_ID == record.runtimeID`). A non-Claude family, or a Claude descendant found only by parent link without the marker, stays `.unknown`.
- Discovery step 3 (≈524–530): an `.unknown` member observed as `.writer` now upgrades too (previously only `.tool` upgraded). Nothing demotes. This lets a member first seen while its path or marker was unreadable become the writer later, so its home is extracted. `writerAlive` is unchanged (unknown and writer both count as possible writers).
- Home extraction is unchanged: the first writer member whose environment has `CLAUDE_CONFIG_DIR` sets `providerHome`, and `discoveryPass` keeps a home once it's recorded.
- New `allClaudeProviderHomes()` (≈1197–1206): every non-empty home on any Claude record, not just this conversation's (the rotator's other profiles).

### (b) One refresh, then the locator — `AgentModeViewModel+RecoveryActions.swift`

- `recoveryClaudeHistoryRoots(conversationID:)` (≈1369) now returns `RecoveryClaudeHistoryLocation` (`.roots([URL])` / `.unknown` / `.ambiguous`). Order: recorded homes for this conversation → if none, `await registry.refresh()` once (`recoveryRefreshHistoryRegistry`, ≈1410) and re-read → if still none, `ClaudeHistoryLocator` over `recoveryClaudeLocatorHomes()` (≈1419). The locator runs through a `nonisolated static async` wrapper, the same pattern as `readClaudeHistory`, so it runs off the main actor.
- Baseline (`captureClaudeDispatchBaseline`, ≈996–1006): `.unknown` → `recordUnsupported("Claude history location unknown")` as before; `.ambiguous` → `recordUnsupported(recoveryClaudeHistoryAmbiguousReason)` ("Claude history for this conversation exists in more than one location"). Like every baseline outcome, it is recorded unsupported and the ordinary send goes ahead. It never refuses the user's send.
- Reconcile (`recoveryHistoryObservation`, Claude branch, ≈1480–1488): same three cases; ambiguous fails with the same sentence plus a period.
- Baseline and reconcile share the same selection logic, but they resolve at different times, so they can pick different roots. For example, the baseline uses a locator-found home and a home is recorded later. The cursor's file identity is the guard against a reconcile reading a different file. (Corrected in round 0; the first version claimed "the same root".)

### (c) `ClaudeHistoryLocator` — new `Sources/RepoPromptAgentCore/AgentMode/Runtime/Recovery/ClaudeHistoryLocator.swift`

- `locate(sessionID:homes:fileSystem:)`: if the ID is not a UUID, or there are no homes, it returns `nil` before any filesystem call. Homes are deduplicated by canonical path, which resolves symlinks so the same home twice is never "ambiguous". Per home it does one listing of `<home>/projects`, keeps real subdirectories only (symlinked project directories are skipped), and checks each for a regular file `<sessionID>.jsonl`. No recursion, no other names. 0 hits → `nil`; 1 → `.unique(home)`; more than 1 → `.ambiguous(homes)`.
- `candidateHomes(recorded:environment:userHome:)`: recorded homes, then the app's `CLAUDE_CONFIG_DIR` if set (tilde-expanded), then `<userHome>/.claude`. Empty entries are dropped.
- `FileSystem` is injectable (three closures; `.live` uses `FileManager` resource values).

### Test seams — `AgentModeViewModel.swift` (≈694–696)

New DEBUG `test_recoveryClaudeHistoryLocatorHomes`. While `test_recoveryClaudeHistoryHomes` is set, the registry refresh is skipped (fixtures never refresh a real registry). `AgentProcessRegistry.production` is already `nil` under XCTest. (Corrected in round 0: the first version claimed that no test reads the real `~/.claude`. That was only true while the home override was set. A test with neither override could list the real `~/.claude/projects` and the runner's `CLAUDE_CONFIG_DIR`. Round 0 closes this; see below.)

## Tests

- `AgentProcessRegistryTests`
  - `testNativeInstallerClaudeDescendantIsTheWriterAndRecordsItsHome`: under `.claudeAndCodex`, a root `node` shim with no home and a marker-bearing child at `…/claude/versions/2.1.302` with `CLAUDE_CONFIG_DIR`. After commit the root has no home; after one refresh the child is `.writer` and `providerHome`, `claudeProviderHomes(conversationID:)` and `allClaudeProviderHomes()` all name the profile.
  - `testNativeInstallerPathIsNoWriterOutsideClaudeOrWithoutTheMarker`: a Codex-family descendant at the same path stays `.unknown`; a Claude descendant at that path linked only by parent (no marker) stays `.unknown` with no home. Also checks the path predicate.
- `ClaudeHistoryLocatorTests` (new; temp directories only)
  - 0 homes or no hit → nil
  - 1 hit → that home
  - the same file in 2 homes → ambiguous; the same home listed twice or through a symlink → unique
  - near misses don't count (other extension, a directory named like the file, deeper nesting, a file directly in `projects`)
  - non-UUID IDs → nil with **zero** filesystem calls (counting fake)
  - the default `~/.claude`-style home is chosen only when the recorded home doesn't have the file
  - candidate order with the app `CLAUDE_CONFIG_DIR`
- `AgentRecoveryReconciliationTests`
  - `testBaselineRetriesTheRecordedHomeOnceThenCaptures`: first lookup `[]`, second lookup has the home → `.committed`, status `.captured`, exactly 2 lookups, locator not reached.
  - `testBaselineFallsBackToTheLocatorsSingleHome`: no recorded home; locator candidates are [empty home, fixture home] → captured at the fixture file's size.
  - `testBaselineRefusesAConversationFileFoundUnderTwoHomes`: a copy under a second home → `.unsupported(ambiguous reason)`, the send still allowed.
  - Existing `testMissingIdentityOrLocationIsRecordedUnsupportedAndNeverBackfilled` still passes unchanged: no recorded home and no locator candidates → unsupported.

## Validation

| Command | Ticket | Result |
|---|---|---|
| `make dev-test FILTER=AgentProcessRegistryTests` | `79fdd957-93e8-428f-9b50-ff3e61e1ca67` | failed to compile: `AgentRecoveryStoreTests.swift:1391`, the parallel Step 3 worker's in-progress file, not this change |
| `make dev-build` | `fb163c52-dcbd-4a0f-ba24-09abde77329a` | completed |
| `make dev-lint` | `108b425d-46cd-44ea-956f-8614e2c53f03` | failed (redundant `Sendable`, test closure formatting); fixed |
| `make dev-lint` | `1675249d-d3ea-466a-a822-289529d81b0f` | completed |
| `make dev-test FILTER=AgentProcessRegistryTests` | `8ce5b5db-2813-44ca-9113-e4e121796ee1` | 41 tests, 0 failures |
| `make dev-test FILTER=ClaudeHistoryLocatorTests` | `f8a3a346-5da1-4d8a-9af2-13050c1dfdf8` | 7 tests, 0 failures (new suite; not in the frozen ledger) |
| `make dev-test FILTER=AgentRecoveryReconciliationTests` | `5362e5fd-8f6e-4a1b-b789-eb3016ce6952` | 71 tests, 0 failures |

Not run: the full test lane, any live check, and a release build.

## Deviations and interpretations

- **Ambiguous at baseline is "recorded unsupported", not a send refusal.** The plan calls it a "new refusal … at both baseline and reconcile". At baseline I read that as refusing to take a baseline (recorded unsupported, ordinary send proceeds), because `.refused` there would block the user's own send. At reconcile it is a failure message.
- **The marker is required for the path rule** (the plan's "a marker-matched member"). The basename rule is unchanged and doesn't require the marker.
- **Unknown → writer upgrade** in discovery step 3 is a small extra beyond the plan's text. Without it, a member first classified unknown would never yield its home.
- **Not done:** a reconcile-path test for the ambiguous text; one would need the full reconcile harness. Both paths share `recoveryClaudeHistoryRoots`.

## Unresolved / to validate live

- `proc_pidpath` output for the native-installer CLI (plan unknown). The `versions/<v>` form is now matched, and `~/.local/bin/claude` already matched by basename. Only the live re-check shows which one the kernel reports.
- With no recorded home (for example, no shim and no `CLAUDE_CONFIG_DIR`), every Claude send pays one registry refresh plus the bounded locator scan of `~/.claude/projects`. This is bounded, as the plan accepts, but not measured.
- If two writer members of one family carry different `CLAUDE_CONFIG_DIR` values, which one is recorded depends on dictionary order. This predates the change; the shim sets the home only for its child.
- The spec's status line for Step 9-live-fixes (4) is the main agent's to update.

## Review fixes (round 0)

Reviews: A (`prompt-exports/oracle-chat-2026-10-28-211623-9fix-4-claude-home-r-06b6.md`) and B (`…-9b3e.md`). Owner fact relayed by the main agent: the rotator profiles' `projects` directories and `~/.claude/projects` are real directories, not symlinks.

1. **A P1, symlinks below the home.** `ClaudeHistoryLocator` now classifies each path with `lstat` (`FileSystem.kind` → absent / directory / regularFile / other / unreadable). Only a real `projects` directory, real project directories and a regular `<id>.jsonl` count. A symlinked `projects` directory, project directory or file is never followed and gives no hit. A candidate *home* may still be an alias (deduplicated by canonical path), which the reviewer allowed.
   - Test: `testSymlinksBelowTheHomeAreNeverFollowed` (real temp directories). Cases:
     - a candidate whose `projects` is a symlink to an external fixture holding the exact UUID file → nil
     - a symlinked project directory → nil
     - a symlinked file → nil
     - the real holder next to all three → unique
2. **B P1-2, a nested Claude can't supply the home.** Home extraction now goes through `AgentProcessRegistry.closestWriterHome`. It takes the root's own `CLAUDE_CONFIG_DIR` if it has one; otherwise the earliest-born writer whose nearest writer ancestor, following observed parent links, is the root. Classification is unchanged: the nested CLI is still a writer, so it still blocks.
   - Interpretation: I applied this to home extraction, not to the writer rule. It is also slightly stricter than "no writer ancestor": a writer whose parent chain doesn't reach the root (for example, reparented to launchd) supplies no home either.
   - Test: `testANestedClaudeStartedByAToolNeverSuppliesTheHome`. Shim (no home) → real CLI (home A) → bash → nested CLI (home B), all with the marker. Roles come out writer, unknown, writer; the home is A. A direct check of `closestWriterHome` with only the nested writer observed returns nil.
3. **A P2, unreadable is not absent.** `locate` returns a new `.uninspectable([URL])` when any candidate couldn't be inspected and fewer than two homes hit. "Couldn't inspect" covers: `lstat` failing with anything other than `ENOENT`/`ENOTDIR`, a `projects` listing that fails, or an unreadable project entry or file. Two hits are still `.ambiguous`.
   - The view model maps it to `RecoveryClaudeHistoryLocation.uninspectable`:
     - baseline: recorded unsupported, "Claude history location couldn't be checked"; the send is still allowed
     - reconcile: fails with the same sentence plus a period
   - Tests:
     - `testAnUninspectableCandidateMakesASingleHitNotUnique`, with an injected unreadable candidate, an unlistable one, and two hits plus one unreadable → ambiguous
     - `testBaselineRecordsUnsupportedWhenAFallbackCandidateCantBeInspected`, a real `chmod 000` `projects` next to the fixture home → `.unsupported(...)`, `admitsWrite`
4. **B P2-1, XCTest isolation.** In `recoveryClaudeLocatorHomes`, under DEBUG and with no locator override, the fallback returns no candidates whenever `AgentRecoveryStore.isProductionCompositionActive` is false (XCTest). It never reaches the developer's `~/.claude` or the runner's `CLAUDE_CONFIG_DIR`. Release is unchanged.
5. **B P2-2, cost before activation.** Checked read-only:
   - `captureClaudeDispatchBaseline` returns `.notCaptured` before any lookup unless `recoveryActionRunner.capturesDispatchBaselines(for:)`.
   - That requires `qualification.historyReconciliation && registrationActive() && activation.coversProvider(...)`.
   - With `AgentRecoveryActivation.production == .off`, `historyReconciliation` is false and no pair is registered.
   - So the shipped app does no refresh and no scan today.
   - Implemented anyway: the refresh now runs at most once per runtime. New `AgentProcessRegistry.claudeProviderHomesRefreshingOnce(conversationID:)` refreshes only when no home is recorded and some still-unresolved Claude runtime of that conversation hasn't been refreshed for its home before. A conversation with no runtime record never triggers a refresh.
   - Test: `testHomeLookupRefreshesAtMostOncePerRuntime`, which counts inventory calls: one pass, then none for the same runtime; a recorded home is returned without a pass.
6. **Missing tests.**
   - `testAnUnknownMemberUpgradesToTheWriterOnceItsEnvironmentIsReadable`: first refresh with the environment unavailable → `.unknown`, no home; second with marker and home → `.writer`, home set.
   - New DEBUG seam `test_recoveryRefreshHistoryRegistry`. `testBaselineRetriesTheRecordedHomeOnceThenCaptures` now records the home only after that seam runs and asserts exactly one refresh, so removing the refresh call fails it.
7. **P3s.**
   - Renamed to `testTheSingleHolderIsFoundWhetherItIsTheDefaultOrARecordedHome`.
   - `locateClaudeHistory` is now `@concurrent private nonisolated static`. The toolchain accepts it; `make dev-build` passed. `readClaudeHistory` is outside this step and left unchanged.
   - Corrected the report's "same root" and "no test reads `~/.claude`" claims above.

Not done, as instructed:
- B P1-1, file-identity dedupe. It is moot now that symlinked `projects` directories give no hit; copies stay ambiguous → unsupported.
- A reconcile-path ambiguity test.

### Validation (round 0)

| Command | Ticket | Result |
|---|---|---|
| `make dev-build` | `2f4e852a-5288-463c-9dad-177dda2367e9` | completed (`@concurrent` accepted) |
| `make dev-test FILTER=ClaudeHistoryLocatorTests` | `ef8e4f89-cd84-43ab-81bc-8377413a5f6f` | build aborted: the parallel worker's `AgentRecoveryStoreTests.swift` changed mid-build |
| `make dev-test FILTER=ClaudeHistoryLocatorTests` | `97665244-4264-4e30-9f4e-a42bcc9be665` | 9 tests, 0 failures |
| `make dev-test FILTER=AgentProcessRegistryTests` | `b7626cca-80ac-4b87-aeb1-8c23a76c1d56` | completed (test count not captured in my filter) |
| `make dev-test FILTER=AgentProcessRegistryTests` | `883f2ed6-a2d7-47b4-998d-25d96bf13722` | 44 tests, 0 failures |
| `make dev-test FILTER=AgentRecoveryReconciliationTests` | `e4924276-a8a3-456b-8a84-c4655fd503f6` | 72 tests, 0 failures |
| `make dev-lint` | `2792f2b8-91ca-4d60-81de-29c3424950ab` | completed |

Still open for the live re-check:
- what `proc_pidpath` returns for the real CLI
- whether the shim's child exists when the baseline's single refresh runs; if not, the locator is the path
- whether embedded ripgrep or other re-exec children show up as writers (B P3)
- send-path timing once activation is on

## Review fixes (round 1)

Reviews: A (`prompt-exports/oracle-chat-2026-10-28-213344-9fix-4-claude-home-r-7816.md`) and B (`…-a8bf.md`). Where this section and the round-0 section disagree with the earlier sections (home extraction order, the filesystem implementation, the refresh rule), they supersede them.

1. **A P1, an unknown ancestor is a barrier.** In `closestWriterHome`, walking up from a candidate writer, only a positively qualified `.tool` ancestor is traversed. Any `.writer` or `.unknown` member between the candidate and the root means no home is attributed, and the locator handles it. The nested CLI is still classified as a writer, so it still blocks.
   - New test `testAnUnknownAncestorBlocksANestedClaudesHome`:
     - pass 1: the outer CLI's environment is unavailable and the nested CLI is readable with home B → roles unknown, unknown, writer; no home
     - pass 2: the outer CLI is readable with home A → writer, unknown, writer; home A
   - The round-0 nested test (shim → A → bash → B → A) still passes.
2. **B P1-1, refresh retries.**
   - **Check (read-only):** discovery has no timer and no event for a new descendant. Passes run only on:
     - `start` (`AgentProcessRegistry.swift` ≈260)
     - `refreshRetryingStorage`, which is the user's Refresh and Check through `AgentRecoveryCoordinator.refreshRuntimeOwnership`
     - `previewStop` and `verifyAllFamiliesStopped`
     - exit events for identities a previous pass already watched (`installWatches` / `watchFired` → `requestRefreshFromEvent`, ≈700–729)
   - So after a pass that saw only the shim, only the shim is watched, and no later pass is guaranteed. I made the change.
   - **Change:** `claudeProviderHomesRefreshingOnce` now:
     - leaves `.reserved` runtimes out
     - counts lookup refreshes per runtime, capped at `maxHomeRefreshesPerRuntime = 3`
     - stops refreshing a runtime once any pass has observed a non-root writer of it with a readable environment and no `CLAUDE_CONFIG_DIR`. This uses the new `FamilyObservation.observedHomelessWriter`, recorded into `homeSettledRuntimeIDs` in `discoveryPass` ≈398.
   - **Test:** `testHomeLookupRefreshesUntilTheWriterIsSeenWithinTheCap` replaces `testHomeLookupRefreshesAtMostOncePerRuntime`. It covers:
     - a reservation → no pass
     - the shim alone → one pass and `[]`; then the child appears → the second lookup refreshes and returns the home; then a recorded home → no pass
     - a writer seen without a home → one pass, then none
     - the shim alone forever → exactly 3 passes
3. **B confirm, the root is a parent.** The root identity enters `membersByIdentity` deliberately in step 1 of `discoverFamily` (≈466–478, "the root (always a writer/launcher)"): as `.writer` when alive (with its observation, ≈472–473) or when its lifetime is unknown (≈478). It is removed only from the persisted member list (`.filter { $0.key != root }`, after step 3). So `parent(of:)` (≈642) finds it for the shim → CLI chain (`next == root`, ≈652). I left the code unchanged. A root that has exited is absent, and its child is reparented anyway, so that case gives no home and falls back to the locator by design.

Not done, as instructed (the main agent limited this round to the three items): B P2-1 (the root's own home wins, sibling writers disagreeing), B P2-2 (whether `isProductionCompositionActive` holds in a DEBUG app launch), B P2-3 (the live copy-count check), and B's P3s (locator and reader symlink rules, the "refused" doc wording, the `chmod` test when run as root).

### Validation (round 1)

| Command | Ticket | Result |
|---|---|---|
| `make dev-test FILTER=AgentProcessRegistryTests` | `2fbce2c5-540f-4cf2-bca6-751ccae2d568` | 45 tests, 0 failures |
| `make dev-test FILTER=ClaudeHistoryLocatorTests` | `99c44287-1aff-4844-8532-efcf7e2b6c52` | 9 tests, 0 failures |
| `make dev-test FILTER=AgentRecoveryReconciliationTests` | `e0e3bd94-786b-42fa-8735-400ec803e28e` | 72 tests, 0 failures |
| `make dev-lint` | `15f134f5-37d9-4afb-ae39-44f027a1470c` | completed |

## Review fixes (round 2, main-agent checked)

Reviews: A (`prompt-exports/oracle-chat-2026-10-28-213905-9fix-4-claude-home-r-1f56.md`) and B (`prompt-exports/oracle-chat-2026-10-28-213958-9fix-4-claude-home-r-f1fa.md`). Only the items below were applied.

1. **A P1: settlement uses the home-attribution ancestry rule.** The ancestry walk is now one helper, `AgentProcessRegistry.rootLinkedWriters(root:roles:observations:)`: observed non-root writers whose nearest writer ancestor is the root, walking up through `.tool` members only, earliest-born first. Both users go through it:
   - `closestWriterHome`, after the root's own home
   - `observedHomelessWriter` in `discoverFamily`

   A nested or uncertain-ancestry homeless writer therefore never adds its runtime to `homeSettledRuntimeIDs`.
   - New test `testANestedHomelessWriterNeverEndsTheHomeLookupRetries`, driven through lookups. The chain is shim → outer CLI (environment unreadable) → bash → nested CLI (marker, readable, no home).
     - First lookup: one pass, `[]`, roles unknown/unknown/writer.
     - Then the outer CLI becomes readable with home A. The next lookup runs another pass and returns `["/fixture/home-a"]`.
2. **B P3, docs and naming only.**
   - `claudeProviderHomesRefreshingOnce` is renamed `claudeProviderHomesRefreshingIfPending`. Its doc now says each lookup runs at most one pass and a runtime gets at most `maxHomeRefreshesPerRuntime` over its lifetime.
   - The view model's "at most once per runtime" comments are corrected.
   - The `RecoveryClaudeHistoryLocation` comments for `.ambiguous` and `.uninspectable` no longer say "refused". They now say the baseline is recorded unsupported (the send proceeds) and reconcile fails.
   - Earlier sections of this report that use the old method name refer to the same method.
3. **B's conditional P1 doesn't apply to the owner's setup.** B's concern was an unclassified process between the shim and the real CLI, which the unknown-ancestor barrier would turn into "no home ever". The main agent checked the live chain read-only: RepoPrompt → `node` (the shim, the runtime root) → `~/.local/bin/claude` (a direct child of the root) → bash.
   - The real CLI's parent is the root, so `rootLinkedWriters` accepts it directly and no barrier sits in between.
   - Whether the kernel path `proc_pidpath` returns is `~/.local/bin/claude` (basename rule) or the resolved `…/claude/versions/<v>` (native-installer rule), the CLI is classified as the writer, so the earlier `proc_pidpath` unknown no longer decides the outcome. The process listing shows the invoked path, not necessarily the kernel path.

### Validation (round 2)

| Command | Ticket | Result |
|---|---|---|
| `make dev-test FILTER=AgentProcessRegistryTests` | `b3821966-b2fd-46b4-b159-0ac93c84abe9` | 46 tests, 0 failures |
| `make dev-test FILTER=AgentRecoveryReconciliationTests` | `ed674bbd-597d-4015-8a18-b704f36742d8` | 72 tests, 0 failures |
| `make dev-lint` | `de0ea79e-51c5-4273-a89f-fa7ece5548ef` | completed |
