# Phase 4 bounded source investigations

Scope: read when the task touches older saved-input canonical ownership or Claude native identity after the inactive lossless-restart checkpoint.
Authority: Reference
Last-verified: 2026-10-22

## Outcome and scope

O10's two source-only investigations are complete. Neither implements or qualifies recovery. The older-message contract, normal-live Claude merge and full Phase 4 remain blocked. Production registry, Stop, fresh-Claude-ID, Resume/history and automated Restart remain OFF; O3 live acceptance is pending.

The owner's notes and O10 were first persisted in signed local commit `206bcbf95353fc3de107114dc5b54ac66d6ee1cf` (six files, documentation plus three exact evidence allowlist entries). The production source under investigation remains the inactive partial checkpoint `fbc1ef041cd7000255c102f7abd7e2464120fe25`.

Read-only workers:
- Older input: session `A3EFFAB5-63E9-4587-B3DF-04C04DA2FB92`, run `FD80746A-90F1-4A08-9C61-FAB754D8420A`.
- Claude identity: session `018CC46A-FE3B-4237-98F9-20CBE2D55324`, run `42D2A7E6-51AA-4BF2-BF7C-D352FB1E966D`. Initial full result is local `prompt-exports/agent-run-018cc46afe3b-1fcca948.md`; a follow-up in the same session checked only official public protocol sources.
- Both completed. Neither edited files, started another worker/Oracle, ran tests, inspected user runtime data, executed a provider or changed activation. Main read their complete results and spot-checked the load-bearing references below. Reports are evidence claims, not authority.

## Older saved input: confirmed source behavior

1. `AgentModeViewModel+RecoveryActions.swift:412-477` searches canonical request anchors, mid-turn user activities and working suffix copies, then refuses an older shown message. `AgentModeViewModel.swift:16898-16934,17428-17440` checks synchronously and reuses a latest bubble without duplicating it.
2. The runtime anchor is not output routing. Main read `AgentModeViewModel.swift:4321-4347`: it chooses the assistant row for the “Worked for” footer. Ordinary live output updates a streaming row or appends to the suffix (`:19399-19475,19916-19931,20010-20023`); Codex also uses its native item scope (`CodexAgentModeCoordinator.swift:6445-6485`).
3. This reaches canonical grouping in the real refresh path, not just an unused legacy helper. Main read the incremental/fallback calls at `AgentModeViewModel.swift:12017-12051,12127-12134`. `AgentTranscriptServices.swift:3311-3316,3376-3391` orders source rows and starts turns from user items.
4. `AgentTabSession.swift:43-46` expressly limits `items` to the mutable full-detail suffix. Main read `AgentTranscriptServices.swift:2758-2787`: working-turn replacement preserves every non-full canonical turn. A suffix remove-and-append cannot delete a canonical-only older occurrence.
5. Main read structural trimming at `AgentTranscriptServices.swift:6360-6410`: non-full spans keep only the conclusion activity, so older mid-turn user placement can disappear. The eligibility selector at `:6092-6106` has no recovery-intent-specific protection. This is not proof that every queued input reaches that state.
6. Main read `AgentRecoveryModels.swift:475-503,915-916` and `AgentRecoveryStore.swift:1930-1959`: payload, origin, deterministic user-item ID, creation time and the submission-ordered intent array survive independently. There is no explicit original transcript sequence/turn/span placement member in that intent shape.
7. Main read the existing fenced canonical save entry at `AgentSessionDataService.swift:2443-2480`. It is the authority to reuse, not a second transcript store. The worker located paired projection installation at `AgentModeViewModel.swift:12758-12794` and canonical save preparation at `:14663-14700`; those deeper call sites still need implementation-specific verification before a patch.

### Concrete failure of the smaller-looking suffix patch

Suppose conclusively unsent A remains as a compacted canonical request, followed by accepted B and C with their own output. Only B/C remain in the working suffix. Removing A from the suffix removes nothing; appending A under its same ID creates another placement while the rebuild preserves old A. Reusing old A without relocating instead leaves later C as the trailing request for newly appended output. Either duplication or wrong request ownership is possible.

For an erased mid-turn A, the recovery intent can reconstruct the payload and identity, but cannot recover its discarded exact old sequence/span placement. Flattening only surviving rows is not reconstruction of canonical history.

### Feasible direction, not implemented safety

A targeted detach-and-tail operation within the existing canonical owner is plausible. It must remove only the saved unsent user's authoritative placement/projections, preserve unrelated request/output/tool state and references, create the same user item at its new execution sequence, repair affected turn envelopes/summaries/frontier, persist through the existing owner, verify that save, then revalidate and use normal dispatch. No existing helper in the inspected chain implements that complete operation. This is a bounded-search conclusion, not a repository-wide proof of API absence.

