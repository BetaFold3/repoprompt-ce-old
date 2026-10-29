# 9-live R3 fix: OracleB round-0 review

Scope: read when the task touches restored bash tool rows or the Codex bash reconcile on Claude sessions.
Authority: Reference
Last-verified: 2026-10-28
Covers: the OracleB review of the first R3 diff (gate plus backstop), copied from its export; the backstop it criticises was then removed




# Review round 0: 9-live R3 fix

## Verdict

**No P0 or P1 is confirmed.** The primary gate fixes the incident path correctly. The guard sits inside `reconcileCodexCommandExecutionRunningUpdate`, so the view model's generic `tool_result` call site is covered as well as the removed live-transcript call. The removed call was inside `insertClaudeLiveTranscriptRow`, so the gate would have made it a no-op anyway.

The backstop is the risky part. It was put in the **shared** lookup `bashTranscriptItemIndex`. The diagnosis suggested a narrower spot: only the finalize/anchor path. In the shared helper it changes behaviour for every caller, and when it fires it appends a new row instead of doing nothing. The goal said Codex and ACP behaviour would stay the same. That claim is not tested.

## Findings

### P2-1: Backstop in a shared helper can duplicate rows on Codex/ACP and change other callers

**Evidence**
- `fix-9live-r3-worker.md`, item 2: "With no unfinished match, the existing `createAnchorIfNeeded` path appends a fresh anchor row." Test 1's comment confirms it: "the backstop alone would append one".
- `bashTranscriptItemIndex` has other callers that intentionally match **finished** rows. You can see one in the slice: `shouldApplyCommandExecutionRunningUpdateToInactiveSession` always passes `argsJSON: nil` and ends with `return Self.isTerminalBashTranscriptItem(item, metadata:)`. By its name, `applyLateRunningOutputToTerminalBashResultIfNeeded` exists to find finished rows. I could not see whether it uses this helper.

**Failure scenarios**

These apply to non-Claude sessions only, and only when the incoming args are empty and there is no invocation ID or process ID:
1. **Duplicate row.** An ACP bash call has no `rawInput` on both the call and the result. The view model first finishes the real row by invocation ID, then calls the reconcile with `argsJSON` nil.
   - Before the fix, the reconcile matched that just-finished args-less row and re-finished it with the same result.
   - Now that row is skipped because it is finished, so `createAnchorIfNeeded` adds a second bash row holding the same output.
2. **Possible P1, needs checking.** Suppose the late-running-output path looks up rows through `bashTranscriptItemIndex`. Then args-less running output that arrives after completion no longer finds the finished row. It falls through to `upsertLiveBashExecution(claimsCurrentProvider: true)`, which anchors a new **running** row. Nothing will ever finish that row. The liveness poll only runs for `.codexExec`, so on ACP it could stay running.
3. On an inactive Codex session, a running update with no IDs used to return `true` when it matched a finished args-less row. Now it returns `false`, so the update is dropped. This is probably harmless, but it is still a behaviour change.

**Smallest fix**
- Revert the change in `bashTranscriptItemIndex`.
- Put the "args-less never adopts a finished row" rule in the finalize path only, as the diagnosis suggested. In that case, return without doing anything, with **no anchor**: if the args are empty, there is no invocation or process ID, there is no live state, and the only signature matches are finished rows, drop the completion.
- This still protects restored rows, and it adds no rows.

### P2-2 (cheap): `hasArgs` checks the raw string, not the signature

**Evidence:** `hasArgs = argsJSON?.trimmingCharacters(...).isEmpty == false`. The match itself compares `canonicalNativeToolFallbackSignature`.

**Failure scenario:** The incoming args are `"{}"`, `"null"`, or JSON with no `command`. If the canonical form of those is also `bash\n` (I have not seen lines 730–751), then `hasArgs` is true while the signature is still the args-less one. The backstop does not fire, and the finished restored row is overwritten as before. This is possible on ACP, where pending calls often have empty `rawInput`.

**Fix:**
```swift
let isArglessSignature = fallbackSignature
    == Self.canonicalNativeToolFallbackSignature(toolName: toolName, argsJSON: nil)
```
Use `!isArglessSignature` instead of `hasArgs`.

### P3-1: Tests

**`testArgslessBashCompletionDoesNotAdoptTerminalBashRow`** does not check the row count. It therefore silently accepts the phantom anchor row from P2-1. Add an assertion on `session.items.count`. After the P2-1 fix, that assertion should be "no new row".

**`testLaterClaudeBashResultDoesNotRewriteRestoredInterruptedBashRow`**
- It does go through the incident path (`test_handleStreamResult` → `tool_result` → reconcile), and the `["bash","bash"]` check correctly pins the gate.
- But `sanitizedToolResult(for: restored)` reads the **snapshot** taken before the run, not the row now in the session. If `AgentChatItem` is a struct, that assertion proves nothing.
- Fix: read the row from `session.items.first { $0.id == restored.id }`.

**No test pins "Codex and ACP unchanged."**
- The 62 liveness tests mostly cover Codex.
- Add one ACP-shaped test: `selectedAgent` set to an ACP agent, a bash call with args, a `{"status":"running"}` `tool_result`, then the completed result.
- Assert there is one row, it is finished, and `bashLiveExecutionByKey` is empty. That checks the ACP dependency the implementer said they could not rule out.

### P3-2: The gate checks `session.selectedAgent`, not the run's provider

If a tab can switch agent while a run is live or about to finish, results from the earlier provider are gated by the new agent. This doesn't matter today if runs lock the agent; just confirm that they do.

## Not verified (no access beyond the slices)

- Whether `applyLateRunningOutputToTerminalBashResultIfNeeded` and `ensureLiveBashExecutionState` call `bashTranscriptItemIndex`. This decides whether P2-1 scenario 2 is a P1.
- That there are no other Claude-reachable callers of `finalizeLiveBashExecution`, `ensureLiveBashExecutionState` or `applyLiveBashRunningUpdate` besides the reconcile.

## Recommendations

1. **Keep** the primary gate and the removal of the dead live-transcript call as they are.
2. **Rescope the backstop (P2-1).** Revert it in `bashTranscriptItemIndex`. Make an args-less, unidentified completion that matches only finished rows a no-op in the finalize path (no anchor row).
3. **Decide "args-less" by the canonical signature (P2-2)**, not by the raw string.
4. **Tighten the tests:**
   - row-count assertion in the backstop test;
   - read the persisted status from the session's row;
   - add one ACP bash running → completed test.
5. **Before merging,** search for callers of `bashTranscriptItemIndex`, `ensureLiveBashExecutionState` and `finalizeLiveBashExecution` to settle the open question in P2-1 scenario 2. Then rerun `CodexAgentModeCoordinatorLivenessTests` and the ACP provider tests.