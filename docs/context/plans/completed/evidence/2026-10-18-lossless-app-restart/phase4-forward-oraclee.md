# Phase 4 forward guidance — OracleE

Scope: read when the task touches the independent forward-guidance consultation for the inactive lossless-restart Phase 4 checkpoint.
Authority: Reference
Last-verified: 2026-10-22

This is planning advice, not another acceptance review or an owner decision. See [main disposition](phase4-forward-guidance.md) before adopting any recommendation. Source checkpoint: `fbc1ef041cd7000255c102f7abd7e2464120fe25`.

Preset identity verified: `OracleE`, `95F2BD07-4A94-417C-AAAF-17CAB847EC35`, explicit selection. Both lanes received the same controlled request and current source excerpts, with the complete review policy attached; automatic workspace selection was excluded. Neither lane received the other's response. No checks were run by either lane.

Trailing Markdown whitespace is normalized for the local checkpoint; the original tool export remains unchanged. Findings wording is preserved.

## Complete exported response

# Oracle Plan

## Summary

**Preserve the existing architecture and keep the current checkpoint inactive.** The smallest useful product outcome remains preserved input, honest interruption state, and ordinary quit followed by manual reopening; that source is already committed, with live acceptance still pending. I recommend three bounded follow-ups: first, determine whether an older, provably unsent item can be relocated under its **same identity** through the canonical transcript authority; second, establish the smallest Claude-specific identity bridge needed for safe history reconciliation; third, record a precise source-validation boundary while explicitly deferring automated Restart. A transcript routing redesign, generic provider provenance framework, and new helper service are not justified by this packet. This is independent, packet-only guidance: no checks were run, and nothing here changes O3/O9 or authorizes implementation or activation.

## Current-state analysis

### Saved input already has the right ownership path

The recovery action path reserves a choice durably, carries its authorization through a store-issued queue receipt, and enters the existing submission path. `dispatchRecoverySavedIntent` requires one saved intent, a current session/lane, an idle local session, readable attachments, and affirmative evidence that earlier attempts did not deliver the input. It then calls ordinary `submitUserTurn`; it does not create a second dispatch mechanism. These are reusable safeguards. <br>
**Evidence:** `AgentModeViewModel+RecoveryActions.swift:486–550`.

The remaining older-message restriction is deliberate. `recoverySavedIntentBubble` searches both canonical request anchors/mid-turn activities and the working suffix, checks the shown payload, and refuses when a later user item exists. `appendPreparedUserTurn` can reuse the identified bubble and start a new runtime footer, but does not relocate it. <br>
**Evidence:** `AgentModeViewModel+RecoveryActions.swift:390–478`; `AgentModeViewModel.swift:17428–17452`.

That restriction protects a demonstrated ownership hazard: the legacy transcript importer sorts by sequence and starts a new turn at each user item. Appending output after a later request can therefore associate it with that later request. The excerpts do **not** establish that every current output path necessarily uses this importer, nor that no targeted canonical mutation already exists elsewhere. Those are bounded source-probe questions. <br>
**Evidence:** `AgentTranscriptServices.swift:3297–3409`; `AgentTabSession.swift:3005–3037`.

### History recovery has a transaction boundary, but not normal-live Claude association

The Claude pre-byte baseline producer is already wired. When enabled, it saves an immutable dispatch boundary through the session owner, verifies the commit, and only then seeds the recovery cursor. A baseline identifies where a dispatch could have begun; it does not identify which native user record or output belongs to which local item. <br>
**Evidence:** `AgentModeViewModel+RecoveryActions.swift:623–737`.

Reconciliation reads history off the main actor, revalidates the session on the main actor, checks association evidence across canonical history and the suffix, then saves rows, native-key ledger, and import receipt together. The recovery cursor advances afterward by CAS. This transaction should remain the authority. <br>
**Evidence:** `AgentModeViewModel+RecoveryActions.swift:760–906`; `AgentSessionProviderHistoryRecovery.swift:3–17`.