Do not silently discard the old turn envelope if it owns notices, output, interruption or checkpoint references. Avoid duplicate turn/item identity when old envelope state must remain. Future pinning against compaction does not repair already compacted history.

Existing regression seams to reuse if a patch is selected:
- `AgentRecoveryVMProducerAdmissionTests.swift:786,832-895,900` (reused bubble cleanup, canonical lookup and refusal).
- `AgentModeViewModelInactiveRefreshTests.swift:196` (retention reconciliation).
- `AgentTranscriptRawInputReuseLifecycleTests.swift:161` (cold/warm derivation).
- Add only the missing behavioral cases: request/activity/canonical-only/compacted placements; B/C ownership unchanged; failed save/stale target/duplicate click; reload between relocation and handoff; zero bytes when proof is absent. No new test framework is indicated.

## Claude: confirmed local evidence

- The shipped pre-byte baseline producer saves dispatch/user IDs plus file identity/offset, verifies its receipt, then seeds the cursor (`AgentModeViewModel+RecoveryActions.swift:708-748`). It is not native-user association.
- Main read the package encoder at `ClaudeSDKProtocolCodec.swift:189-206`: it sends text and session ID, not the local user UUID. The controller writes before local turn tracking (`ClaudeNativeProcessSessionController.swift:955-960`); its returned local turn UUID is not provider acceptance evidence.
- Main read `ClaudeSDKNDJSONTranslator.swift:916-923`: live tool-use strings map to translator-local random UUIDs. The raw tool-use string is not retained on the demonstrated result DTO.
- The bridge carries only currently available result fields (`ClaudeCompatibleProviderRuntimeBridge.swift:254-295`); content/tool results lack a proven native JSONL row/block association. The worker traced controller stream emission through `ClaudeIntegratedAgentModeRunner.swift:388-399,732-733` to the actual app reducer.
- Main read `AgentModeViewModel.swift:19399-19475`: live content buffers/merges and final content can replace a trailing assistant row. The tool reducer can replace a call with its result under one local item ID (`:19564-19590`). These are not one-native-row/one-local-item guarantees.
- Main read history projection `ClaudeSessionHistoryReader.swift:632-684`: import IDs derive from provider/session/entry UUID/kind/block ordinal; native user-text rows have nil local identity; import tool invocation IDs are deterministic from tool-use identity. These do not match live random identities by construction.
- Main read captured stdout fixture `ClaudeNativeUsage/2.1.268-child.jsonl:3-9`: two assistant envelopes share API `message.id` but have different envelope UUIDs; user envelopes can represent a child prompt or tool result. This defeats API-message-ID-only and first-user-text heuristics. It is stdout evidence, not a paired native-file trace.
- Main read `ClaudeSessionHistoryReaderTests.swift:5-11,209-227`: history fixtures are explicitly constructor-derived, not live qualification. Whole candidates reject file-history snapshots/system/sidechain/compaction metadata. `ClaudeSessionHistoryReader.swift:294-319` validates every complete line before applying its cursor. Ordinary native-file viability remains unproved by the scoped fixtures; stdout metadata does not prove native-file metadata.
- Main re-read `ClaudeSessionHistoryReader.swift:331-350` and `AgentProviderHistoryImport.swift:97-125`: known keys suppress rows. A partial local “Hel” plus a native final “Hello” must not become “already fully imported” merely because identity was associated. Any later solution needs partial-to-final materialization semantics, not only IDs.

### Official public protocol evidence, checked 2026-10-22

The follow-up found a positive acknowledgement route, so a live observation is not the only conceivable evidence source:

