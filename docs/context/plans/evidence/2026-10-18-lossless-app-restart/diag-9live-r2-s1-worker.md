# 9-live round 2, S1: why no Claude dispatch baseline was saved
Scope: read when the task touches the Claude dispatch baseline (history position) captured at send time.
Authority: Reference
Last-verified: 2026-10-29
Covers: read-only diagnosis of S1 from the round-2 live check
Content: cause with file:line evidence and record excerpts (no secrets), the smallest fix, and a unit test that would have caught it.

Read-only diagnosis on HEAD `1fd160d7` (the build the verifier ran, plus the `production = .claudeAndCodex` line). No source edits, builds or tests were run. Only record types, keys, IDs and timestamps from Claude's history were read, no message content.

## Cause in one paragraph

The baseline code ran, found the conversation and its history file, and then **recorded the kill turn's baseline as `unsupported` with "Claude history contains records this version doesn't support"**. In `.baseline` mode the Claude history decoder checks the whole file before it records a position. The file of a real RepoPrompt Claude session (CLI 2.1.302) contains record shapes outside the `nativeEntriesSubsetV2` allow-lists. The first is line 6, `attachment.type = mcp_instructions_delta`. The subset was qualified only on the O19 capture, which ran `--safe-mode --strict-mcp-config` with 0 MCP servers, 0 skills and no thinking (`phase4d-claude-capture.md` lines 7, 21, 30, 86). An unsupported baseline then shows up at reconcile as "No history position was saved…", which hides the recorded reason. That is why the verifier read it as "no baseline field".

## Where the baseline lives (and why the verifier missed it)

- Dispatch baselines aren't in the recovery record (`AgentRecovery/v1/sessions/<id>.json`). They live in the **agent session file** under `providerHistoryRecovery.dispatchBaselines`: `Workspaces/Workspace-repoprompt-ce-personal-touch-A9DF143F-…/AgentSessions/AgentSession-<id>.json`. They are written at `AgentModeViewModel+RecoveryActions.swift:985` (unsupported) and `:1103` (captured).
- The recovery record links to them by ID. In K1's record, `attempts[1].attemptID = 320E1D9D-…` (intent `85E1C582-…`, runAttemptID `FC40B345-…`) is the baseline's `dispatchID` in the session file.

### K1 (`15ED5106-…`) session file: `providerHistoryRecovery`

| # | dispatchID | runAttemptID | status | unsupportedReason | recordedAt |
|---|---|---|---|---|---|
| 1 | `6E5A263F-…` (warm-up) | `8006639E-…` | `unsupported` | "no Claude conversation identity before sending" | 16:55:27.677Z |
| 2 | `320E1D9D-…` (**kill turn**) | `FC40B345-…` | `unsupported` | "Claude history contains records this version doesn't support" | 17:14:36.760Z |
| 3 | `734099C5-…` (post-relaunch send) | `ABCEDAD3-…` | `unsupported` | same as #2 | 17:57:32.940Z |