The demonstrated stream fields do not close the association gap. The translator extracts an envelope UUID for usage observations; `contentMessageID` has documented API-message usage semantics and is unset for Claude content results. Neither establishes a JSONL-entry identity or a local transcript-item identity. <br>
**Evidence:** `ClaudeSDKNDJSONTranslator.swift:1134–1157`; `ClaudeProviderStreamResult.swift:103–108`.

Codex already uses its existing coordinator/controller observation route. Verified completion is retained independently of whether recovered rows can safely project or save. Preserve that separation; do not introduce another reader or client. <br>
**Evidence:** `AgentModeViewModel+RecoveryActions.swift:820–870, 891–906, 966–994`.

### Restart is a separate, inactive lifecycle addition

The helper uses the existing bundled executable and the shared shutdown pipeline. The parent’s budget is one absolute eight-second attempt, with cleanup reserved inside it. A correlated abort acknowledgement or exact-child exit establishes that the helper cannot reopen the bundle; a signal result does not. <br>
**Evidence:** `AppRelaunchCoordinator.swift:6–12, 142–154`; `ProcessRelaunchHelper.swift:605–649, 908–969`; `AgentLifecycleShutdownCoordinator.swift:872–905`.

The arm-sent/unknown-stop branch retains ownership and offers no choices, potentially leaving lifecycle work wedged. That is an acknowledged, unapproved exception—not a reason to reopen the already completed ordinary quit/window-close work. Production composition currently prevents spawning this helper. <br>
**Evidence:** `AgentLifecycleShutdownCoordinator.swift:91–100, 800–815`; `AppRelaunchCoordinator.swift:168–185`.

## Design

### 1. First: resolve older saved input with a bounded canonical relocation probe

**Recommendation:** investigate same-item relocation before requesting a routing redesign. Do not remove the “not latest” refusal until the replacement behavior has been demonstrated across canonical history, later turns, and compaction.

#### Separate the contract from the presentation assumption

| Requirement | What must survive |
|---|---|
| Stable identity | The existing intent ID and deterministic user-item ID. A copied message with a new ID does not complete recovery of the original. |
| No duplication or loss | One authoritative input, one explicit handoff, no duplicate bubble, and no automatic retry after a crash. |
| Payload and provenance | Saved text, attachments, tagged files, workflow/interview choice, origin, and applicable schedule/handoff provenance. |
| Order | The original durable ordering information and the meaning of any explicit decision to send this item now. |
| Correct output ownership | New output belongs to this saved request’s actual execution, without changing the ownership of later requests or their results. |
| Fixed visual position | The quoted spec does **not** explicitly require an unsent bubble to remain permanently at its original visual position. |

The order requirement still matters. Moving an item to become the next executed request is not automatically equivalent to preserving its original queue precedence. The owner-visible choice should be explicit: **send this saved input now, after the conversation’s later turns, and move its existing bubble to that execution position while retaining its identity and original saved chronology.**

That can be a legitimate interpretation of the spec, but it needs an owner selection. If “order” instead requires the original transcript position or original dispatch precedence to remain fixed, relocation is not the selected solution.

#### The minimum source probe

Trace only this path:

`dispatchRecoverySavedIntent` → canonical item lookup/mutation → owner session save → synchronous `submitPreparedUserTurn` → runtime user anchor → output insertion.

Resolve these questions:

1. **Which existing canonical mutation API can move a request anchor or user activity?** Inspect how it maintains turns, response spans, source-item indexes, UI projections, and the compacted-prefix/working-suffix boundary.
2. **Where is original intent order stored?** The packet supplies the requirement but not the complete `AgentRecoveryIntent` schema. Do not assume `sequenceIndex` is merely presentation order if it is also the only surviving ordering authority.
3. **What does the runtime anchor actually control?** Follow `recordAgentTurnUserAnchor` through assistant deltas, tool rows, terminal state, and persistence. A footer anchor alone is not proof of transcript output routing.
4. **What survives compaction?** Determine whether unresolved unsent inputs retain enough request, activity, and ownership information to be moved safely, including inputs outside the working suffix.

