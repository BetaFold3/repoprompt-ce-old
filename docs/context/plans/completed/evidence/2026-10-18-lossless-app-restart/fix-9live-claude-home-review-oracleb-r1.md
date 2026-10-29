# 9-live fix 4 (Claude history location): OracleB review, round 1

Scope: read when the task touches where recovery finds a Claude conversation's history, Claude process classification in the process registry, or the Claude dispatch baseline.
Authority: Reference
Last-verified: 2026-10-28
Covers: the OracleB review (round 1) of the Step 4 diff, copied from its export; the fixes are in fix-9live-claude-home-worker.md




# Re-review (round 1): Step 4, O42 Claude history location

**Verdict: almost ready, but one conditional P1 needs a check or a small change before the live re-check.** No P0.

Most round-0 findings are fixed, and so are OracleA's P1 and P2. The new `.uninspectable` outcome doesn't block a send. The XCTest isolation is compiled only into DEBUG builds. The new P1 comes from the once-per-runtime refresh: in the owner's own setup (a shim plus a child it starts asynchronously), it can spend the runtime's only refresh before the real CLI exists.

I reviewed the diff only, not the repo. These parts are outside the diff, so I treat what's said about them as claims:
- how `membersByIdentity` and `observationsByIdentity` are built
- whether discovery runs periodically
- what `refresh()` does when a pass is already running
- `isProductionCompositionActive`
- `readClaudeHistory`

## Status of earlier findings

| Finding | Status | Evidence |
|---|---|---|
| B P1-1: dedupe by file identity | **Not done, and I accept that** (with one live check, see P2-3) | Real directories plus a refused symlinked `projects` mean a hard link is the only thing file identity would still merge. A copy stays `.ambiguous` and the baseline is recorded unsupported. The send is still allowed (`testBaselineRefusesAConversationFileFoundUnderTwoHomes` asserts `admitsWrite`). |
| B P1-2: a nested Claude supplies the home | **Fixed** (see the item to confirm below) | `closestWriterHome` only accepts a writer whose nearest writer ancestor is the root. `testANestedClaudeStartedByAToolNeverSuppliesTheHome` pins shim → CLI(A) → bash → CLI(B) and expects A. Ripgrep-style re-exec children of the real CLI are excluded the same way. |
| B P2-1: tests read the real `~/.claude` | **Fixed for tests** | `recoveryClaudeLocatorHomes` returns `[]` when `!isProductionCompositionActive`, inside `#if DEBUG`. See P2-2 for the dev-build side. |
| B P2-2: cost on the send path | **Fixed**, but the fix creates P1-1 | The activation gate (`.notCaptured` unless `capturesDispatchBaselines`) is a claim, but a plausible one. |
| B P2-3: unknown → writer test | **Fixed** | `testAnUnknownMemberUpgradesToTheWriterOnceItsEnvironmentIsReadable`. |
| B P3: refresh seam | **Fixed** | The home appears only after `test_recoveryRefreshHistoryRegistry` runs, and the test asserts `refreshes == 1` and `lookups == 2`. |
| B P3: `@concurrent`, test rename, report wording | **Fixed** | `@concurrent private nonisolated static func locateClaudeHistory`. Some report sections are still stale (P3). |
| A P1: a symlinked `projects` escapes the search | **Fixed** | `lstat` is applied at the `projects`, `<project>` and file levels. The test uses real temp directories and covers all three, plus the real holder found alongside them. |
| A P2: unreadable treated as absent | **Fixed** | Only `ENOENT`/`ENOTDIR` count as absent. An unlistable `projects` or an unreadable entry gives `.uninspectable`. Two hits still give `.ambiguous`. Both the injected-filesystem test and the real `chmod 000` test pass. |

### Item to confirm: `closestWriterHome` in the normal shim → CLI chain

`parent(of:)` looks for the parent only among `roles.keys`, which is `membersByIdentity`. It never searches `observations`. So the shim → CLI chain resolves to `true` **only if the root identity is a key of `membersByIdentity`**. If it isn't, the result is:
- `parent(of: cli)` returns nil
- the CLI is rejected
- no home is recorded in exactly the case O42 targets

