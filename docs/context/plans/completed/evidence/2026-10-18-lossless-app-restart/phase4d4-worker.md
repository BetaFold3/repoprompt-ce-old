# Step 4d4 worker evidence — exact O20 `mode` record and resumed Read projection

Scope: read when the task touches the Step 4d4 reader change (the exact observed Claude `mode` record) or its O20-shaped fixture validation evidence.
Authority: Reference
Last-verified: 2026-10-24

## Contract implemented (HEAD 6cf06842, uncommitted, unstaged)

Source: only the sanitized `phase4d-tool-resume-capture.md` (O20) observations. No raw capture, config, provider prompt, app, helper or provider process was used. The live classifier, the owner and the runtime gates are unchanged and still OFF. There are no architecture, CLI, package, schema, persisted-format, ID or digest changes.

- **`mode` record.** `ClaudeSessionHistoryReader.parseEntry` has a dedicated `case "mode"`, handled by `parseModeRecord`. `mode` is deliberately **not** added to `operationalTypes`. The record is skipped as nonprojected metadata (`.success(nil)`) only when it is exactly `{type:"mode", mode:"normal", sessionId:<this session>}`. Checks run in this order, each using an existing typed `Unsupported` case:
  1. Any `uuid` or `parentUuid` key, even null → `.operationalRecord("mode", line:)`.
  2. `sessionId` missing, non-string, null or a different session → `.sessionMismatch(line:)`.
  3. Any key besides `type`/`mode`/`sessionId` → `.metadata(<first extra key, sorted>, line:)`. This covers marker keys such as `supersedes`.
  4. `mode` missing, non-string, null or any value other than `"normal"` → `.metadata("mode", line:)`.

  An unknown type (for example `mode-v2`) still refuses with `.entryType`. There is no new fallback. The header contract comment has a short 4d4 note.
- **Existing projection fits the observations unchanged.** No other reader code changed. The fixture carries every observed semantic and metadata field (`promptId`, `promptSource`, `turnOrigin`, `turnPosition`, `permissionMode`, `requestId`, `wireToolInputs`, `apiBlockIndex`, `effort`, `perTurnEffort`, `requestedModel`, `toolUseResult`, `permissionDecision` with `reasonType`, `message.stop_reason`, `message.model`), and the existing reader accepted all of them. No observed semantic field was rejected, so nothing was broadened.
- **Tool association is the existing rule.** A result is parented directly on its call and its `sourceToolAssistantUUID` names that call. `tool_use_id` must name a call of that parent. The invocation ID is `rpce-claude-history-tool-v1` over (provider, session, `tool_use_id`).

## Tests added (`ClaudeSessionHistoryReaderTests`, sanitized hand-written O20 shape)

The builders are `o20Exchange`, `o20Processes`, `o20ModeRecord` and `o20CostState`. They cover three Read exchanges: two in process 1, then the resumed process 2 append, followed by `mode` and `cost-state`. They reuse the existing `entry`/`attachment`/`operational` helpers and the private-context/request sentinels. No captured ids, paths, file contents, or attachment or request payloads appear.

- `testO20ReadExchangesAcrossASameSessionResumeProjectThroughTheExistingToolAssociation` checks:
  - The process 1 bytes are a byte-exact prefix of the full file.
  - Rows per prompt are caller `userText` (ledger-only, `localItemID == nil`), then `toolCall`, `toolResult`, `assistantText`. There is exactly one Read per prompt.
  - Call and result local IDs are the deterministic native-UUID row IDs, and the result has its own distinct UUID.
  - Call and result share `tool_use_id` and the invocation ID derived from it. Their `toolName` is `Read` and the canonical `file_path` input is preserved.
  - An absent `is_error` gives `toolIsError == nil`, and the final text tokens are preserved.
  - No sentinel reaches any row.
  - `userMessageEntries` holds only the three caller anchors, with their prompt SHA-256. Tool-result users are never anchors.
  - Completion stays unconfirmed.
  - A native `stop_reason` (`tool_use`/`end_turn`) and a stdout-style null give identical rows, IDs and digests, even though the bytes differ.
- `testO20ResumedAppendImportsOnlyTheNewExchangeAndReplaysAsANoOp` checks:
  - The process 1 import appends two call/result/answer triples.
  - The same-file `importAfter(firstPlan.cursor)` with its ledger is not a rescan. It yields only `[C3, U3a, U3b, U3c]` and validates all 12 rows, and only C3 is a new anchor.
  - The planner appends call, result and answer with a shared invocation ID and row-derived IDs, and the ledger holds 12 items.
  - Re-reading after the latest cursor yields no rows, and replaying the observation appends nothing.
- `testO20ModeRecordIsAcceptedOnlyInItsExactObservedShape` checks:
  - `mode ∉ operationalTypes`.
  - The exact record is accepted as both an import and a baseline.
  - Exact-line refusals cover: unknown key(s), other mode values or types (`plan`, `Normal`, `""`, `1`, null, missing), `uuid`/`parentUuid` (null or string), `sessionId` (missing, null, other), a `supersedes` key, and the `mode-v2` type.