The relevant entry anchors are `AgentModeViewModel+RecoveryActions.swift:412–550`, `AgentModeViewModel.swift:16874–16933, 17428–17452`, `AgentTabSession.swift:3005–3037`, and `AgentTranscriptServices.swift:3297–3409`. The full canonical mutation and save-commit implementations are not supplied; locating those implementations is part of the probe, not evidence of their absence.

#### Candidate behavior if the probe supports relocation

Keep the existing eligibility checks, reservations, and dispatch path. Add preparation inside the existing **asynchronous** saved-intent performer, before its final synchronous submission:

- Revalidate the saved intent’s identity, payload, incarnation, reset generation, target, and conclusively not-delivered status.
- Resolve all canonical/suffix representations of the same item. Consistent projections are not separate messages; conflicting or genuinely duplicated authoritative items remain a refusal.
- Move the same unsent item through the canonical owner. Preserve its immutable ID and timestamp, payload, original intent-order information, and provenance. Give it the appropriate new execution sequence without renumbering unrelated history.
- Preserve every unrelated turn, activity, result, interruption record, and checkpoint reference. Remove an old container only if the canonical model proves that it has no independent state to retain.
- Save through the existing owner path and verify the relevant commit before provider bytes. Revalidate after suspension, then call the existing synchronous submission path, whose latest-item check should now succeed.
- Keep the original intent held if saving, revalidation, or submission fails. A crash after relocation but before dispatch restores the same unsent item; it must not trigger a send.

Do not insert an `await` between the current synchronous bubble check and its use. If another user action changes the conversation during preparation, fail the final fence rather than silently relocating again.

This is a targeted operation over existing state, not a second transcript representation. A one-time scan of the relevant canonical history is reasonable for an explicit recovery action; per-event scanning or a new indexing subsystem is not justified without evidence of a practical problem.

#### Historical hazards that must be demonstrated

Use one older saved item A, a later accepted request B with output, and a further turn C. Exercise A as:

- a canonical request anchor;
- a mid-turn user activity;
- a canonical-only item outside the suffix;
- an item in or before structurally compacted history.

Verify that moving A cannot take B’s output, detach tool results, invalidate turn references, or cause C’s later output to be rebuilt under A. An empty activity list in a compacted turn does not prove that the turn never owned output. A retained summary may also encode the original structure, so a suffix-only edit or full reconstruction from surviving legacy items is insufficient.

Pinning future unsent items against compaction may prevent recurrence, but it does not satisfy the requirement for already saved older items.

**Done when:** the probe yields either a demonstrated same-ID canonical operation covering the required historical placements, or a precise counterexample identifying why it cannot. The product gap closes only after the selected behavior preserves identity, payload, order semantics, and output ownership across those placements. Passing the latest-item or mutable-suffix case alone is not completion.

**Minimal affected checks:** extend existing saved-intent/canonical-transcript tests for the historical placements above, duplicate clicks, failed save, stale session after suspension, and crash/reload between relocation and dispatch. Assert the preserved payload and IDs, unchanged ownership of B/C, and zero provider bytes on refusal. Reuse injected dispatch and storage seams.

**Owner choice:** prefer same-ID relocation if this evidence supports it and the owner accepts “send now after later turns.” Alternatives are targeted insertion into the original request’s canonical turn, or continued deferral. A broad routing refactor becomes justified only after existing targeted operations are shown insufficient. Retaining a workaround that creates a new message must not be recorded as satisfying the older-message requirement.

### 2. Second: establish a Claude-specific identity bridge, not generic provenance infrastructure

**Recommendation:** prove one ordinary native-Claude dispatch end to end, then extend only the existing transport, reducer, and session ledger seams needed to represent that evidence. The baseline producer is not another task.

#### The identities must remain distinct

