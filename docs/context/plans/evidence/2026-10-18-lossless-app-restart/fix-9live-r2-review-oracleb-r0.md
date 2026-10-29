# 9-live round-2 fixes: OracleB review, round 0
Scope: read when the task touches the round-2 live-check fixes (Claude history shapes and claim, Codex full item view, recovery wording).
Authority: Reference
Last-verified: 2026-10-29
Covers: OracleB review round 0 of the S1, S3, S4 and S5 fixes



# Review: 9-live round-2 fixes (S1, S3, S4, S5)

## Summary

The diff covers four findings from the round-2 live check:

- **S1, Claude history decoder.** It now accepts 7 more attachment types and 3 more title-type records, all seen in the owner's real sessions. Assistant `thinking` blocks are now checked and skipped: they produce no row, take no ordinal and are left out of the envelope digest. When a baseline is refused, the saved reason now names the specific case, and Reconcile/Continue show that saved reason instead of the misleading "No history position was saved".
- **S3, Codex recovery read.** The recovery read now asks for `itemsView: "full"`. If the server rejects the field, it retries once without it and remembers that for the transport. Any turn whose returned view isn't `full` is treated as having no usable items.
- **S4.** The crash row now says "In an earlier launch…".
- **S5.** The survivor item now shows the agent's own PID next to the shim's PID.

The changes are small and fail closed. Line by line, I found no wrongly imported rows and no new send path. One acceptance risk needs a test before this is trusted: "no duplicated rows" now depends on a Claude live/history mismatch that this diff makes the common case.

## P0

None found.

## P1

### 1. Live and history now disagree on `thinking`, and nothing tests the import that results
**Files:** `ClaudeSessionHistoryReader.swift:736-738` and the Claude dispatch-window preflight at `AgentModeViewModel+RecoveryActions.swift:~1273`.

- The history decoder now accepts and skips assistant `thinking`. The worker report says the live stream classifier still refuses it (`unsupportedAssistant`), and `ClaudeLiveTranscriptQualificationTests` were not run.
- Thinking appears in 172 of 200 real files. So most Claude turns will now render assistant text live **without** a matching live ledger row. Before this change the whole history was refused, so this mismatch could never reach an import.
- After a kill, Reconcile imports every entry after the baseline. If the live text (already persisted in the transcript) has no ledger mapping and the overlap preflight doesn't catch it, the reply is imported a **second time**. That breaks the acceptance bar.
- The only thing preventing this today is that the dispatch-window/overlap preflight refuses whenever live output exists without ledger proof. No test in this diff exercises that.

**Suggestion:** add an end-to-end `AgentRecoveryReconciliationTests` case:
1. Capture a baseline on the default-config fixture.
2. Stream a live turn of `[thinking-only entry] → [text entry]` through the live producer, so the text is persisted in the transcript.
3. Append the matching native history and call `reconcileRecoveryHistory`.
4. Assert it refuses with association/overlap unavailable, or imports zero duplicate rows.

Also run `ClaudeLiveTranscriptQualificationTests`. Even if this is safe, expect the S1 fix to often move the refusal from "baseline unavailable" to "overlap", not to a real import. Decide whether the live classifier also needs a thinking-skip so that live rows exist.

## P2

### 2. The subset version isn't bumped, and the header says it should be
**File:** `ClaudeSessionHistoryReader.swift:6-8` (header) and `profileName`.

The header says "V2" versions *our decoder subset" and gives the V1→V2 bump for new predicates as the example. This change widens the accepted set and changes what the digest covers for thinking-bearing entries, but `profileName` stays `nativeEntriesSubsetV2`. The worker's argument (nothing branches on it) is true today, but the stored profile no longer tells you which rules accepted a baseline.

**Suggestion:** either bump to `nativeEntriesSubsetV3` (V2 baselines stay as recorded, like V1), or edit the header to say widening doesn't bump the version and the profile is informational only.

### 3. The new reason still hides the one detail the next live check needs
**Files:** `RecoveryActions.swift:1587-1614` (`case let .attachment(line)`), and `Unsupported.attachment` in the reader.

72 of 200 files still refuse, almost all on attachment types. "(attachment, line 6)" sends the next diagnosis back to reading the user's file. The attachment *type* is a schema name, not payload, and it already goes through the same `name()` sanitizer used for `.entryType`, `.contentBlock` and `.metadata`.

**Suggestion:** change the case to `.attachment(type: String?, line:)`. Set the type only when it is a string, and pass it through `name()`. Update the test assertion that currently requires the kind to be left out.

### 4. A thinking-only entry breaks parallel-group detection when thinking sits between tool calls
**File:** `ClaudeSessionHistoryReader.swift` `isInParallelGroup` (just above `envelopeDigest`, ~:950).

Take the chain `thinking → tool_use A → thinking → tool_use B`, all sharing one `message.id`:
- `isInParallelGroup(A)` looks only at A's direct parent and children for a tool-use entry with the same message ID. The thinking nodes have no tool use, so it returns false.
- A's forked result is then counted as a second tip, and the read fails with `ambiguousBranch`.

This is safe (it refuses), but interleaved thinking is common with tools, so it will cost refusals. Neither fixture covers parallel calls with thinking.

**Suggestion:** when looking for group siblings, walk through thinking-only nodes that have the same message ID. Add fixtures for `thinking → A → B` with parallel results (must pass) and the interleaved shape (pass or refuse, but pinned by a test).

### 5. The rules for what was allowed and what stays refused don't match
**File:** `ClaudeSessionHistoryReader.swift:368-382`.

