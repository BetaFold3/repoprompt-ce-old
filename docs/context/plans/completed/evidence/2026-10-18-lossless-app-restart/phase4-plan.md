# Phase 4 bounded implementation plan

Scope: read when the task touches Phase 4 recovery actions, provider-history import, explicit Resume or Restart safely.
Authority: Reference
Last-verified: 2026-10-22

OracleA preset `61D024A4-CCFB-4C9C-A614-CC65E0A1864C` was explicitly selected and its returned identity verified. This plan is based on the original spec, Phase 3 activation clarification, prior scout and source excerpts at Phase 2 commit `93af6fb55a9044c7d8134e9c6be41c792db497d8`. Phase 3 released Core/App at signed checkpoint `559ecd9d6d037ba762d8f4d2297d3c397a9d1f67`; Phase 4 implementation starts from that checkpoint and verifies the final interfaces. The historical raw planning responses below retain their original pre-checkpoint wording. Production recovery dispatch and Restart safely stay gated while the registry is off. The recommendations are implementation assumptions, not Owner Decisions. The native-history clarification below supersedes the original reader sketch. The final helper-reuse amendment supersedes the dedicated helper target and its packaging work. The later baseline/identity amendment records a bounded partial-source cut: dispatch baselines and typed refusal are to be implemented, but full normal-live Claude canonical merging remains blocked without trustworthy native identity associations. Raw planning responses follow.

# Oracle Plan

# Phase 4 — Recovery actions and safe restart

## 1. Summary

Implement Phase 4 as **one coupled source package**, extending the existing recovery store, coordinator, transcript persistence, provider controllers, normal dispatch path, and shutdown pipeline. **Do not begin code changes until the Phase 3 worker commits and releases Core.** Complete fixture-backed recovery actions, history reconciliation, and safe-restart orchestration without activating unqualified production behavior. Phase 3 remains OFF; interim crash confirmation does not satisfy R6. No provider homes, credentials, CLIs, network calls, actual shutdowns, helper executions, or live qualification are authorized.

## 2. Current-state analysis

### Evidence boundary

This plan uses only the supplied material; no repository inspection or validation was performed.

- **Directly evidenced by excerpts:**
  - `AgentModeRunService.startRun(...)` accepts immutable `inputConstituents`, prepares `AgentProviderHandoff`, revalidates the session, and checks `providerHandoffAuthorization` before invoking a runner. Actual durable dispatch occurs later; Codex owns a separate existing evidence path.
  - `AgentRecoveryRunTurnJoin` distinguishes explicit turn identity, steering associations, and ambiguous process-run joins. It must remain the joining authority.
  - Codex snapshot reading skips turn data for idle threads and otherwise reads the newest turn. That is insufficient to prove the interrupted request completed.
  - `ClaudeSDKNDJSONTranslator` produces live `AIStreamResult` values. It is not a history-import transaction.
  - Transcript rebuilding explicitly preserves interruption and recovered-outcome envelopes.
- **Supplied checkpoint/status facts:** Phases 1–2 are signed at `93af6fb55a9044c7d8134e9c6be41c792db497d8`; Phase 3 is still being implemented.
- **Scout claims requiring implementation-time verification:** exact controller interfaces, native-ID availability, session-save commit APIs, production composition points, UI filenames, and launch-client factories. Scout line numbers are navigation hints, not current evidence.

The original spec’s historical “no code exists” statement is superseded by the checkpoint/status information.

### Existing ownership and flow

The relevant architecture is already established:

1. **Recovery authority:** `AgentRecoveryStore`, an app-scoped actor, owns recovery/runtime records, revisions, incarnation checks, and tombstones.
2. **Transcript authority:** existing session persistence owns `AgentSession` JSON at serialization version 7.
3. **Presentation and action ownership:** the main-actor recovery coordinator and catalog project records into session banners and the Needs-attention UI.
4. **Dispatch:** app view model → run service → existing provider handoff/coordinator → provider controller. Intent acceptance and run completion are separate evidence.
5. **Process ownership:** Phase 3’s `AgentProcessRegistry` owns discovery and admission. Platform inspection supplies facts, not session policy.
6. **Shutdown:** the existing R4 Stage A/B pipeline owns admission freeze, preservation, teardown, final flush, and termination error handling.

Phase 4 should extend these seams, not introduce another recovery manager, writer, database, event pipeline, or provider transport.

### Blocking gaps

- No qualified Claude native-history schema or request-bound terminal proof is supplied.
- Codex’s current snapshot cannot identify completion of the specific interrupted request.
- A supposedly observational Codex request may start its transport and therefore must use mandatory Phase 3 registration.
- Recovery needs a durable click reservation and crash-safe joins to its eventual intent/attempt.
- History rows and their deduplication identities must commit together before a separate recovery cursor advances.
- Restart safely requires **verified family shutdown**, not merely flushed state, a clean mark, or root-process exit.

This warrants a targeted, cross-file extension—not a broader refactor.

## 3. Design

### A. Qualification and default production behavior

Use the existing composition point and Phase 3 qualification state. Add narrow provider capability checks there; do not build a configurable qualification framework.

| Capability | Required evidence | Default with supplied evidence |
|---|---|---|
| View/edit recovery text; preserve action drafts | Existing recovery persistence | Available |
| Claude history import | Validated native-history schema and exact-file resolution | Disabled in production; fixture path complete |
| Codex recovery observation | Phase 3 active; registered transport; supported observational schema | Disabled while Phase 3 is OFF |
| Same-conversation Continue / Send saved message through Phase 4 | Phase 3 active; current R6 authorization; provider continuation qualification | Disabled |
| “Completed while closed” from provider history | Request-bound, version-qualified completion evidence | Never inferred |
| Restart safely | Phase 3 active; complete family evidence; R4 preservation; verified shutdown | Disabled while Phase 3 is OFF |

**Useful completion without fabricated proof:** the source package can fully implement and test action persistence/joining, editing, history framing and commit ordering, controller observation, dispatch authorization, and restart orchestration using injected boundaries. Production can expose saved input and editable recovery text with explicit blockers.

Additional rules:

- Existing Phase 1/2 manual-send behavior remains unchanged while Phase 3 is OFF. Phase 4 must not reuse its crash confirmation as an ownership permit.
- Lack of **terminal proof alone** does not permanently disable Continue. Once ownership, history interpretation, and provider continuation behavior are qualified, display “Last answer recovered; completion unconfirmed” and allow an explicit continuation.
- Unsupported history schema and unsupported resume behavior are separate blockers. Do not invent parsing or assume dangling-tool compatibility.
- Qualification unavailable after activation must not cause existing registry records to be ignored.
- ACP, Oh My Pi, and remote-host sessions retain their existing scope; no native Resume is added for them.

### B. Durable recovery action and single-dispatch ownership

#### Ownership and interfaces

Extend `AgentRecoveryCoordinator` on the main actor. It owns in-flight action tasks, not durable truth.

Conceptual additive entrypoint:

`performRecoveryAction(itemID, expectedRevision, actionID, request) async → action result`

The request is one of:

- continue the interrupted conversation with explicit text;
- send one saved, provably unsent intent;
- use a recovered question answer as ordinary input;
- explicitly continue in a new conversation;
- reconcile history without sending.

Edit-first remains a local composer operation backed by existing persistence, not a provider action.

Extend the existing recovery-decision representation rather than replacing it. Preserve `pending`, `continueRequested(actionID)`, `dismissed`, and `resolved`.

For each reserved action, persist these additive fields, reusing existing identity types:

| Field | Meaning |
|---|---|
| `actionID` | Stable caller-generated UUID |
| `recoveryItemID` | Item being acted upon |
| `expectedRevision` | Opaque revision supplied by the click |
| `sessionIncarnation` | Existing durable incarnation |
| `kind` | One of the five action requests above |
| `sourceRunAttemptID`, `sourceIntentID`, `sourceQuestionID` | Optional applicable source identities |
| `target` | Frozen provider/conversation/worktree identity |
| `text` | Exact clicked text; attachments come from the selected saved intent where applicable |
| `intentID`, `userItemID`, `runAttemptID` | Associated dispatch identities when allocated |
| `outcome` | Absent while unresolved; otherwise `notDispatched(reason)`, `dispatched`, or `importedCompleted` |

`dispatched` is action bookkeeping, **not** evidence of provider acceptance. Existing R2 records remain authoritative for delivery and completion.

If Phase 2 already stores an equivalent field, reuse it instead of adding a synonym. Preserve prior unresolved action evidence; retention is deferred.

#### Reservation and joining

1. Check the in-flight action for the item.
   - Repeated clicks for that operation join its task.
   - A competing request with different text or target returns a conflict; it does not replace the first.
2. Reserve the action through the store using expected revision, incarnation, and tombstone checks.
3. Only after the reservation commits, perform provider observation or prepare dispatch.
4. Revalidate identities after every suspension and again at the actual handoff boundary.

The store handles an exact duplicate `actionID` idempotently before rejecting its now-stale original revision. Reusing an ID with different parameters is an error.

On relaunch:

- Never restart an action task automatically.
- An unresolved `continueRequested` is joined to its existing intent/attempt evidence.
- If dispatch may have occurred, show “Resume was interrupted; status unknown.”
- A later explicit click observes/reconciles first. It never automatically resends the uncertain continuation.
- A positively never-handed-off saved intent can be selected again with the same intent and user-item identities.

Cancellation before handoff leaves the payload saved and records `notDispatched` when provable. Cancellation after possible handoff preserves uncertainty.

#### Dispatch integration

Use one normal dispatch operation—not a recovery-specific provider sender:

1. Validate the session, incarnation, provider identity, native conversation, worktree, and attachment availability.
2. Obtain current R6 discovery/authorization.
3. Reconcile supported provider history.
4. If request-bound successful completion is verified, commit the imported outcome and stop.
5. Otherwise select exactly one input:
   - existing saved unsent payload; or
   - one newly persisted continuation.
6. Obtain the shared pre-dispatch permit, including the existing checkpoint capture seam.
7. Invoke the normal app/run-service/provider path once.

Thread the recovery action association through the existing carried input/handoff context. The ordinary dispatch owner allocates or consumes the reserved attempt identity and commits R2 dispatch evidence; the coordinator must not perform a second, independent dispatch commit.

The supplied synchronous `providerHandoffAuthorization` remains a late revocation check, not a substitute for asynchronous registry discovery or authorization at the actual provider handoff. Validate the final Phase 3 permit contract before adapting this call chain.

**No automatic retry, tool replay, queue drain, scheduled-send confirmation, or bundling of other held input.** `runAlongsideOtherSessions` cannot bypass the reservation or R6.

### C. History authority and commit ordering

#### Minimal persisted projection

Add an optional `providerHistoryRecovery` envelope to the existing version-7 session serialization. Its contents are keyed by exact provider conversation and scoped to the session incarnation/transcript reset generation:

- `nativeItems`: persistent native-key → local transcript-item-ID associations.
- `lastImportCommit`: import UUID, provider conversation, source identity, and complete-line offset when applicable.

A native key contains:

- provider kind and exact native conversation;
- native message identity;
- native tool-use/result identity where applicable;
- native parent/lane identity where applicable;
- item kind and block ordinal when a message projects into several rows.

These are **internal normalized fields**, not assumptions about Claude’s raw JSON property names. The qualified adapter supplies them.

Use existing transcript item types. The persisted association marks imported rows as recovered; no new transcript event engine is needed.

Deduplication rules:

- Match native identity, never text similarity or generated translator invocation UUIDs.
- Map a known request to its existing deterministic user-item ID.
- Repeated identical native items produce no new row.
- Conflicting content for an identity unsupported by the pinned schema aborts that batch; do not guess replacement semantics.
- Preserve the native identity index through compaction so a rescan does not resurrect compacted rows.
- Clear it only through existing reset/incarnation semantics, never by retargeting it to another conversation.

Where live projection already has native identities, retain those associations at its canonical transcript projection boundary. This allows later history import to recognize already-saved output. For legacy rows without a trustworthy association, import only an unambiguously identified tail; otherwise report history reconciliation unavailable rather than deduplicating by text.

#### Exact transaction boundary

**The session file owns imported rows and their deduplication ledger.** The recovery file’s cursor is an optimization, not proof that rows exist.

One import batch follows this order:

1. Read and parse into immutable data off the main actor.
2. On the main actor, validate a fully hydrated, unchanged session/incarnation and build a history-only merge.
3. Through the existing serialized session-save authority, atomically replace the session JSON containing:
   - merged transcript;
   - native identity associations;
   - the matching `lastImportCommit`;
   - any verified imported-completion outcome.
4. Await the actual atomic-replacement success—not merely a debounce request.
5. Advance the recovery cursor with store revision checks and the matching import UUID.
6. Publish the committed result through existing session/catalog observation.

No cross-file atomic transaction is claimed.

