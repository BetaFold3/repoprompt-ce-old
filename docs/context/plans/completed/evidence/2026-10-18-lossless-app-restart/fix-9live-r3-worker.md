# 9-live R3 fix: a later Claude tool result no longer rewrites a restored bash row
Scope: read when the task touches restored bash tool rows or the Codex bash reconcile on Claude sessions.
Authority: Reference
Last-verified: 2026-10-28
Covers: the R3 source and test changes

Diagnosis: `diag-9live-r3-rewrite-worker.md`.

## Changes

Round 0 reverted the backstop (item 2) and its test. See "Review fixes (round 0)" for the current state.

1. **Primary gate.** `CodexAgentModeCoordinator.reconcileCodexCommandExecutionRunningUpdate` (`CodexAgentModeCoordinator.swift:9823-9826`) now returns at once for `session.selectedAgent.usesClaudeNativeRuntime` (Claude Code, GLM, Kimi, custom Claude-compatible).
   - The guard lives in the function, so it covers both view-model call sites: the generic `tool_result` path (`AgentModeViewModel.swift:19722`) and the Claude live-transcript path.
   - The live-transcript call (formerly `AgentModeViewModel.swift:20377`) was Claude-only and is now dead code, so it was removed and replaced by a one-line comment.
   - The coordinator's own Codex call sites (`:6378`, `:7960`) are unaffected.
2. **Backstop (reverted in round 0).** `bashTranscriptItemIndex` (`CodexAgentModeCoordinator.swift:8481-8492`) keeps its args-signature fallback. When the incoming args are empty (signature `bash\n`), it now skips rows that are finished (`isTerminalBashTranscriptItem`).
   - **Chosen: skip finished rows.** "Empty args never match" would also stop args-less Codex updates from finding an unfinished args-less row (a running row or a pending call). Codex may rely on that, and it is not the bug.
   - **What it protects.** A finished row can only lose its recorded outcome when an unidentified result anchors to it, so it is never adopted.
   - **What still happens instead.** With no unfinished match, the existing `createAnchorIfNeeded` path appends a fresh anchor row. Calls with args, an invocation ID or a process ID behave exactly as before.
3. **Tests** in `CodexAgentModeCoordinatorLivenessTests` (`:1602-1669`, helper `restoredInterruptedBashRow` at `:2647`):
   - `testLaterClaudeBashResultDoesNotRewriteRestoredInterruptedBashRow`: covers the incident path end to end through `test_handleStreamResult`. It sets up a Claude session with a restored, args-less, cancelled `Bash` row, then sends a live `tool_call` with args and a `tool_result` with no args and `go\ndone`. It checks:
     - the restored row is byte-identical and still saves as `cancelled`;
     - only the new row holds `go\ndone`;
     - there is no extra anchor row (this pins the primary gate, because the backstop alone would append one);
     - no live bash state is left.
   - `testArgslessBashCompletionDoesNotAdoptTerminalBashRow` (deleted in round 0): the backstop on a Codex session. An args-less, unidentified plain-text completion leaves the finished row untouched.
   - Both tests failed before the fix: the restored row was overwritten, and the Claude case had no separate anchor.

## Other providers

- **ACP (OMP, OpenCode, Cursor).** ACP still runs the reconcile, and no change was made for it. `ACPProviderSupport.normalizeToolCallUpdate` (`ACPProviderSupport.swift:247-290`) emits `tool_result` with `{"status":"running"}` for `in_progress`/`pending`. For an ACP bash tool, that reaches the reconcile's running-update/live-state path (keyed by the args signature), and the later `completed` result finalizes it. No test covers this, so I could not rule out a dependency, and I kept it. ACP results carry `rawInput` args, so the empty-args case is rare there; if it happens, the backstop covers it.
- **Pi.** No Pi native provider exists in the tree yet, so nothing depends on this path.
- The bash liveness poll (`updateBashLivenessTaskState`) is already limited to `.codexExec`.

## Validation