- `silent_turn_reminder` stays refused as "model-facing text injected into a turn". But `skill_listing` (`content`), `mcp_instructions_delta` (`addedBlocks`) and `instructions` are also model-facing text, and they were allowed.
- `custom-title`, `agent-name` and `agent_listing_delta` each appear in only 3 files, none of them K1/E7. Other shapes with similar counts (`bridge-session`, `frame-link`, `auto_mode`) were refused as "rare, meaning unclear". `agent-name` is also close to the team/agent metadata the reader refuses (`agentId`, `teamName`).

**Suggestion:** write down one rule in the header. For example: "a payload that is never read is accepted when the node is a non-rendering graph node, or a record with no graph identity, *and* it cannot start, end, or re-parent a turn". Then judge each type by its graph position, not by whether its payload is model-facing. Either drop `agent-name`/`custom-title` until they show up in a RepoPrompt session, or note that they are only safe because entries carrying `agentId`/`teamName` still refuse.

### 6. The retry path skips the error handling the first attempt gets
**File:** `CodexNativeSessionController.swift:~1873-1880`.

`turns = try await listTurns(fullItemsView: false)` inside the `catch` throws any error unchanged:
- There is no `requireObservedGeneration()` after a failure, so a transport that changed mid-retry shows up as a raw request error instead of a stale-generation error.
- There is no `isTurnsListUnsupportedError` → `thread/read` fallback.

Also confirm that `isTurnsListItemsViewRejection` matches a server that accepts the field but rejects the *value* (`unknown variant 'full'`). If it doesn't, that error may match `isTurnsListUnsupportedError` and mark `turnsList = .unsupported` for the whole transport. That outcome is still safe, but it degrades.

**Suggestion:** wrap the retry in the same `catch` body (generation check, then the unsupported fallback). Add a test case with an "unknown variant `full`" error.

### 7. The S1 fixture is duplicated across two test files
**Files:** `AgentRecoveryReconciliationTests.swift:1858` (`defaultConfigurationFirstTurn`) and `ClaudeSessionHistoryReaderTests.swift:1007` (`s1Session`).

The two builders encode the same K1 lines 1–26 structure, and they will drift. **Suggestion:** move a single sanitized builder into `Tests/RepoPromptTests/Helpers`, parameterized by session ID.

## P3

8. **`AgentModeViewModel+RecoveryList.swift:1150-1154`:** the text can say "(1 process found, started as PID 56334, agent PID 56474)". The new test pins exactly that string. Showing two PIDs next to "1 process" reads as a contradiction. Also, nothing shows `writerPID` belongs to a live member; users may `kill` the PID shown, so naming an exited (possibly reused) PID is a small hazard. **Suggestion:** reword to "(… found; launcher PID X, agent PID Y)", and only set `writerPID` from members the last refresh saw alive.

9. **`RecoveryActions.swift:1630-1640`:** for baselines recorded before this change (K1, E7), the new text reads "…when the interrupted run was sent: Claude history contains records this version doesn't support." After the upgrade, "this version" does support them. Consider "the version that sent it" or similar.

10. **`CodexNativeSessionController.swift:1944-1954`:** a *completed* turn returned as `summary` (a server that ignores the request field) now confirms completion with zero rows. That is consistent with the existing completed-unsupported-items path. Check that the resulting text says items couldn't be read, not "no new history". Otherwise S3's confusing text comes back for completed turns.

11. **`ClaudeSessionHistoryReaderTests.swift:641-647`:** the O19 test now needs the S1 fixture to prove the allow-list matches exactly. That ties two separate qualification records together. A dedicated allow-list coverage test would be clearer.

12. **Docs:** all four evidence documents are orphans for `Scripts/check-agent-context`, which the S1 worker report itself notes. Link them from the lossless-restart plan index. The verifier report also contains absolute home paths. That's fine for a personal fork, but worth noting if the docs are ever shared.

## Recommendations

1. **Before landing S1, close P1.** Add the live-plus-history thinking duplication test and run `ClaudeLiveTranscriptQualificationTests`. Whether S1 actually lets Claude Reconcile succeed depends on the live classifier, so run a live K3/K4 re-check (Claude tool turn interrupted mid-call) right after.

2. **`deferred_tools_record`: allow it, with conditions.**
   - The worker's concern, that `toolInputCopies` may differ from the `tool_use` input, doesn't affect the reader. Attachment payloads are never read, hashed or projected, so a different copy can't change any row, digest or ledger key.
   - What matters is graph position. If it ever sits between a call and its result, the result's parent would no longer be the call, and the existing association check already refuses. That is safe.
   - Before allowing it, (a) run a structure-only tally of its parent and child kinds, (b) build a sanitized real-shape fixture, and (c) add a test that pins the refusal when it sits between a call and its result.
   - The value is high: RepoPrompt's own MCP tools are deferred under the default configuration, so this shape will grow.

3. **`silent_turn_reminder`: keep refusing for now.**
   - The risk isn't the injected text; that would be no worse than `skill_listing`. The risk is turn semantics. If a "silent turn" makes assistant output with no native user entry, that output would be imported after the baseline and attached to the interrupted attempt. No outbound claim would exist to check it against, and `userMessageEntries` matching can't see it.
   - Revisit once a capture shows where it sits. If it only ever appears inside a turn started by a matched user entry, allow it with that position rule: refuse when it follows an assistant tip.

4. **Re-run the residual script before deciding on either type, with each candidate allowed in turn.** The "37" and "27" counts are *first* refusals. Many of those files also contain the other type (67 contain `silent_turn_reminder`), so allowing only one may unblock far fewer files than the counts suggest.

5. Add the sanitized attachment type to the refusal reason (P2-3) so the next live check names the blocking shape directly.

6. Decide the `profileName` question (P2-2) explicitly in the header, so later widenings follow one documented rule.