| Identity | What the packet establishes | What remains unproved |
|---|---|---|
| Stream envelope UUID | Extracted into usage observation metadata | Whether it identifies a particular JSONL entry, and for which event shapes |
| API `message.id` / `contentMessageID` | Used for API usage/message association; may group parallel calls in history | Native-entry identity, local item identity, or deduplication equivalence |
| Local `toolInvocationID` | Associates local tool presentation | Equality with native tool-use IDs or JSONL entry UUIDs |
| JSONL entry UUID | Part of the reader’s normalized native row key | Which live local user/output item represents it |
| Dispatch/run/local-user IDs | Existing local durable identities and ordered dispatch constituents | An authoritative provider acknowledgement or history relation joining them to native entries |

**Evidence:** `ClaudeProviderStreamResult.swift:95–108`; `ClaudeSDKNDJSONTranslator.swift:1149–1152`; `ClaudeSessionHistoryReader.swift:30–39, 59–69`; `AgentSessionProviderHistoryRecovery.swift:147–155`.

The current `encodeUserMessage(text:sessionID:)` excerpt does not supply a caller-controlled message identity. Adding a UUID field and assuming Claude will preserve or echo it would invent a protocol guarantee. <br>
**Evidence:** `ClaudeSDKProtocolCodec.swift:189–206`.

#### Minimum evidence, with a strict stopping point

The smallest useful evidence is a pinned protocol/source explanation plus one sanitized paired trace for the actual supported CLI/shim path showing:

1. **User identity:** the outgoing local dispatch and an authoritative acknowledgement or native record that identifies its JSONL user entry.
2. **Output identity:** content/tool stream events, their message/block boundaries, the corresponding JSONL entries, and the local item IDs actually produced by the normal reducer.
3. **Cardinality:** whether one native user entry represents one local input or several ordered inputs, and whether output blocks map one-to-one, many-to-one, or one-to-many to local rows.
4. **Ordinary-file viability:** the complete candidate remains acceptable to the reader for that real shape.

The fourth point is essential. The current reader validates the whole captured candidate and rejects system/progress/file-history-snapshot records, unsupported metadata/content, and ambiguous graphs. Proving a UUID relationship in a synthetic user/assistant-only file does not establish that an ordinary conversation can be imported. <br>
**Evidence:** `ClaudeSessionHistoryReader.swift:14–42, 274–358, 387–393`.

Start with a single ordinary input in an already identified conversation with a valid captured baseline. Do not assume first-send identity is available while fresh-session-ID qualification remains off. Add steering, combined dispatches, tools, or compaction only when evidence establishes their relationships.

This consultation authorizes no trace collection, provider execution, or home inspection. Existing authorized source/fixtures can establish local plumbing; if they cannot establish the native relationship, stop with that exact missing observation for a separately authorized probe.

#### Carry the evidence through existing seams

The source path to inspect and, after proof, extend is:

- `ClaudeSDKProtocolCodec`: outgoing message encoding and any **proven** correlation capability.
- `ClaudeSDKNDJSONTranslator`: extraction of distinct native references without changing their meanings.
- `ClaudeProviderStreamResult`, the intervening plugin DTO, and `ClaudeCompatibleProviderRuntimeBridge.streamResult`: immutable, optional evidence carried with the relevant event.
- The existing live reducer/buffer: association with the local item ID at creation or update.
- `AgentSessionProviderHistoryRecovery`: durable association saved with canonical transcript state.
- `AgentProviderHistoryAssociationPreflight` and the existing import planner: validation and application to the correct request.

Do not infer ownership from whichever run happens to be current when a late event arrives. Use existing dispatch/run/session-generation fences. Retired sessions, reset generations, and changed provider conversations must reject late association writes.

The packet does not include the plugin DTO definitions, all stream producers, or live reducer implementations. Their exact call-site inventory is a required source-probe output. No second translator, controller, client, or store is indicated.

#### Association is not the same as complete materialization

This is the most important implementation constraint after identity itself.

