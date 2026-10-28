# 9-live fix 4 (Claude history location): OracleB review, round 0

Scope: read when the task touches where recovery finds a Claude conversation's history, Claude process classification in the process registry, or the Claude dispatch baseline.
Authority: Reference
Last-verified: 2026-10-28
Covers: the OracleB review (round 0) of the Step 4 diff, copied from its export; the fixes are in fix-9live-claude-home-worker.md




# Review: Step 4, O42 Claude history location (round 0)

**Verdict: needs changes before the re-check. No P0.** The core design is sound:
- The new path rule needs a Claude family and the record's own marker.
- The locator is bounded and checks for a UUID before it touches the filesystem.
- An ambiguous location never blocks a send.
- Every test hook is DEBUG-only.

Two P1s remain, and both are about choosing the home. The UUID filename means neither one can make recovery read *another conversation's* history. What they do is make O42 fail without a clear cause in the owner's rotator setup.

I reviewed the diff only; I couldn't open the repo. These parts sit outside the diff, so what I say about them is inferred from the report and plan:
- how `discoverFamily` extracts the home ("first writer with `CLAUDE_CONFIG_DIR`, sticky")
- the "two-writer rule"
- `readClaudeHistory`'s check on the cursor's file identity

## P1

### P1-1: The fallback search counts one shared or copied history file as "ambiguous". For rotator users the fallback is likely the usual path.

**Evidence.**
- `locate` removes duplicate *homes* by canonical path, but counts a hit once per distinct home.
- `--resume <id>` has to work across rotator profiles. So the rotator very likely either symlinks `profiles/*/projects` to one shared directory, or copies `<id>.jsonl` between profiles.
- The candidate list includes every recorded Claude home, across all conversations.
- The refresh-and-retry probably misses the home for a just-spawned runtime. The shim (`node`) starts its real-CLI child asynchronously, so a refresh run at baseline time can see only the shim, and then the code falls through to the locator.

**Failure scenario.**
- Profiles A and B are both recorded from earlier runtimes. `A/projects` and `B/projects` both point to `~/.claude-rotator/shared/projects`.
- The locator lists `A/projects` and finds the file, then lists `B/projects` and finds it again: `.ambiguous`.
- Every fallback baseline is recorded unsupported, so Reconcile and Continue stay refused for that dispatch. That is the same live symptom O42 was meant to fix.
- In the copy layout, if the profile holding the live copy was never recorded, a stale copy can be the "unique" hit. The cursor's file-identity guard should then fail Reconcile rather than import from the wrong file. That guard isn't in this diff, so it needs confirming.

**Smallest fix.** Decide ambiguity by file identity, not by home:
1. Resolve each hit's canonical path (or its `fileResourceIdentifierKey`).
2. Treat hits that resolve to the same file as one hit, and return the first home that reached it.
3. Add one locator test with two homes whose `projects` is a symlink to one directory: expect `.unique`.

**Before the re-check:** run `ls -la ~/.claude-rotator/profiles/*/ | grep projects` and confirm which layout the rotator uses.

### P1-2: A nested native-installer Claude started by a tool becomes a writer, and its home can be recorded for the session

**Evidence.**
- The new rule makes any member at `…/claude/versions/*` that carries the marker a `.writer`.
- Every descendant of the session's CLI inherits `RPCE_RUNTIME_ID`.
- Suppose a Bash tool runs `claude -p …`, which is common in agent orchestration, and here it goes through the rotator shim. Its real CLI then has the marker and possibly a *different* `CLAUDE_CONFIG_DIR`, because the rotator picks a profile per launch.
- Home extraction takes "the first writer with `CLAUDE_CONFIG_DIR`", in dictionary order. Swift randomizes dictionary order per process. A recorded home is kept once set.
- The report calls this "pre-existing", but before this change the nested CLI's basename was its version string, so it was `.unknown`. This change makes the case reachable.

**Failure scenario.**
1. The session's CLI is first seen while its own environment is unreadable, or while only the shim exists (see P1-1).
2. A later discovery pass runs during a tool call that started a nested Claude under profile B.
3. B is recorded as `providerHome` and kept.
4. `claudeProviderHomes(conversationID:)` now returns B, and the recorded path skips the locator. The baseline is captured as "file absent" in B, and Reconcile later finds nothing.

The filename is the conversation's UUID, so this is a failure, not a leak of another conversation's data. But it is the "wrong home chosen" class you asked about, and it can't be reproduced reliably. It could also trip the two-writer rule, which I couldn't see.

**Smallest fix (pick one).**
- Apply the path rule only to a member that has no writer among its ancestors. The real CLI's parent is the shim; the nested CLI's ancestor is the real CLI.
- Or set `providerHome` only when all writer members report the same `CLAUDE_CONFIG_DIR`, and set none if they disagree.

Add a registry test: root shim → real CLI (home A) → bash → nested CLI (home B), all with the marker. Expect home A.

## P2

### P2-1: The report's claim "no test ever reads the real `~/.claude`" doesn't hold

`recoveryClaudeLocatorHomes` only returns `[]` when `test_recoveryClaudeHistoryHomes` is set. Take any existing test that:
- reaches `captureClaudeDispatchBaseline` or reconcile with neither override set,
- has a nil registry under XCTest, and
- uses a UUID conversation ID.

