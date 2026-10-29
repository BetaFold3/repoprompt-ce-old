# 9-live R3: cancelled tool row later saved as success
Scope: read when the task touches a restore-cancelled tool row of a Claude session later recorded as success.
Authority: Reference
Last-verified: 2026-10-28
Covers: bounded read-only investigation under decision O45

## Answer

- **The `success` status is wrong** (verified). Claude's own history records the turn-1 Bash call as interrupted, with unknown outcome and `is_error: true`. RepoPrompt never received a success result for it.
- **Cause** (code path verified; runtime sequence inferred, because no event log was captured). A *later* Claude bash `tool_result` was applied to T7's old row. The output came from turn 4's `echo go; sleep 60; echo done`.
  - Every Claude provider `tool_result` also runs the Codex-only `reconcileCodexCommandExecutionRunningUpdate`.
  - That function finalizes "the last bash row whose args signature matches".
  - Claude result events carry no args, so the signature is just `bash\n`.
  - That signature matches any bash row with no args. T7's restored turn-1 row is one, because saved rows keep no args.
- None of the four candidates in the brief caused it: resume/history import, re-sanitize/re-save, provider-history merge, or Continue. The cause is a Codex live-bash reconcile reached from the generic Claude tool-result path.

## Timeline of T7 (`3BC977C7-8BFB-4FEB-9856-8B467C2F8EE1`; Claude conversation `4d5cdfd5-bf5c-4d14-b389-577de18cb910`)

Local time is UTC+7. JSONL: `~/.claude-rotator/profiles/38b72e00-…/projects/-Users-tnguyen-workspace-repoprompt-ce-personal-touch/4d5cdfd5-….jsonl`. It lives under a rotator profile, which matches the baselines' "Claude history location unknown".

| Local | Source | Event |
|---|---|---|
| 15:28:56 | JSONL line 22 | `tool_use toolu_01WDcZKYXr1mg7ZK2TQGqohA` `echo RPCE_VERIFY_V1_start; sleep 590; echo done`. No real result was ever recorded. |
| (kill, relaunch) | session file | Turn 1: `terminalState: cancelled`, `interruption.reason: appCrash`. Cold restore cancels the row. |
| 15:56:09 | JSONL line 25 | Claude Code's synthetic `tool_result` for `toolu_01WD…`, `is_error: true`: "[Tool call interrupted: … its outcome is unknown …]". Written when Claude started for turn 2. |
| 15:56:08–11 | session file, g2 notes | Turn 2 "after: reply OK" → "OK". No tool. The row still rendered as failure (`F1-T7-after-send.png`). |
| 16:54:11 | JSONL line 48 | Turn 3: `toolu_01LsBj…` `sleep 60` blocked, `is_error: true`. |
| 16:56:37 | JSONL line 63 | Turn 4: `toolu_01Ryy8V…` result `go\ndone`, `is_error: false`. |
| 16:56:40 | session file `savedAt` 814874200.6 | Turn-1 row `C15E1353…` (invocation `6F9ECC28…`) now stored as `{"status":"success","summary_only":true,"summary_text":"bash • success","type":"commandExecution"}`. That is byte-identical to turn 4's own row `E436239C…`. |

- **No relaunch between 15:56 and 16:56** (verified): the recovery record's attempts for turns 2, 3 and 4 all have `appInstanceID 0A1BCCD1…`. So no cold restore or history import ran in that window. `providerHistoryRecovery` has only `dispatchBaselines`, all `unsupported`; it has no `claudeLocalItemIDs` and no native items, so no Claude history association or import took place.
- **The saved session file has no args field anywhere** (verified: `grep -ci args` → 0). A restored row is therefore rebuilt with `toolArgsJSON == nil`. Live rows in turns 3 and 4 kept their `tool_call` args in memory.

## Code path (verified by reading)

