# Step 4d3b: inactive single-text live identity (worker implementation evidence)

Scope: read when the task touches Claude live-output qualification (`ClaudeLiveTranscriptProducerState`), the native controller's producer-owned qualification latch, the transient `AIStreamResult.claudeLiveTranscriptEvidence` carrier, the view-model canonical owner of a qualified live assistant text, or live proof invalidation in the provider-history ledger.
Authority: Reference
Last-verified: 2026-10-24

Worker evidence for main's bounded Step 4d3b in [phase4d3.md](phase4d3.md#step4d3b-implementation-boundary). The worker implemented the controller-only scope reduction as one coherent inactive feature, on top of the Step 4d3a checkpoint `60132a4b8b8d83c3e21804452a98bc18b396c7cf`. It then applied main's bounded completion before the initial review:
- replay became optional corroboration;
- the observed shape now fails closed;
- the tool guards were cut.

The initial review of the staged 2349 snapshot was then dispositioned in the working tree; the index was not changed. See [Initial review disposition](#initial-review-disposition).

What the feature is and is not:
- **Inactive.** The injected `liveTranscriptQualificationEnabled` defaults to `false` and has no production caller. All gates stay OFF.
- **Not added:** a package DTO, translator or bridge change, persistent marker, store or journal, tool invocation ID change, CLI argument change, finalization change, architecture change, provider prompt, private capture, config read, or app/helper/lifecycle operation.
- **Fixture evidence only.** Nothing here qualifies Claude's live format.
- **Not committed.** The worker staged and committed nothing, and the original unrelated dirt was left untouched (see [Baseline](#baseline)).

## Changed files

Counts are against `60132a4b`.

| File | Change |
|---|---|
| `Sources/RepoPromptAgentCore/AI/Providers/ClaudeCode/SDK/ClaudeLiveTranscriptQualification.swift` | new, 441 lines: disqualification reasons, complete-text identity (with `matchesProjection`), evidence, carrier, outcome, producer state and classifier |
| `Sources/RepoPromptAgentCore/AI/Providers/ClaudeCode/SDK/ClaudeNativeProcessSessionController.swift` | +154/−2: injected flag, latch install/eligibility, outbound note, classification before suppression, carrier emission, direct-disqualification carrier, EOF-drain token and retirement, DEBUG seams |
| `Sources/RepoPromptAgentCore/AI/Providers/ClaudeCode/SDK/ClaudeSessionHistoryReader.swift` | +22/−1: `semanticMarker(in:)` internal; `singleTextAssistantRow` reuses `project()` |
| `Sources/RepoPromptAgentCore/AI/Providers/AIProviderFactory.swift` | +4: transient optional `claudeLiveTranscriptEvidence` |
| `Sources/RepoPromptAgentCore/AgentMode/Models/AgentSessionProviderHistoryRecovery.swift` | +40: `hasProoflessClaudeItem(nativeSessionID:)`, `invalidateClaudeEnvelopeProofs()` |
| `Sources/RepoPromptAgentCore/AgentMode/Runtime/Session/AgentTabSession.swift` | +9/−1: transient `claudeLiveTranscriptRefusedProducers`; corrected `providerHistoryRecovery` writer comment |
| `Sources/RepoPrompt/Features/AgentMode/ViewModels/AgentModeViewModel.swift` | +100: evidence pre-switch, canonical owner (projection and conversation guards), refusal/invalidation (no `tool_result` change) |
| `Tests/RepoPromptTests/AgentMode/ClaudeCompatible/ClaudeLiveTranscriptQualificationTests.swift` | new source suite, 8 tests |
| `Tests/RepoPromptTests/AgentMode/ClaudeCompatible/ClaudeNativeBackgroundTranscriptTests.swift` | +369/−2: 4 owner tests (extension of `AgentModeRunServiceLifecycleTests`); opt-in qualified mode of the existing `BackgroundTranscriptController` |
| `Tests/RepoPromptTests/AgentMode/Recovery/AgentRecoveryReconciliationTests.swift` | +135: 2 real-composition tests |
| `Tests/RepoPromptTests/AgentMode/Recovery/ClaudeSessionHistoryReaderTests.swift` | +64: 1 parity test |
| `Scripts/source_layout_guardrails.sh` | allowlist entry for this file |
| `docs/context/plans/evidence/2026-10-18-lossless-app-restart/phase4d3.md` | one link line to this file at the end of the Step 4d3b boundary section (added earlier, as instructed then) |

## Implementation

### Core classifier (`ClaudeLiveTranscriptProducerState`)

The classifier is pure and runs once per raw payload. It parses the exact bytes the translator read, before any translated result is filtered or suppressed. It inspects only the supplied key names and the value types or values named below. There is no generic recursive validator, and no private capture or auth field is read.

**Allowlisted O19 shapes:**
- **`system/init`.** Its keys must be a subset of the bounded known-key list: `additional_directories`, `agents`, `analytics_disabled`, `apiKeySource`, `capabilities`, `claude_code_version`, `cwd`, `fast_mode_disabled_reason`, `fast_mode_state`, `mcp_servers`, `messaging_socket_path`, `model`, `original_cwd`, `output_style`, `per_turn_effort_active`, `permissionMode`, `plugins`, `product_feedback_disabled`, `session_id`, `skills`, `slash_commands`, `subtype`, `tools`, `type`, `user_message_uuids`, `uuid`, `view_mode`. Values are not validated further.
- `command_lifecycle` with only the known keys, in state `queued`, `started` or `completed`.
- `rate_limit_event` with only the known `rate_limit_info` keys and status `allowed`.
- **User replay: optional corroboration only.** When a replay is present it must:
  - be the first replay of the open dispatch;
  - match the producer's own recorded outbound UUID and exact provider text;
  - have string content, `isReplay == true` and no parent tool use.

  Anything else refuses. The app's CLI arguments do not request `--replay-user-messages`, and they were not changed. An ordinary invocation therefore produces no replay, and qualification does not require one.
- **Assistant envelope.** Accepted only while the producer is eligible and its own identified dispatch is in flight.
  - **Ownership by consumed-user attribution.** When `user_message_uuid` is provided it must be a string naming exactly the outbound UUID. When `user_message_uuids` is provided it must be exactly a one-element array of that UUID. A contradiction refuses (`attributionMismatch`), even after a replay. An unreplayed dispatch also requires affirmative attribution: with neither attribution nor replay, the assistant refuses (`unattributedAssistant`). The latest message is never assumed.
  - **Shape.** It must have:
    - the allowlisted keys;
    - role `assistant` and a non-empty message ID;
    - `stop_reason`, `stop_sequence`, `container`, `context_management`, `diagnostics` and `stop_details` all null;
    - `input_transformations` absent or an empty array;
    - exactly one `{type,text}` block with non-empty text.
  - **Translation.** Its translated non-usage results must be exactly one `content` with the same text.
  - **Answered state.** The outbound identity is kept for the result.
- **Success result.**
  - Keys must be a subset of the bounded known-key list: `api_error_status`, `duration_api_ms`, `duration_ms`, `fast_mode_disabled_reason`, `fast_mode_state`, `first_content_frame_ms`, `first_request_input_tokens`, `is_error`, `modelUsage`, `num_turns`, `permission_denials`, `queued_turn_count`, `request_sent_wall_ms`, `result`, `result_index`, `safety_stops`, `session_id`, `stop_reason`, `subagent_stats`, `subtype`, `terminal_reason`, `time_to_request_ms`, `total_cost_usd`, `ttft_ms`, `ttft_stream_ms`, `type`, `usage`, `user_message_uuid`, `user_message_uuids`, `uuid`.
  - Required values: subtype `success`, `is_error == false`, a string `result`, null `api_error_status`, and empty `permission_denials`.
  - Values checked only when the key is present: `terminal_reason == "completed"`, `stop_reason == "end_turn"`, `safety_stops` a JSON integer 0.
  - Its `result` must equal the turn's qualified assistant text exactly, whatever the translator forwards.
  - Provided attribution must name exactly the turn's outbound UUID, with the same rules as the assistant.

**Everything else disqualifies,** including:
- an unknown type;
- system subtypes other than `init` (compact, status, task) and unknown init keys;
- `stream_event`;
- semantic markers at the top or message level (`supersedes`, `aborted`, `retracted_message_uuids`);
- a session mismatch;
- tool-use, thinking and multiblock content;
- non-null stop fields;
- non-empty input transformations;
- unknown result keys and other terminal, stop or safety values;
- non-success results;
- contradicting or missing attribution;
- a second assistant in a turn;
- an unidentified or overlapping outbound message;
- a malformed payload or line.

There is no broad all-system or all-rate-limit benign rule.

**Identity.** `singleTextAssistantRow` feeds one synthetic `.assistant` entry with a single `.text` block through the reader's existing `project()`. The complete text therefore carries the same deterministic local ID (namespace `rpce-claude-history-row-v1`), the same `envelopeDigest`, ledger key and `item(for:)` canonical row. No algorithm is copied.

### Controller latch (`ClaudeNativeProcessSessionController`)

The pre-review replay correction did not change the controller; the initial-review repair did, as described below.

**Lifetime.** A `ClaudeLiveTranscriptProducerState` is installed only where an actual `activeStdoutLaunchToken` is installed: the real spawn, and the DEBUG synthetic launch that stands in for it. A consumer reset, a new turn, `system/init` or a router change never replaces it.

**Eligibility.**
- The state is resolved right after `beginUsageLaunch`.
- An automatic, resolved, default-backend launch with no routing overrides (`outboundUserMessageIdentityEligible`) marks it eligible.
- Any other launch drops the state, giving exact parity with the gate OFF.
- Until eligibility is resolved the state stays pending: payloads are classified and disqualifications stick, but nothing is emitted.

**Reads and outbound.**
- A stale producer's state is never read: the state's token must equal the current stdout token, and stale stdout is already dropped by `isCurrentStdoutLaunch`.
- `sendUserMessage` notes the outbound UUID and text in the same non-suspending actor step as the successful write.

**Classification in `handleStreamPayload`.**
- **Attach:** sets evidence on the one `content` result. Content is never duplicated.
- **Standalone:** a metadata-only `lifecycle` carrier with nil text, no usage and no stop reason. It is emitted after the existing assistant usage emission and before the payload's own results, so it survives empty and suppressed output.
- **Unchanged:** the original-result-owned completion and usage branches.
- **Codec failures:** a failure in `handleLine` disqualifies with `malformedLine` before any recovery path.
- **Direct disqualification:** a disqualification outside payload classification (`malformedLine`, `malformedPayload`, `unidentifiedOutbound`, `overlappingOutbound`) of an eligible, still-qualifying producer emits one metadata-only carrier at once. Disabled, ineligible and already-disqualified producers emit nothing.
- **EOF tail:** `handleStdoutEOF` still clears the stdout token first. It sets a drain-scoped `liveTranscriptEOFDrainLaunchToken` only around its buffered-tail `handleLine` loop, so the exiting producer classifies its own tail. It then clears that token and retires the producer's state; a replacement launch's state is kept. While the drain is active, the lookup selects only the drain token's state, never the current stdout token's. The drain's only suspension is `handleLine`'s fatal decode path (`failProtocolAndShutdown` → `shutdown()`). During it, `startOrResume` can reset `isShuttingDown` and install a replacement launch, whose stdout task may run concurrently. That is handled three ways:
- **Before the suspension:** the fatal path disqualifies the exiting producer (one direct carrier) before it awaits.
- **Old tail:** the rest of the old tail never selects the replacement's state. Once the replacement replaced the exiting state, that tail is unclassified, and its producer was already refused.
- **Replacement:** a launch installed while a drain is active starts disqualified (`launchDuringDrain`), because its payloads during the drain cannot be classified. It never qualifies, and since it attaches nothing, it has nothing to invalidate.

Retirement compares tokens, so it never retires a replacement. No reentrancy test exists for this (there's no seam to suspend mid-drain); it is covered by code reading.
- **Monotonic:** once disqualified, the producer re-emits its first reason only on `user`, `assistant` and `result` payloads. This lets an owner whose consumer missed the first carrier hear it before any later turn's output. It never requalifies.

### Canonical owner (`AgentModeViewModel.applyStreamResult`)

Evidence is processed after the existing active/background delivery guard and before `switch result.type`. Gate-OFF results carry no evidence, so the generic path is byte-for-byte the old one.

**`completeText`** is accepted only when all of these hold:
- the delivery is `.activeRun` for a Claude native session;
- the producer was not refused in this tab;
- the evidence's local ID and digest are exactly the reader's projection of its entry and text (`matchesProjection`);
- its conversation equals the tab's `providerSessionID` when that is known and non-empty;
- the conversation has no proofless Claude row (never healed);
- the canonical row builds and carries the evidence's local ID.

**Order of effects when accepted:**
1. Clear the reasoning status.
2. Flush the older generic buffer.
3. End the run's assistant segment.
4. Append the `NativeItem` (with digest) and the non-streaming canonical row together in the MainActor snapshot.
5. Set `isDirty` and call `scheduleSave`.

No import receipt, cursor or prefix proof is minted.

**Already recorded.** The same key, an equal `NativeItem` (identity plus a valid proof) and the actual canonical row in the suffix, same text and not streaming, is a no-op.

**Refusals.** All of the following preserve the old state, let the incoming result continue through the legacy path unidentified, and refuse the producer:
- the same key with a changed text, or a missing row;
- a proofless entry;
- a collision, where the deterministic ID is already held by any canonical item (persisted turn or suffix) without its ledger entry;
- a background delivery.

**`resultAgreement`** agrees only when a Claude ledger entry with that local ID has a non-nil digest and the suffix holds that assistant row with exactly that text. Otherwise it refuses. It never changes the transcript.

**`disqualified`** refuses.

**What a refusal does:**
- Inserts the producer token into the tab's transient refused set.
- Runs `invalidateClaudeEnvelopeProofs()`. This clears the typed `envelopeDigest` and the raw `extras["envelopeDigest"]` of every Claude row in the tab's ledger. Keys, local IDs, other extras, Codex rows, receipts, baselines and ledger extras are preserved.
- On any change, explicitly sets `isDirty` (the property has no observer) and calls `scheduleSave`.

The scope is conservative: all Claude rows of the tab, because disqualification evidence carries no trusted conversation binding. The reader refuses a known entry whose digest is nil (`ledgerConflict`), so reconciliation of these rows refuses.

**Generic writers.** Step 4d3b keeps the Step 4d3a assistant guards (delta, `final_content` and background delta) unchanged. It adds no `tool_result` guard and no finalization change. A single-text qualified turn creates no tool row. Qualification of tool rows, including protection from the generic `tool_result` writers and terminal `finalizePendingToolCalls`, is out of scope and left for a future step.

## Initial review disposition

Two independent reviews of the staged 2349 snapshot were dispositioned in the working tree; the index was not changed. Main keeps the raw review copies and status.

| Finding | Disposition |
|---|---|
| A R1: a direct disqualification (undecodable line or payload, unidentified or overlapping outbound) never reached the owner without a later payload | **Fixed.** One immediate metadata-only carrier on the transition of an eligible producer (see [Controller latch](#controller-latch-claudenativeprocesssessioncontroller)). Sticky repetition is unchanged. Tests: controller carriers, plus the end-to-end owner invalidation. |
| A R2 / B F2: the EOF-flushed tail was never classified | **Fixed** with a drain-scoped EOF token. The existing stdout-token clear is not moved, gate-off ordering is unchanged and the state is retired after the drain. Tests: controller tail classification with gate-off parity, plus the end-to-end owner invalidation. |
| B F1: clearing every Claude proof on any refusal would disable 4d2 recovery once enabled | **Deferred activation blocker.** The conservative scope stays, with no launch→row map. The gate stays off, and no owner acceptance is claimed. |
| B F3: the history-only merge might overwrite live ledger changes made during its reads | **Already guarded.** In `AgentModeViewModel+RecoveryActions.swift`, `reconcileRecoveryHistory` captures `ledgerAtStart` before its record and history awaits. On the main actor it then requires `session.providerHistoryRecovery == ledgerAtStart` (the guard ending "The session changed while its history was read. Nothing was imported."). No suspension occurs before it assigns `plan.ledger`. A live insert or invalidation during the reads therefore blocks the merge. The stale `AgentTabSession.providerHistoryRecovery` comment ("changed only by the history-only merge") was corrected. No dedicated injected-disqualification test was added. |
| B F4: no controller → runner → view-model test | **Added**, using the small existing harness: `BackgroundTranscriptController` (the real controller, translator, events stream, integrated runner, run service and view-model handler) gained an opt-in qualified O19 mode. |
| B F5: the complete text's ID and digest could disagree with the row | **Fixed:** the projection and row-ID guards. |
| B F6: no check against the tab's conversation | **Fixed:** a known non-empty `providerSessionID` must equal the evidence's conversation. |
| B F7: the test hid a legacy merge | **Clarified** with a comment: ending the segment avoids legacy merging of the next unidentified text. |

## Validation

All runs were coordinated `make dev-*` operations. No full suite, packaging, app run, provider, capture or lifecycle operation ran, and no `make dev-format` mutation was made. Each ticket below was checked with `./conductor job status <ticket> --full-log` for its operation and filter, not taken from the shared job list's order.

**Final source state (after the review disposition, working tree):**

| Check | Ticket | Result |
|---|---|---|
| Compile RepoPrompt (`make dev-swift-build PRODUCT=RepoPrompt`) | `50636fda-8b5a-42e0-a37b-5a9852ba11c4` (operation `swift-build`, product `RepoPrompt`) | succeeded |
| `ClaudeLiveTranscriptQualificationTests` (new source suite; the frozen ledger warns and runs it with default deadlines) | `3493e42c-b614-4356-bba5-e187c74367b1` (operation `test`, filter as named) | 8/8 |
| `ClaudeSessionHistoryReaderTests` | `3fc21435-bfb0-4018-89ad-af00bfd7c582` | 35/35 (34 + 1 new) |
| `AgentModeRunServiceLifecycleTests` (owns `ClaudeNativeBackgroundTranscriptTests`) | `272ce871-4cc8-4608-897b-74593d996ef4` | 199/199 (195 + 4 new) |
| `AgentRecoveryReconciliationTests` | `ed99d0ec-521f-4139-a76c-01e0c9614d13` | 45/45 (43 + 2 new) |
| `ClaudeNativeUsageAttributionTests` (controller parity) | `d62bd435-299d-4dc5-865a-3f50431330c0` | 16/16 |
| `make dev-format-check` | `de6387c8-4af4-485a-bae5-d41bfa8da81a` (operation `format-check`) | 0/2177 files require formatting |
| `make dev-lint` | `5f87c72c-d064-4aa8-a569-3e9cd48ee86e` (operation `lint`) | passed (exit 0, no warning or violation lines) |

The reader and reconciliation tickets above predate the EOF-drain context fix (lookup preference, fatal-path disqualification, `launchDuringDrain`). That fix changes only controller code and adds an enum case, so those two suites were not rerun. Before that fix, the disposition passed compile `1aa64e16-da1f-40a2-b19d-5847feb2a15b`, qualification `03e83ddf-271f-46bc-844e-2d42e17f45f3` (8/8), lifecycle `be5e4d8a-3f02-4def-9c29-107e3b81c8c3` (199/199), usage `57be3b20-62e7-4c6f-9cff-f245e32bdbcd` (16/16), format-check `dfd15ae8-bd22-454f-ac4e-a69fbfe2fe9e` and lint `50561830-2d1c-4bd2-91a8-d96505092b6d`.

**Superseded runs on the staged 2349 snapshot.** These passed: compile `1b393a5f-6294-45b2-a0d2-7efd2a77f543`, qualification `7bfd7cca-3fee-48d7-be8f-68d2633152cc` (7/7), reader `2d467b75-fc88-404d-8f57-d0af713eb293` (35/35), lifecycle `00327396-7b05-41a2-a042-ebcc8c9806d6` (197/197), reconciliation `c680050c-e544-4cd2-bc8e-4b61d1d29fa7` (45/45), usage `64bba687-0f7a-4734-922c-dac1ea57182a` (16/16), format-check `f5d8e23e-2ff1-4725-8387-85a15bc42085` and lint `d01baa19-93e2-4d01-9cb6-01a025e30029`.

**Superseded runs on the pre-correction source.** These passed: compile `6f3380db-3071-4f9c-b5a0-fc7c0cb2ca0b`, qualification `d416ff23-9ac9-4bec-ab90-f83dd2330ac5` (6/6), reader `f9087ecb-8b45-4633-8ba9-fe1e7fbd9522` (35/35), lifecycle `6f7e396f-6225-4894-bda9-9244e6b6409f` (198/198, including the since-cut tool-row test), reconciliation `cdbeb141-7a88-401d-82d5-5152c0ebd36d` (45/45) and usage `e21f5daf-1ced-4b9d-a0e7-f7cc34c6d7c0` (16/16). Format-check and lint also passed then, but their ticket IDs were not captured.

**Earlier runs:**
- First compile `02bb61d6-aaa7-4173-ad6a-3e9da9df7d47` succeeded.
- Test compile `aef90ceb-93fc-4e0b-86dd-058b91132e2f` failed on test-only API misuse. `AIStreamResult` tool fields are `let`, and tool invocation IDs are UUIDs. Fixed in the tests.
- `97b8149e-380e-4bfe-a2b9-5c6065347e81` and two single-test runs hit the 180 s active-method deadline in the new suite's drain. See [Test-seam finding](#test-seam-finding).
- Diagnostic `edb08e34-a3a3-4fa2-aa55-9c1357b1cbe7` failed fast after the subscription-generation check was added.
- After the fix, pass tickets `4233621d`, `6228e880`, `c8f6a93d`, `194289b1` and `d74e9dbc` preceded the formatting edit (removing redundant `Sendable`).
- Temporary debug output, `print` calls and a `/tmp` log written by a test-local helper, was used only to locate the hang. It was removed before final validation, and the `/tmp` file was deleted.

No deadline was disabled and no assertion was weakened.

**Not run:** the full suite, other suites, the debug app, packaging, a live provider capture and production activation. Repository doc checks are listed with the final handoff.

## Test-seam finding

`ClaudeNativeProcessSessionController` conforms to `NativeAgentRuntimeControlling`. That protocol's extension defines async defaults for `emitEventMarker(_:)` (returns `nil`, yields nothing) and `eventsSubscription()` (generation `nil`). A direct `await controller.emitEventMarker(...)` on the concrete actor binds the async extension default, because overload ranking prefers async in an async context. As a result no marker was yielded and the original drain waited forever.

The suite now reads events through the protocol existential, as the runner does, which dispatches to the actor's witnesses. It keeps one long-lived iterator per subscription, and fails fast unless the marker's generation equals the subscription's. Production callers use the existential. Direct concrete calls elsewhere were not audited and remain a latent pitfall.

## Tests added (coverage map)

| Requirement | Test |
|---|---|
| Current app shape: no replay, attributed assistant and result qualify and agree; missing attribution without replay refuses; contradicting `user_message_uuid`, non-singleton `user_message_uuids` and a replayed-but-contradicting assistant refuse; non-empty `input_transformations` refuses; result contradiction, unknown result key and other `terminal_reason`/`stop_reason`/`safety_stops` values refuse; an unknown `system/init` key refuses | `testUnreplayedDispatchQualifiesOnlyWithExactConsumedUserAttribution` |
| Gate-OFF and ineligible parity on the no-replay app shape; eligible adds only evidence (same results, order and finalization; content never duplicated; carriers have no text, usage or stop) | `testGateOffAndIneligibleLaunchesMatchLegacyOutputAndEligibleAddsOnlyEvidence` |
| Complete single-text proof/digest/ID parity with the reader's projection of the same history entry, with replay corroboration; an invalidated proof refuses as `ledgerConflict` | `testLiveQualifiedTextMatchesTheHistoryProjectionOfTheSameEntry` (reader); `testO19TurnAttachesOnceWithTheReadersIdentityAndResultAgrees` |
| Unknown, suppressed and empty signals; disqualifier table, including a replay of another message; direct disqualifications (undecodable line, unidentified and overlapping outbound) emit one carrier at once, never repeated directly, and nothing when disabled or ineligible | `testUnsupportedShapesDisqualifyWithTheirReason`, `testEmptySuppressedAndMalformedOutputDeliverDisqualification` |
| An unterminated final stdout record is classified during the EOF drain (a contradicting result is refused before the stream ends); the producer retires; gate-off results and order are unchanged | `testEOFDrainedTailIsClassifiedBeforeTheProducerRetires` |
| End to end through the real controller, runner, run service and view model: the qualified turn inserts the canonical row with its proof while carriers add no rows and the run completes; a later undecodable line, or a contradicting EOF tail, reaches the owner between runs and invalidates the proof | `testClaudeLiveEvidenceReachesTheOwnerThroughTheRunServiceAndLaterRefusalsInvalidateProofs` |
| A projection-inconsistent ID or digest, or another conversation than the tab's, is refused; the exact projection is accepted | `testClaudeLiveCompleteTextMustBeTheReadersProjectionForTheTabsConversation` |
| Latch survives a consumer reset and later turns; a new producer resets; a stale token never stamps the replacement | `testLatchSurvivesConsumerResetAndTurnsAndOnlyANewLaunchResetsIt`, `testDisqualificationIsStickyAndNeverRequalifies` |
| Active/background routing, collision, refused producer, typed and raw invalidation, preserved members | `testClaudeLiveRefusalsInvalidateProofsAndRefusedProducersNeverRequalify` |
| Insert, duplicate, conflict, final-text agreement, no healing | `testClaudeLiveCompleteTextInsertsCanonicalRowOnceAndConflictsInvalidateProofs` |
| Coherent row+proof save round trip; import records without duplicating; durable invalidation with unchanged native history refuses; no healing after reload | `testLiveQualifiedRowRoundTripsAndInvalidationRefusesWithoutHealing` |
| Save ordering with the existing hook (an older in-flight snapshot never outlives the invalidation) | `testAnInFlightOlderSaveNeverOutlivesALiveProofInvalidation` |

## Accepted boundaries

Main accepted these boundaries; they are not broadened.

- **Conservative invalidation.** Every refusal invalidates all Claude proofs of the tab's ledger. Review B F1 records this as an activation blocker: under the strict allowlist, refusal is the normal outcome for tool-using sessions, so enabling the gate as is would end 4d2 recovery for most tabs.
- **Suffix-only late duplicates.** The owner's duplicate and agreement checks look only at the suffix (`session.items`). After a terminal commit moves the row into a persisted turn, a late duplicate or agreement refuses (fail-closed) rather than matching.
- **Scheduled-save crash window.** `scheduleSave` is the boundary. A crash before the invalidation commits leaves the old proof on disk; there is no crash-safe revocation, and gates stay OFF.
- **Transient refused-producer set.** Across a reload, the persisted proofless rows block requalification of that conversation, while a new conversation can qualify.

## Other limits

**Out of scope (future).** Tool-row qualification, including generic `tool_result` writers and terminal `finalizePendingToolCalls`.

**Field checks.** `model`, `request_id`, `usage` content and `system/init` values are not compared. An equal-text `final_content` records no provenance (F2, unchanged).

**Carrier delivery.**
- A carrier dropped by the active-run delivery guard (a stale run ID) relies on the producer's sticky re-emission. That reaches the owner on the next `user`, `assistant` or `result` payload, not on lifecycle or system payloads.
- Classification of payloads that arrive before the launch identity is recorded uses the pending state. An assistant then disqualifies.

**Coverage method.** The `sendUserMessage` wiring is covered by code reading plus the mirrored DEBUG seam `test_noteLiveTranscriptOutbound`, also from the end-to-end harness's send. A real subprocess write was not exercised, and the end-to-end test uses a synthetic launch, not a spawned process.

**Qualification status.** No new capture-qualification claim is made. The fixtures mirror the allowlisted notes: no replay with consumed-user attribution as the current app shape, an optional exact replay, 0 `stream_event`, and equal native/live/result text.

## Baseline

The pre-existing unrelated diff (`.gitignore`, `AGENTS.md`, `CodemapSeamTestSupport.swift`, `code-mode-measurements.md`, the code-mode plan, the lossless spec and `phase4d3.md`, plus untracked `2026-10-18-turn-worktree-checkpoints-spec.md` and `completed/2026-10-18-codemap-wait-fix-plan.md`) matched the saved baseline (md5 `f76a1b24e3033c8b8ac58a0d14954666`). The only later change to those files is the one link line appended to `phase4d3.md` earlier, as requested at that time.