That test now calls `candidateHomes(recorded: [], environment: <test runner env>, userHome: <real home>)`. It lists the developer's real `~/.claude/projects`, and also the runner's own `CLAUDE_CONFIG_DIR` when the tests run inside a Claude session. The result is still `.unknown`, so the tests pass, but the isolation is broken.

**Fix.** Under `#if DEBUG`, when running under XCTest with no locator override set, return `[]`. Then grep for Claude baseline and reconcile tests that set neither override.

### P2-2: Every send without a recorded home pays for a registry refresh plus a `projects` scan, on the send path

Users without the rotator and without `CLAUDE_CONFIG_DIR` never get a home recorded. So *every* Claude send awaits a full discovery pass and a listing of `~/.claude/projects` before dispatch. Nothing has measured this.

The longer await also widens the window in which `stillCurrent` can fail. On the baseline path that returns `.refused(recoveryActionStaleText)`.

Also check whether this code runs at all before the activation switch. If baseline capture isn't gated on activation, the shipped app pays this cost today.

**Fix.** Refresh at most once per runtime ID, or skip the refresh when that runtime already has an observed writer without a home, since a refresh can't help then. Gate on activation if it isn't already.

### P2-3: The unknown → writer upgrade has no test

This upgrade is the deviation the report justifies ("a member first seen unreadable later becomes the writer"), but no test covers it.

**Fix.** Add a registry test: the first refresh sees the `versions/<v>` member with `.unavailable` environment, so it stays `.unknown` with no home. The second refresh sees `.available` with the marker and a home, so it becomes `.writer` and its `providerHome` is set. This also covers the missing "path rule with an unreadable environment" case.

## P3 (cheap)

- **Refresh not pinned by a test.** In `testBaselineRetriesTheRecordedHomeOnceThenCaptures` the refresh is skipped because the override is set. Deleting the `recoveryRefreshHistoryRegistry()` call would still pass. Add a `test_recoveryRefreshHistoryRegistry` closure seam and make the second lookup depend on it having run.
- **"Baseline and reconcile read the same root" is only true at a single moment.** They resolve at different times. For example, baseline uses the locator and reconcile later uses a newly recorded home. In that case the file-identity guard is the real protection. Reword the report and confirm the guard rejects a mismatch.
- **Off-main execution depends on build settings.** `nonisolated static … async` runs off the main actor only without `NonisolatedNonsendingByDefault` (Swift 6.2 approachable concurrency). Mark it `@concurrent`, or confirm the setting, for both this wrapper and `readClaudeHistory`.
- **Misleading test name.** `testTheDefaultHomeIsUsedOnlyWhenNoRecordedHomeHoldsTheFile` suggests the recorded home takes precedence. The locator has no precedence; the second half just has one holder. Rename it.
- **No reconcile-path tests.** There's none for the ambiguous text or for the fallback (the report admits this).
- **Validate live: embedded ripgrep.** I believe, but haven't verified, that native Claude builds run their embedded ripgrep by re-executing their own binary. If so, those short-lived children would also become writers (with the same home). Check with `ps` during a Grep tool call, and check how the two-writer rule treats them.

## Checked and fine

| Concern | Finding |
|---|---|
| Non-Claude writer | Guarded by `isClaude(record.family)` and a marker match on an `.available` environment; the Codex case is tested. |
| Unrelated Claude-named paths | Need the marker, so only descendants qualify. |
| Release-reachable hooks | `test_recoveryClaudeHistoryLocatorHomes` is declared and used only inside `#if DEBUG`. |
| Unbounded filesystem access | No. A UUID check runs before any filesystem call (tested with a counting fake), there's one listing per home with no recursion, symlinked project directories are skipped, and only regular files count. |
| Ordinary send blocked | No. Ambiguous at baseline is recorded unsupported, and the test asserts `admitsWrite`. |
| Main-thread blocking | The scan runs in a nonisolated async wrapper and the refresh runs on the registry actor (see the P3 note). |

## Deviations

- **Ambiguous at baseline recorded as unsupported, not refused: agree.** A `.refused` at baseline would block the user's own send, which the plan forbids elsewhere. The plan's "refusal" fits Reconcile only.
- **Unknown → writer upgrade: agree.** It's needed for the "path or environment unreadable at first sight" case, and nothing ever demotes a member. It isn't the source of P1-2: a nested CLI is a writer at first sight anyway. It just needs the P2-3 test.

## Recommendations

1. **P1-1:** decide ambiguity by canonical file identity, add the symlinked-`projects` test, and check the rotator's real profile layout before the live re-check.
2. **P1-2:** apply the native-installer writer rule (or home extraction) only to the writer closest to the root, or record no home when writers disagree. Add the nested-Claude test.
3. **P2-1:** close the test-isolation gap: no real-home candidates under XCTest unless the locator override is set.
4. **P2-2:** refresh at most once per runtime, confirm the path is gated on activation, and time the send-path cost in the live re-check.
5. Add the unknown → writer upgrade test (P2-3) and a refresh seam test (P3). Correct the "same root" and "no test reads `~/.claude`" claims in the report.
6. In the live re-check, record:
   - what `proc_pidpath` returns for the real CLI
   - whether the shim's child exists when the baseline's refresh runs
   - whether ripgrep or other children appear as writers