| Command | Ticket | Result |
|---|---|---|
| `./conductor test --filter 'CodexAgentModeCoordinatorLivenessTests/test(LaterClaude…|ArgslessBash…)'` before the fix (the regex needs quoting, which `make dev-test FILTER=` doesn't do) | (first run) | 2 tests, 3 failures (reproduced) |
| `./conductor test --filter CodexAgentModeCoordinatorLivenessTests` | `65f4b744-7a66-4d74-a003-425c9750ab2c` | 62 tests, 0 failures |
| `./conductor test --filter 'ClaudeLiveTranscriptQualificationTests\|AgentModeRunServiceLifecycleTests\|AgentModeViewModelInactiveRefreshTests\|AgentModeChatSwitchActivationTests\|AgentStaleResetOwnershipTests'` (`AgentModeRunServiceLifecycleTests` includes the `ClaudeNativeBackgroundTranscriptTests` extension) | `0f3c9607-8da8-4112-87b2-971c7a0487c2` | 0 failures |
| `make dev-lint` | `f626e66d-e175-489f-827b-ef771ef8b902` | exit 0 |
| `Scripts/check-agent-context` | n/a | exit 0, but run before this report existed (see round 0) |

Not run: the full root test suite, ACP bash live runs, and a live Claude restart acceptance.

## Review fixes (round 0)

Reviews: `prompt-exports/oracle-chat-2026-10-28-205419-9fix-r3-review-a-1ca-70cd.md` and `…-review-b-dd7-8756.md`. Both flagged the backstop in the shared `bashTranscriptItemIndex`: it could redirect a result to the wrong row, append phantom rows, and affect other callers. Decision: cut the backstop entirely.

1. **Backstop reverted.** `bashTranscriptItemIndex` is byte-identical to `HEAD`, and `testArgslessBashCompletionDoesNotAdoptTerminalBashRow` is deleted. The remaining source diff is only:
   - the Claude-native gate in `reconcileCodexCommandExecutionRunningUpdate` (`CodexAgentModeCoordinator.swift:9823-9826`);
   - the removed dead call in the Claude live-transcript path (`AgentModeViewModel.swift:20377`).
2. **B P3-1.** `testLaterClaudeBashResultDoesNotRewriteRestoredInterruptedBashRow` (`CodexAgentModeCoordinatorLivenessTests.swift:1602-1648`, helper `restoredInterruptedBashRow` at `:2627`) now reads the restored row from `session.items` by id. It checks the equality and the persisted status (`cancelled`) on that current row.
   - With the gate temporarily removed, the test fails (ticket `3c3b7745-6df9-4c22-b30e-5e9b71b9b06f`): the row differs, and its persisted status is `success` instead of `cancelled`, which is exactly the incident. The gate was then restored.
3. **B P3-2: can a tab's `selectedAgent` change during a live run?** Effectively no; read-only check, no code change.
   - **The lock.** After the first send, `isProviderSelectionLocked` (`AgentTabSession.swift:1711`, `hasSentFirstMessage && !pendingHandoff.defersProviderLockUntilSend`) holds. `canSelectAgent` (`AgentModeViewModel.swift:465-479`) then only allows the same agent, or a switch between Claude-native kinds.
   - **Why that's safe for the gate.** A Claude-native↔Claude-native switch keeps `usesClaudeNativeRuntime` true, so the gate's answer can't flip.
   - **What enforces it.**
     - The `selectedAgent` `didSet` (`:293-305`) reverts any disallowed switch.
     - `handleAgentProviderAvailabilityChanged` (`:2115-2121`) returns early while a run is active or the provider is locked.
   - **Edge paths not traced further.**
     - `mcpConfigureSession` (`:8863-8880`) checks the lock only when `activeAgentSessionID != nil`.
     - `selectRemoteAgentModel` (`:1463-1480`) sets the agent for remote-host sessions without `canSelectAgent`. Remote rows come from the remote projector, not the local reconcile; I didn't verify that further.
     - Neither path is a normal mid-run switch.

### Validation (round 0)

| Command | Ticket | Result |
|---|---|---|
| `./conductor test --filter CodexAgentModeCoordinatorLivenessTests/testLaterClaudeBashResultDoesNotRewriteRestoredInterruptedBashRow` with the gate removed | `3c3b7745-6df9-4c22-b30e-5e9b71b9b06f` | 1 test, 2 failures (expected) |
| `./conductor test --filter CodexAgentModeCoordinatorLivenessTests` | `29ae0df3-f1f4-4ab6-aeb7-4fd3cca5b7a5` | 61 tests, 0 failures |
| `make dev-lint` | `1cc3485b-d6b9-4f90-ab12-41636955c150` | exit 0 |
| `Scripts/check-agent-context` | n/a | exit 1: this report is an orphan until the spec's Step 9-live-fixes status line links it (left to the main agent, which owns that line) |

The earlier Validation table and the "Other providers" note on the backstop describe the pre-review state. Without the backstop, an ACP bash result that has no args can still hit the empty-signature fallback. That's a pre-existing risk, out of scope here.