The persisted record shows `members == [831]`, without the root. That means the root is in the in-memory map and is filtered out when saved, or else the two tests can't pass. The report says 41 tests became 44, which matches the three new registry tests, so they probably do pass.

**Check:** one grep showing the root is inserted into `membersByIdentity` (and `observationsByIdentity`) before step 3. If it's only there by accident, search `observations.keys` in `parent(of:)` and treat the root as a valid parent explicitly.

## P1

### P1-1 (conditional): the once-per-runtime refresh can be spent before the real CLI exists, so the owner's rotator runtime may never record its home

**Evidence.**
- `claudeProviderHomesRefreshingOnce` adds every pending runtime to `homeRefreshedRuntimeIDs` *before* `await refresh()`. It does this whatever the pass actually saw.
- `pending` includes `.reserved`, a runtime that has no process yet.
- The rotator shim sets `CLAUDE_CONFIG_DIR` only for the child it starts asynchronously.

**Failure scenario.**
1. A send starts a fresh runtime, and the baseline is captured within milliseconds of the spawn (or while the runtime is still `.reserved`).
2. The one refresh sees only the `node` shim, and the runtime is marked as refreshed.
3. The locator searches the recorded homes from *other* runtimes, the app's environment and `~/.claude`. If this profile was never recorded and the file isn't in `~/.claude`, the result is `.unknown` and the baseline is recorded unsupported.
4. Every later send on this runtime skips the refresh. Unless some other discovery pass runs, the home is never recorded, and every dispatch stays unsupported. That is the original live symptom.

A second way to hit this: if `refresh()` merges into a pass that is already running and started before the child existed, the one allowed refresh returns stale results.

This is **P2 instead of P1** if discovery also runs on a timer or on process events after spawn. In that case a later pass records the home anyway. Check `refreshTask` and `watchGeneration` to see what triggers a pass.

**Smallest fix.**
- Leave `.reserved` runtimes out of `pending`.
- Mark a runtime as refreshed only when the pass actually observed a non-root writer for it with a readable environment and no home. That's the case where another refresh can't help, which was my round-0 suggestion.
- If you want a hard limit, cap retries at 2 or 3 per runtime.

**Test.** First lookup: only the shim exists, so the result is `[]`. Then add the `versions/<v>` child with a home. The second lookup should refresh and return the home. The current `testHomeLookupRefreshesAtMostOncePerRuntime` asserts the opposite and would need to change.

## P2

### P2-1: the root's own home always wins, and among sibling writers the earliest-born wins

- **The root's environment always wins.** `closestWriterHome` returns the root's `CLAUDE_CONFIG_DIR` whatever the root's role. Suppose the app passes an inherited `CLAUDE_CONFIG_DIR` to the shim (for example, the app was launched from a shell that had it set) and the shim then overrides it for the real CLI. The recorded home is then the app's, not the one the CLI writes to. If that home also holds a stale copy of `<id>.jsonl`, the reader reads the wrong file consistently, and the file-identity guard doesn't catch it, because baseline and reconcile both use that same stale file.
  - **Fix:** prefer the closest non-root writer's home when the root isn't a writer. If the two disagree, record no home.
- **Sibling writers.** If the rotator relaunches its child under another profile within one runtime, or an old child and a new child briefly overlap, "earliest-born" plus a home that never changes once set keeps the old profile.
  - **Fix:** if root-linked writers disagree, record no home (or clear it). That was the alternative in round 0.
  - **Live check:** whether the rotator ever relaunches its child within one runtime.

### P2-2: in DEBUG builds, the isolation depends on `isProductionCompositionActive` being true in a normal app launch

The guard isn't an XCTest check. It's a composition flag. The live re-check almost certainly runs a `make dev-build` (DEBUG) app. If that flag is false there, for example because it tracks activation rather than "the app's composition ran", the locator gets no candidates. O42 would then look broken live while release behaves differently.

