# 9-live fix 4 (Claude history location): OracleB review, round 2

Scope: read when the task touches where recovery finds a Claude conversation's history, Claude process classification in the process registry, or the Claude dispatch baseline.
Authority: Reference
Last-verified: 2026-10-28
Covers: the OracleB review (round 2) of the Step 4 diff, copied from its export; the fixes are in fix-9live-claude-home-worker.md


# Re-review (round 2, final): Step 4, O42 Claude history location

**Verdict: my P1-1 is fixed. No P0, no blocked send, and refreshes are bounded.** One new P1 depends on how the owner's processes are actually arranged. OracleA's unknown-ancestor barrier can leave the normal chain with no home if any unclassified process sits between the root and the real CLI. One `ps` check settles it before the live re-check.

As before, I reviewed only the diff.

## P1-1 (refresh spent before the real CLI exists): fixed

- **Reserved runtimes are skipped.** `.reserved` is excluded from `pending`, and the test asserts that no inventory pass runs.
- **A shim-only pass no longer ends the retries.** The test covers this: the shim alone returns `[]`, then the child appears and the second lookup returns `home-r`.
- **Refreshes are bounded three ways:**
  - each lookup runs at most one pass;
  - each runtime gets at most `maxHomeRefreshesPerRuntime = 3` lookup refreshes;
  - a runtime stops refreshing once a pass sees a non-root writer whose environment is readable but has no `CLAUDE_CONFIG_DIR` (`homeSettledRuntimeIDs`). Users without the rotator therefore pay for one pass per runtime, then none.
- **The cap won't run out in practice.** Under O44 the first send has no provider session ID, so it never does a lookup. Later sends follow a finished turn, when the real CLI already exists. Three attempts can't realistically all land while only the shim is running.

## New P1 (conditional): an unclassified process between the shim and the CLI means no home is ever recorded

**Evidence.** `nearestWriterAncestorIsRoot` only walks past ancestors whose role is `.tool`. Shells and similar processes don't qualify as tools in the Claude family: `testANestedClaudeStartedByAToolNeverSuppliesTheHome` shows `bash` with the marker classified as `.unknown`. So any unknown process in between stops the walk, for example:
- `/bin/sh -c` from a Node `spawn(..., {shell: true})`
- an `npx` or `node` wrapper
- the app launching through a login shell, if that shell doesn't `exec`

**Failure scenario.**
1. The tree is root → `sh` (unknown) → `claude/versions/<v>` (writer, home A).
2. `closestWriterHome` returns nil on every pass.
3. The runtime is never settled, because the CLI *has* a home. So three passes are spent, then the code falls through to the locator.
4. The locator searches recorded homes (none, since every runtime has the same tree), the app's environment and `~/.claude`. The rotator profile is never searched (D5), so the result is `.unknown`.
5. Every dispatch is recorded as unsupported. That is the original O42 symptom, now with no error to explain it. Sends still go through.

**Check first.** While a runtime is idle, run `ps -o pid,ppid,comm -g <pgid>` (or `pstree`) for the owner's rotator runtime. If the real CLI's parent PID is the root, this finding goes away.

**Smallest fix, if there is an intermediate process.** Make only the following ancestors stop the walk:
- a writer;
- an unknown member whose environment or path couldn't be read;
- an unknown member whose path is a native-installer Claude executable (that's the case OracleA's barrier is for).

Walk past any other unknown member whose environment and path are readable. Add a test with the chain shim → `sh` (unknown, readable) → CLI (home A) and expect home A. Keep `testAnUnknownAncestorBlocksANestedClaudesHome` passing unchanged.

## Other requested checks

| Risk | Result |
|---|---|
| Normal direct shim → CLI chain gets no home | **No.** The root is a key in `membersByIdentity` (step 1), so `parent(of:)` reaches it, and the test pins this. Only the case with a process in between (above) fails. |
| A send is blocked | **No.** `.unknown`, `.ambiguous` and `.uninspectable` all go to `recordUnsupported`. Only the existing `stillCurrent` check refuses. |
| Unbounded refreshes | **No.** At most one pass per lookup and three per runtime. A runtime with no home stops after one. The attempt counters reset on restart, which still keeps the total bounded. |
| A runtime is marked settled too early | **Rare (P3).** `observedHomelessWriter` looks at *any* non-root writer, not just the one closest to the root. A nested `claude` started with `CLAUDE_CONFIG_DIR` explicitly unset, while the outer CLI's environment can't be read yet, would stop retries for good. |

## P3 (brief)

- **Names and comments describe the old once-only refresh.** `claudeProviderHomesRefreshingOnce` and the `recoveryClaudeHistoryRoots` doc comment still say "at most once per runtime". Rename to something like `claudeProviderHomesRefreshingIfPending` and update the doc.
- **The `RecoveryClaudeHistoryLocation` doc still says "refused"** for `.ambiguous` and `.uninspectable`. At baseline both are recorded unsupported.
- **`homeRefreshAttempts` is never pruned.** It's small, but drop the entries when a runtime exits.

## Recommendations

1. Before the live re-check, capture the owner's real process tree. If anything sits between the root and `claude/versions/<v>`, apply the narrower barrier above and add the shim → `sh` → CLI test. If not, note in the report that the CLI is a direct child of the root.
2. Fix the "once" naming and doc comment, and the "refused" doc wording.
3. In the live re-check, also confirm:
   - the CLI's home is recorded on the second send (registry record `providerHome`);
   - no fourth refresh pass happens for a runtime;
   - send latency with activation on.
4. Otherwise the step is ready to merge from this review's side.