Today, the reader filters ledger-known native row keys, and the planner skips known keys. If a live **partial** answer is entered into that same “already imported” set merely because its identity is known, a later full native answer could be skipped, losing the missing tail. <br>
**Evidence:** `ClaudeSessionHistoryReader.swift:331–350`; `AgentProviderHistoryImport.swift:97–125`.

The extension therefore must distinguish:

- a proven native-to-local association;
- whether the native content is fully represented locally.

Keep both within the existing session-owned history state. Do not place incomplete live associations into the existing imported-row set with unchanged semantics. A narrowly typed optional association member is preferable to changing the meaning of every existing `NativeItem`; its exact cardinality must follow the probe evidence.

For an associated partial assistant item, reconciliation must update that same local item using a verified content relationship. It must neither append a second complete answer nor suppress the remaining content. If the native record is not demonstrably a replacement or continuation of the stored partial, refuse.

Likewise, association preflight success does not establish destination routing. The current planner returns `appendedItems`, and the caller appends them to the session. Recovering output for an earlier request still requires proving that those rows land in that request’s canonical turn. <br>
**Evidence:** `AgentProviderHistoryImport.swift:68–75, 89–160`; `AgentModeViewModel+RecoveryActions.swift:872–890`.

Preserve the existing transaction order: canonical changes plus association/import evidence and receipt commit together; cursor CAS follows. On failure, retain pending state and do not advance the cursor. Claude completion remains unconfirmed without separately validated request-bound terminal evidence. Codex completion evidence remains independent of row projection success.

#### What a narrower useful path can accomplish

A single-input, latest-turn, un-compacted Claude path can be useful without a generic provenance redesign. An even smaller case—positive native-user association and demonstrably no existing local provider output—can avoid live-output overlap for that case. It still requires positive user association; a baseline or empty output is not a substitute.

The distinction is between **implementation scope** and **product scope**:

- A Claude-specific implementation is compatible with the architecture.
- Refusing an individual unsupported or unprovable case is required degraded behavior.
- Declaring all legacy turns, steering, ordinary tool turns, or compacted histories out of the promised product scope requires an owner decision.
- Calling a narrow demonstration “full Phase 4 complete” would be incorrect.
- Activating that path alone is not authorized by its source tests.

**Done when:** the evidence establishes the selected user/output relationships and the existing path can persist and reconcile them without duplication, missing tails, or wrong-request attribution. If provider semantics remain unproved, the bounded deliverable is a source-plumbing result and one exact missing evidence request—not a claim that association is implemented.

**Minimal affected checks:** translator/bridge identity preservation; intentionally distinct envelope/API/tool/entry IDs; partial-to-final output recovery; duplicate/out-of-order events; multiple dispatch constituents where supported; canonical-only/compacted overlap refusal; and session-save/cursor crash cuts. Reuse existing history and injected provider suites.

**Owner choice:** prefer a narrow Claude-specific bridge while retaining conservative refusals. Alternatives are continued deferral, or an explicitly reduced initial product scope. Do not spend the next iteration designing provider-wide provenance before proving that the needed native identity exists.

### 3. Third: keep Restart deferred and define the source-only acceptance boundary

**Recommendation:** resolve the scope question now: automated Restart remains deferred. Do not make solving its exceptional helper policy a prerequisite for preserved input or the two probes above.

#### The honest helper policies

| Helper state | Permitted interpretation under the current contract |
|---|---|
| Arm was never sent; stop remains unknown | Retain helper ownership and refuse another helper. Restore the normal stage-appropriate choices because the protocol proves this helper cannot open the bundle. |
| Correlated abort acknowledgement or exact helper exit observed | Release ownership and restore the appropriate Retry/Cancel or Retry/Quit anyway choices. |
| Arm may have been sent; neither proof arrives within the absolute budget | Reopen capability remains unknown. Do not report stopped, renew the deadline, or offer ordinary choices on the assumption that a signal succeeded. |

