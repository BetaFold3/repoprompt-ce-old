# 9-live round-2 fixes: OracleB review, round 1
Scope: read when the task touches the round-2 live-check fixes (Claude history shapes and claim, Codex full item view, recovery wording).
Authority: Reference
Last-verified: 2026-10-29
Covers: OracleB review round 1 of the S1, S3, S4 and S5 fixes

# Re-review round 1: 9-live round-2 fixes

## Summary

This round adds three things:

- The live classifier now skips an assistant `thinking` envelope that arrives before the answer. The reader already skips these.
- The reader now computes the claim digest for the CLI's real outbound user entry, whose content is exactly one `{type:text,text}` block. Before this, every real Claude dispatch was refused as claim-unmatched.
- The saved refusal reason now names the attachment type, and its wording covers baselines saved by an older version.

I traced each changed path and found **no P0 or P1 regressions**. One item is still not proven by any capture. I'd treat it as a P1 gate before calling S1 done.

What I checked:

- **Live/reader identity agrees.** A thinking-only live envelope is `.benign` and changes no state (`ClaudeLiveTranscriptQualification.swift:517-525`). The following text envelope attaches through `singleTextAssistantRow`. On the reader side, the thinking block takes no ordinal and stays out of the digest (`ClaudeSessionHistoryReader.swift:749-751`). So the live ledger key and digest equal what the reader projects for the native text entry, and `ledgerConflict` then suppresses it. That closes the duplicate-row risk from round 0, and `testLiveThinkingThenTextTurnReconcilesWithoutADuplicateRow` pins it, including the repeat run.
- **Every other thinking case still refuses.**
  - Thinking after the answer: `unownedAssistant`.
  - `redacted_thinking`, or a thinking block with extra keys: `unsupportedAssistant`.
  - Any translated non-`usage` result: `translationMismatch`.
  - Thinking inside a multi-block envelope falls through to `completeText`, which requires exactly one block.
  
  All of these disqualify the producer for its launch. None of them imports anything.
- **The claim digest only widens exact matches** (`ClaudeSessionHistoryReader.swift:798-803`).
  - Content with extra block keys (such as `cache_control`), several blocks, or no blocks still gets a nil digest, so it can't match a claim.
  - User rows are still never projected. The new digest feeds only `userMessageEntries`.
  - Synthetic CLI user entries, such as `[Request interrupted by user]`, now get a digest too. They can only match if their text equals a recorded outbound claim, so they still refuse as unmatched.
- **The attachment type in the reason is sanitized twice**: first by `structuralTypeName`, then by `name()` when the reason is formatted. A type that is free text gives `nil`, and tests cover that.

## P1 (gate, not a code defect)

### The live thinking path has never seen a real stdout envelope or the real translator
**Files:** `ClaudeLiveTranscriptQualification.swift:644-660` (`classifyThinking`) and the e2e test at `AgentRecoveryReconciliationTests.swift:~3260`.

The e2e test calls `state.classify` directly, with hand-built envelopes and `translated: []` for the thinking envelope. It never runs the real Claude translator or the native controller. The whole-file check (`reader_emulation.py`) qualified K1 and E7 **history** files, not stdout. So two assumptions are untested:

1. **The translator emits nothing but `usage` for a thinking block.** The code comment says "reasoning extraction is off". If the translator emits a `reasoning` result, or any other non-`usage` type, then every turn that thinks (172 of 200 files) disqualifies the producer at its first envelope. Claude Reconcile would then refuse on overlap. That is safe, but S1 would deliver nothing. If reasoning display is a user setting, recovery would also silently depend on that setting.
2. **The stdout thinking envelope fits `assistantKeys` and `assistantMessageKeys`.** Any extra top-level or message key on real thinking envelopes would refuse as `unsupportedAssistant`.

**Suggestion:** add one test that feeds a recorded or sanitized stream through the real translator, either through the controller or `ClaudeSDKProtocolCodec` plus the translator. The stream should be thinking envelope → text envelope → result. Assert that the thinking envelope produces only `usage` (or nothing), and that the text row attaches. If the translator can emit reasoning under some setting, decide whether that setting should disqualify the producer, and document the choice.

## Recommendations

1. **Close the P1 gate above before the live re-check**, so that a failed V5/V6 points at something new and not at an untested translator assumption.
2. **Do one structure-only check on K1/E7 that needs no code.** For each of the 3 prompt entries, compare the native entry's `uuid` with RepoPrompt's recorded outbound UUID for that dispatch (the `user_message_uuid` attribution). The e2e fixture assumes they are equal (`nativeUser.uuid = caller`). If claim association or the live attribution path depends on that equality, the real files should show it. Only IDs are compared, no content.
3. **Then run the live re-check** (round-2 V5/V6/E2), in this order:
   - a plain thinking → text turn killed after the answer is shown. Expect Reconcile `.imported(rowCount: 0)` and no duplicate.
   - a turn killed mid-thinking. Expect zero rows and the claim matched.
   - a Claude tool turn (K3/K4). Expect a safe refusal: non-Read tools disqualify live, and overlap refuses.
   
   Record the saved baseline reason for any refusal. With P2-3 in place, it now names the blocking attachment type directly.
4. **`deferred_tools_record` and `silent_turn_reminder`:** my round-0 recommendation stands, and the owner has deferred both. If the live re-check hits either one, the new reason text will name it. Count how often that happens before deciding.