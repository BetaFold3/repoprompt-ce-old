# F1 deferred-start test regression bisect
Scope: read when the task touches the intermittent failure of testClaudeDeferredStartEndedDuringPreparationSettlesNotHandedOffAndSignals or awaiting recovery terminal evidence in tests.
Authority: Reference
Last-verified: 2026-10-28
Covers: AgentProviderHandoffTests.swift, the first bad commit's changed files

## Result in one paragraph

There is no first bad commit. The test is flaky: it has raced since it was added in 7b436eba ("Hold scheduled follow-ups until their runner settles (restart fix F1)"). It reads the durable record after awaiting only the lane's *delivery*-evidence writes. The run's *terminal* evidence is a separate, unawaited, two-step write: the run attempt first, then its terminal. When the test's read lands between those two steps, it sees one run attempt with `terminal == nil`, which is exactly the line-659 failure. Every commit tested passes in a clean worktree, both alone and with the whole suite, HEAD included. The failures come from runs under heavier load or with more tests in the run: the full suite and multi-suite filters. A 300 ms delay injected between the two steps reproduces the failure on every run, in all three cases. With the delay kept, the test passes once it awaits the terminal-evidence tail. 6f8d1edb and 81e9cf67 are not the cause.

## Commits tested

All runs used `make dev-test` in a detached worktree at `~/workspace/rpce-bisect-f1` (now removed). The conductor accepted the `Suite/test` filter form. Job logs are under `~/Library/Application Support/RepoPrompt CE/Conductor/ae6d85c7eb530efb228e8c7af2e5326fe3ad26c9c1468977af16a31efab2b16c/jobs/`.

| Commit | Filter | Result | Job log |
|---|---|---|---|
| 71b23427 | single test | pass (0.159 s) | `27bf33f3-54ab-4a66-a669-39f5444966c2.log` |
| 6f8d1edb | single test | pass (0.115 s) | `f18609e4-2150-4aa3-9c12-d79a2d870bef.log` |
| a1131d5d | single test | pass (0.132 s) | `aa681ded-020c-4014-8e2d-2f97e91969ef.log` |
| fbf5777d (HEAD) | single test | pass (0.108 s) | `42119e34-70c0-4bfd-b210-1a081ea036e9.log` |
| fbf5777d (HEAD) | `AgentModeRunServiceLifecycleTests` (237 tests) | pass, 0 failures | `31e15040-27b7-44b3-ae4f-37bae74c5872.log` |
| fbf5777d + 300 ms delay (temporary) | single test | **fail**: line 659 for `acquire-failed`, `cancelled-userCancel` and `cancelled-appQuit`; lines 661–662 for appQuit | `f6e9bd69-1138-45be-a7ed-adb551db94a7.log` |
| fbf5777d + delay + test awaits `settleEvidenceWrites()` (temporary) | single test | pass (1.132 s) | `8c99b1d9-2898-4c4a-afeb-0f1af0f12968.log` |

I did not run the code between a1131d5d and HEAD separately. `git diff --stat a1131d5d fbf5777d -- Sources Tests Packages Package.swift Package.resolved` is empty, because 8263d7da, 34f3dd3e, 530cbc09 and fbf5777d change only scripts and docs. I did not run 7b436eba; its source is checked under "Since when" below.

### Historical runs of this test (all conductor job logs on this machine)

Collected by searching every `Conductor/*/jobs/*.log` for this test's result line:

| Time | Tree | Filter | Result |
|---|---|---|---|
| 10-26 17:24–18:50 (7 runs) | rp-agent-7b243a25 and one other | various | pass |
| 10-26 20:00, 20:27 | ws5-helper-exit-loss (base cea449e5 + uncommitted work) | MCP watchdog/helper-exit suites (+ lifecycle) | pass |
| 10-26 20:53 | same ws5 tree | MCP watchdog/helper-exit suites | **fail**, `cancelled-appQuit` at 659/661/662 (`bf9df36f…/jobs/e193ae08….log`) |
| 10-26 20:55 | same ws5 tree | `MCPToolExecutionWatchdogTests\|MCPHelperExitRunConnectionLossTests\|AgentModeRunServiceLifecycleTests` | **fail**, `acquire-failed` at 659 (`bf9df36f…/jobs/2827361c….log`) |
| 10-26 20:57 | same ws5 tree | same as 20:53 | pass |
| 10-27 14:28 | /private/tmp/rpce-baseline | `AgentModeRunServiceLifecycleTests` | **fail** at 659 (`b9a619ee…/jobs/0d72c6b2….log`), then **pass** the same minute (`1cb158c0….log`) |
| 10-27 15:52–18:11 (8 runs) | main checkout | various | pass |
| 10-28 13:05 | main checkout | full suite (8114 tests) | **fail** (`82430cd6…/jobs/fa33f075….log`) |
| 10-28 13:08 | main checkout | `AgentModeRunServiceLifecycleTests` | pass (`82430cd6…/jobs/e840d56c….log`) |
| 10-28 13:12 | main checkout | 13-suite filter (612 tests) | **fail** (`82430cd6…/jobs/dbc749d2….log`) |

On the same tree, the test fails and passes within minutes. The 10-26 failures came before 6f8d1edb was committed (10-27 19:11). In the main checkout the lifecycle suite alone passed at 13:08; I found no main-checkout job where the test failed when run alone.

## First bad commit