These distinctions are already represented by `AgentLifecycleRelaunchAbandonment` and `ProcessRelaunchStopProof`. The unresolved arm-sent branch is the product-policy gap. <br>
**Evidence:** `AgentLifecycleShutdownCoordinator.swift:117–138`; `ProcessRelaunchHelper.swift:636–670`.

The current no-choice freeze does not satisfy the intended usable failure behavior merely because it fails closed. Conversely, restoring normal usability while forgetting a potentially armed helper could let a later ordinary quit reopen the app unexpectedly. The helper’s own timeout is not parent-observed stop proof.

The smallest contract-preserving alternatives are:

1. **Defer automated Restart**, preserving ordinary quit/reopen and current recovery holds. This is my recommendation.
2. **Remove automated Restart from the near-term milestone**, with an explicit owner scope decision if the milestone is to be called complete.
3. **Pursue a separate bounded repair of the existing helper protocol and failure policy** only if automated reopening is important enough to justify it. That repair must demonstrate a valid outcome within the original deadline and preserve R4/R6; the packet does not establish such an outcome.

A “finish exiting even if reopening is unconfirmed” variant could avoid the frozen application after all state and all-stopped prerequisites are secured, but it changes the current post-teardown failure-choice semantics. It is an owner-approved contract alternative, **not** a compliant fix to assume here. A new lease, persistent service, or additional handshake is not justified while deferral delivers the owner’s primary preservation goal.

Late exit observation may eventually release retained ownership, but it does not by itself repair the original eight-second failure contract.

#### Source-only work that can precede live O3 acceptance

Permissible preparation consists of bounded source tracing, injected tests, compile validation of affected targets, and concise evidence recording. It can establish:

- canonical identity and ownership behavior;
- dispatch-before-commit prohibitions and crash-cut behavior;
- DTO/reducer association preservation;
- session-save/import-receipt/cursor ordering;
- helper state-machine behavior under injected clocks, I/O, exit, and open effects;
- unchanged production-off gates and ordinary no-helper quit/window-close behavior.

It cannot establish actual marker propagation, process-family discovery, shim behavior, real provider acceptance/resume semantics, helper packaging/opening, or application crash preservation.

All current gates stay off:

- production registry registration, marker injection, and enforcement;
- Stop;
- fresh Claude session IDs;
- same-conversation actions, history reconciliation, and fresh-conversation continuation;
- Restart safely.

`AgentRuntimeQualification.activatesRegistration` requires coverage of **every supported family/provider pair**. Qualifying one native Claude route cannot activate that coupled system. A narrower supported set or different activation model is a separate design and owner choice. <br>
**Evidence:** `AgentProcessRegistrySupport.swift:58–96`.

There is also an action-level coupling: `sameConversationResume` controls Continue, Send saved, and Answer as input. Completing the older-message source work does not independently authorize a Send-saved-only release. <br>
**Evidence:** `AgentRecoveryActionRunner.swift:23–53`.

For eventual live acceptance, use the already documented isolated-test choice when the owner authorizes it. A disposable account is the smaller first option than introducing an Application Support override across all stores. Neither account setup nor live execution is part of this consultation.

**Done when:** the next handoff states exactly what source evidence exists, what remains unproved, and which owner authorization would permit the next observation. Restart is explicitly deferred; full Phase 4 remains blocked. The reported 592 injected tests and compile-only builds retain those labels.

**Minimal affected checks:** no test rerun for a documentation-only scope decision. For later code changes, run the affected existing suites and relevant compile targets; test production-off behavior and shared lifecycle isolation where touched. Do not add packaging, full-root tests, performance qualification, or another review round merely to make this consultation feel more rigorous.

**Owner choice:** retain O3/O9 as written. Alternatives are separately authorizing bounded live acceptance, changing supported scope/coupling, or prioritizing a new Restart design. None is an assumed decision.

### Compact maintainer-guidance check