- `testO20WrongToolResultIdSourceOrParentRefusesTheWholeCandidate` checks that each of these on the resumed result refuses with `toolAssociation("unassociated tool result o20-u3b")`:
  - an unknown `tool_use_id`;
  - an earlier call's id;
  - a wrong `sourceToolAssistantUUID`;
  - a parent that is a pre-call attachment (the result becomes a sibling of the call);
  - a parent that is the caller.

  Existing coverage is unchanged: `testAmbiguousToolAssociationRejects` and `testAttachmentsKeepEveryGraphSafeguard` (interposed attachment, forked result without source).
- The existing `testCaptureQualifiedSingleTextTurnProjectsOnlyTheClaimedUserAndAssistantText` still pins `operationalTypes` to the O19 set, unchanged.

## Validation (coordinated conductor, final tree)

| Check | Ticket | Result |
|---|---|---|
| `make dev-test FILTER=ClaudeSessionHistoryReaderTests` | 514577f4-bd50-46df-9f46-96da3ed60657 | 40 tests, 0 failures (4 new `testO20*` passed; also first run 28c88f92-0034-400b-b795-fe16cf68a393 before style-only edits) |
| `make dev-test FILTER=AgentRecoveryReconciliationTests` | 1ca5b0a8-c38f-4d7f-8ff4-5f3ee71f7b8e | 46 tests, 0 failures (earlier b9e97ed3-cf25-466b-8d0e-8fd8601484c9) |
| `make dev-swift-build PRODUCT=RepoPrompt` | 47e9b38b-ffed-4fc5-b985-274eb01e3030 | completed (earlier c31adb75-930f-4b7d-9f71-99e7c0731b26) |
| `make dev-format-check` | 9c90192b-f129-410e-b57e-87a7366f5999 | clean. The first run (17c640bc-b44d-4097-b072-a83ef3512756) flagged style in the new code only; this was fixed by hand without `make dev-format`. |
| `make dev-lint` | 0b09e766-717d-4d8e-9aa8-ae6ba5361c12 | clean |

The conductor noted that the suite is not in the frozen curated ledger and ran with default deadlines. The ledger was not touched. There was no full suite, no dev-build/run/package, and no visible app, helper or provider action. The reconciliation harness was not changed, because the reader suite already covers the planner import and replay path.

## Limitations

- This is fixture-backed reader qualification of one sanitized observed shape: CLI 2.1.302, the safe-mode plus restricted `--tools Read` profile, main-thread `Read` only, string-content prompts, one call per prompt, and successful results. It is **not** app qualification, live acceptance, a no-replay proof, or activation.
- It covers no thinking blocks, multi-block messages, parallel tools beyond the existing pinned fixtures, error results, permission denials or prompts, other tools, or array-content prompts. Other `mode` values (for example after a permission-mode change) refuse until they are observed and qualified.
- The live classifier still does not accept tool rows, and tool-row mutability is unchanged.
- Plan updates, evidence links and the guardrail allowlist are main's.

## Main review snapshot

Main read the complete 22438-character two-file diff and independently checked all five final tickets above. The source was staged and frozen as `2026-10-24/0904` (+323/−0). Fresh independent OracleA/OracleB initial reviews were sent together with identical source, capture evidence, validation and full review policy. No worker remains running. The earlier orphan error was resolved by a reachable evidence link. Main also ran the context checker and its 23 tests, guardrails and whitespace checks; only the existing route-count warning remained. Both results returned the exact expected preset identities and main read them in full. [OracleA](phase4d4-review-oraclea.md) approved without findings; [OracleB](phase4d4-review-oracleb.md) found no P0/P1. Main made only the cheap accuracy corrections: P2-01 relabels the pre-call attachment case correctly; P3-01/02 clarify nonprojected metadata comments; P3-03 explicitly labels the fixture as a semantic model with reduced operational record counts, not a byte-for-byte or ordinal copy. P3-04 extraction remains deferred as unnecessary. Runtime logic and assertions are unchanged; affected reader/style checks are rerun, with no P2/P3-only review round.

Final comment/label-only correction validated by main: reader 40/40, ticket `b105fd56-79bd-4da6-8232-22e1d6506494`; format-check `a5614808-1f89-43ec-bd6f-b0b4de6ec32d` and lint `cd846e30-566b-4fa0-b88e-cb498000905f`, all exit 0. Reconciliation 46/46 and product compile above predate only these non-behavioral edits. Main read the entire initial source diff and the complete +8/−6 comment/label delta; no additional review was required. No full-suite, packaging or live app acceptance is claimed.

The source diff is recorded in the Git review snapshot and subsequent local checkpoint; it is not duplicated here.