| Failure/cut | Result |
|---|---|
| Before session commit | No cursor advance |
| After session commit, before cursor commit | Rescan; persisted native IDs make it idempotent |
| Cursor write conflict/failure | Keep imported rows; retain old cursor |
| Cursor references a missing/mismatched session receipt | Do not trust it; rescan safely |
| Session reset/delete or stale target during import | Reject the result; never overwrite the new generation |

Extend the existing session-save seam only as needed to return a commit receipt and prevent older queued snapshots from overwriting newly committed import state. Do not add another writer. Reuse `AgentRecoveryRunTurnJoin` for attempt attribution; ambiguous joins never become completion proof.

### D. Claude exact-session history reader

Add `ClaudeSessionHistoryReader.swift` as a read-only reader using immutable inputs and outputs. It owns no session, controller, permission handler, or dispatch capability.

Conceptual interface:

`readBatch(exactConversation, allowedRoots, cursor, supportedSchema) async throws → history batch`

#### File selection and cursor

- Resolve only the exact `<sessionID>.jsonl` under the allowed roots supplied by existing registry/configuration knowledge.
- Do not assume the selected rotator profile is the history root.
- No match means history unavailable.
- More than one distinct matching file is ambiguous and blocks import; do not choose by newest timestamp.
- Open one file descriptor and obtain its identity from that descriptor.
- Persist file identity using device/inode and available birth/generation identity, plus the last complete-line byte offset.
- Replacement, truncation, or mismatch of a small saved boundary fingerprint causes a scan from zero while retaining native-ID deduplication.

#### Parsing

- Stream bounded chunks off the main actor.
- Parse newline-terminated records only. Preserve an incomplete final line for a later read.
- Advance only through records successfully understood or explicitly classified as irrelevant by the supported schema.
- A malformed or unknown potentially meaningful record stops the batch before that record. Never advance past silently discarded content.
- Apply a fixed input limit using the existing provider frame/record limit where available; an oversized record reports unsupported history without cursor advancement.
- Revalidate file identity and relevant size/boundary facts before returning the batch.

Memory is bounded by the batch plus native-ID lookup; scanning is linear in bytes read, with expected constant-time identity lookup per projected item.

#### History-only import

The adapter outputs transcript data—not `AIStreamResult` events sent to live runners.

Reuse pure parsing helpers only after verifying their compatibility with a native-history schema. The supplied stream translator is insufficient by itself: it omits user text and generates instance-local invocation identities.

Recovered tool calls, results, approvals, and questions are inert history. They cannot invoke a tool, reply to a permission channel, or restore a continuation.

#### Completion and dangling tools

- An assistant response, stream result, last-line position, root exit, or accepted send is not request-bound completion.
- Successful completion requires a supported schema and evidence bound to the interrupted request, including steering/Stop-hook implications.
- Otherwise retain interruption and show completion unconfirmed.
- Claude recovery must suppress any existing implicit fresh-conversation fallback.
- A dangling-tool refusal surfaces **Continue in a new conversation**. That requires another explicit action through the existing context handoff, with R6/worktree checks.
- If the failed resume may have handed off input, record uncertainty rather than claiming a harmless rejection.

Actual history schema, terminal evidence, and dangling-tool behavior remain qualification blockers.

### E. Controller-owned Codex observation

Keep all protocol parsing and reconciliation inside `CodexNativeSessionController`.

Add an observational method to the existing controller protocol:

`observeRecovery(threadID, expectedTurnID, timeout) async throws → recovery observation`

The observation contains:

- exact thread identity;
- request-correlated native turn identity, if established;
- recovered transcript items with stable native identities;
- terminal category: `completed`, `interrupted`, `failed`, or `unconfirmed`;
- native abort detail, including `turn_aborted interrupted` only when actually supplied;
- schema/transport-generation information sufficient to reject stale results.

`CodexRecoveryAdapter` is a thin facade forwarding this operation and normalizing its result. It owns no client, process, cache, or rollout reader.

#### Observation behavior

- Accept an explicit thread ID without rebinding the controller’s active thread.
- Reuse existing request/parsing and generation-scoped compatibility handling.
- Do not use the idle shortcut: recovery must inspect the relevant turn even when the thread is idle.
- Locate the expected native turn using supported listing/read APIs. If bounded supported observation cannot find it, return unconfirmed.
- Never infer completion from latest-turn status, idle state, provisional submission identity, or acceptance.
- Do not invoke `startOrResume`, `thread/resume`, interruption, steering, or `turn/start` to obtain history.

#### Transport startup

An observational request may invoke `startIfNeeded`. Therefore:

- Obtain the controller/client through the existing registered production factory.
- Apply mandatory Phase 3 reservation and birth registration before initialization/protocol writes.
- A missing registration dependency fails closed.
- Associate the observed thread with the registered runtime through the registry without resuming it.
- While Phase 3 is OFF, the Phase 4 observation entrypoint is unavailable; it must not silently launch the legacy client.

After a safe, explicit continuation, the **normal** Codex send path owns `thread/resume` and the single new `turn/start`. The observation facade never performs either.

### F. Recovery text and presentation

Extend the existing catalog/UI rather than adding another screen.

- **Continuation:** visible and editable, initially:
  > RepoPrompt restarted during the previous turn. Check the current state before repeating any action, then continue.
- Persist edited recovery text in the existing recovery record, using the existing non-secret draft timing policy. The clicked text is synchronously captured and committed with the action before any observation or handoff.
- **Saved unsent input:** sends its original intent/user-item ID and attachments. Missing attachments or stale conversation bindings remain blockers.
- **Recovered question:** preserve question, options, and partial answer. Sending the answer creates ordinary user input associated with that snapshot—not an expired RPC/tool reply.
- **Edit first:** use existing composer persistence. Never silently overwrite a nonempty composer; require explicit replacement or cancellation.
- **Other held inputs:** remain separate and visible.
- **Dismiss:** retains existing acknowledgment-only semantics.
- **Checkpoint seam:** display existing checkpoint references/outcomes if available. No file restore, checkpoint-store implementation, or mandatory file review enters Phase 4.

R6 distinctions remain visible:

- alive/reserved/unknown writers block same-conversation continuation;
- positively identified tool-only survivors require the existing explicit confirmation;
- new-conversation handoff with unresolved prior execution requires the existing Stop/confirmation policy and never clears unknown ownership.

### G. Restart safely and short-lived helper

Add `AppRelaunchCoordinator` as app-owned orchestration over the **existing R4 pipeline**, not a second shutdown implementation.

#### Pre-exit lifecycle

1. The menu command requests the existing shutdown operation with reason `safeRestart`.
2. Reuse the full Stage A flow: layout persistence, synchronous admission freeze, recovery preservation, hydrated-session flush, and the same absolute 8-second deadline.
3. Before the point of no return:
   - require active, qualified registry coverage;
   - reject unresolved prior families that ordinary teardown cannot safely stop;
   - prepare the bundled helper with an inherited private control channel;
   - require helper-ready acknowledgment within the remaining R4 budget.
4. Run the existing point-of-no-return and Stage B teardown.
5. Perform fresh family verification after teardown.
   - **Every managed family must be verifiably stopped**, including tools that would merely require confirmation for Resume.
   - Root exit, clean launch state, and empty incomplete inventory are insufficient.
   - Do not automatically signal recovered survivors; they require the existing explicit Stop action.
6. Finish existing final flush/clean marking, arm the helper, receive acknowledgment, then permit termination.

Use the existing shutdown owner to serialize duplicate Restart/quit requests. An unarmed helper exits on channel closure; Stage A cancellation explicitly abandons it.

#### Errors and deadlines

- Stage A failure: existing Retry/Cancel flow; unfreeze admission and leave the app usable.
- Stage B failure or failed family verification: existing Retry/Quit anyway flow; no Cancel.
- **Quit anyway never arms the helper.** If shutdown remains uncertain, retain the existing unclean state.
- Retry uses the existing R4 retry semantics and reruns outstanding flush/verification/helper readiness; no helper-specific or per-session deadline extends the original shutdown attempt.
- Helper-arm failure is a Stage B failure, not permission to relaunch later unexpectedly.

#### Helper boundary

Add a small bundled executable with no AgentCore dependency and no agent work. Its only inputs are the old process’s exact lifetime identity, the current app bundle URL, and its inherited control channel.

It:

1. acknowledges readiness;
2. waits for explicit arm;
3. watches the exact old process lifetime;
4. opens the specified bundle once, only after verified exit;
5. exits.

No PID-only polling, shell command construction, daemon, retry loop, or recovery-file writes. Reuse suitable Platform lifetime-observation primitives.

Bound post-arm parent waiting to 15 seconds and launch completion to 10 seconds. On failure, show a bounded helper-owned error explaining that manual reopening is required, then exit; do not retry launch. These bounds do not extend the old app’s 8-second deadline.

Only source and injected lifecycle tests are authorized here. Do not execute the helper or exercise actual app lifecycle.

## 4. File-by-file impact

Paths below use supplied anchors. Existing files not fully shown must be located and verified after Phase 3; reuse their actual locations rather than creating duplicates.

| File/component | Change and dependency |
|---|---|
| `Sources/RepoPromptAgentCore/AgentMode/Models/AgentRecoveryModels.swift` | Add action associations, editable recovery text, cursor/observation value shapes. Extend existing decisions and preserve unknown members. |
| `…/Runtime/Recovery/AgentRecoveryStore.swift` | Add idempotent action reservation/completion and cursor CAS operations using existing incarnation/tombstone authority. |
| `…/Runtime/Recovery/AgentRecoveryCoordinator.swift` | Main-actor action joining, reconciliation ordering, target validation, and normal-dispatch orchestration. Depends on store and provider seams. |
| Existing `AgentRecoveryCatalog` file | Project action progress, unconfirmed completion, qualification blockers, and action availability. Do not create a second catalog. |
| `…/Runtime/AgentSession.swift` and its existing codec | Optional version-7 history identity index/import receipt; defaults absent. |
| Existing `AgentSessionDataService`/session-save implementation | Awaitable guarded session commit for rows plus native identities; prevent stale saves from overwriting imports. Verify actual owning file. |
| `…/Runtime/Transcript/AgentTranscriptServices.swift` | History-only merge using existing transcript transformations; preserve interruption, recovered outcome, identities, and compaction behavior. |
| `…/Runtime/AgentSessionRestoreSupport.swift` | Validate cursor receipts and join unresolved actions to existing attempts. Reuse `AgentRecoveryRunTurnJoin`; no automatic recovery execution. |
| `…/Runtime/Recovery/AgentProviderRecoveryAdapter.swift` | Small shared observation/batch value types and existing adapter contract, if needed. No adapter registry or service framework. |
| `…/AI/Providers/ClaudeCode/SDK/ClaudeSessionHistoryReader.swift` — new | Exact-file streaming, complete-line cursor, identity validation, supported-schema parsing. |
| `…/Runtime/Claude/ClaudeAgentModeCoordinator.swift` | Recovery dispatch context, native identity capture at the existing projection boundary, explicit rather than implicit fresh-conversation fallback. |
| `…/AI/Providers/ClaudeCode/SDK/ClaudeNativeProcessSessionController.swift` | Carry recovery fallback policy through existing start/resume entrypoint if required; preserve Phase 3 launch registration. |
| `…/AI/Providers/Codex/AppServer/CodexNativeSessionController.swift` | Explicit-thread observation, relevant-turn lookup, richer request-bound results; additive protocol method and conformer/test-double updates. |
| `…/Runtime/Codex/CodexRecoveryAdapter.swift` — new | Thin facade over controller observation; no separate client/reader. |
| `…/Runtime/Codex/CodexAgentModeCoordinator.swift` | Wire existing controller/factory, identity associations, and action-linked normal dispatch. |
| `…/Runtime/AgentModeRunService.swift` and existing `AgentProviderHandoff` implementation | Carry action identity/permit through existing handoff; preserve late authorization and single dispatch ownership. |
| Existing app provider/recovery composition file | Wire qualification defaults and registered dependencies. Do not independently activate Phase 3 components. |
| `Sources/RepoPrompt/Features/AgentMode/ViewModels/AgentModeViewModel+Recovery.swift` | UI action bridge, committed history projection, edit-first, saved-input/question handling. |
| `…/AgentModeViewModel.swift` | Minimal normal-start/context changes needed by the recovery bridge. No alternate run path. |
| Existing recovery banner and Needs-attention sheet files | Editable text, exact blockers, explicit fallback and action progress. Verify Phase 2 filenames. |
| `AppDelegate.swift`, existing shutdown owner, and `WindowStateManager.swift` only where necessary | Thread `safeRestart` through the existing Stage A/B operation and termination acknowledgment. Leave window-close semantics unchanged. |
| `AppRelaunchCoordinator.swift` — new | Helper preparation/arming integrated with R4 and registry verification. |
| `Sources/RepoPromptRelaunchHelper/main.swift` — new | Bounded wait-and-open helper; no agent dependencies. |
| Existing app menu and authoritative build definition | Register menu command and bundle helper target. Verify whether the repository uses package/project generation before editing. |
| `Tests/RepoPromptTests/AgentMode/Recovery/` | Coupled action, import transaction, gating, dispatch, and restart failure suites. |
| `Tests/RepoPromptTests/AgentMode/Codex/CodexNativeResumeLifecycleTests.swift` | Explicit-thread/idle observation and request-correlation tests. |
| `Tests/RepoPromptTests/AgentMode/AgentModeRunServiceLifecycleTests.swift` and `Recovery/AgentProviderHandoffTests.swift` | Single handoff, permit revocation, uncertainty, and stable saved-input identity. |
| Existing shutdown/helper test location | Injected Stage A/B and helper protocol tests; no process execution. |
| Original spec and its existing evidence directory | Original-plan status/owner-answer maintenance only; validation and review evidence stay under `evidence/2026-10-18-lossless-app-restart/`. No fresh standalone plan elsewhere. |