| Check | Older saved input | Claude association | Restart / acceptance boundary |
|---|---|---|---|
| **User invariant** | Same input survives and sends once under the correct request | No duplicate output, missing tail, or false completion | Preserved state, usable failure behavior, no unproved reopening |
| **Confidence** | Relocation is plausible; canonical feasibility is unproved | Local seams exist; native identity relationships are unproved | High confidence that deferral is smaller |
| **Authority** | Existing canonical owner, recovery reservation, normal dispatch | Existing stream path, session ledger, DataService, cursor CAS | Existing R4 coordinator and bundled helper; O3/O9 govern |
| **State safety** | Commit before bytes; revalidate after suspension | Association and content saved together; partial is not complete | Retain unknown ownership; never equate signal success with exit |
| **Scale / observability** | One explicit-action scan; IDs and ownership assertions | Per-dispatch/row evidence, not per-chunk persistence or polling | Existing injected counters/clocks; no new service |
| **Recommended scope** | Canonical operation before routing redesign | Claude-specific bridge before generic provenance | Defer automated Restart |
| **Validation boundary** | Source/fixture correctness is not live acceptance | Fixture transport preservation is not provider qualification | Compile/state-machine tests are not real helper or app lifecycle tests |

## File-by-file impact

These are **probe targets and conditional implementation boundaries**, not instructions to change all listed files. Full paths below identify the shortened source citations used above.

| File and anchors | Bounded impact and dependency |
|---|---|
| `Sources/RepoPromptAgentCore/AgentMode/Models/AgentChatModels.swift:118–186` | Verify immutable ID/timestamp and mutable sequence semantics. Relocation should not require a new user-item identity or a wholesale model change. |
| `Sources/RepoPromptAgentCore/AgentMode/Runtime/Transcript/AgentTranscriptServices.swift:3297–3409` | Trace request/output grouping and locate the canonical mutation path. Do not rebuild compacted history from the working suffix. |
| `Sources/RepoPromptAgentCore/AgentMode/Runtime/Session/AgentTabSession.swift:3005–3037` | Identify mutation/index/projection invariants a canonical relocation or associated-output update must preserve. Plain append is insufficient evidence of relocation support. |
| `Sources/RepoPrompt/Features/AgentMode/ViewModels/AgentModeViewModel.swift:16874–16933, 17428–17452` | Preserve synchronous final validation and ordinary submission. Trace runtime-anchor ownership through actual output consumers. Depends on the canonical probe. |
| `Sources/RepoPrompt/Features/AgentMode/ViewModels/AgentModeViewModel+RecoveryActions.swift:390–550` | Potential location for asynchronous saved-item preparation before existing submission. Preserve receipt, eligibility, action authorization, and stale-session behavior. |
| `Sources/RepoPrompt/Features/AgentMode/ViewModels/AgentModeViewModel+RecoveryActions.swift:623–737, 760–906` | Reuse the shipped baseline producer and session-save/cursor transaction. Association changes must retain revalidation and completion evidence. |
| `Packages/RepoPromptAgentProviders/Sources/RepoPromptClaudeCompatibleProvider/ClaudeSDKProtocolCodec.swift:189–206` | Inspect supported outbound correlation. No speculative UUID field or provider-guarantee change. |
| `Packages/RepoPromptAgentProviders/Sources/RepoPromptClaudeCompatibleProvider/ClaudeSDKNDJSONTranslator.swift:1134–1157` | Trace evidence extraction and its event scope. Extend only after the native relationship is established. |
| `Packages/RepoPromptAgentProviders/Sources/RepoPromptClaudeCompatibleProvider/ClaudeProviderStreamResult.swift:83–151` | Candidate seam for optional immutable identity evidence; preserve distinct identifier meanings and existing consumers. |
| `Sources/RepoPromptAgentCore/AI/Providers/ClaudeCode/ClaudeCompatibleProviderRuntimeBridge.swift:254–275` | Carry any proven evidence through the existing bridge. Inventory intervening DTOs and downstream reducers before implementation. |
| `Sources/RepoPromptAgentCore/AgentMode/Models/AgentSessionProviderHistoryRecovery.swift:21–85, 138–155, 295–300` | Keep imported-row semantics separate from incomplete live association evidence. Any additive persisted member needs absent-as-unavailable decoding and unknown-data preservation. |
| `Sources/RepoPromptAgentCore/AI/Providers/ClaudeCode/SDK/ClaudeSessionHistoryReader.swift:14–42, 274–358` | Preserve whole-candidate validation. Review ledger filtering before introducing live associations; unknown or partial representation must not suppress recoverable output. |
| `Sources/RepoPromptAgentCore/AgentMode/Runtime/Recovery/AgentProviderHistoryImport.swift:89–160, 198–251, 317–346` | Keep explicit user/output preflight; establish correct destination and partial-output semantics before extending the planner. |
| `Sources/RepoPromptAgentCore/AgentMode/Runtime/Recovery/AgentRecoveryActionRunner.swift:23–53` | Leave production qualification unchanged. A separate Send-saved capability would be an additional owner-selected design, not part of this roadmap. |
| `Sources/RepoPromptAgentCore/AgentMode/Runtime/Recovery/AgentProcessRegistrySupport.swift:58–96` | Leave coupled all-pairs activation unchanged. No fixture-derived qualification. |
| `Sources/RepoPrompt/App/AppRelaunchCoordinator.swift:83–154, 168–185` | No recommended production behavior change. Preserve ownership retention and the production-off composition. |
| `Sources/RepoPromptPlatform/Infrastructure/Process/ProcessRelaunchHelper.swift:605–670, 848–969` | No recommended protocol redesign now. These anchors define the proof and deadline constraints for any future Restart proposal. |
| `Sources/RepoPrompt/App/AgentLifecycleShutdownCoordinator.swift:82–138, 767–818, 872–905` | Keep ordinary lifecycle behavior separate from the deferred arm-sent exception. Do not normalize the exception as accepted behavior. |