None. The flaky assertion has been in the test since **7b436eba**, the commit that added it; the test file is byte-identical since then (`git diff --quiet 7b436eba HEAD -- …AgentProviderHandoffTests.swift`). No commit in 7b436eba..HEAD turned a passing test into a failing one. The suspects 6f8d1edb and 81e9cf67 both pass in a clean tree and do not touch the evidence-write path.

## Root cause

### The race (verified by source reading and the delay experiment)

1. The acquire-failed case: the armer returns `false` (`AgentProviderHandoffTests.swift:596-600`, `return cancels` at 599). `MCPBootstrapLease.acquire()` then cancels and returns `false` (`Sources/RepoPromptAgentCore/MCP/MCPBootstrapLease.swift:316-324`). The runner calls `handleAcquireFailure` (`Sources/RepoPromptAgentCore/AgentMode/Runtime/Runners/ClaudeIntegratedAgentModeRunner.swift:121-131`). That records no handoff and commits a `.cancelled` terminal through the barrier (`ClaudeIntegratedAgentModeRunner.swift:807-831`).
2. `noteNoHandoff` posts `agentRecoveryDeliveryEvidenceDidSettle` before the commit starts (`AgentRecoveryCoordinator.swift:3250-3264`). That fulfils the test's `settled` expectation (`AgentProviderHandoffTests.swift:626`, awaited at 636).
3. The barrier calls `lane.recordTerminalEvidence(revision, …)` and does **not** await the task it returns (`Sources/RepoPromptAgentCore/AgentMode/Runtime/AgentRunTerminalCommitBarrier.swift:394`).
4. `recordTerminalEvidence` (`Sources/RepoPromptAgentCore/AgentMode/Runtime/Recovery/AgentRecoveryCoordinator.swift:3134-3161`) is a `@MainActor` task chained on `terminalEvidenceTail`. It makes two separate store transactions: `ensureRunAttempt` (line 3143), which creates the run attempt with no terminal (no earlier writer created it, because `attachRunAttempt` is never reached on this path), and then `recordRunTerminal(commit)` (line 3153).
5. The test waits for `!session.runState.isActive` and `agentTask?.value`, then reads intents and attempts. Then it calls `fixture.lane.deliveryEvidenceWritesSettled()` (`AgentProviderHandoffTests.swift:653`). That method awaits only `pendingDeliveryEvidenceWrites` (`AgentRecoveryCoordinator.swift:3268-3272`), and this path has none. It does **not** await `terminalEvidenceTail`; `settleEvidenceWrites()` does (`AgentRecoveryCoordinator.swift:3276-3279`).
6. The test reads the record at `AgentProviderHandoffTests.swift:654`. If the terminal task has finished `ensureRunAttempt` but not yet `recordRunTerminal`, `runAttempts.count == 1` passes (line 657) and `runAttempts.first?.terminal` is `nil`, so line 659 fails. The comment above line 653 ("once every evidence write of the terminal … has landed") states the intent, but the call does not deliver it.

### Why it usually passes and why load matters (inferred)

On an idle machine, the two terminal-evidence transactions usually finish while the test is suspended in its earlier store reads (`fixture.intent`, `fixture.attempts`, lines 645 and 647). Under the full suite or many suites, more work competes for the main actor and the store actors. That widens the gap between steps 4a and 4b relative to the test's reads, so the read sometimes lands inside it. The cancel cases usually pass because `cancelRun` adds more suspension before the read; they are not immune (10-26 20:53 failed on `cancelled-appQuit`, and the delay run failed all three). I did not instrument the scheduler to prove this ordering; it follows from the code and the observed flake pattern.

### Delay experiment (verified)

In the bisect worktree only, I wrapped the `recordRunTerminal(commit)` call at `AgentRecoveryCoordinator.swift:3153` in a closure that first sleeps 300 ms. That deterministically produced the reported failure (job `f6e9bd69…`). Keeping the delay and changing the test's line 653 to `await fixture.lane.settleEvidenceWrites()` made it pass (job `8c99b1d9…`). I reverted both edits and removed the worktree.

## Since when (verified by `git show 7b436eba:…`)

At 7b436eba:
- `recordTerminalEvidence` already makes the same two-step write: `ensureRunAttempt` at line 3014, `recordRunTerminal(commit)` at line 3021, and the tail assigned at line 3027.
- The barrier already fires it without awaiting (`AgentRunTerminalCommitBarrier.swift:394`).
- `deliveryEvidenceWritesSettled` and `settleEvidenceWrites` both exist (lines 3136 and 3144).
- The test already calls `deliveryEvidenceWritesSettled()` at 653 and asserts at 659.

So the race exists from the commit that added the test. I did not run 7b436eba itself; a single clean run would very likely pass, like every other clean run here, and so would prove nothing.

## Suggested minimal fix direction (not implemented)

Test-only: at `AgentProviderHandoffTests.swift:653`, await `fixture.lane.settleEvidenceWrites()` instead of `deliveryEvidenceWritesSettled()`. It awaits the delivery writes and then the terminal-evidence tail, which is what the comment above the line already claims. The delay experiment showed this is enough. No product change is needed: production readers that need terminal evidence already use `settleEvidenceWrites()`, for example shutdown at `AgentModeViewModel+Shutdown.swift:521` and `prepareForShutdown` at `AgentRecoveryCoordinator.swift:2704`. Worth checking during the fix: other recovery tests that read `runAttempts[].terminal` right after a run ends without awaiting the terminal tail. I did not survey them.