Do not modify the shared stream translator merely to make it accept unqualified history. Extract a pure helper only if verified schema reuse actually requires it.

## 5. Risks and migration

### Additive compatibility

- Session serialization remains **version 7**; metadata index remains **8**.
- Recovery schema remains **1** with additive optional members.
- Missing action/history fields mean “no Phase 4 evidence,” not “safe to resume.”
- Preserve unknown members at every newly touched envelope, including nested actions/cursors. Unknown semantic variants disable the affected action and retain their raw data.
- No eager migration or provider-history scan is required.
- Old builds can discard new fields and ignore fences. Preserve the existing downgrade requirement: quit cleanly and resolve recovery before rollback.

### Principal risks

- **False completion:** prevent with request-bound evidence and existing ambiguity-aware joins.
- **Lost imported rows:** prevent by session rows/index/receipt committing atomically before cursor advancement.
- **Duplicate continuation:** prevent by durable reservation, action-to-intent joins, and no automatic replay after uncertainty.
- **Unregistered observational process:** prevent by using the Phase 3 client factory even for reads.
- **Accidental second writer:** never substitute confirmation, helper exit, or clean shutdown for complete R6 evidence.
- **Silent fresh conversation:** suppress Claude’s implicit recovery fallback.

## 6. Implementation order

Use **one coupled worker**, with these internal cuts—not separately reviewed unused substrates.

1. **Wait for Phase 3 commit and Core release.**<br>
   Verify final registry/permit contracts, action codecs, save authority, native-ID projection, controller factories, UI owners, and R4 lifecycle. Record the actual Phase 3 commit. No Phase 4 code before this point.

2. **Implement one vertical saved-input/action slice.**<br>
   Wire reservation → joining → catalog/UI → normal handoff with injected qualified ownership. Test revision conflict, duplicate click, stale incarnation, tombstone, saved user-item identity, and action interruption.

3. **Implement Claude history plus the real session commit boundary together.**<br>
   Test complete/incomplete lines, replacement/truncation, ambiguous files, malformed records, native-ID duplicates, compaction, and both sides of the session-commit/cursor-commit crash cut. Synthetic fixtures prove mechanics only.

4. **Implement Codex observation through the existing controller and registered factory.**<br>
   Test idle threads, requested turn older than latest, missing turn identity, bounded unsupported fallback, stale transport generations, and abort details. Assert zero `thread/resume`/`turn/start` during observation and zero initialization writes after failed registration.

5. **Complete continuation/question/fallback dispatch.**<br>
   Test terminal import with zero sends; unconfirmed continuation; unchanged unrelated held input; expired-question answer as text; permit revocation after suspension; dispatch-bookkeeping failure; and explicit new-conversation fallback. Verify the normal handoff occurs at most once per reserved action.

6. **Implement safe restart through R4 and the bundled helper source.**<br>
   Inject all process/helper boundaries. Test Stage A cancellation restores usability, Stage B retry cannot cancel, unknown/tool survivors prevent arming, Quit anyway never relaunches, duplicate commands join, and helper readiness consumes the shared deadline.

7. **Validate the coupled package and run required reviews.**<br>
   Check default-OFF production composition, v7/additive round trips, unknown-member preservation, scheduling regression, and no automatic recovery work on startup. Follow OracleA/OracleB policy on the same snapshot; attach the supplied policy verbatim to future review requests. Save fixture/source evidence without calling it live acceptance.

8. **Commit only after required validation/reviews; report three separate statuses.**<br>
   - Phase 4 source/fixture completion.
   - Production capabilities still gated.
   - Live acceptance still pending under O3.

   Maintain the original plan’s single Phase 4 status line. Record recommendations under `assumed:`, not Owner Decisions. Only actual owner answers belong in Owner Decisions.

## Recommendations

- **Proceed with the coupled source package after Phase 3 releases Core; keep production recovery dispatch and Restart safely gated while Phase 3 is OFF.**
- Treat missing terminal proof as **completion unconfirmed**, not as permission to invent completion and not as a permanent ban on otherwise qualified explicit continuation.
- Keep Claude schema, Codex schema/resume behavior, process-family qualification, and real-app acceptance as separately named blockers. Current authorization permits none of their live tests.
- Cut retention, optional polish, generic frameworks, file restore, parallel history readers, automatic fallback/retry, and Phase 5 work.
- Continue through source validation, required reviews, and the permitted commit without further design questions; stop only the dependent live/activation work until specifically authorized.

## Native-history evidence and bounded amendment

Read-only probe: `prompt-exports/agent-run-b1958a406e6d-1f5d963b.md`. Main independently opened Anthropic's [native fixture constructor and parallel-tool fixtures](https://github.com/anthropics/claude-agent-sdk-python/blob/main/tests/test_sessions.py#L575-L640), [parent-chain reader](https://github.com/anthropics/claude-agent-sdk-python/blob/main/src/claude_agent_sdk/_internal/sessions.py#L808-L923), and [Stop-hook documentation](https://code.claude.com/docs/en/hooks#stop). The fixtures distinguish entry UUIDs from shared API message IDs and retain explicit parallel-tool associations. The reader traverses native parents and treats compaction specially. The hook documentation says transcript writes can lag and Stop can continue. These are implementation facts from mutable primary sources, not a stable native-history schema or production qualification.

The probe did not establish a versioned native-history contract, a safe snapshot-record decoder, or request-bound terminal evidence. Production qualification stays off. The source subset must explicitly refuse unsupported common metadata; it must not be described as general normal-history support. The implementer pins the actual upstream revision for reproducibility without inventing an accepted Claude version.

The following continuation was returned by the same OracleA planning lane, with inherited preset identity verified, and narrows only the reader portion of the original plan.

# Oracle Plan

## Summary

Amend only the Claude-reader portion of Phase 4: implement **one built-in, deliberately unqualified native-history format profile**, exercised by fixtures through the real decoder and projector. It must support a concrete subset of native entries—not delegate parsing to an injected callback—but must not claim normal-history compatibility or request completion. Production remains OFF, and implementation still waits for the Phase 3 checkpoint and Core release.

## Current-state analysis

The new primary-source findings establish useful structural facts:

- Native entries carry `type`, `uuid`, `parentUuid`, `sessionId`, and `message(role, content)`.
- Separate entry UUIDs can share an API `message.id`; therefore **API message ID alone is not a deduplication key**.
- Parallel-tool recovery uses additional relationships, including `sourceToolAssistantUUID`.
- Parent traversal includes non-message entries and does not cross compaction using `logicalParentUuid`.
- Stop is not durable proof of completion: transcripts can lag, and Stop hooks can continue execution.

These facts support a bounded decoder and projector. They do **not** establish a stable native-history contract, a qualified CLI version, arbitrary metadata handling, or interrupted-request terminal proof.

This amendment relies on the supplied account of the independently opened sources. I have not opened the export or links in this turn. The implementer must verify exact field locations and fixture shapes against those sources before coding; their conclusions must remain distinguishable from synthetic test coverage.

## Design amendment

### 1. One concrete built-in profile

In `ClaudeSessionHistoryReader.swift`, implement a single internal profile named, for example, `nativeEntriesSubsetV1`.

“V1” versions **our decoder subset**, not Claude’s format or CLI. Do not introduce a profile registry, dynamic parser selection, or a production parsing closure. Test injection is limited to file access and file-identity boundaries; fixture bytes run through the built-in decoder, parent traversal, tool association, and projector.

The profile’s explicit contract is:

| Entry/content | Behavior |
|---|---|
| `user` and `assistant` with supported native envelopes | Decode identity, parent, session, role, and supported content blocks |
| Text content | Project inert user/assistant text |
| Assistant tool-use blocks | Project inert tool-call history with native tool identity |
| User tool-result blocks | Project inert results, preserving separate native entries and their tool associations |
| `progress`, `system`, `attachment` | Recognize as possible parent-chain entries, but accept only concrete subshapes verified and covered by pinned primary-source fixtures |
| Compaction requiring `logicalParentUuid` traversal | Unsupported; do not stitch across it |
| `file-history-snapshot` | Unsupported in this initial contract; its shape and safe treatment have not been established |
| Other entry types, unsupported content blocks, malformed envelopes | Unsupported; no silent skipping |

For the first package, **do not invent accepted subshapes for `progress`, `system`, or `attachment`**. Unless the supplied primary sources establish a particular shape and its treatment, encountering one rejects the candidate import. Recognizing its parent fields is not permission to treat it as harmless.

Unknown additive JSON members may remain uninterpreted; an unknown **entry type, content variant, or relevant relationship discriminator** is different and must fail closed.

This is useful as an implemented, testable source subset. It is **not useful enough to advertise general native-history support**: a normal file beginning with `file-history-snapshot` can be rejected before importing any messages. Record that explicitly as a qualification blocker rather than hiding it behind “complete-lines support.”

### 2. Small parent-chain algorithm, not a general graph engine

Keep the algorithm private to the reader, using a UUID-to-entry dictionary and ordinary parent walks.

For each explicit read:

1. Resolve and open the exact session file using the previously planned identity checks.
2. Capture a finite file boundary and decode only complete lines through that boundary.
3. Validate session identity and native entry identities.
   - Identical repetitions of an entry are idempotent.
   - Conflicting records with the same entry UUID reject the candidate.
4. Build parent links from `parentUuid` only.
   - Missing required parents, cycles, inconsistent session identities, and unsupported branching reject the candidate.
   - Never use `logicalParentUuid` to bridge a missing parent or compaction boundary.
5. Identify the relevant chain using an existing trustworthy native request association where available.
   - Without one, permit only an unambiguous supported conversation chain.
   - Do not select “the newest leaf” to resolve competing branches.
   - A conversation-level import without a request association cannot establish which interrupted attempt completed.
6. Include parallel tool entries using the **specific relationships demonstrated by the pinned official reader and fixtures**, including `sourceToolAssistantUUID`.
   - Shared API `message.id` identifies a possible grouping, not duplicate entries.
   - Retain separate tool-result entries.
   - A missing, conflicting, or multiply resolvable tool association rejects the candidate.
7. Produce immutable inert rows and a candidate complete-line cursor. No session mutation happens inside the reader.

The implementation must reproduce only the demonstrated parallel-tool association cases. If the exact relationship needed by a fixture is not established by the supplied evidence, that case stays unsupported; do not infer a rule from matching text or tool names.

**Minimal cursor strategy:** reconstruct the parent index from the complete file prefix on each explicit import, while using the persisted cursor and native-ID ledger to identify already imported material. This avoids a second durable parent-index schema. Cost is linear in scanned bytes and entry count; optimize incremental ancestry reconstruction only if later evidence justifies it.

For this initial subset, validate the entire captured candidate before publishing any of its rows. An unsupported complete record means no rows or cursor from that candidate commit. Previously committed history remains intact. An incomplete trailing line alone is not an error and does not prevent importing the validated preceding prefix.

### 3. Deterministic, inert projection and deduplication

Use these normalized identities:

| Purpose | Identity |
|---|---|
| Native entry | Provider + native session ID + entry UUID |
| Projected row/block | Native entry identity + content kind + block ordinal |
| Tool association | Native tool-use ID, source assistant entry UUID where supplied, and enclosing native entry identity |
| Supporting relationships | Parent UUID and API message ID |

API `message.id`, tool name, message text, and translator-generated invocation UUIDs must not serve as sole deduplication keys.

Persist the native-key-to-local-item association in the version-7 session envelope already proposed. Use the repository’s existing deterministic-ID facility if available; otherwise derive a namespaced UUID from an unambiguous encoding of the native row key using a fixed, documented algorithm—not Swift’s randomized `Hasher`.

Projection rules:

- Preserve separate assistant entries sharing an API message ID.
- Preserve separate parallel tool results.
- Render tool inputs/results as data only; never pass them through live stream handlers.
- Do not manufacture approval requests, pending RPCs, execution status, or completion timestamps.
- Reuse an existing user item only through an established native/request association, never text matching.
- Retain interruption/recovered-outcome envelopes through the existing transcript merge.

The earlier authority transaction remains unchanged:

**Session rows + native-ID ledger + import receipt commit together → recovery cursor advances afterward.**

Replacement or truncation causes a rescan, not deletion of previously imported rows. Conflicting identities fail rather than rewriting history speculatively.