- The [official CLI reference](https://code.claude.com/docs/en/cli-reference#cli-flags) documents `--replay-user-messages` as stdin-user acknowledgement on stdout under stream-json input/output. Main verified that entry. It does not explicitly establish equality with persisted native entry identity.
- Official releases [v0.3.265](https://github.com/anthropics/claude-agent-sdk-typescript/releases/tag/v0.3.265) and [v0.3.269](https://github.com/anthropics/claude-agent-sdk-typescript/releases/tag/v0.3.269) document UUID-based answered-user attribution, including supplied synthetic input, mid-turn pickup and partial/complete reply surfaces. Main verified those release notes. Attribution of answered users is not the assistant row's identity.
- The official Python native-file reader at pinned revision `3cb0c27eca8caccdc153471a1b19f97fce4ada03` copies a JSONL entry's UUID into its returned session message; main verified [the conversion](https://github.com/anthropics/claude-agent-sdk-python/blob/3cb0c27eca8caccdc153471a1b19f97fce4ada03/src/claude_agent_sdk/_internal/sessions.py#L1146-L1163). A reader is not evidence of how the closed CLI assigns that UUID.

The scoped official lookup did not establish caller UUID = replay acknowledgement UUID = native user-entry UUID, complete assistant envelope UUID = native assistant-entry UUID, or partial-event identity's relationship to a final native row. It also does not qualify the owner's actual shim/version. Do not infer these joins from text, timing, relative file position, SDK field names, checkpoint usefulness or wrapper transport preservation.

### Exact remaining evidence request

Use either an explicit applicable provider contract/writer-source guarantee, or a separately authorized disposable, version-pinned sanitized paired observation:
- one outgoing local input and any identifier-bearing acknowledgement;
- corresponding native JSONL user/output records, including surrounding record types;
- partial and complete stream events with canonical local IDs/content;
- preserved identifier equality/cardinality/block order during sanitization.

A passive matching-text trace cannot establish a positive user join. A paired observation can validate/falsify the relationship for that case, not guarantee every version, merged dispatch, interruption and shim. The protocol/source claim and qualification scope must remain explicit. No logger, schema or generic provenance framework was built.

Minimal future suites depend on the established seam: `ClaudeSDKProtocolCodecTests`, `ClaudeSDKNDJSONTranslatorTests`, `ClaudeCompatiblePluginBridgeTests`, `ClaudeNativeBackgroundTranscriptTests`, `ClaudeSessionHistoryReaderTests`, `AgentRecoveryReconciliationTests`. They were not run for this source-only investigation.

## Product choice, assumptions and deferred work

Main asked the owner whether Send saved may move/reconstruct the same unsent bubble at the current conversation end, preserving ID/payload/saved chronology and unrelated history, and leave it unsent there after a failed dispatch. Alternatives were original-position targeted insertion or deferral. The question timed out after 303 seconds with no selection. No new owner Decision was recorded.

The owner subsequently selected this behavior explicitly as O11; [the bounded implementation follow-up](phase4a-saved-relocation.md) supersedes the earlier unanswered choice. At the investigation checkpoint, for further reversible planning only, main's recommended assumption was same-ID move/reconstruction with commit-before-handoff and no rollback of the visible relocation on a pre-handoff refusal. That earlier assumption was not owner approval. O11 now selects the product semantics, but does not prove implementation safety or authorize live work. The bounded follow-up must preserve old-envelope identity/references and complete historical coverage; a suffix-only subset is not full completion.

Automated Restart stays deferred rather than changing the unresolved-arm failure contract. Main re-read production qualification at `AgentProcessRegistrySupport.swift:58-96` and `AgentRecoveryActionRunner.swift:23-53`: all-pairs registry activation and the shared Continue/Send/Answer action gate are unchanged. Fixtures cannot activate either. O3 live acceptance, provider execution, runtime-data inspection and visible app actions remain unapproved.

## Maintainer-guidance check

- User invariant: no copied/lost saved input, wrong-request output, duplicate answer or omitted partial tail.
- Confidence: source ownership/compaction/identity gaps are confirmed in the inspected paths; same-ID canonical relocation is plausible, not proven safe; native protocol joins are unknown.
- Authority: existing recovery store/coordinator, canonical session owner/DataService and provider protocol; no parallel authority.
- State safety: preserve all unrelated history, fence stale sessions, commit before bytes, keep association distinct from full materialization.
- Scale/observability: one explicit-action canonical operation, not per-event scans or a new service/logger.
- Recommended scope: source evidence complete; next is a bounded conditional canonical design and exact external identity evidence, not speculative implementation or activation.
- Validation boundary: static reads and primary-source lookup only; neither fixture safety nor live behavior was exercised.

## Validation and checkpoint

Notes/decision persistence ran `Scripts/check-agent-context`, all 23 `Scripts/test-check-agent-context` cases, `make guardrails`, `.githooks/pre-commit` and staged whitespace checks successfully. The existing 24-route warning remains. The first staged raw-response whitespace check failed; Markdown hard breaks in OracleE's local copy were converted to explicit line-break markup, and the staged check passed before signed commit `206bcbf9`. Original tool exports remain unchanged.

No Swift source, tests, package definitions, production gates, frozen ledger or release metadata changed. No build, root test, provider/helper/MCP execution, packaging, app lifecycle, signalling, home/credential inspection, performance campaign, new Oracle review, push or history rewrite ran. This evidence adds no new owner Decision and does not reopen the capped Phase 4 review. Documentation-only evidence needs no new behavioral review.

For the completed investigation evidence, main reran the context checker and all 23 checker tests, staged the exact five intended documentation/allowlist paths, read the complete staged diff, and passed `make guardrails`, `.githooks/pre-commit` and the staged whitespace check. Only the existing route-count warning remained. Worker polling and scoped session listings confirmed both workers completed, with no running or waiting-for-input children. Original unrelated dirt remains excluded.

Checkpoint signing attempt failed with `1Password: failed to fill whole buffer` and `failed to write commit object`; HEAD stayed at the signed notes commit. O8 permits a per-invocation unsigned fallback, used for this documentation-only findings checkpoint without changing signing configuration or rewriting history.