- Every entry has `conversationID = 1b92920a-…` (none on #1), `completeLineOffset 0`, no `file`, no `baselineCommitID` and no `prefixSHA256`.
- There is no `lastImportCommit`, so no cursor was ever seeded.
- Entry #1 is expected: a fresh session has no conversation ID before its first send (`:1004`).

### K1 recovery record

- `attempts[1]`: kill turn, `outcome.kind = deliveryUnknown`.
- `actions[0..2]`: Continue, then Reconcile twice. All are `notDispatched`, with "No history position was saved before the interrupted run…".
- That text comes from `recoveryAssociationText(.baselineUnavailable)` (`RecoveryActions.swift:1602-1604`). `AgentProviderHistoryImport.swift:348/819` returns `.baselineUnavailable` because the attempt has no *captured* baseline. The recorded unsupported reason isn't shown.

### E7 (`14863B15-…`) session file

| # | dispatchID | status | notes |
|---|---|---|---|
| 1 | `5A95725B-…` | `captured` | `file` absent, offset 0, `prefixSHA256 = e3b0c442…` (empty prefix). The history file didn't exist yet (verified absence, `ClaudeSessionHistoryReader.swift:281-302`). `lastImportCommit 2753F85F-…` has 0 rows. |
| 2 | `59F27F03-…` | `unsupported` | "Claude history contains records this version doesn't support" |
| 3 | `ADFEE0BC-…` | `unsupported` | same as #2 |

So in E7 too, every dispatch made after Claude had written its first turn failed the same way. E7's `providerHome` passing (fix 4) only shows that the history location was found. Its one captured baseline would also fail at reconcile, because `.importAfter` validates the whole file the same way.

## Trace of the kill-turn dispatch (`captureClaudeDispatchBaseline`, `AgentModeViewModel+RecoveryActions.swift:950-1121`)

| Step | Line | Result for `320E1D9D` |
|---|---|---|
| `selectedAgent == .claudeCode && capturesDispatchBaselines(for:)` | 956-958 | **passed**. `AgentRecoveryActionRunner.swift:174-177`: history reconciliation is qualified and registration is active under `.claudeAndCodex`. Otherwise it returns `.notCaptured` and writes no entry. |
| `identity` + live `recoveryLane` | 959 | **passed** (an entry was written) |
| `admitRecorded()` | 970 | nil (first admission of this dispatch) |
| `providerSessionID` non-empty | 1004 | **passed** (`conversationID` is on the entry) |
| `recoveryClaudeHistoryRoots` | 1007-1019 | **`.roots`**. The "location unknown", ambiguous and uninspectable reasons weren't recorded. The file is under rotator profile `38b72e00…`, which matches E7's `providerHome`. |
| `stillCurrent` | 1008, 1033 | **passed**. A stale session returns `.refused` with no entry. |
| `readClaudeHistory(mode: .baseline, …)` | 1023-1032 | **`.unsupported(<other>)`** |
| `case .unsupported:` (catch-all) | 1045-1046 | `recordUnsupported("Claude history contains records this version doesn't support")` → entry #2. The ordinary send went ahead (`admitsWrite`). |

The dispatch kind doesn't matter: the run never got to the claim or commit code (`committedWithOutboundUserMessage`, `:1068-1121`).

### Which records the decoder rejects

`decode` (`ClaudeSessionHistoryReader.swift:375-437`) parses every complete line before it computes the baseline (`case .baseline:` at 436). Any `parseEntry` failure rejects the whole file. The kill turn was sent at 17:14:36.743Z, so the file then held lines 1–26 (line 27, the next `queue-operation`, is stamped 17:14:36.762Z). Here are the off-subset records in K1's file `1b92920a-….jsonl` (`version` 2.1.302), in file order:

| Line | Record | Rejected at | Unsupported case |
|---|---|---|---|
| **6** | `attachment`, `attachment.type = mcp_instructions_delta` | `:678-683` (`attachmentTypes`, `:359-362`) | **`.attachment(line: 6)`**, the first failure |
| 7 | `attachment` `skill_listing` | same | `.attachment` |
| 10 | `attachment` `instructions` | same | `.attachment` |
| 13 | `attachment` `remote_session_change` | same | `.attachment` |
| 20, 25 | `ai-title` (no `uuid`) | `:644` (not in `operationalTypes`, `:364-367`) | `.entryType("ai-title")` |
| 21 (also 35, 46) | `assistant` whose only block is `thinking` | `:760` | `.contentBlock("thinking")` |

E7's file has the same set: attachments on lines 6, 7, 10 and 13, `ai-title` on 20 and 31, and `thinking` on 21, 33, 41 and 49. No entry in K1's file has any of the `rejectedWhenTrue` or `rejectedWhenPresent` keys or semantic markers. Every other record type (`queue-operation`, `atis-latch`, `api-request*`, `last-prompt`, `cost-state`, `mode`) and attachment type (`environment`, `model`, `total_tokens_reminder`, `session_context`, `date`, `prompt_snapshot`) is already allowed.

Any default-configuration RepoPrompt Claude session has MCP (RepoPrompt's own), skills and `CLAUDE.md` instructions, and usually thinking. Its first turn therefore always writes these records. The result: **no Claude dispatch after the first turn can ever capture a baseline, and no file with a first turn can be imported.** Fixing only the baseline isn't enough.

## Smallest fix

1. **Widen the decoder subset to the shapes observed in real sessions** (`ClaudeSessionHistoryReader.swift`). This changes a deliberately tested contract: `ClaudeSessionHistoryReaderTests.swift:950-951` asserts that `thinking` is refused. It needs main/owner sign-off and should cite this K1/E7 evidence as the capture.
   - Add `mcp_instructions_delta`, `skill_listing`, `instructions` and `remote_session_change` to `attachmentTypes` (`:359`). Like the existing ones, they are nonrendering graph nodes, and their payload is never read.
   - Add `ai-title` to `operationalTypes` (`:364`). It has no graph identity, and the existing `uuid`/`parentUuid` refusal still applies.
   - Accept `thinking` (and, if wanted, `redacted_thinking`) blocks **in assistant entries only** as nonprojected. In `:713-761`, add `case ("thinking", true): continue`, so the block adds no row and isn't hashed into row text. A thinking-only assistant entry is then a message node with no blocks: it keeps its graph place, and `chainOrder`/`project` emit nothing for it. Check that the envelope digest, duplicate comparison and parallel-tool `message.id` grouping still behave when an entry has zero blocks (the line 35 → 36 thinking → tool_use pair in K1 is the shape to cover).
   - Bump `profileName` to `nativeEntriesSubsetV3` if the profile contract requires a new subset version for new accepted shapes (header lines 6-8). Existing V2 baselines stay as recorded.
2. **Keep the reason (diagnostics only).** At `RecoveryActions.swift:1045-1046`, add the specific case to the recorded reason, e.g. "…doesn't support (attachment, line 6)". The cases carry only schema names and line numbers; `.attachment` already leaves out the attachment type. Also map `.baselineUnavailable` for an attempt whose baseline is `unsupported` to text that names the recorded reason, instead of "No history position was saved", in `:1602-1604` / `AgentProviderHistoryImport.swift:348,819`. Without this, the next live check would show the same misleading text if another unseen record type appears.

Relaxing only `.baseline` mode, for example to boundary plus digest without validation, isn't enough on its own. `.importAfter` validates the same lines, so Reconcile would fail with `recoveryHistoryUnsupportedText` instead.

## Unit tests that would have caught it

- **Reader (`ClaudeSessionHistoryReaderTests`):** `testDefaultConfigurationFirstTurnShapeBaselinesAndImportsTextOnly`.
  - Build a redacted fixture with the same record sequence as K1 lines 1–26, plus lines 27–36 for a second turn: `queue-operation`; user text; attachments `environment`, `model`, `mcp_instructions_delta`, `skill_listing`, `total_tokens_reminder`, `instructions`, `session_context`, `date`, `remote_session_change`, `prompt_snapshot`; `atis-latch`; `api-request-shape`, `api-request-blob`, `api-request`; `last-prompt`; `ai-title`; a thinking-only assistant; a text assistant parented on it; and so on.
  - Assert that `.baseline` returns `.candidate` at the full complete-line offset.
  - Assert that `.importAfter(cursor at line 26)` returns only the second turn's rows: user text and `tool_use`, with no thinking row.
  - Today it fails with `.unsupported(.attachment(line: 6))`.
- **Producer (`AgentRecoveryReconciliationTests`, next to `testBaselineCommitsAZeroRowReceiptBeforeAdmittingAndKeepsEachDispatchsBoundary` at `:1682`):** write the same fixture with `harness.appendHistory`, then call `captureClaudeDispatchBaseline` for a second dispatch. Assert `.committed` and `status == .captured`.
  - The existing producer tests only append hand-made one-block `user`/`assistant` text entries (`:1684`, `:1708`), so they could never hit this.
  - Fixture rule for the future: every new allow-list entry or refusal test should come from a recorded real-session shape, not only from the O19 safe-mode capture.

## Changes (approved widening, not committed or staged)

Main approved the widening on 2026-10-29: these shapes occur in the owner's real app profile, which is the qualification that was still pending.

### Tally (counts only)

The script is `.agent-artifacts/s1-tally/tally.py` (git-ignored), run with `python3 -I`. It scanned the 200 most recently modified `*.jsonl` files, all changed within the last 14 days, under `~/.claude/projects` and `~/.claude-rotator/profiles/*/projects`. It counts only structural names; no text, inputs or outputs were printed or saved. The figures are the number of files containing each name.

- **Unsupported top-level types:**
  - `ai-title` 120, `system` 35;
  - in 3 files each: `custom-title`, `agent-name`, `bridge-session`, `frame-link`, `artifact-comment-monitor`, `artifact-autoreact-ledger`, `file-history-delta`, `file-history-snapshot`;
  - `isolation-latch` 2.
  - No operational record carried `uuid`/`parentUuid`.
- **`system` subtypes:** `compact_boundary` 34, `stop_hook_summary` 3.
- **Unsupported attachment types:**

  | Files | Types |
  |---|---|
  | 123 | `mcp_instructions_delta` |
  | 121 | `skill_listing`, `remote_session_change` |
  | 113 | `instructions` |
  | 80 | `deferred_tools_delta` |
  | 67 | `silent_turn_reminder` |
  | 56 | `deferred_tools_record` |
  | 29 | `thinking_drop` |
  | 28 | `compact_file_reference` |
  | 24 | `queued_command` |
  | 17 | `file` |
  | 15 | `edited_text_file` |
  | 3 each | `auto_mode`, `hook_additional_context`, `hook_success`, `agent_listing_delta`, `read_truncation_notice` |
  | 1 each | `task_status`, `sandbox_instructions` |

- **Content blocks:**
  - `assistant:thinking` 172 and `user:image` 1 are unsupported.
  - `redacted_thinking`: 0 files.
  - Inside `tool_result`, the parts `image` 9 and `tool_reference` 1 are unsupported.
- **Rejected keys:** `user.isCompactSummary` 34, `user.isVisibleInTranscriptOnly` 34, `user.isMeta` 6, `assistant.isApiErrorMessage` 6. These stay refused.
- **Effect:** a structural pre-check (`residual.py`, the decoder's per-line type rules only, no graph checks) passes **0/200** files under the old lists and **128/200** under the new ones. The first remaining refusal in the other 72:

  | Files | First refusal |
  |---|---|
  | 37 | `deferred_tools_record` |
  | 27 | `silent_turn_reminder` |
  | 2 each | `file`, `auto_mode` |
  | 1 each | `isMeta`, `user:image`, `queued_command`, `sandbox_instructions` |

### What was allowed, and why

All of these are judged from key names only (`keys.py`); payloads were never read.

- **Attachments.** These are nonrendering graph nodes; their payload is never read.

  | Type | Keys | Why it's metadata |
  |---|---|---|
  | `mcp_instructions_delta` | `addedBlocks`, `addedNames`, `removedNames` | Which MCP servers' instructions are available |
  | `skill_listing` | `content`, `names`, `skillCount`, `isInitial` | Which skills are available |
  | `instructions` | `files` (sometimes `changed`, `reason`) | Which `CLAUDE.md` files were loaded |
  | `deferred_tools_delta` | `addedNames`, `removedNames`, MCP server status lists | Which tools are available |
  | `agent_listing_delta` | `addedTypes`, `removedTypes`, `builtInTypes` | Which subagent types are available |
  | `remote_session_change` | `commit`, `pr`, `url` | Repo and PR metadata |
  | `thinking_drop` | `blockHashes`, counts, `requestId` | Telemetry about thinking retention; no conversation content |

- **Operational records.** These have no graph identity; the existing `uuid`/`parentUuid` refusal still applies.

  | Type | Keys |
  |---|---|
  | `ai-title` | `aiTitle`, `sessionId` |
  | `custom-title` | `customTitle`, `sessionId` |
  | `agent-name` | `agentName`, `sessionId` |

  All three are session display names only.

- **`thinking` blocks.** Accepted in **assistant** entries only, and the `thinking` field must be a string. They produce no row and take no ordinal, so a [thinking, text] entry digests exactly like a lone text entry. They are not part of the envelope digest and their text is never kept. A thinking-only entry is a message graph node that projects nothing, which matches K1's thinking → text and thinking → `tool_use` pairs that share an API message ID.

### Still refused, and why

- `deferred_tools_record`: its `toolInputCopies` duplicates tool inputs. Allowing it needs proof that it never differs from the `tool_use` input.
- `silent_turn_reminder`: model-facing `text` injected into a turn.
- `queued_command`, `file`, `edited_text_file`, `read_truncation_notice`, `task_status`: they carry or change conversation and tool content.
- Hooks: `hook_*`, and `system`/`stop_hook_summary`.
- Compaction: `compact_file_reference`, `system`/`compact_boundary`, `isCompactSummary`.
- `auto_mode`: a permission mode; only `mode: normal` is qualified.
- `sandbox_instructions` (1 file), `isolation-latch`, `bridge-session`, `frame-link` and `artifact-*`: rare, and their meaning is unclear.
- `file-history-*`, by the existing design.
- `redacted_thinking`, and `thinking` in a user entry.
- `user:image`, and image or `tool_reference` parts inside `tool_result`.

`profileName` stays `nativeEntriesSubsetV2`. It is only stored on each baseline (`RecoveryActions.swift:995, 1097`; `AgentSessionProviderHistoryRecovery.swift:397/439`); nothing reads it to make a decision.

### Code (file:line)

- **`ClaudeSessionHistoryReader.swift`:**
  - `:44-51`: header contract for the owner-profile qualification; `:29`: the content-block note now names `redacted_thinking`.
  - `:368-376`: `attachmentTypes`, plus 7 types.
  - `:378-382`: `operationalTypes`, plus 3 types.
  - `:736-738`: `case ("thinking", true)` validates the block and skips it.
  - `:975-976`: the digest note.
- **`AgentModeViewModel+RecoveryActions.swift`:**
  - `:1045-1046`: the catch-all records `recoveryBaselineUnsupportedReason(other)`.
  - `:1587-1614`: that function, which keeps the case's schema name and line only: no payload, no entry or tool IDs, and type or key names outside `[A-Za-z0-9_.-]` or longer than 48 characters become "unrecognized".
  - `:1630-1640`: `recoveryAssociationText(_:baseline:)`. A `.baselineUnavailable` for an attempt whose first baseline is `unsupported(reason)` says: "No history position could be saved when the interrupted run was sent: <reason>. Its history can't be matched safely. Nothing was imported." Every other case keeps the existing text.
  - `:1206`, `:1276`: the two Claude preflight refusals use it. The Continue note ("The message you typed to continue it was not sent.") is put in front of this reconcile text.

### Tests

- **`ClaudeSessionHistoryReaderTests`:**
  - `:641-647`: the O19 test's coverage assertion now covers the O19 and S1 fixtures together, which must equal the allow-lists exactly.
  - `:939` (renamed from `testDocumentedRetractionThinkingAndCompactionMarkersRefuse`): assistant thinking is skipped; a thinking-only tip projects nothing; a [thinking, text] entry keeps ordinal 0 and the lone-text digest; the thinking text isn't kept.
  - `:975` `testRedactedThinkingUserThinkingAndMalformedThinkingStillRefuse`: `redacted_thinking` refuses in both import and baseline mode; user `thinking` refuses; a non-string or missing `thinking` field is a malformed line.
  - `:1007` `s1Session()`: a sanitized fixture with K1's lines 1–26 structure and order (invented text), plus a second turn: thinking → `Bash` call (same message ID) → associated result → reply, with the remaining new attachment and title types.
  - `:1058` `testOwnerProfileDefaultConfigurationSessionBaselinesAndImportsWithoutThinkingRows`:
    - the baseline is captured at the first turn's size and digest;
    - the import after it returns exactly the second turn's 4 rows: user text, tool call, tool result (with its tool name), reply;
    - the from-start import returns 6 rows;
    - no payload is kept;
    - an `ai-title` that carries a `uuid` still refuses.
- **`AgentRecoveryReconciliationTests`:**
  - `:1858` `defaultConfigurationFirstTurn()`.
  - `:1902` `testBaselineAfterADefaultConfigurationFirstTurnIsCaptured`: `.committed`, `.captured`, at the file's size, with the receipt committed.
  - `:1918` `testUnsupportedHistoryBaselineKeepsItsCaseAndReconcileNamesIt`: a `hook_additional_context` record on line 2 records "…doesn't support (attachment, line 2)" without the kind or payload, the send still proceeds, and Reconcile returns the new text. With no recorded baseline, the old text is unchanged.

### Validation

| Command | Result | Ticket |
|---|---|---|
| `make dev-test FILTER=ClaudeSessionHistoryReaderTests` | 44 tests, 0 failures | first run `2ef5a76b-7fb2-4f7a-9bc6-5893ee3275f0`; rerun after formatting `23b82aec-0ad7-4f9b-b49a-e8cf9bf9af61` |
| `make dev-test FILTER=AgentRecoveryReconciliationTests` | 78 tests, 0 failures | `70ee4536-6848-4b4f-b758-0e91b77df067`; rerun `972c7a85-6e86-454b-a89c-affee2aa2557` |
| `make dev-lint` | passed, 0/2207 files need formatting | the first run flagged only the alignment of my new literals, which I fixed by hand; `dev-format` wasn't run because other workers' files are dirty |

Not run:

- the full suite;
- `ClaudeLiveTranscriptQualificationTests`, which is unchanged: the live stream classifier still refuses thinking (`unsupportedAssistant`), which is separate from this history decoder;
- any live check.

### Follow-ups for main

- Re-run the round-2 Claude kill steps (V5/V6, E2) on a build with this change.
- `deferred_tools_record` (56 files) and `silent_turn_reminder` (67 files) remain the biggest blockers for sessions that use deferred tools or silent turns. Allowing them needs an owner decision.
- `Scripts/check-agent-context` reports this report as an orphan; it needs a link from a reachable document.

## Round-0 fixes

Scope after the owner's cut: B P1, B P2-3 and B P3-9 only. **Dropped:** P2-4 (parallel-group walk), P2-5 (dropping `custom-title`/`agent-name` and the header rule) and P2-2 (header note on the profile name). No edits had been made for them, so nothing was reverted. `deferred_tools_record` and `silent_turn_reminder` stay refused. B P2-7 and P3-11 were skipped. Nothing is committed or staged.

### P1: the live classifier skips assistant thinking like the reader

- **Classifier** (`ClaudeLiveTranscriptQualification.swift`). While the dispatch is unanswered (`.dispatched`), or a Read chain awaits its final answer (`.readReturned`), a single-block `thinking` envelope is benign (`:518-523`, `classifyThinking` `:644`).
  - **Block shape:** keys ⊆ `type`/`thinking`/`signature`, string values, signature optional.
  - **Attribution:** optional. If present, it must name the outbound message (`attributionMismatch` otherwise).
  - **Translated results:** only `usage` is allowed (`translationMismatch` otherwise).
  - **Effect:** no state change, so the following text envelope attaches with the reader's identity.
  - **Still refused:** `redacted_thinking`, a thinking block with extra keys, and thinking after the answer (`unownedAssistant`).
  - **Refactor:** `isSingleToolUseEnvelope` now delegates to `isSingleBlockEnvelope(_:type:)` (`:632`).
- **Classifier tests** (`ClaudeLiveTranscriptQualificationTests.swift`).
  - The old "thinking block disqualifies" case became: `redacted_thinking`, thinking with an extra key, thinking with a translated row, and thinking attributed to another message.
  - New: `testAThinkingOnlyEnvelopeBeforeTheAnswerIsBenignAndTheAnswerStillQualifies` (`:316`).
- **End to end** (`AgentRecoveryReconciliationTests.testLiveThinkingThenTextTurnReconcilesWithoutADuplicateRow`, `:3216`, windows 5293/5294).
  - **Setup:** a captured baseline after the K1-shaped first turn; the live thinking envelope (benign) then the text envelope, through the real producer and owner; the row and proof persisted.
  - **Native history:** matching, with thinking `a2t` → text `a2`. Reconcile then runs twice.
  - **Array user content** (the CLI's real outbound form, `ClaudeSDKProtocolCodec.encodeUserMessage`): refuses with `.associationUnavailable(.outboundClaimUnmatched, …)`.
  - **String user content:** gives `.imported(completion: .unconfirmed, rowCount: 0)`.
  - **Both variants:**
    - the reply is shown once;
    - the user item is not re-created;
    - on the repeat, the rows, ledger and cursor are unchanged;
    - no new dispatch baseline and no run.

**Finding for main (not fixed, out of the cut).** `ClaudeSessionHistoryReader` sets the claim digest `userStringContentSHA256` only for string content (`:807`). It is nil for array content (`:503` feeds it to `nativeUserEntries`). The CLI writes the outbound user message as `[{type:text,text}]`, so `claimAssociation` (`AgentProviderHistoryImport.swift:751`) always returns `outboundClaimUnmatched` for a real Claude dispatch.

- **Safety:** this is a safe refusal. The test proves there is no duplicate and no send.
- **Effect:** Claude Reconcile can't import or confirm a real interrupted turn even with a captured baseline. This will block V5/V6 Claude on the next live run.
- **Smallest fix:** also hash the text of a user entry whose content is exactly one `{type:text,text}` block, keeping its keys exact. Then flip the array-variant expectation in the new test to `.imported(…, rowCount: 0)`.

### P2-3: the attachment type in the saved reason

- `Unsupported.attachment` is now `attachment(type: String?, line:)` (`ClaudeSessionHistoryReader.swift:174`). The reader keeps `attachment.type` only when `structuralTypeName` (`:370`) accepts it: ASCII `[A-Za-z0-9_.-]`, 1–48 characters. Anything else gives `nil`, and the payload is never read.
- The saved reason reads "attachment hook_additional_context, line 2", or "attachment, line N" with no type (`AgentModeViewModel+RecoveryActions.swift:1605`).
- Reader tests were updated: the type is now included, and free text, oversized and empty types give `nil`.

### P3-9: wording for older baselines

- The saved reason now reads "Claude history contains records the version that sent it doesn't support (…)" (`:1614`), because it is shown later, possibly by a newer version.
- The reconcile-time refusal ("…this version doesn't support. Nothing was imported or sent.") is unchanged, since it describes the running version.

### Validation

| Command | Result |
|---|---|
| `make dev-test FILTER=ClaudeLiveTranscriptQualificationTests` | 13/13 passed (ticket `6e7294ca`, after the lint fix) |
| `make dev-test FILTER=ClaudeSessionHistoryReaderTests` | 44/44 passed |
| `make dev-test FILTER=AgentRecoveryReconciliationTests` | 79/79 passed (ticket `4117c91c`) |
| `make dev-lint` | Passed, after three hand fixes (a blank line, a doc comment, a redundant `throws`) |

`make dev-format` was not run.

## Round-0 fixes, part 2: claim digest and whole-file check

Main counted the claim-digest finding above as part of P1. It is now fixed, which supersedes the "not fixed" note in the previous section. Nothing else changed. Nothing is committed or staged.

### Claim digest for the CLI's outbound form

- `ClaudeSessionHistoryReader.parseEntry` now hashes the text of a user entry whose content is exactly one block with exactly the keys `type` and `text` (`type == "text"`, string text) (`:802`). Before, it hashed only string content.
  - Any other array gives no digest, so it never matches a claim: an extra key such as `cache_control`, more than one block, or no blocks.
  - Assistant entries are unaffected.
  - The field's doc comment was updated.
- New `ClaudeSessionHistoryReaderTests.testASingleExactTextBlockUserEntryCarriesTheClaimDigestAndOtherArraysDoNot`. Its user entry carries K1's prompt metadata keys (`promptId`, `promptSource`, `turnOrigin`, `turnPosition`, `permissionMode`, `entrypoint`, `userType`, `gitBranch`). It covers the single block, the string form, and the three nil cases.
- `AgentRecoveryReconciliationTests.testLiveThinkingThenTextTurnReconcilesWithoutADuplicateRow` was flipped. Both the array (CLI) and string variants now give `.imported(completion: .unconfirmed, rowCount: 0)`.
  - The ledger records the claimed user entry and `a2`.
  - The reply appears once.
  - The repeat gives "The provider has no new history for this conversation." with the rows, ledger and cursor unchanged.
  - Nothing is sent.

### Whole K1 and E7 files against the reader (structure only)

The script is `.agent-artifacts/s1-tally/reader_emulation.py` (git-ignored), run with `python3 -I`. It emulates every rule of `parseEntry`, including the duplicate rule, and of `validateGraph` (roots, cycles, tool association, branching, tips and parallel groups) at the current allow-lists. It prints only case names, key names and line numbers. No text, tool input or output, or other value was printed or saved.

It checks each file whole, and also the prefix just before each user prompt entry, which is the file as a baseline at each send would see it.

| File | Lines | Whole file | Prefixes before the prompts | Prompt entries |
|---|---|---|---|---|
| K1 `1b92920a…` | 50 | passes | lines 3, 29, 41: all pass | 3, all single-text-block arrays |
| E7 `32f15902…` | 52 | passes | lines 3, 37, 45: all pass | 3, all single-text-block arrays |

Nothing refuses, so no allow-list or fixture change was needed. The reader has no allow-list for the top-level keys of user and assistant entries. It refuses only `rejectedWhenTrue`, `rejectedWhenPresent` and the semantic markers, and never reads any other key. The keys seen:

- **User entries:**
  - `promptId`, `promptSource`, `turnOrigin`, `turnPosition`, `permissionMode`;
  - the tool-result entry's `sourceToolAssistantUUID`, `toolUseResult` and `toolDenialKind` (K1 line 39, a string);
  - `permissionDecision` (E7 line 24, an object).
- **Assistant entries:** `apiBlockIndex`, `perTurnEffort`, `requestId`, `requestRef`, `requestedModel`, `thinkingDisplay`, `thinkingDurationMs`, `wireToolInputs`, `attributionMcpServer`, `attributionMcpTool`.
- **`isApiErrorMessage`:** K1 line 40 has the key with the value `false`, which the reader accepts. A `true` value still refuses.
- **Content blocks:**
  - `tool_use` blocks carry an extra `caller` key, which the reader doesn't read;
  - `tool_result` blocks carry `content`, `is_error` and `tool_use_id`;
  - `thinking` blocks carry `type`, `thinking` and `signature`.
- **Records:** the record types (including K1's `mode`, which must be `normal`) and attachment types are all on the current allow-lists.

**Notes for main.** Nothing meaning-changing refuses. Two points:

- `toolDenialKind`, `toolUseResult` and `permissionDecision` restate a tool call's outcome. The reader ignores them, as it ignores all unlisted top-level keys, and projects the result from the `tool_result` block (content and `is_error`) only.
- The emulation is a model of the reader, not the reader itself. The unit fixtures cover the shapes, but not every one of these exact metadata keys.

### Validation

| Command | Result |
|---|---|
| `make dev-test FILTER=ClaudeSessionHistoryReaderTests` | 45/45 passed (ticket `3ba3dd48`) |
| `make dev-test FILTER=AgentRecoveryReconciliationTests` | 79/79 passed (ticket `08a7062f`) |
| `make dev-lint` | Passed, after one brace-wrap fix by hand (whitespace only, after the tests) |

`ClaudeLiveTranscriptQualificationTests` was not re-run: neither its code nor its tests changed in this part.

## Round 1: OracleB's two read-only confirmations

Sources:

- the code;
- the app's raw Claude stdout event logs for K1 and E7 (`/tmp/repoprompt-ce-claude-raw-events/claude-session-{1b92920a…,32f15902…}-*.jsonl`, written by the DEBUG raw-event logging);
- the K1/E7 session records and native history files.

All reads were structure-only, through `.agent-artifacts/s1-tally/stdout_shapes.py` and `ids.py` (`python3 -I`). They printed key names, block types, counts and 8-character ID prefixes only. `cycle15/` holds no stdout envelopes. **No code was changed.**

### 1. Translator output and envelope shape for an assistant thinking envelope

**(a) The translator emits only `usage`: true.**

- `ClaudeReasoningExtractionFeature.isEnabled` is a compile-time `static let … = false` in both copies (`Sources/RepoPromptAgentCore/AI/Providers/ClaudeCode/SDK/ClaudeSDKNDJSONTranslator.swift:4-6`, `Packages/RepoPromptAgentProviders/Sources/RepoPromptClaudeCompatibleProvider/ClaudeReasoningDiagnostics.swift:3-5`). No setting or default reads it.
- The controller's translator (`ClaudeNativeProcessSessionController.swift:536`, `:2578`) is the core facade over `ClaudeCompatiblePluginNDJSONTranslator` (core facade `:44-68`).
- Its `parseAssistantMessage` emits `usage` first (package translator `:240-275`). The `case "thinking":` branch is `guard …isEnabled else { continue }` (`:289-290`). `thinking_delta` returns `[]` (`:420-421`).
- So a thinking-only envelope translates to `[usage]`, or `[]` without usage. `classifyThinking` accepts both.
- **Live confirmation:** in the raw logs, every real thinking-only envelope was followed by exactly one `translator.streamResult` of type `usage`, and nothing else. That is K1 3/3 and E7 4/4.

**(b) A real stdout thinking envelope fits `assistantKeys`/`assistantMessageKeys`: FALSE.**

All 7 real thinking-only envelopes have these top-level keys:

`message, parent_tool_use_id, request_id, session_id, thinking_display, thinking_duration_ms, timestamp, type, uuid`

- **Message keys:** `container, content, context_management, diagnostics, id, input_transformations, model, role, stop_details, stop_reason, stop_sequence, type, usage`. All are in `assistantMessageKeys`, and the null-key and empty-`input_transformations` rules pass.
- **Thinking block keys:** `signature, thinking, type`. These fit.
- **The misfit:** `thinking_display` and `thinking_duration_ms` are not in `assistantKeys` (`ClaudeLiveTranscriptQualification.swift:358-361`). `assistantBlock` (`:605-607`) fails on them, so `classifyThinking` returns `disqualified(.unsupportedAssistant)` (`:649-653`).
- **Consequence:** on the real CLI, the first thinking envelope of any thinking turn disqualifies the live producer for the rest of its launch.
  - This is fail-closed. There is no wrong row, only no live rows or proofs.
  - Reconcile would then import the reply from native history, with no duplicate, since the producer inserted nothing.
  - But round 0's P1 goal, live parity on thinking turns, isn't met on the real CLI.
- **Other shapes:**
  - Real single-text envelopes fit (K1 2, E7 4).
  - These thinking envelopes carry no `user_message_uuid` attribution, which is allowed: attribution is optional on thinking.
  - The E7 MCP `tool_use` envelope adds `tool_use_meta`. It isn't on any classifier path, so a non-Read call refuses anyway.
- **Smallest fix (not applied, awaiting main):** let `classifyThinking` accept `thinking_display`/`thinking_duration_ms` as optional top-level keys of a thinking envelope only, type-checked:
  - `thinking_duration_ms` a number;
  - `thinking_display` with the observed scalar type, to be confirmed by type name only.

  It also needs a fixture with those keys in `ClaudeLiveTranscriptQualificationTests`.

### 2. Native prompt entry `uuid` vs RepoPrompt's recorded outbound UUID (K1, E7)

**No comparison is possible: no outbound UUID was ever recorded or sent.**

- **Outbound frames:** all 6 outbound user frames in the raw logs (K1 3, E7 3) have the keys `message, parent_tool_use_id, session_id, type`, with **no `uuid`**. The content is one `{type,text}` block.
- **Dispatch baselines:** none has an `outboundUserMessage`.
  - K1: `6E5A263F`/`320E1D9D`/`734099C5`, all `unsupported`.
  - E7: `5A95725B` `captured`, `59F27F03`/`ADFEE0BC` `unsupported`.
- **Native prompt entries:** their UUIDs are CLI-generated.
  - K1: lines 3/29/41 → `683d0e50`/`601b6c46`/`ce03f1d7`.
  - E7: lines 3/37/45 → `07620e7d`/`5b6a9ac7`/`de3df0b5`.

  None matches any dispatch ID.
- **Why there was no identity:**
  - A claim is minted only when the transport reports `identityEligible` (`ClaudeAgentModeCoordinator.swift:2397-2403`).
  - That requires `commandProvenance == .automaticResolved`, `backend == .defaultClaude` and **`environmentOverrideKeys.isEmpty`** (`ClaudeNativeProcessSessionController.swift:1044-1049`).
  - `CLAUDE_CONFIG_DIR` is a backend-routing key (`:207-208`). It is collected from the exact child environment, including the inherited login shell (`:194-197`, `:215-227`).
  - The owner's login shell has `CLAUDE_CONFIG_DIR` set (checked for presence only). The K1/E7 history lives under the rotator profile it points to.
  - So these launches were identity-ineligible. Inference: the launch identity's key list isn't in the raw log.
- **Does claim association depend on the equality? Yes.**
  - `claimAssociation` requires each baseline's `dispatchID == claim.uuid`, and the native user entries' IDs to equal the claimed UUIDs (lowercased) in order (`AgentProviderHistoryImport.swift:772-774`), before the digest check (`:775`).
  - When a frame does carry `uuid`, the CLI adopts it as the native entry's `uuid` (`phase4d-no-replay-capture.md:10-11`, `phase4d-tool-resume-capture.md:29`, `:52-53`). That is the equality the e2e fixture assumes.
- **Consequence for the owner's real setup:**
  - With no claim, `claimAssociation` returns `.legacy` (`:767-769`).
  - `check` then needs every dispatch user item to already have a ledger native-user `localItemID` (`:376-383`). A fresh dispatch has none, so Claude Reconcile refuses with `.nativeUserAssociationUnavailable` even with a captured baseline. This is a safe refusal: nothing is imported or sent.
  - So the round-0 claim-digest fix only takes effect on identity-eligible launches. Those need no backend-routing environment key, which is not the owner's rotator setup.
  - Making the rotator setup eligible is a design decision for main/owner: either treat a `CLAUDE_CONFIG_DIR` that matches the discovered history root as non-routing, or accept it explicitly. It isn't a cheap fix.

### Answer summary

| Question | Answer |
|---|---|
| 1a. The translator emits only `usage` for thinking | **True** (code and 7 live envelopes) |
| 1b. A real thinking envelope fits the key sets | **False**: `thinking_display`, `thinking_duration_ms`. Fail-closed; a fix is proposed, not applied |
| 2. Native prompt `uuid` equals the recorded outbound UUID | **Not applicable**: no outbound UUID was recorded or sent (`CLAUDE_CONFIG_DIR` makes the launch identity-ineligible). Association does depend on the equality; the CLI adopts a supplied `uuid` per the O19/O20 captures |

## Round 1, part 2: the thinking-envelope keys, and launch-identity facts

### 1. Fix: the real CLI's thinking-envelope keys (applied)

- The live classifier accepts `thinking_display` and `thinking_duration_ms` on thinking envelopes only (`ClaudeLiveTranscriptQualification.swift:372`). `classifyThinking` uses that set and type-checks both keys, which are optional (`:652-656`):
  - `thinking_display` must be a string. The real value was `"updates"` in all 7 envelopes.
  - `thinking_duration_ms` must be a JSON number (not a boolean) and ≥ 0. It was an integer in all 7.
- Every other envelope still uses `assistantKeys`. A text envelope carrying these keys still refuses with `unsupportedAssistant`.
- **Fixture:** `realThinkingEnvelope()` (`ClaudeLiveTranscriptQualificationTests.swift:354`) has the exact top-level and message key sets recorded on K1/E7 stdout, with invented values and no attribution.
- **Test:** `testTheRealCLIThinkingEnvelopeIsBenignAndItsExtraKeysAreTypeCheckedOnThinkingOnly` (`:385`). It checks that:
  - the real envelope with `[usage]` is benign;
  - the following text envelope attaches;
  - a numeric or null display, and a string, boolean or negative duration, each refuse with `unsupportedAssistant`;
  - an attributed text envelope with the two keys refuses with `unsupportedAssistant`.

| Command | Result |
|---|---|
| `make dev-test FILTER=ClaudeLiveTranscriptQualificationTests` | 14/14 passed (ticket `69f6673a`, after one test fix: the text-envelope case first failed on attribution instead of on its keys, so it is now attributed) |
| `make dev-test FILTER=AgentRecoveryReconciliationTests` | 79/79 passed (ticket `bcc23887`; it runs the classifier end to end) |
| `make dev-lint` | Passed |

### 2. Launch-identity facts (read-only; nothing changed)

**Correction to round 1, answer 2.** I wrote there that the owner's launches were identity-ineligible because of `CLAUDE_CONFIG_DIR`. That was wrong. My login-shell check inherited this agent session's own `CLAUDE_CONFIG_DIR`, because this session runs under the rotator profile.

A clean login shell (`env -i … zsh -lic`/`-lc`) has `CLAUDE_CONFIG_DIR` **unset**:

- no zsh or bash startup file mentions it;
- `launchctl getenv` has it unset;
- the running app (PID 1959, parent launchd) has no `CLAUDE_CONFIG_DIR` in its environment.

The real blocker is command provenance, below.

#### a. How `environmentOverrideKeys` is computed, and the owner's launch

- **Computation:** `launchEnvironmentEvidence` (`ClaudeNativeProcessSessionController.swift:215-227`, called at `:1530-1535` with the exact dictionary passed to spawn). It is the union of:
  1. every resolver override key and removed key, whatever its name (`:221-222`);
  2. every backend-routing key present in the final child environment, whatever its origin (`:223`);
  3. every routing key among the configured process-environment overrides (`:224`).

  So it is not limited to keys RepoPrompt sets. An inherited routing key counts too. This was documented when introduced: usage plan §2.10 (`2026-09-13-agent-usage-and-wait-efficiency-plan.md:205`), "whatever its origin (inherited login shell, configured override…)".
- **The final environment:** `resolvedLaunchEnvironment` (`:4674-4690`) → `ProcessEnvironmentBuilder.build(.claudeNative)`.
  - The base is the captured interactive login-shell environment. When the app itself was started from a terminal, the base is the app's inherited environment instead (`ProcessEnvironmentBuilder.swift:65-74`, `:80-92`, `:122-134`).
  - The app's own environment then fills missing keys (`:136-146`), and the configured and resolver overrides are applied last (`:4693-4712`).
- **The resolver for the built-in backend** returns no overrides and no removed keys (`ClaudeCompatibleRuntimeSupport.swift:583-587`).
- **The owner's real launch** (app → node rotator shim → `claude`):
  - The app was started by launchd, so the base is the captured login shell, which has no `CLAUDE_CONFIG_DIR`. A clean login shell also has no `ANTHROPIC_*`, `CLAUDE_CODE_USE_*` or `CLAUDE_CODE_OAUTH_TOKEN`.
  - The shim sets `CLAUDE_CONFIG_DIR` only for the child it spawns. That is the spec's "Provider home" note (`2026-10-18-lossless-app-restart-spec.md:335`), and `fix-9live-claude-home-review-oracleb-r1.md:56`.
  - RepoPrompt computes the keys from the environment it hands to the shim, so `CLAUDE_CONFIG_DIR` is **not** in `environmentOverrideKeys`, and the keys are most likely empty.
  - This matches spec line 121: the shim needs `CLAUDE_CONFIG_DIR` unset or it skips its login. If RepoPrompt passed it, the shim wouldn't rotate.
  - **Exception:** if the app is launched from a terminal or agent shell that has `CLAUDE_CONFIG_DIR` set (for example an agent running under a rotator profile), the inherited environment is used. The key is then present and the launch is ineligible.
- **Why K1/E7 sent no uuid:** the app's defaults hold `cliExecutableOverride.claude`, an exact path in Settings to a Node shim inside a `claude-rotator` directory (path classified only).
  - That makes `commandProvenance == .configuredOverride` (`ClaudeNativeProcessSessionController.swift:1305-1314`).
  - Eligibility requires `.automaticResolved` (`:1046`), so every owner launch is ineligible on provenance alone, whatever the environment.
  - E7's captured baseline `5A95725B` has no claim. That is consistent: the claim is fixed only when `identityEligible` (`ClaudeAgentModeCoordinator.swift:2397-2403`). K1's baselines were all `unsupported` (S1), so no claim was possible for them either.
- **cycle15:** no launch-identity record exists in its evidence: no `process.spawned`, `commandProvenance` or `environmentOverrideKeys` in any file. The `/tmp` raw logs start after spawn and hold only `usage.runtime.binding` (keys `apiKeySource, apiProvider, launchToken, model, permissionMode`), with no provenance or override keys.

#### b. Why `CLAUDE_CONFIG_DIR` is a routing key, and what excluding it guards

- **Origin:** `backendRoutingEnvironmentKeys` (`:207-208`) arrived in `1028b735` (2026-09-15, "add Claude and Codex live usage readouts"), for the **usage** contract.
  - Usage plan §2.10 (`:205`): the keys "change which backend, account or credential a launch talks to" (also the source comment at `:205-206`).
  - §2.11 (`:270-272`) adds that a config dir's `settings.json` can set `env.ANTHROPIC_*`, `apiKeyHelper` and so on. Reported cost and usage then can't be trusted as first-party.
- **Reuse for identity:** the outbound-identity rule reused the same launch evidence in `3e9bf63b` (2026-10-23, "Persist qualified Claude outbound message identity before sending"; Step 4d1, `phase4d1-worker.md:17-20`). The rationale on record:
  - **Q6** in `phase4d-plan-oracleb.md:413`: restrict the contract to built-in `.claudeCode`, exclude GLM, Kimi, custom runtimes and wrappers, and keep every unqualified live identity assumption failing closed.
  - `phase4d1-worker.md:181`: "requiring no backend-routing keys is fail-closed".
  - `phase4d1-review-oracleb.md:97`: eligibility doesn't authenticate the binary or check the CLI version.
  - No decision ID names `CLAUDE_CONFIG_DIR` for identity specifically. It came with the usage list.
- **The risk it guards:** not that a compatible backend ignores the `uuid`. The API never sees the native entry's uuid (see c). The guard is against an **unqualified CLI/wrapper/profile path**. What was explicitly not claimed: "that the installed CLI and wrapper persist the caller's streamed `uuid` as the native entry `uuid`" (`phase4d-plan-oracleb.md:557`).
  - A redirected config dir, or a wrapper, means a different CLI install or settings. It also meant a history location the reader couldn't find; fix 4's history locator has since resolved that.
  - A config dir's `env` routing to a compatible backend matters for usage figures, not for uuid adoption.

#### c. Does uuid adoption depend on the backend?

**No: it is CLI-side.** The CLI reads the stream-json frame and writes the native JSONL itself. The model API receives messages, not native entry UUIDs.

- **What's evidenced:** adoption by CLI **2.1.302**, run directly (`~/.local/bin/claude`, a symlink to `versions/2.1.302`), first-party, with `CLAUDE_CONFIG_DIR` removed for the child (O19, `phase4d-no-replay-capture.md:10-11`, `:20-23`; `phase4d-tool-resume-capture.md:29`, `:52-53`; `phase4-prerequisite-resolution.md:55`).
- **K1 and E7** ran the same 2.1.302 (every entry's `version`), but through the rotator shim.
- **The shim:**
  - In managed stream-json mode it spawns the real CLI with piped stdio. It forwards each stdin frame as the **raw bytes** it received, parsed only to classify the frame (`forwardBrokerFrame` → `writeChildBytes(activeChild, rawFrame)`, shim `:4612-4649`). Otherwise it pipes stdin straight through (`:3957`).
  - So a top-level `uuid` would reach the CLI unchanged.
  - **Exception:** during a live continuation failover (account cutover), a held turn may be delivered to a replacement child in another profile. Its native entry would then be in another history file, so the claim wouldn't match there, which refuses safely.
- **Not evidenced live:**
  - a frame with `uuid` through the shim (no K1/E7 frame carried one);
  - any compatible backend.
- **Conclusion:** adoption depends on the CLI version and on the wrapper passing frames unchanged, not on the backend. Architecturally, a compatible backend set by `ANTHROPIC_BASE_URL` doesn't change who writes the native entry.

## Round 1, part 3: a configured exact path is identity-eligible (owner decision 2026-10-29)

### Change

- **Rule:** `outboundUserMessageIdentityEligible` (`ClaudeNativeProcessSessionController.swift:1047`) now accepts `commandProvenance` `.automaticResolved` **or `.configuredOverride`**. It still requires `backend == .defaultClaude` and an empty `environmentOverrideKeys`, and `.programmaticOverride` stays ineligible.
- **Doc comment:** a configured exact path, such as a pass-through wrapper the owner controls (the rotator shim), qualifies. A wrapper that drops or rewrites the frame's `uuid` leaves the native entry under another ID, so the claim never matches and Reconcile refuses safely.
- **Live transcript too:** the same property also gates live-transcript producer eligibility (`resolveLiveTranscriptEligibility`), so configured paths now get live rows and proofs as well. Its doc comment was updated.
  - This is needed for import. An identified outbound with an ineligible producer would leave the live reply rows unidentified, and Reconcile would refuse with `canonicalOutputAssociationUnavailable`.
- **Unchanged:** capture stays gated as before, and nothing else changed.

### Tests

- **`RegisteredNativeTransportWriteFenceTests.testClaudeUserFrameCarriesTheAdmittedOutboundUUIDOnlyForAnEligibleLaunch`.**
  - **Now ineligible (no `uuid`):** a programmatic override, a configured path on a compatible backend (`.compatible(.glmZAI)`), and a configured path with a routing key (`CLAUDE_CONFIG_DIR`).
  - **Now eligible:** a configured path on the first-party backend with no routing keys. It carries exactly the claimed lowercase `uuid` (`:518-521`).
  - **Already covered:** no launch identity, an `ANTHROPIC_BASE_URL` routing key on an automatic launch, and automatic eligibility.
  - The write count went from 5 to 8 (three added sends).
- **`ClaudeLiveTranscriptQualificationTests`** (three controller gating tests). The ineligible case is now `.programmaticOverride`. `testGateOffAndIneligibleLaunchesMatchLegacyOutputAndEligibleAddsOnlyEvidence` adds a configured-path run that must match the automatic run's results and evidence kinds exactly (`:655-660`).

| Command | Result |
|---|---|
| `make dev-test FILTER=RegisteredNativeTransportWriteFenceTests` | 18/18 passed (ticket `78dbb6c3`, after updating the write count) |
| `make dev-test FILTER=ClaudeLiveTranscriptQualificationTests` | 14/14 passed (ticket `68d4c4a8`) |
| `make dev-lint` | Passed (before the count-only test edit) |

## For the shim owner

The claude-rotator shim is now treated as a qualified pass-through when RepoPrompt runs it as the configured Claude executable.

**What RepoPrompt sends.** For a newly saved dispatch, RepoPrompt writes one stdin line of this form:

```
{"type":"user","message":{"role":"user","content":[{"type":"text","text":…}]},"parent_tool_use_id":null,"session_id":…,"uuid":"<lowercase dispatch UUID>"}
```

The `uuid` is top-level only. A retry, or any other write, carries no `uuid`. RepoPrompt never mints a second one.

**What the shim must do.**

- **Forward every stdin user frame to the real `claude` child exactly as received**, including the top-level `uuid`: don't drop, rename, regenerate or move it, and don't rewrite the content array.
  - Today's broker already does this. It parses only to classify, then calls `writeChildBytes(activeChild, rawFrame)` (`forwardBrokerFrame`, shim `:4612-4649`). Outside broker mode it pipes stdin straight through (`:3957`).
  - Keep it that way in future versions.
- **Don't set `CLAUDE_CONFIG_DIR`, `ANTHROPIC_*`, `CLAUDE_CODE_USE_*` or `CLAUDE_CODE_OAUTH_TOKEN` in RepoPrompt's own environment.** Setting them for the child only is fine. If one appears in RepoPrompt's launch environment, the launch becomes ineligible.

**Account failover mid-turn.** Suppose the shim re-delivers a held turn to a replacement child under another profile. What RepoPrompt reads at Reconcile:

- **Which file.** The history homes recorded for this conversation's runtimes, otherwise a locator search (`AgentModeViewModel+RecoveryActions.swift:1380-1414`). Exactly one `<session>.jsonl` across those homes is read. Two or more distinct copies refuse as ambiguous (`ClaudeSessionHistoryReader.swift:16-17`, `:282-283`).
- **A different file than the baseline's.** It is accepted only if its bytes up to the saved position match byte-for-byte (`:58-66`, `:486`). Otherwise Reconcile refuses as rewritten.
- **The claim.** The prompt entry after that position must carry the frame's `uuid` and the same text (`AgentProviderHistoryImport.swift:772-775`).

What that means for failover:

- **Import can still succeed** only if all of these hold:
  - a single copy of the session file is found;
  - its earlier bytes are unchanged;
  - it holds the turn once, under the frame's `uuid`.
- **Otherwise Reconcile refuses**, and nothing is imported or sent. The failing cases:
  - the old profile's copy is left in place next to a new one (ambiguous);
  - the earlier history was rewritten;
  - the turn was written under a new `uuid`, written with changed text, or never delivered.

So failover can never cause a duplicate or wrong import, only a refusal. To keep recovery working:

- deliver a held turn byte-for-byte, once, to exactly one child, in the same session;
- don't leave two live copies of the session file in homes RepoPrompt searches.

**How to check.** Send one turn through RepoPrompt with recovery capture on. Then compare IDs only:

1. Read the dispatch's saved claim: `providerHistoryRecovery.dispatchBaselines[].outboundUserMessage.uuid` in the session record.
2. Find the native prompt entry: the history file's `type:"user"` entry with no `tool_result` block.
3. That entry's `uuid` must equal the claim's UUID (lowercase), and its `message.content` must be the same single `{type,text}` block.
4. If the raw-event log is on, the stdin frame in `protocol.outbound.raw` must also carry that `uuid`.

A mismatch, or a missing `uuid`, means the shim (or something after it) changed the frame.