### 4. Completion remains unconfirmed

For this initial built-in Claude profile, history observation always returns **completion unconfirmed**. Do not add a speculative terminal recognizer.

Neither a final assistant answer, an apparent stop reason, a Stop-hook event, nor reaching EOF proves the interrupted request finished. Existing independently persisted terminal evidence retains its existing meaning; the new reader supplies no stronger proof.

Production history import remains disabled pending a supported native-history contract and qualification. Production Resume additionally remains subject to Phase 3 activation, R6 authorization, and continuation qualification. Missing terminal proof alone need not block a later qualified explicit Continue; it blocks the claim that no continuation is needed.

## File-by-file impact

Only refine the files already in the Phase 4 package:

| File | Amendment |
|---|---|
| `…/ClaudeCode/SDK/ClaudeSessionHistoryReader.swift` | Built-in subset decoder, private parent walk, demonstrated parallel-tool association, deterministic inert projection, complete-line/file-identity handling |
| `…/Runtime/Recovery/AgentProviderRecoveryAdapter.swift` | Represent unsupported history and completion-unconfirmed without inventing terminal evidence; reuse existing result shapes where possible |
| `…/Runtime/Transcript/AgentTranscriptServices.swift` | Consume inert rows and native associations through the previously planned history-only transaction |
| Existing session codec/history envelope | Persist entry-based deduplication identities; retain version 7 and additive/unknown-member compatibility |
| `Tests/RepoPromptTests/AgentMode/Recovery/ClaudeSessionHistoryReaderTests.swift` | Exercise the actual decoder/projector, not fake parsed batches |
| Existing evidence directory | Record upstream revision, fixture provenance, supported shapes, and explicit unsupported cases; no new standalone plan |

No shared stream-translator changes are required merely to support this subset.

## Implementation order and acceptance

After Phase 3 commits/releases Core, the same coupled worker should:

1. **Pin the primary-source fixtures and reader revision.** Verify exact content-block shapes, tool association fields, and parent traversal. Pinning is reproducibility, not qualification.
2. **Implement decoder and projector together with the session import transaction.** Do not land an unused parser substrate as a separately reviewed milestone.
3. **Run focused fixtures through the real path**, proving:
   - supported user/assistant text imports;
   - separate entry UUIDs sharing `message.id` remain separate;
   - demonstrated parallel calls/results retain their associations;
   - replay and replacement rescan produce no duplicate rows;
   - incomplete trailing lines wait;
   - malformed complete lines, unsupported metadata/content, ambiguous branches, missing parents, and compaction crossings produce no candidate commit or cursor advance;
   - `file-history-snapshot` explicitly reports unsupported rather than disappearing;
   - tools, approvals, and continuations are never invoked;
   - a final answer still produces completion-unconfirmed;
   - session-commit/cursor-commit crash cuts remain idempotent.
4. **Keep the production gate OFF.** Report “built-in subset implemented and fixture-tested,” not “Claude native history qualified.”

## Recommendations

- Adopt this **single built-in conservative subset**, with real decoding and projection rather than fake-only behavior.
- Explicitly acknowledge that unsupported common metadata prevents normal-history support; do not silently skip it or claim qualification.
- Keep terminal inference absent, production activation OFF, and all R6 gates intact.
- Continue source work after the Phase 3 checkpoint without another owner question. Cut generalized graph handling, parser frameworks, optional diagnostics, and retention work.

## Relaunch helper scope cut

The first read-only helper probe identified the separate-target packaging inventories. The follow-up `prompt-exports/agent-run-7d5c71ba39a3-4799b808.md` found an exclusive early private mode in the already bundled MCP executable. Main checked `Sources/RepoPromptMCP/main.swift`, its existing dependency in `Package.swift:238–245`, the stable-product ownership rule, and R4's existing composition. OracleA continued the same Phase 4 planning lane; its returned preset identity was verified. The following amendment is adopted as a reversible main-source assumption: reuse the existing executable, preserve thin delegation and the three-product boundary, and cut the new product plus packaging/cache/release/lane inventory work. Production activation and live validation remain deferred. Implementation-time source verification and focused fixtures remain required.

# Oracle Plan

## Summary

**Reuse the bundled `repoprompt-mcp` executable through an exclusive early private mode.** This preserves the three-product boundary and avoids a new helper’s build, copy, signing, cache, release, and lane inventories. Keep the entry thin: ordinary invocation delegates unchanged to MCPCore; private relaunch delegates to a narrow Platform implementation. This replaces the earlier dedicated-executable recommendation as a **main-source assumption**, not an Owner Decision.

No implementation starts while Pair owns Phase 3. Production Restart safely remains gated OFF; live acceptance remains pending.

## Current-state analysis

The supplied source directly establishes:

- `Sources/RepoPromptMCP/main.swift` currently does only the version declaration and `runRepoPromptMCP` delegation.
- Its `Package.swift` target depends only on MCPCore.
- `docs/architecture/source-layout.md` requires a thin entry and explicitly preserves the three executable products.
- Platform may own generic process primitives and depend on system frameworks, but not App or AgentCore.

The scout additionally reports that an early branch bypasses MCP service construction and that existing packaging already covers this executable. **Those details require implementation-time source verification**, not packaging execution.

Reuse does not make the executable MCP-free: its existing dependencies still link/load. The guarantee is **no normal MCP runtime, parsing, connections, or service startup on the private path**.

A dedicated executable is not materially necessary on this evidence. Its cleaner dependency isolation does not justify the additional packaging scope.

## Design

### 1. Thin, exclusive dispatch

Reserve the private argument `--rpce-private-relaunch-v1`.

Before calling `runRepoPromptMCP`, classify arguments into exactly three outcomes:

| Invocation | Behavior |
|---|---|
| No argument beginning `--rpce-private-relaunch` | Invoke the existing MCPCore delegate unchanged |
| Exactly the single argument `--rpce-private-relaunch-v1` | Invoke the Platform helper entry |
| Any other use of that reserved prefix, including extra arguments or another version | Exit unsuccessfully; never enter MCPCore |

Do not inspect ordinary stdin, introduce environment-variable activation, change public CLI help, increment the CLI version for this private protocol, or reuse `--launch-app`.

The entry owns only dispatch and exit status. It must contain no process watching, protocol parsing, app lifecycle, or error-reporting implementation.

### 2. Narrow ownership boundaries

**App — `AppRelaunchCoordinator`:**

- Owns Restart safely policy, production gating, R4 orchestration, and all recovery/registry checks.
- Locates `repoprompt-mcp` inside the current app bundle using the existing bundled-executable resolver; no PATH or installed-CLI fallback.
- Launches it with dedicated stdin/stdout pipes and the private argument.
- Owns the child handle and pipe endpoints until termination or abandonment.
- Supplies the current bundle URL and exact parent lifetime identity.
- Alone decides when shutdown permits arming.

**Platform — proposed `Infrastructure/Process/ProcessRelaunchHelper.swift`:**

- Owns private invocation classification, bounded protocol decoding, handshake state, exact-lifetime watching, and one bundle-open request.
- Reuses existing process-inspection/watch primitives.
- Knows nothing about sessions, providers, registry qualification, recovery records, or clean-launch marks.
- Uses immutable values and one serialized asynchronous state machine; injected channel, clock, watch, and open operations support tests.
- Exposes only the package-level entry and value types needed by App, the executable entry, and tests.

Keep protocol DTOs beside this engine in Platform. Both callers already need Platform, so **no Shared DTO file or new cross-package dependency is necessary**. This is one helper implementation, not a reusable CLI framework.

### 3. Conservative private protocol

Use the child’s dedicated stdin/stdout pipes, not a socket, listener, temporary request file, or ordinary MCP channel. Stdout carries protocol frames only.

Use newline-delimited JSON with a fixed **16 KiB maximum per frame**. Version 1 has this closed message set:

| Direction | Message | Required information |
|---|---|---|
| App → helper | `prepare` | Protocol version, invocation UUID, exact parent birth identity, absolute bundle file URL |
| Helper → app | `ready` | Matching invocation UUID |
| App → helper | `arm` | Matching invocation UUID |
| Helper → app | `armed` | Matching invocation UUID |
| App → helper | `abort` | Matching invocation UUID |
| Helper → app | `aborted` | Matching invocation UUID |
| Helper → app | `failed` | Matching invocation UUID when available; bounded error code |

The invocation UUID correlates messages; it is **not authentication**.

Before `ready`, the helper must:

- Validate the first message and its version.
- Verify that the supplied live parent is its actual parent, with matching UID and birth identity.
- Verify that its executable belongs to the supplied bundle; reject a different bundle or non-file URL.
- Establish the exact-lifetime exit watch before acknowledging readiness.

Reject malformed, oversized, out-of-order, duplicate, unknown, or mismatched frames. Reject unknown protocol members for this private version; this is separate from recovery persistence’s unknown-member preservation requirement. Errors never fall through to normal MCP behavior.

#### State and exit rules

- `awaitingPrepare → ready → armed → openOnce → finished`
- `abort` from `ready` or `armed` leads to `aborted`, closes resources, and exits.
- Parent exit before arming means **no launch**.
- Pipe closure is never proof of parent exit.
- After arming, relaunch requires verified exit of the exact watched parent lifetime.
- Inspection/watch failure, timeout, or uncertain identity means **no launch**.
- Opening uses the exact supplied bundle URL, once, without shell execution, bundle-ID fallback, or retries.

Retain the earlier bounded lifecycle: an unarmed helper expires within eight seconds of startup; after arming, parent-exit waiting is limited to 15 seconds and bundle-open completion to 10 seconds. These are helper lifetime limits, not extensions to R4’s deadline.

Before parent exit, failures return to the app’s existing shutdown error UI. After parent exit, opening failure uses a bounded generic helper error presentation instructing manual reopening. Its implementation remains in Platform and initializes no app services or stores.

### 4. R4 remains the sole lifecycle authority

Reuse the entire existing Stage A/B deadline and error flow:

1. Stage A prepares the helper and awaits `ready` within the remaining shared deadline.
2. Stage A cancellation aborts the helper and restores admission through existing R4 behavior.
3. Stage B performs existing teardown, final persistence, and fresh complete-family verification.
4. Only after all success conditions hold does App send `arm`.
5. App awaits `armed`, then completes the existing termination acknowledgment.

**Unknown families and surviving managed tools prevent arming.** The helper never substitutes parent exit for the registry’s all-processes-stopped proof.

Avoid an armed-helper ambiguity on errors:

- Before presenting a post-arm failure choice, App must obtain `aborted` or verify that the exact helper child has exited.
- A lost `armed` acknowledgment is not proof that arming failed.
- Retry does not reuse an uncertain helper instance.
- Quit anyway must leave no armed helper; it never silently becomes Restart safely.

The child is a short-lived infrastructure helper, not a provider runtime. App owns its handle explicitly; it is excluded from the provider-family stop requirement and managed separately.

## File-by-file impact

| File | Change |
|---|---|
| `Sources/RepoPromptMCP/main.swift` | Add Platform import and exclusive early delegation; preserve ordinary MCPCore call |
| `Package.swift` | Add `RepoPromptPlatform` dependency to the existing `RepoPromptMCP` target; no new target/product |
| `Sources/RepoPromptPlatform/Infrastructure/Process/ProcessRelaunchHelper.swift` | Add bounded engine, protocol values, and OS adapters |
| Planned `AppRelaunchCoordinator.swift` | Launch the existing bundled executable; own helper lifecycle and R4 handshake |
| Existing shutdown integration files | Retain previously planned `safeRestart` integration; no second shutdown pipeline |
| `Tests/RepoPromptTests/ProcessRelaunchHelperTests.swift` | Add injected dispatch/protocol/watch/open tests |
| Existing R4/relaunch tests | Exercise helper failures against Stage A/B behavior |
| `docs/architecture/source-layout.md` | Document the narrow dual delegation while retaining thin-entry and stable-product rules |
| Existing Phase 4 evidence artifact | Record this scope cut and supersede the dedicated-helper proposal |

Remove the proposed `Sources/RepoPromptRelaunchHelper/main.swift` and associated packaging work from the plan. Do not change packaging/cache/release scripts or relax source-layout guardrails.

Only an applicable status-line update belongs in the original spec; do not add this assumption to Owner Decisions.

## Implementation order and narrow acceptance

After Phase 3 commits and releases Core:

1. Verify the remaining scout claims: early-call boundary, bundled resolver, Platform dependency compatibility, and existing handle/watch contracts.
2. Implement early dispatch and the helper engine together with App’s existing R4 integration—not as a separately reviewed unused substrate.
3. Validate with injected operations:
   - Ordinary arguments select the unchanged MCP delegate.
   - Every malformed private invocation selects neither MCP nor bundle opening.
   - Parent/bundle mismatch, invalid frames, EOF before arm, and watch uncertainty produce zero opens.
   - Arm acknowledgment loss followed by abort/verified child exit cannot relaunch.
   - Exact parent exit after arm produces exactly one open; repeated callbacks do not.
   - Stage A failures restore usability; Stage B failures retain existing restrictions.
   - Unknown/surviving families and production gate OFF prevent arming.