The definitions of `AgentSessionDataService.commitProviderHistoryImport`, the full `saveSession(for:)` commit guards, canonical mutation APIs, live reducers, and test-suite filenames are not provided. Locate them through the named call chains before preparing a patch; inventing paths or claiming a complete repository inventory would be misleading.

No persistence migration is selected by this consultation. A later design must preserve session serialization version 7 and its stated downgrade limitation. In particular, older import code must not encounter newly stored partial associations disguised as completed imported rows.

## Implementation order

1. **Run the bounded older-input source probe and present the relocation/order decision.** If subsequently authorized, canonical mutation, projection/index maintenance, verified persistence, and saved-dispatch integration form one atomic behavior change. Keep the current refusal until those pieces work together.

2. **Run the Claude identity probe independently.** Establish native semantics before changing transport or persisted fields. If subsequently authorized, the identity producer, DTO/bridge/reducer transport, durable association, and partial-output-aware consumer must land together behind unchanged gates; shipping only an importer that assumes the missing associations is unsafe.

3. **Record the remaining acceptance boundary and stop expansion.** Preserve the closed Phase 4 review cap, ordinary quit/window-close work, and inactive checkpoint status. Documentation and evidence clarification do not require another review round. Any later behavioral proposal follows the applicable review policy without reopening this consultation as another acceptance review.

## Recommendations

- **Choose the smallest canonical solution for older saved input.** Same-ID relocation is a credible candidate, not an established capability. Select it only after proving historical ownership safety and resolving the owner-visible meaning of order.
- **Make Claude identity an evidence task before making it an architecture task.** Reuse the existing transport, reducer, ledger, and transaction. Cut generic provenance infrastructure, heuristic matching, and speculative protocol fields.
- **Defer automated Restart explicitly.** Preserved manual quit/reopen is the smaller outcome. The possibly armed helper exception remains unapproved; no deadline extension, successful-signal assumption, or silent restoration of choices resolves it.
- **Keep source readiness and live acceptance separate.** Retain all production gates, the coupled family/provider requirement, and the full Phase 4 block. Cut optional polish, retention work, new test frameworks, broad performance work, and additional review cycling until a concrete user-facing requirement makes them necessary.