1. **Claude result events have no args.** `ClaudeSDKNDJSONTranslator.swift:316-335` and `:343-372` build `tool_result` results with `toolResultJSON` = the raw content text (here `go\ndone`) and no `toolArgsJSON`.
2. **The generic handler updates turn 4's own row.** `AgentModeViewModel.swift:19670-19722` (`case "tool_result"`) matches by invocation ID and updates turn 4's row. Then, for every tool result whatever the provider, it calls `codexCoordinator.reconcileCodexCommandExecutionRunningUpdate(...)` at `AgentModeViewModel.swift:19724`. The Claude live-transcript path also calls it at `:20379`.
3. **The reconcile finalizes with no identity.** At `CodexAgentModeCoordinator.swift:9816-9906`, tool `Bash` normalizes to `bash`, and the plain-text result is not running. The function then calls `finalizeLiveBashExecution(invocationID: nil, argsJSON: nil, statusWord: "completed", isError: false)` (`:9893-9902`).
4. **No live state exists, so it anchors by signature.** `finalizeLiveBashExecution` (`:8916-8963`) finds no live state, so it calls `ensureLiveBashExecutionState` (`:8617`, `claimsCurrentProvider: false`). That uses `bashTranscriptItemIndex` (`:8459-8489`):
   - no invocation ID, no process ID;
   - so it falls back to `session.items.lastIndex` with the same `canonicalNativeToolFallbackSignature` (`:8481`);
   - with nil args that signature is `"bash\n"` (`:730-751`);
   - the only bash row with nil args is the restored turn-1 row.
5. **The old row gets the new output.** Back in `finalizeLiveBashExecution`, `mergeCommandExecutionCompletionPayload` (`CodexNativeSessionController.swift:7851-7857`) returns the non-JSON incoming text unchanged. The old row gets `toolResultJSON = text = "go\ndone"` and `toolIsError = false`. Its invocation ID is kept (`invocationID ?? item.toolInvocationID`), as is the sequence index.
6. **The save then derives `success`.** The 16:56:40 save summarizes bash through `AgentToolResultPersistencePolicy.derivedStatusWord` (`:1915-1946`):
   - the text has no status word;
   - the row has `toolIsError` false;
   - so the result is `success`. Turn 4's own row, which holds the same `go\ndone`, got the same summary.

Inferred, not seen in a log: turn 3's blocked result (`is_error: true`) went through the same path at 16:54. It would have overwritten the row with the blocked text as a failure, so the row still looked red until turn 4. No Claude raw event log exists (`ClaudeRawEvents`: none). The live-bash reconcile has no log of its own.

This corrects one claim in `diag-9live-r2-r5-worker.md` R3 item 5: "live bash execution state is built only by the Codex coordinator, so Step 7-minor never applies to Claude". The Codex coordinator code *is* reached for Claude sessions, through the generic tool-result call sites. Step 7-minor's owner gate is not involved, though: this path passes `claimsCurrentProvider: false` and goes through the anchor fallback, not the liveness poll.

## Is `success` wrong?

Yes (verified).
- Claude's history holds only the synthetic interrupted result (`is_error: true`, "outcome unknown") for `toolu_01WD…`.
- The stored `success` comes from another call's output (`go\ndone` from `toolu_01Ryy8V…`).
- g2 notes say the `sleep 590` process exited about 15:38:32. Even if the command finished on its own, no result for it ever reached RepoPrompt or Claude.

Scope of the defect (inferred from the code, not tested): any Claude session can have an args-less bash row, that is, any bash row restored from a saved file. Each later Claude bash result without a matching invocation/process can overwrite the newest such row, whether it was cancelled, failed or succeeded. It isn't limited to restore-cancelled rows.

## Smallest fix direction

1. **Primary.** Don't run the Codex live-bash reconcile for Claude-native sessions.
   - Gate the two call sites, `AgentModeViewModel.swift:19724` and `:20379`, with `!session.selectedAgent.usesClaudeNativeRuntime`.
   - Or put the equivalent guard at the top of `CodexAgentModeCoordinator.reconcileCodexCommandExecutionRunningUpdate` (`:9816`).
   - Before also gating ACP agents, check whether their bash or `write_stdin` running updates depend on this reconcile. I didn't trace that.
2. **Defense in depth.** In `bashTranscriptItemIndex` (`CodexAgentModeCoordinator.swift:8481`), skip the args-signature fallback when `argsJSON` is nil or empty, because `"bash\n"` is not an identity. Optionally, don't adopt an already-terminal row as the anchor in `ensureLiveBashExecutionState` (`:8664`) when called from finalize.
3. **Regression test shape.**
   - Set up a Claude-native session with a restored, args-less, cancelled bash row.
   - Feed a live Claude `tool_call` (with args) and then a `tool_result` (no args, plain text, `isError: false`).
   - Assert that the older row keeps its cancelled payload and status, and that only the new row becomes success.

## Not done

- No log-level trace of the actual 16:54 and 16:56 events exists: no raw event log, and the reconcile path doesn't log. The step-by-step runtime sequence is inferred from the code plus the byte-identical stored rows.
- No test was written or run (read-only scope).