Do not execute the helper, launch the app, run packaging, inspect credentials, or treat fixtures as live qualification. No new cache checks, packaging matrix, or generic CLI restructuring is needed.

## Recommendations

- **Prefer existing-executable reuse:** it is the smallest architecture-preserving source change.
- Keep private dispatch exclusive, protocol handling bounded, and lifecycle policy in App.
- Preserve production gating and live-acceptance blockers; no additional owner question is needed.
- Record the adjustment in existing evidence as an assumption, and wait for Pair’s Phase 3 checkpoint before implementation.

## Baseline and native-identity scope amendment

Main consulted the same OracleA preset/chat after reading the first implementation and a narrow source probe (`prompt-exports/agent-run-b1958a406e6d-c484cf0e.md`). Exact preset identity was explicitly selected and verified. Main adopts the following reversible assumption, not an Owner Decision: build the real dispatch-bound baseline producer and typed no-merge guard, but do not manufacture live-stream/native-history UUID equivalence or claim full Claude history source completion. The full canonical merge portion remains blocked on identity evidence. Existing helper reuse and strict whole-candidate decoder rules are unchanged. No live qualification or provider inspection is authorized.

# Oracle Plan

## Summary

**Wire a real pre-user-byte baseline producer, but cut unproven live-to-history association from this source package.** Do not propagate raw stream UUIDs as native-history identities merely behind a profile gate: that would implement an unsupported equivalence across several layers. Persist the actual boundary and local dispatch identity through existing authorities; return a typed limitation when canonical reconciliation requires a native association that does not exist. This closes the missing baseline producer without falsely declaring Claude history recovery complete.

Phase 3 is signed at `559ecd9d`. Phase 4’s initial source remains unreviewed; production capabilities remain OFF and O3 acceptance pending. This is a planning adjustment, not acceptance of the supplied implementation.

## Current-state analysis

Three different identities must remain distinct:

| Identity | What the supplied evidence establishes |
|---|---|
| Local dispatch/user item | Existing handoff constituents provide the canonical user-item ID and durable dispatch ownership. |
| Live stream envelope/tool | Raw envelope UUIDs and tool IDs exist upstream, but their meanings are not preserved as canonical native-history associations. |
| Native history entry | The built-in reader obtains entry UUIDs and native tool relationships directly from JSONL. |

The missing relationship is **between the second and third rows**, and then between those identities and the actual projected canonical rows. A raw UUID appearing in usage observations does not establish that relationship.

The source also establishes two independent gaps:

- `.baseline` has no normal-start producer.
- `AgentProviderHistoryImportPlanner` deduplicates its own ledger and deterministic imported IDs, not previously persisted live rows with unrelated IDs.

Consequently, a baseline alone identifies a file boundary; it does **not** identify which later history rows are already represented locally. Nor does it identify the native user entry corresponding to the handoff’s known local user item.

The main-spotchecked facts support this decision. Remaining scout details—particularly the final controller admission callback and session-save call contracts—must be verified while adapting the code.

## Design

### 1. Explicit scope cut: no speculative identity pipeline

For this package:

- **Do not change** `AIStreamResult`, `ClaudeProviderStreamResult`, translator events, or `AgentChatItem` to label raw stream UUIDs as native-history entry UUIDs.
- Do not use API message IDs, text equality, timestamps, file position, or “first user after baseline” to manufacture associations.
- Do not inject a UUID into outbound user encoding without evidence that Claude accepts and preserves it as the history entry identity.
- Do not replace existing live rows with imported rows, or deduplicate them by content.

A format-profile switch cannot turn an unestablished relationship into evidence. Carrying raw provenance could eventually be useful, but doing so now would be unused cross-layer work rather than the smallest closure.

**Bounded consequence:** normal Claude interrupted attempts without trustworthy native-to-canonical associations remain unavailable for canonical history import. The implemented reader and import transaction remain usable for their explicitly supported fixture/ledger cases; they are not a complete live reconciliation implementation.

### 2. Capture the baseline at the existing final write admission

The baseline belongs to a **specific durable dispatch**, not merely a conversation or the recovery action that later observes it.

#### Placement

Extend the existing controller’s pre-byte admission path, using the captured `AgentRuntimeOperationOwner` and handoff ownership:

1. Existing preparation/initialization establishes whatever exact session identity is available.
2. The controller reaches its serialized user-write admission, before encoding/writing user bytes.
3. An awaited admission callback captures and persists the baseline.
4. The controller revalidates owner, target, reservation, and admission after that await.
5. Only then may it write the user message.

The coordinator’s earlier `handoff.commitDispatch` may already have run. That is acceptable: baseline failure before bytes must use the existing **verified no-handoff settlement**, not be reported as provider rejection or leave a falsely accepted send.

Do not put baseline capture before initialization merely because that is easier: initialization can supply `session_id`. Do not put it after `sendUserMessage`, in the response callback, or at Resume time.

#### Inputs and prerequisites

The callback receives immutable values:

- Existing session incarnation/reset generation.
- Existing durable dispatch identity and run-attempt ID.
- Ordered handoff constituents, including their local user-item IDs.
- Exact native conversation ID observed by the controller.
- Registry-authorized history roots associated with that conversation.

Resolve roots through the existing registry seam. An unknown home does not become a guessed default. Fresh-session ID preallocation remains separately OFF.

Pre-byte identity availability is conditional:

- Initialization can provide it.
- Qualified preallocation could provide it later.
- It may still be absent.

Missing conversation identity or roots produces an explicit **baseline unavailable** result. Never retrospectively capture a baseline once the original user bytes have been sent.

#### Concurrency

Keep the write admission exclusive while the callback awaits; no competing user write may pass it. Perform file reading off the main actor, then return to the existing main-actor session owner for persistence.

The callback must not call back into controller operations that require the same write admission. Revalidate session ownership after every suspension. Cancellation or ownership change releases the admission without sending bytes.

### 3. Persist an immutable boundary, not a replacement conversation cursor

Extend `AgentSessionProviderHistoryRecovery.swift` with an optional collection of dispatch-bound baselines. Reuse the existing dispatch identifier type; do not invent another attempt counter.

Each baseline contains:

| Field | Purpose |
|---|---|
| `dispatchID` | Existing durable dispatch identity; idempotency key |
| `runAttemptID` | Existing attempt association |
| `transcriptResetGeneration` | Prevent use across transcript resets |
| `conversationID` | Exact native conversation |
| `userItemIDs` | Ordered local identities from handoff constituents |
| `file` | Captured file identity, or nil for positively established absence |
| `completeLineOffset` | Boundary before this dispatch |
| `baselineCommitID` | Session-side commit receipt |
| `profileName` | Existing built-in subset identity |

The surrounding session/lane provides incarnation ownership. Preserve unknown members in the new nested values, retain session serialization **7**, and default missing baselines to absent.

**Do not overwrite an older attempt’s boundary with a later run’s baseline.** A conversation-level recovery cursor remains an import optimization; it is not the authority for selecting the interrupted attempt’s starting boundary.

#### Commit order

Reuse the existing writer and receipt mechanism:

1. Capture `.baseline` without producing transcript rows.
2. Add the dispatch-bound baseline and zero-row receipt to the session history envelope.
3. Commit through the existing guarded session-save authority.
4. Verify that this exact receipt committed.
5. Only afterward seed/update the recovery cursor through its existing compare-and-swap seam, where applicable.
6. Return admission success, then perform final ownership checks and write bytes.

A zero-row baseline is a real commit. The current “no appended rows/no ledger growth” shortcut must not suppress it.

The session baseline must be sufficient to reconstruct the intended starting boundary if a crash occurs before cursor persistence. A stale recovery cursor must not cause fallback to an unrelated run’s baseline.

For the enabled source path, a baseline persistence failure stops that dispatch before bytes. Missing identity/location is different: record an explicit unsupported capture outcome using the existing dispatch/recovery context, then allow ordinary sending under its existing policy. It must not advertise history recovery for that dispatch.

With production capabilities OFF, perform **no baseline filesystem reads or extra persistence** and preserve existing send behavior.

#### Reader boundary correction necessary for this producer

An empty candidate list currently conflates absence with enumeration/stat failures. Before treating `file: nil, offset: 0` as a baseline:

- Establish successful enumeration of all authorized roots and genuine absence.
- Treat inaccessible roots or candidate identity failures as unavailable.
- Refuse a baseline ending in a partial record; otherwise that pre-existing partial record could become a seemingly post-baseline entry later.

These are required boundary semantics, not broader reader hardening.

### 4. Canonical import requires association evidence

Add a typed preflight result to the existing history import flow, rather than a new service:

- `baselineUnavailable`
- `baselineTargetMismatch`
- `nativeUserAssociationUnavailable`
- `canonicalOutputAssociationUnavailable`

Reuse existing unsupported-schema/file results separately.

The preflight must inspect the **canonical transcript plus mutable suffix**, not just `session.items`. Compacted or closed canonical history cannot be treated as absent merely because it is outside the live suffix.

For a selected interrupted dispatch:

1. Find its immutable baseline and validate generation/conversation.
2. Validate the candidate with the existing built-in reader.
3. Require explicit associations for native user rows claimed to represent the local dispatch.
4. Require trustworthy coverage of already-canonical provider output before importing potentially overlapping native rows.
5. Only then run the existing inert import planner.

**Current normal-live result:** these associations are unavailable, so return the appropriate limitation with zero transcript changes and zero cursor advance.

Do not create a “no visible output” shortcut in this package. An empty mutable suffix does not prove no canonical output, and lack of output would still not supply the native user association.

The existing `NativeItem.localItemID == nil` must mean **unassociated/not projected**, not “proven RepoPrompt-originated user input.” Correct the reader/importer comments and any decision logic relying on that stronger assertion. Do not associate all native user text with the known local request or silently treat it as accounted-for input.

Existing ledger-based re-import can remain supported where exact associations already exist, but fixtures must distinguish:

- Ledger/idempotency mechanics.
- A genuine live producer.

The former does not prove the latter.

### 5. Recovery behavior when association is unavailable

Return a precise message, for example:

> The pre-send history position was saved, but this build cannot safely match Claude’s history to messages already in this conversation. Nothing was imported.

This is distinct from “no baseline” and from “no new history.”

The already-planned reconciliation-before-Continue flow must receive this typed unavailable result, not successful reconciliation or completion. Current production Continue remains OFF. Preserve the explicit safe new-conversation choice under its existing R6 policy; do not silently dispatch a continuation or retry an interrupted action.

Claude completion remains unconfirmed. Nothing in baseline capture supplies interrupted-request terminal proof.

## File-by-file impact

| File | Bounded change |
|---|---|
| `…/ClaudeCode/SDK/ClaudeNativeProcessSessionController.swift` | Await baseline admission within the existing pre-user-byte fence, after possible initialization identity; revalidate before writing. |
| `…/Runtime/Claude/ClaudeAgentModeCoordinator.swift` | Bind admission to existing handoff/owner identities; use existing no-handoff settlement on failure. |
| `…/Runtime/Runners/AgentProviderHandoff.swift` | Expose immutable dispatch/constituent identity to this callback only if not already accessible. No new dispatch authority. |
| `…/Models/AgentSessionProviderHistoryRecovery.swift` | Add immutable dispatch-bound baselines with additive codecs and unknown-member preservation. |
| `…/ClaudeCode/SDK/ClaudeSessionHistoryReader.swift` | Distinguish verified absence from failed inspection; reject partial-record baselines; retain current subset limits. |
| `…/ViewModels/AgentModeViewModel+RecoveryActions.swift` | Own baseline session commit through existing save machinery; select baseline by source dispatch/attempt; surface typed association blockers. |
| `…/Runtime/Recovery/AgentProviderHistoryImport.swift` | Add association preflight; stop treating unassociated native user rows as proven local input; preserve transaction ordering. |
| Existing session-save/recovery-cursor seams | Support zero-row baseline receipts and cursor-after-session ordering without another writer. |
| Existing recovery/controller tests | Add the focused tests below. |

No translator/event-model expansion, helper changes, packaging changes, or new qualification framework.

## Implementation order and focused acceptance

1. **Add baseline values and pre-byte producer together.**
   A fake controller initialization supplies an exact session ID; injected authorized roots and fixture bytes exercise the real reader and actual persistence ordering.

2. **Test the handoff boundary.**
   - No bytes before session baseline commit.
   - Commit failure, cancellation, or changed owner yields zero bytes.
   - Missing pre-byte identity produces an explicit unsupported capture outcome; later identity does not backfill it.
   - Two dispatches retain distinct boundaries.
   - Failed enumeration is not an absent-file baseline.
   - Production OFF performs no history reads.

3. **Add canonical association preflight.**
   - A persisted live assistant row with a different local ID blocks import, even if text matches.
   - Shared API message ID and matching raw stream UUID values do not establish association.
   - Unknown native user UUID is not mapped to the local user item.
   - Compacted canonical rows cannot disappear from the check.
   - Established ledger associations deduplicate correctly.