**Fix:** confirm that the flag is set at app composition, independent of activation, or switch to an explicit XCTest check (`NSClassFromString("XCTestCase") != nil` or the existing test-environment helper).

### P2-3: whether copied history is common still needs one live check

The main agent confirmed the directories are real. Copies are what decide whether ambiguity becomes the *usual* fallback result for the owner.

Run `ls ~/.claude/projects/*/<id>.jsonl ~/.claude-rotator/profiles/*/projects/*/<id>.jsonl` for one conversation that has been resumed across profiles. If the file shows up more than once, the fallback will always be unsupported for such conversations. That is acceptable only if P1-1 makes sure the recorded-home path is the one normally taken.

## P3 (brief)

- **Stale report text.** These parts of the report contradict the code:
  - section (a): "Home extraction is unchanged: first writer…"
  - section (b): "three cases", "`nonisolated static async`", "`await registry.refresh()` once"
  - section (c): "`.live` uses `FileManager` resource values" (it now uses `lstat`)
  - Unresolved: the "dictionary order" note

  Correct them to match round 0.
- **Locator and reader follow different symlink rules.** The locator now ignores symlinked project directories and files, but `readClaudeHistory` searches the chosen `projects` root using its own rules. If it follows symlinks, it could pick or count a file the locator ignored. Confirm the reader uses the same `lstat` rules, or pass it the exact file the locator found.
- **The `RecoveryClaudeHistoryLocation` doc comment says "refused"** for `.ambiguous` and `.uninspectable`. At baseline both are *recorded unsupported*. Reword.
- **The `chmod 000` test fails when run as root**, because the listing succeeds and the result is `.committed`. Skip it when `getuid() == 0`.
- **No reconcile-path test** for `.ambiguous` or `.uninspectable` text. This was accepted as a decision; both cases share `recoveryClaudeHistoryRoots`.

## New-risk checks requested

| Risk | Result |
|---|---|
| `.uninspectable` blocks a send | **No.** At baseline it is `recordUnsupported` with `admitsWrite` asserted (real `chmod 000` test). At reconcile it is a failure message only. |
| Once-per-runtime refresh skips a needed refresh | **Yes, conditionally:** P1-1. |
| XCTest isolation leaks into release | **No.** It's entirely inside `#if DEBUG`, and release always builds the candidates. Leaking into the DEBUG *app* is P2-2. |
| `closestWriterHome` picks no home in shim → CLI | **Not if the root is a member key.** The tests pin this; confirm the dependency (item above). The shim exiting after it starts the child (reparenting to launchd) also gives no home; that's by design and falls back to the locator. |
| Non-Claude writer, or a writer without the marker | Still guarded: Claude family, `isClaudeNativeInstallerExecutable`, and `runtimeID` matching the marker. The Codex case and the no-marker case are both tested. |
| Test hooks in release | All three seams are declared and used only under `#if DEBUG`. |

## Recommendations

1. **P1-1:** leave `.reserved` runtimes out, mark a runtime as refreshed only once a pass has observed its non-root writer, and change the once-per-runtime test into "the shim alone, then the child: the second lookup records the home". If discovery already runs a pass after every spawn, record that fact in the report and downgrade to P2.
2. **Confirm** that the root is a key of `membersByIdentity` when `closestWriterHome` runs. Otherwise make `parent(of:)` accept the root explicitly.
3. **P2-1:** a non-root writer's home wins over the root's environment when the root isn't a writer, and record no home when root-linked writers disagree.
4. **P2-2:** confirm `isProductionCompositionActive` is true in a normal DEBUG app launch before the live re-check, or switch to an XCTest check.
5. **Before the live re-check:**
   - run the copy-count `ls` (P2-3)
   - record what `proc_pidpath` returns for the real CLI
   - check whether the shim's child exists when the baseline's refresh runs
   - check whether the rotator relaunches children within one runtime
   - time the send path with activation on
6. **P3s:** update the stale report sections, align the locator's and reader's symlink rules, fix the "refused" doc comment, and skip the `chmod` test when running as root.