4. **Test crash ordering and presentation.**
   - Session baseline committed/cursor missing remains recoverable as a boundary.
   - No receipt or wrong generation remains unavailable.
   - Zero-row baseline persistence is not skipped.
   - Association failure leaves transcript/cursor unchanged and is not “nothing new” or verified completion.

These tests require no live provider, home, process-environment, or helper access.

## Recommendations

- **Implement now:** the genuine pre-byte baseline producer, dispatch-bound persistence, conservative file-boundary semantics, and typed canonical-association refusal.
- **Defer:** raw-stream-to-native identity carry-through and normal-live Claude canonical history merging until evidence establishes the exact relationship—including user-entry identity and projection/coalescing behavior.
- Record this as a **bounded partial-source scope**, not “Claude history complete, qualification only pending.” Baseline capture can be complete while live association remains unimplemented.
- No owner question is needed to make this reversible cut. If full Claude canonical recovery is required for Phase 4 sign-off, that portion remains blocked; it cannot be honestly completed from the supplied evidence.
- Keep production OFF, R6 intact, and O3 pending.

## Bounded public identity check

A final read-only probe used three targeted searches and official Anthropic documentation/source reads: `prompt-exports/agent-run-b1958a406e6d-834faf5c.md`. Main opened the pinned [Python client source](https://raw.githubusercontent.com/anthropics/claude-agent-sdk-python/3cb0c27eca8caccdc153471a1b19f97fce4ada03/src/claude_agent_sdk/client.py) and [official streaming documentation](https://code.claude.com/docs/en/agent-sdk/streaming-output). These describe user checkpoint UUIDs and block-granular assistant streaming, not an end-to-end native-history-to-canonical-row mapping. The bounded check did not establish the needed equivalence; this is a limited evidence finding, not a claim that no such provider relationship can exist. The no-speculative-association cut remains in force. No terminal proof, schema acceptance or live qualification follows.

## Cold Codex observation composition amendment

The first implementation required an already-connected controller, which cannot satisfy a cold-restart recovery action. Main spot-read the current factory, explicit optional-attempt lifecycle scope, fixed registration-authority boolean and pre-start generation capture, then consulted the same OracleA planning chat. Exact explicit preset identity was verified. Main adopts the bounded existing-coordinator transaction below as an implementation assumption, not an Owner Decision. The Claude identity cut and all production gates remain unchanged.

# Oracle Plan

## Summary

**Close cold Codex recovery through an observation transaction owned by `CodexAgentModeCoordinator`, using the existing controller factory and registered client.** Do not call `ensureCodexNativeSession`, install a temporary controller on the session, or introduce another client/reader/service. Explicitly finish transport startup before capturing its generation, read the expected thread/turn observationally, and join cleanup of any action-created controller before returning a usable result.

This is a source-composition fix, not qualification or acceptance. Production gates remain OFF; the adopted partial-Claude scope and O3 deferral are unchanged.

## Current-state analysis

The supplied excerpts establish:

- The normal coordinator factory already receives workspace, permission profile, session profile, task-label kind, and computer-use configuration.
- Normal preparation additionally mutates `session.runID`, installs `session.codexController`, attaches live event handling, and enables automatic recovery paths. **Those behaviors are inappropriate for observation.**
- `observeRecovery` currently captures the transport generation before a request that may start the client. Its generation check can therefore reject a successful first cold read.
- `client.isRuntimeRegistrationActive` establishes that registration authority is configured—not that a registered process has already started.
- The adapter is already suitably thin and controller-owned parsing already targets the expected turn.

The main-spotchecked facts additionally establish that `startIfNeeded(runtimeSession:)` joins startup, and that durable session associations permit absent run-attempt/process-run IDs. Those facts support a bounded cold path without inventing a logical run.

Exact retirement, shutdown, policy-installation, and registry-association methods were not supplied. The worker must verify and reuse their actual contracts; the signatures below describe additive interfaces, not claims about existing names.

## Design

### 1. Coordinator owns acquisition, policy, and release

Add one main-actor operation to `CodexAgentModeCoordinator`, conceptually:

`observeRecovery(session, actionID, expectedThreadID, expectedTurnID, sourceRunAttemptID?, isStillCurrent) async throws → CodexRecoveryObservation`

The existing recovery action runner continues owning action reservation and duplicate-click joining. This coordinator method owns only the temporary resource transaction.

Capture an immutable operation context containing:

- Durable lane/lifecycle association and transcript reset generation.
- Exact thread and expected turn.
- Optional **existing** source run-attempt identity.
- Workspace, permission profile, session profile, task-label kind, and feature configuration.
- Selected controller identity, when borrowing one.

Construct `.session(existingLifecycleAssociation)` explicitly. Never derive cold ownership from a live-only `runtimeSessionScope` that returns `.unavailable`, and never fall back to `.sessionless`.

Use `actionID` for the existing factory’s UUID parameter **only as its transient controller/process correlation identifier**, after verifying its consumers. Do not assign it to `session.runID`, create a run-attempt record, or describe it as an OS birth identity. The durable association’s `processRunID` can remain nil.

#### Acquisition sequence

1. Check qualification, current action/session ownership, idle-state admission, and existing R6 authorization.
2. Join outstanding controller retirements for this session through the existing retirement mechanism.
3. Revalidate the captured context.
4. Choose one path:

| Path | Ownership |
|---|---|
| Compatible `session.codexController` exists | Borrow that exact instance; do not replace it or shut it down |
| No controller exists | Create one through `codexControllerFactory`; retain it locally for this action |
| Existing controller has incompatible workspace/policy or changes during acquisition | Refuse as stale; do not invalidate it or silently create another |

For an action-created controller:

- Call `useOwnerCapturedRuntimeSessions()`.
- Do **not** assign it to `session.codexController`.
- Do not start usage execution, install a session event task, subscribe to live projection, or invoke normal ensure/resume logic.
- Keep the recovery reservation busy until cleanup is joined.

The factory must remain the existing App-composed factory with registered launch authority and `stopOnShutdown` behavior.

### 2. Preserve permission and MCP authority without activating a run

Reuse the **same policy derivation** used by normal controller construction. Do not substitute permissive defaults for cold recovery.

If necessary, extract only the existing immutable factory-input calculation into a private coordinator helper shared by normal preparation and observation. Do not extract a new provider service.

The worker must trace whether factory/startup requires a connection-policy installation:

- If required, invoke the existing installer with the captured session restrictions and action-scoped correlation, before startup.
- Reuse the existing expected-PID binding mechanism; do not waive it because the operation is observational.
- Release only policy resources created by this action, using existing cleanup.
- Never revoke or overwrite a borrowed controller’s policy.
- If no connection policy is needed for transport-only initialization, do not install one merely to resemble a normal run.

Current worktree and permission bindings must be revalidated after suspensions. Any change invalidates the observation rather than triggering a reconnect.

No live event handlers means no recovered tool execution or approval routing. Verify that the controller’s existing inbound-request handling cannot execute tools through a detached observation controller. If normal startup enables such handling independently of the session event task, use its existing restrictive admission mechanism; do not wire the normal runner to satisfy it.

### 3. Controller starts transport before generation capture

Keep `CodexSessionControlling.observeRecovery(threadID:expectedTurnID:timeout:)` as the observation interface. Run it under the explicitly captured `AgentRuntimeOperationOwner` scope. No separate public “prepare recovery transport” API is needed.

Inside `CodexNativeSessionController.observeRecovery`, use this order:

1. Validate thread/turn IDs and registered launch-authority availability.
2. Apply the existing client process-feature policy.
3. Await `client.startIfNeeded(runtimeSession: capturedScope)`.
   - This must finish registered startup and protocol initialization.
   - Reservation/birth-registration failures propagate before observational requests.
4. Capture `currentTransportGeneration()`.
5. Associate the expected thread with the current registered runtime through the existing authority, including captured session/worktree/permission context.
   - This is registry association, **not** controller thread rebinding or `thread/resume`.
   - Await persistence where the existing authority requires it.
6. Check generation again before sending the first history request.
7. Perform the existing bounded turn listing/read.
8. Check generation after each response and before returning.

The existing authority boolean remains a **precondition**, not the proof of completed startup. `startIfNeeded` supplies that startup boundary.

#### Generation and compatibility behavior

- Scope the capability memo to the post-start generation.
- Check generation **before** recording supported/unsupported capability results.
- If an unsupported-list error arrives from a changed generation, return stale—not the full-read fallback.
- Use the same generation for the bounded `thread/read` fallback.
- Do not retry observation after replacement or transport loss.

Verify whether `performRequest` automatically restarts/retries transport. For this operation, reuse an existing generation-bound/no-retry facility if present. Otherwise add the smallest internal option at that request boundary to reject a changed/unavailable transport rather than restarting it. Do not restructure ordinary request behavior.

Allowed conversational RPCs remain only the existing observational `thread/turns/list` and `thread/read`. Initialization is allowed; `thread/start`, `thread/resume`, `turn/start`, steer, and interrupt are forbidden.

### 4. Cleanup is part of observation success

Hold the raw observation locally until resource release finishes.

**Action-created controller:**

- Await its existing shutdown operation on success, failure, cancellation, and stale-target exits.
- Join the exact client shutdown/root-reap completion and any existing retirement task.
- Cancellation must stop observation but must not abandon cleanup ownership.
- Do not return an importable or continuation-enabling result while cleanup is unresolved.

If cleanup cannot complete within the existing shutdown bounds, transfer ownership to the existing retirement mechanism, retain the registry restriction, and return a typed cleanup-pending failure. Never drop the handle or claim the process stopped.

Root reaping is necessary resource cleanup, **not family-completeness proof**. Before a subsequent normal continuation, the existing R6 permit must still perform fresh authorization. Surviving/unknown descendants remain blocking.

**Borrowed controller:**

- Cancel only this operation’s outstanding request.
- Do not shut down the controller, cancel its event task, interrupt its turn, or alter its bound thread.
- If the session replaces it, discard the observation and leave retirement to its normal owner.

Finally revalidate lane, target, policies, cancellation, and borrowed-controller identity. Only then return the observation to the VM.

### 5. VM consumes the transaction, not controller availability

In `AgentModeViewModel+RecoveryActions.swift`, replace the `session.codexController != nil` prerequisite with a call to the coordinator transaction.

Pass the durable action identity and source attempt, expected thread/turn, and existing currentness fence. Continue using `CodexRecoveryAdapter.historyObservation` for inert normalization after the transaction succeeds.

Keep request-bound completion separate from row availability:

- Verified completion of the expected turn suppresses dispatch even if its item subset cannot be imported.
- Missing/ambiguous expected turn remains unconfirmed.
- Cleanup failure or stale ownership is a failed observation, not “no new history.”
- No observation result enters the live event/projector path.

The existing session-ledger commit followed by cursor commit remains unchanged.

## File-by-file impact

| File | Change |
|---|---|
| `…/Runtime/Codex/CodexAgentModeCoordinator.swift` | Add action-scoped acquire/observe/release operation; reuse factory, captured policy inputs, and retirement ownership |
| `…/AppServer/CodexNativeSessionController.swift` | Explicit registered startup before generation capture; registry thread association; generation-safe requests and memo updates |
| Existing `CodexAppServerClient` request/startup implementation | Only if needed: narrow generation-bound/no-retry request support and exposure of existing joined shutdown completion |
| `…/Runtime/Codex/CodexRecoveryAdapter.swift` | Retain thin normalization; add/reuse typed stale-context and cleanup-pending errors where appropriate |
| `…/ViewModels/AgentModeViewModel+RecoveryActions.swift` | Replace cold nil-controller refusal with coordinator transaction; preserve completion-before-dispatch behavior |
| Existing Codex coordinator/recovery tests | Add cold/warm ownership and policy fixtures |
| `…/Codex/CodexNativeResumeLifecycleTests.swift` | Add startup-generation and generation-change cases through the real observation method |

No runtime schema change, new persistent manager, controller cache, alternative factory, or logical run is required.

## Implementation order and focused acceptance

1. **Fix controller startup/generation ordering.**
   Exercise registered fake startup that advances generation, then successfully reads the expected turn. Do not rely solely on the DEBUG registration-bypass boolean.

2. **Compose cold acquisition and joined cleanup in the coordinator.**
   Test:
   - Initial `session.codexController == nil`.
   - Exactly one factory creation and one joined startup.
   - Lifecycle scope is explicit; absent attempt remains nil.
   - Expected thread association precedes its read.
   - Shutdown/root reap completes before the result is released.
   - Session controller/run/event-task state remains unchanged.

3. **Wire the VM through that transaction.**
   Test expected-turn completion causes zero normal dispatches, including unsupported item projection; unconfirmed observation can proceed only through the existing explicit action and permit.

4. **Exercise ownership and failure cuts.**
   - Registration failure: zero initialization/history writes.
   - Prior retirement pending: zero new starts until joined.
   - Target/policy replacement after an await: zero import or continuation.
   - Cancellation after spawn: cleanup joined; zero conversation mutations.
   - Warm reuse: zero factory creations and zero shutdowns.
   - Mid-read generation replacement: stale result, no fallback/retry or stale memo update.
   - Cleanup pending: no usable history result and no continuation.
   - Production OFF: zero factory/start/observation calls.

“Zero effects” after cancellation means zero conversational mutations, history commits, and dispatch—not pretending an already-started transport never existed. Its lifecycle must be accounted for and cleaned up.

## Recommendations

- **Implement this bounded coordinator composition.** The supplied factory, explicit lifecycle scope, registered startup, and controller-owned reader are sufficient grounds to close cold Codex source behavior rather than declare it unsupported.
- Require startup-before-generation, policy-preserving ownership, and joined cleanup as one coupled change.
- Verify the unsupplied request-retry and shutdown seams while implementing; extend those existing seams minimally if necessary, not with another service.
- Keep production OFF and qualification/live acceptance pending. Do not broaden Claude, helper, packaging, or schema scope.

## Pinned native-history fixture provenance

Read-only follow-up: `prompt-exports/agent-run-b1958a406e6d-fc162f4c.md`. Main opened both public upstream files pinned to commit `3cb0c27eca8caccdc153471a1b19f97fce4ada03` and checked the named symbols. Use symbols rather than treating browser-normalized line offsets as certified GitHub anchors.

The pinned [`_make_transcript_entry` and `_parallel_tool_turn` fixtures](https://github.com/anthropics/claude-agent-sdk-python/blob/3cb0c27eca8caccdc153471a1b19f97fce4ada03/tests/test_sessions.py) establish the entry fields and concrete parallel shapes: distinct entry identities can share an API response ID; tool results reference their call through parent/source/tool IDs. `test_parallel_tool_calls_keep_every_call_and_result` exercises four result orders. The pinned [`_build_conversation_chain` and `_recover_orphaned_parallel_tool_results` reader](https://github.com/anthropics/claude-agent-sdk-python/blob/3cb0c27eca8caccdc153471a1b19f97fce4ada03/src/claude_agent_sdk/_internal/sessions.py) supplies parent traversal and same-writer association context. These are reproducible implementation/synthetic-fixture evidence, not a stable schema, accepted CLI version, completion proof or live qualification.

The adopted conservative decoder contract above still wins over the scout's loose stopping wording: validate the **entire captured complete candidate** before any row/cursor commit. Unsupported meaningful metadata (including `file-history-snapshot`) causes no candidate commit; only an incomplete trailing line may leave a separately validated complete prefix. Do not copy upstream's permissive skipping or broaden the decoder into a general graph/sidechain engine.

## Pre-R1 bounded correction amendment

OracleA planning continuation on held source, not an additional review round. Main verified preset `61D024A4-CCFB-4C9C-A614-CC65E0A1864C` / `OracleA`, explicit selection; export `prompt-exports/oracle-plan-2026-10-22-165257-restart-phase-4-boun-ac2a.md`. Main read the complete response. The three corrections below are adopted for implementation. The extra saved-bubble cut is rejected because the existing normal seam can reuse its deterministic item. The unresolved-helper exceptional Stage B restriction is an activation-policy choice for the owner; production Restart safely stays OFF regardless. The owner question timed out after 302 seconds with no selection. Assumed: follow the recommended reversible option, keep Restart safely disabled, and complete/review only the conservative source. This is not approval of the exception or an owner Decision; activation remains blocked until accepted or resolved. This is not an owner Decision or source acceptance. Full Claude canonical merge remains evidence-blocked.

# Oracle Plan

## Summary

Make three targeted corrections: move recovery-action exclusion into the existing app-scoped `AgentRecoveryCoordinator`, carry its exact payload authorization through deferred normal submission; require positive helper-disarm/exit proof rather than treating termination timeout as success; and reuse a matching saved user bubble through `appendPreparedUserTurn` instead of refusing Send saved. These are planning amendments, not another review round or source acceptance. Production remains OFF, O3 pending, and the adopted Claude cut is unchanged.

## Current-state analysis

The supplied source establishes the gaps:

- `AgentRecoveryActionRunner.inFlight` is window-local. Shared lane admission exists, but `AgentRecoverySessionLane.isValidForHandoff` currently checks only retirement, reset, and shutdown.
- Queue receipts survive deferred submission, whereas `.submitted` can precede actual handoff. Consequently, runner completion currently releases its hold too early.
- `stopUnarmed()` ignores both termination success and the final exit-wait result, then marks the helper finished. `showFailure` assumes `abandon()` supplied proof that it did not.
- Send saved already supplies the original intent receipt and deterministic user-item ID. Its explicit existing-bubble refusal and the unconditional append in `appendPreparedUserTurn` prevent that identity from being reused.

The probe’s remaining call-site claims should be verified while editing. No new service or broader audit is required.

## Design

### 1. Shared action hold with exact, deferred dispatch authority

#### Shared owner and scope

Extend `AgentRecoveryCoordinator` beside its existing lane mappings and tokenized shutdown-freeze machinery.

Add a synchronous, main-actor acquisition operation, conceptually:

`beginRecoveryAction(request, lane, workspace) → holder / existing-operation / refusal`

The coordinator owns a small in-memory entry containing:

- Opaque token and action ID.
- Exact lane identity and lifecycle binding.
- Durable session ID and authoritative workspace ID.
- Frozen request identity.
- Authorized payload identities.
- Pending submission/handoff state and completion notification.

Acquire it **before the first reservation/reconciliation await**. Refuse another action or ordinary dispatch in the same session or workspace. Resolve workspace scope through the existing coordinator mapping, not an optional caller value that can omit the workspace fence. An unresolved required mapping fails action acquisition.

The token is an exclusion/authorization record, **not a lock held across persistence**. Never hold the lifecycle persistence gate, MCP bootstrap lease, or scheduler lease for this interval.

Keep the window-local runner for execution if convenient, but make cross-window ownership authoritative in the coordinator. Exact duplicate requests join the shared operation; different requests cannot acquire another hold. A successor lane cannot inherit the predecessor’s token.

#### Exact holder-only authorization

Do not broaden `.explicitUserAction` into a bypass.

Issue an opaque action authorization bound to:

- The hold token, action ID, lane and lifecycle.
- For continuation/question input: its planned user-item ID, frozen admitted payload, and subsequently its store-issued intent ID.
- For Send saved: its single source intent ID and original user-item ID.
- Exactly one submission and its resulting dispatch attempt.

Carry this authorization in `AdmittedUserTurnInput` and `AgentQueuedInputIdentity`, then into `AgentRecoveryDispatchEvidence`. Its initializer must remain coordinator-controlled. Persisted action/intent associations remain the durable evidence; the in-memory authorization must not decode as reusable authority after relaunch.

Check it at all existing convergence points:

1. **Input admission:** lane `admitQueued`.
2. **Dispatch commit:** lane `beginDispatch`/`beginDispatches`, before and after suspensions.
3. **Actual handoff:** `AgentRecoveryDispatchEvidence.isValidForHandoff(in:)`.

Replace the lane-wide Boolean-only final check with an evidence-aware check accepting the carried authorization and exact receipts. Retain the existing retirement/reset/shutdown checks.

A valid holder token exempts only the matching action from **its own action hold**. It never bypasses startup, R6, crash restrictions, shutdown, reset, attachment checks, or stale ownership.

Reject mixed/coalesced payloads containing unrelated constituents. A token for one saved message must not authorize draining its neighboring queue entries.

Already-admitted ordinary input gets refused at dispatch or final handoff. Where dispatch was durably committed but handoff has not begun, reuse `settleStaleDispatch` to return it to queued. Also check the shared hold before the untracked-evidence shortcut; absence of a receipt must not become an exemption.

The scheduler’s existing unresolved-work projection should query this coordinator state. Its `runAlongsideOtherSessions` distinction remains unchanged: that setting cannot bypass an action hold.

#### Release only after deferred submission settles

**`.submitted` is not `.dispatched`.** Preserve the ordinary submission API, but add an action-scoped completion carried by the same input identity.

For recovery callers:

- `.blocked` or `.scheduled` settles as no recovery handoff.
- `.submitted` means the action waits for its carried completion.
- Hydration cancellation, validation failure, queue removal, and pre-handoff failure settle that completion as not handed off.
- The existing provider handoff/evidence path settles it when handoff has occurred, been rejected, or become uncertain.

Use existing evidence writes and their ordered write tail; do not wait for the model turn to finish. For any provider whose acceptance can arrive much later, distinguish actual handoff completion from affirmative acceptance rather than keeping the action hold until model completion.

Release the shared hold only after:

1. Observation cleanup has finished.
2. The exact deferred submission has settled.
3. Required dispatch evidence and the action-outcome write have completed or failed explicitly.
4. Any failure requiring an uncertainty restriction has installed that restriction.

Then ordinary active-run/R6 restrictions take over.

A timeout or cancelled UI task is not release evidence. Before releasing a cancelled pending submission, revoke its authorization so later hydration/provider tasks fail their final check. If handoff may already have happened, preserve delivery uncertainty and the existing restrictions. Late callbacks cannot revive the revoked token.

This also covers lane replacement: revoke the old token synchronously, retain ownership until its delayed work is fenced/settled, and never authorize the replacement lane with it.

### 2. Helper abandonment must return proof, not `Void`

#### Minimal result contracts

In `ProcessRelaunchHelper.swift`, change the private channel termination closure from `Void` to a result distinguishing:

- Signal successfully requested.
- Exact child already observed exited.
- Failure/identity uncertainty.

**Signal successfully requested is not exit proof.**

Change `stopUnarmed`/`abandon` to return:

- `safe`: correlated abort acknowledgment establishing irreversible disarm, or observed exact-child exit.
- `unresolved`: deadline expired, termination failed, or identity/exit could not be established.

The helper may acknowledge `aborted` only after its state has irrevocably disabled opening the bundle. Merely receiving the abort request is insufficient. Keep child-resource ownership until its eventual exit even if disarm acknowledgment already establishes no-relaunch safety.

In `AppRelaunchCoordinator.swift:168–212`, replace the unchecked `isRunning`/`kill` assumption with the existing exact-child lifetime/exit authority. Record the signal result. Neither `kill == 0`, `ESRCH` alone, nor elapsed grace establishes observed exit.

#### One deadline, including cleanup

Keep one absolute R4 expiry and a work cutoff one second earlier. Pass the **remaining absolute cleanup budget** into abandonment; retries, repeated calls, and sequential waits must not restart that budget.

`stopUnarmed`:

1. Send abort.
2. Await correlated disarm acknowledgment or exact-child exit within the allocated slice.
3. If unproven, request exact-child termination.
4. Await exit only through the remaining absolute deadline.
5. Return `unresolved` if proof is still absent.

Only a safe result sets the no-relaunch state. Never set `.finished` merely because both waits expired.

In `AgentLifecycleShutdownCoordinator.showFailure`:

- Await the typed abandonment result.
- Present the existing Retry/Cancel or Retry/Quit anyway choices **only on safe abandonment**.
- Do not clear away ownership/proof state before that result.
- An unresolved helper must not be replaced with a fresh helper.

#### Genuine limitation and choice

No bounded userspace signal/wait sequence can guarantee an exact child exits within one second under every failure. Thus these three promises cannot all be unconditional:

1. Stop waiting within R4’s eight seconds.
2. Offer Quit anyway immediately.
3. Prove an ambiguously armed helper cannot relaunch.

The smallest honest implementation reports **helper safety unresolved** by the deadline, retains ownership, and does not offer a purportedly non-relaunching exit. It does not wait unboundedly; later exact-child exit/disarm evidence can clear that restriction.

That exceptional state departs from R4’s unconditional Stage B choice set. **This is the only genuine owner-policy choice:** accept that exceptional restriction, or keep Restart safely unavailable. Recommend keeping production Restart safely OFF and marking this activation condition unresolved; do not weaken proof or add time. Ordinary quit behavior is not to be redesigned.

### 3. Send saved should reuse its original bubble

A narrow branch in the existing preparation seam is sufficient. No second sender or new bubble-cut is justified.

#### Authorization and lookup

Remove the blanket refusal in `dispatchRecoverySavedIntent` only for an exact, authorized Send saved input.

Before submission, require:

- Current lane/incarnation/reset generation and unchanged target.
- One claimed intent, with authoritative evidence that it was never handed off or was verifiably returned to queued—not acceptance or delivery uncertainty.
- No active run, pending unsupported handoff, or missing managed attachment.
- The action’s exact authorization and store-issued queue receipt.
- An unambiguous canonical user item with `intent.userItemID`, if one exists.

Resolve that item through existing transcript/working-suffix projection. `session.items` alone is insufficient, and the same item represented in both views is not two distinct items.

The persisted intent remains the payload authority. Validate an existing item’s user kind, attachment identities, tagged-file references, workflow, and expected bubble rendering using `userBubbleText`. Text matching is a consistency check **after the stable-ID join**, never identity evidence.

If retained canonical details cannot establish consistency, refuse without changing the item or payload. Do not reinterpret missing compacted details as a new absent bubble.

#### Existing append seam

Add a narrow authorized reuse input to `appendPreparedUserTurn`, propagated from `submitPreparedUserTurn`. Ordinary composer/MCP/scheduled behavior stays unchanged.

For authorized reuse:

- Return the original `AgentChatItem`.
- Do not append, increment sequence, change its timestamp/ID, or rewrite its attachments.
- Reestablish the existing turn anchor using that item without creating another request.
- Build provider text from the saved intent through the existing preparation/wrapping path.
- Do not consume current composer/interview state or stage unrelated composer computer-use changes.
- Preserve the original saved interview/workflow selection.

For genuinely absent items, use the existing append path with the same preassigned user-item ID.

Normal dispatch then creates a **new run attempt and dispatch attempt**, still joined to the original user-item/turn identity. Preserve prior attempts as history; never reuse an uncertain old attempt. Any reopening of a previously no-handoff turn must use the normal run-start mutation for that same turn, not append a second turn.

Add an explicit appended-versus-reused result to `PreparedUserTurnAppend`. Failure cleanup must remove only a newly appended optimistic row; it must never delete the pre-existing saved bubble. In particular, inspect callers of `removeUnconfirmedMCPOptimisticCodexUserItem` for this distinction.

## File-by-file impact

| File | Minimal change |
|---|---|
| `AgentRecoveryCoordinator.swift` | Shared action ownership; payload-scoped authorization; lane admission/final-handoff checks; shared workspace projection |
| `AgentRecoveryActionRunner.swift` | Acquire/join shared ownership; await actual deferred submission settlement before outcome/release |
| `AgentRecoveryQueuedInput.swift` | Carry authorization/completion with existing identities and dispatch evidence; fence untracked and delayed paths |
| `AgentModeViewModel+RecoveryActions.swift` | Await action submission completion; authorize saved-bubble reuse; remove blanket existing-item refusal |
| `AgentModeViewModel.swift` | Propagate context through hydration/Codex tasks; reuse branch in `appendPreparedUserTurn`; distinguish reused-row cleanup |
| `AgentModeViewModel+ScheduledSend.swift` | Replace local runner busy projection with shared coordinator state |
| Existing handoff/provider evidence call sites | Settle action completion at actual handoff/no-handoff boundaries, not `.submitted` |
| `ProcessRelaunchHelper.swift` | Typed termination/abandonment results; absolute-budget cleanup; no false `.finished` |
| `AppRelaunchCoordinator.swift` | Exact-child signal result and observed-exit proof |
| `AgentLifecycleShutdownCoordinator.swift` | Consume abandonment proof before failure choices; preserve sole deadline and unresolved ownership |

No persistence framework or new store is required. Retain existing additive persistence/unknown-member handling wherever action associations are extended.

## Implementation order and bounded validation

1. **Shared ownership plus deferred completion, atomically.**
   - Two VMs sharing one coordinator cannot dispatch competing actions/input in the same workspace.
   - Manual, MCP, queued, scheduled, and `runAlongside` starts are blocked.
   - Exact holder payload passes; mixed/forged/stale authorization fails.
   - `.submitted` followed by delayed hydration keeps the hold.
   - Pre-handoff rejection, cancellation, lane replacement, and failed outcome persistence release only after revocation/settlement and appropriate uncertainty restriction.
   - Persistence inside the action does not deadlock.

2. **Saved-bubble reuse through that normal path.**
   - Existing deterministic bubble: one bubble, original attachments, one new dispatch/run attempt.
   - Canonical item outside `session.items` is found.
   - Mismatch/uncertain delivery: zero handoffs and no mutation.
   - Failed sending preserves a reused bubble.
   - Genuinely absent bubble appends once.
   - Unrelated composer and held inputs remain untouched.

3. **Helper proof propagation as one coupled fix.**
   - Lost arm acknowledgment plus correlated disarm is safe.
   - Successful signal without observed exit remains unresolved.
   - Failed signal, wrong lifetime, and deadline expiry never report finished.
   - All cleanup consumes the original eight-second budget.
   - Retry/Quit anyway is not presented on unresolved helper safety; no fresh helper starts.

Use injected clocks, provider boundaries, and child-exit events only. No helper execution, live processes, provider calls, or additional review round is authorized by this planning response.

## Recommendations

- Implement the shared coordinator hold and exact receipt-carried authorization **together with deferred handoff settlement**.
- Implement saved-bubble reuse; its stable identity already provides the necessary normal-dispatch seam.
- Implement typed helper proof and fail closed on unresolved abandonment.
- Keep Restart safely OFF unless the owner accepts its exceptional unresolved-helper restriction. That is the sole blocking policy choice; the other two fixes require no new architecture or scope cut.

## R1 correction scope (main disposition)

R1 source tree `85142397c2e1d74b0a74bb0a6a7750ef9c314ff6` did not close all required findings; raw responses and dispositions are linked from `phase4.md`. The earlier planning assumption that hard action exclusion should cover ordinary manual/MCP/queued input in sibling sessions is superseded: the spec's R9 asks for workspace-wide **automatic** busy aggregation. Hard exclusion remains shared across windows for the action's own durable session; sibling live input stays usable. This cuts unnecessary scope rather than adding a service.

Required closure is exact post-commit no-handoff settlement during shutdown/reset; explicit original-turn response anchoring for older saved bubbles through normal dispatch; captured absolute work/final helper expiries through serialization/spawn/cleanup; and the plausible non-Codex pre-evidence start-failure settlement path. The disclosed older-bubble refusal is not adopted as an extra cut. If the normal anchor cannot support it without a new timeline architecture, the worker must report that precise blocker rather than fabricate one.

Provably-unarmed helper ownership does not require an owner exception: restore R4 Stage A usability while retaining child ownership and preventing a replacement helper. Only an ambiguously arm-sent unresolved helper retains the pending activation-policy exception. Production Restart safely stays OFF; no owner answer or activation is inferred. One normal re-review remains, for the required fixes and regressions only.

## Older-bubble source obstruction and owner-approved checkpoint

Main read the item model, positional importer/final-turn boundary, tail append and runtime-footer anchor directly. The planning continuation below supersedes the earlier assertion that the existing original-turn anchor suffices. Main verified OracleA preset `61D024A4-CCFB-4C9C-A614-CC65E0A1864C` / `OracleA`, explicit continuation in the same planning chat, and read its complete response. Export: `prompt-exports/oracle-plan-2026-10-22-182901-restart-phase-4-boun-249c.md`. This is not a further review or acceptance.

The owner answered the Phase 4 architecture question after 21 seconds: **Preserve architecture; partial checkpoint (Recommended)**. This actual answer is recorded as O9. It authorizes the reviewed inactive partial checkpoint, not full R1a/R7 completion, activation, or a transcript-membership redesign. Main will retain the fail-closed refusal and clarify its text; no source-order or timeline-model change is made. The arm-sent helper-policy question remains unanswered and Restart safely stays OFF.

# Oracle Plan

## Summary

**Keep the older-bubble refusal and prepare a bounded, inactive checkpoint—not full Phase 4 completion.** The supplied source does not establish a bounded normal-dispatch seam that can attach new output to an older user item while preserving later turns, including compacted history. My earlier recommendation that an explicit original-turn anchor would suffice was too strong: the existing anchor controls runtime bookkeeping, not transcript membership. Do not introduce a timeline redesign under this repair.

## Current-state analysis

The obstruction is concrete, not merely a missing parameter:

| Source | Established behavior |
|---|---|
| `AgentChatModels.swift:118–242` | `AgentChatItem` carries identity and sequence, but no explicit owning-turn identity. |
| `AgentTabSession.appendItem`, `:3005–3039` | New output receives the next sequence index and is appended to the working suffix. |
| `AgentTranscriptServices.importLegacyItems`, `:3295–3424` | Items are sorted by sequence/timestamp. Each user item starts a turn; following output belongs to that positional turn. |
| `AgentTranscriptServices.finalTurnStartIndex` | Incremental import identifies the final turn by the **last user item**. |
| `AgentModeViewModel.recordAgentTurnUserAnchor`, `:4275–4342` | The anchor drives timers/footer placement using sequence ranges. It does not redirect output or change importer membership. |
| `appendPreparedUserTurn`, `:17370–17479` | Reuse preserves the original bubble and records a runtime anchor; it does not alter the provider output destination. |

For example, with existing order:

**unsent user A → newer user B → B’s output**

sending A without appending another bubble leaves newly appended output after B. The importer therefore attributes that output to B, regardless of the dispatch receipt or run attempt identifying A.

The worker’s proposed cross-cutting membership design is **not proven to be the only possible future solution**. However, the supplied source does prove that carrying `userItemID` or calling the existing anchor method alone does not solve this case.

## Design decision

### Do not patch canonical turns directly

Directly appending a response span to A’s canonical turn would not close the existing path:

- Normal streaming still appends and updates working items at the tail.
- Positional reconstruction can place those items under B again.
- Updating both representations requires a durable rule that tells subsequent rebuilds where those items belong.
- For a compacted A, the supplied code establishes no supported operation that reopens that historical turn and keeps subsequent working-prefix merges consistent.

A canonical-only mutation would therefore need either a parallel output path or additional membership semantics honored by the existing transformations. Neither is an evidenced, localized repair.

Likewise, do not:

- Remove the latest-user guard.
- Change sequence numbers or move A/later messages.
- Insert another user bubble with A’s identity.
- Temporarily rearrange the working suffix and restore it afterward.
- Special-case only un-compacted turns and call the full contract satisfied.

These approaches either change the requested behavior or leave persistence/rebuild attribution unresolved.

### Retain the bounded supported behavior

Keep the current distinction:

- **Absent original bubble:** existing deterministic-ID append path.
- **Matching latest user bubble:** existing authorized reuse path, subject to its normal validation.
- **Matching older bubble with newer user messages:** refuse before provider dispatch; preserve the intent, attachments, original bubble, and later history.

The older-bubble refusal must:

- Return `notDispatched`, never resolve the intent as sent or withdrawn.
- Settle/release the action authorization through the existing no-handoff path.
- Leave Edit available as an explicitly different action.
- Never imply that editing and sending a new message fulfills stable-ID Send saved.

Current wording is adequate in substance, but “Edit it to send it again” can imply previous delivery. Prefer:

> Newer messages follow this saved message. Sending it without duplicating or moving its original bubble isn’t supported yet. Nothing was sent. You can edit it as a new message.

No new schema, importer mode, provider adapter, or presentation path is authorized by this decision.

## File-by-file impact

| File | Direction |
|---|---|
| `AgentModeViewModel+RecoveryActions.swift` | Retain `recoverySavedIntentBubble`’s older-message refusal; clarify the limitation text and avoid claiming complete Send saved coverage. |
| `AgentModeViewModel.swift` | Keep the authorized latest-bubble reuse branch. Do not extend `recordAgentTurnUserAnchor` into an unsupported transcript-routing mechanism. |
| `AgentChatModels.swift`, `AgentTranscriptServices.swift`, `AgentTabSession.swift` | **No changes for this scope decision.** In particular, no new per-item turn-membership field or positional-order rewrite. |
| Existing recovery tests | Add or retain the narrow refusal/preservation cases below. |
| Existing Phase 4 evidence artifact | Record the source-backed limitation and supersede the earlier claim that an original-turn anchor alone closes older-bubble sending. |
| Original spec | Status-line changes only unless the owner supplies an actual decision. Keep the full goal blocked. |

## Implementation order and bounded validation

1. **Keep the speculative timeline work stopped.** Retain the guard and align its message/comments with the actual supported subset.
2. **Validate through existing recovery tests:**
   - Older matching bubble in the working suffix: zero handoffs; original intent and all message identities/order preserved.
   - Older canonical/compacted request with a newer user item: same refusal and preservation.
   - Refusal creates no second bubble and leaves the input discoverable.
   - Action authorization settles as no-handoff; unrelated admission is not left permanently held.
   - Existing absent/latest-bubble cases retain their normal-dispatch behavior.
3. **Carry this exact limitation into the already-required normal R2 process.** This response adds no review round and does not establish acceptance.
4. **Checkpoint only under the existing review/commit policy.** Do not mark the full contract or an associated open finding resolved merely because the feature is inactive. Record source progress separately from contract completion.

## Recommendations

- **Recommend the bounded inactive checkpoint.** Preserve the architecture and keep older-bubble Send saved explicitly blocked.
- The owner’s actual choice is whether to accept that partial checkpoint with the full goal still open, or authorize a separately bounded transcript-membership change. Recommend the former; no speculative design is needed now.
- Do not claim that no future smaller solution exists—only that none is grounded in the supplied seams.
- Keep production OFF, normal-live Claude canonical merge blocked, and O3 pending. This decision neither expands those cuts nor declares Phase 4 complete.
