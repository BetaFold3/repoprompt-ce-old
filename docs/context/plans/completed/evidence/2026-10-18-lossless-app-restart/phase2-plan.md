# Phase 2 remaining implementation planning

Scope: read when the task touches completion of honest interruption, the shared recovery catalog, durable card acknowledgement, or normal-operation question persistence.
Authority: Reference
Last-verified: 2026-10-21

OracleA identity verified (`61D024A4-CCFB-4C9C-A614-CC65E0A1864C`), chat `restart-phase2-remaining-DC4C51`, baseline signed commit `57e451205ecded20a42b3ce1b61834ebd514cbac`. Main adopts the ordered single-worker implementation and explicit question-timing assumption. To avoid a redundant plan, the original lossless-restart plan remains the sole status/owner-decision document; all Phase 2 evidence stays in this existing evidence directory, rather than the separate plan/directory proposed below. Implementation is in progress; the [implementation evidence](phase2.md) records validation and remaining gaps. Independent review is pending. O3 live acceptance remains pending.

# Oracle Plan



## 1. Summary

Complete Phase 2 as a **targeted extension of the existing recovery architecture**, using **one coupled implementation worker** and one reviewed product checkpoint. The remaining work is typed live interruption evidence, correct terminal-outcome presentation, schema-8 metadata hints, a coordinator-owned catalog feeding the banner and app-wide Needs Attention sheet, durable acknowledgement-only Dismiss, and normal-operation question persistence. Preserve R4 ownership serialization, terminal commits, startup admission, crash holds, and scheduled-send rules. Exclude Resume, Restart Safely, process registration, history import, retention work, and new storage systems. **O3 real-app/live acceptance remains explicitly pending.**

This plan uses the supplied source excerpts and scout; no tools, validation, workers, or reviews were run. The reported baseline is signed HEAD `57e451205ecded20a42b3ce1b61834ebd514cbac`, with an empty real index and unrelated dirty files preserved.

## 2. Current-state analysis

### Existing authority and flow

- `AgentRecoveryAppComposition` creates **one recovery store, one recovery coordinator, and the shared scheduler**. Startup captures the previous launch, inventories closed workspaces, reconciles sessions, publishes restrictions, and only then opens scheduler admission.
- `AgentRecoveryStore` owns durable per-session recovery records. `AgentSessionDataService` owns session persistence and reconciliation under session gates. Live mutations go through the existing recovery lane and lifecycle binding.
- `AgentRunTerminalCommitBarrier` is the ownership-checked terminal boundary. It finalizes the run, prepares transcript publication, records terminal evidence through `lane.recordTerminalEvidence`, and updates bindings.
- `AgentTranscriptTurn.interruption` already exists. Cold restore stamps open turns before sanitization; per-attempt shutdown reasons precede launch evidence. `preservingInterruptedTurnEnvelopes` already carries the interruption record across rebuilds by turn ID.
- `AgentModeViewModel+RecoveryList.swift` already projects recovery records into useful rows and implements guarded Open, Edit, Remove, question-copy, schedule-cancel, and crash-hold confirmation actions.
- `AgentRecoveryQuestionSnapshotBuilder` already captures active and queued native questions, `ask_user`, and elicitation metadata. `updateQuestionSnapshots` already performs exact interaction-ID upserts/removals without replacing unrelated questions.

These are extension points, not components to replace.

### Remaining defects and gaps

1. **Live interruption evidence is incomplete.**
   Cold restore only stamps still-open turns. A terminal turn saved by R4 therefore needs its interruption stamped during the terminal commit. Provider-loss paths currently finalize without a typed interruption cause.

2. **Terminal evidence is misclassified.**
   `AgentSessionDataService.swift:3546–3555` treats any non-nil terminal evidence as completed. Failed and explicitly cancelled runs must not receive completion wording.

3. **The metadata index remains schema 7.**
   `hasUnresolvedInterruption` is transcript-derived and optional. A stub rebuild intentionally has no transcript, so absence cannot mean “nothing to recover.”

4. **Recovery projection is still view-model-local.**
   Inventory is already app-wide, but row construction filters by workspace and depends on VM-local state. There is no shared typed catalog or independently accessible Needs Attention surface.

5. **Hide is transient.**
   `.hide` in `performRecoveryListAction` performs no I/O and marks a local row `.resolved`. This neither survives restart nor supplies shared acknowledgement semantics.

6. **Questions are only captured reliably during shutdown.**
   Creation, queued requests, non-secret draft changes, and live resolution need normal-operation durability. The existing snapshot builder must remain the privacy boundary; elicitation is an action card, not a form.

### Constraints retained

- Session serialization stays **version 7**; recovery records stay **schema 1 with additive fields**. Only the rebuildable metadata index advances to 8.
- No new `.interrupted` run-state case.
- No recovered continuation, provider construction, send, queue drain, or schedule confirmation.
- Dismiss never changes admission or ownership.
- R4 Stage A freeze, deadline, secret-answer veto, rollback, and Stage B semantics remain intact.
- The earlier spec’s “Code: none exists” and older status prose are historical, not current implementation authority.

## 3. Design

### A. Typed terminal causes and honest reconciliation

#### Types and interfaces

Add an internal/package terminal-cause enum alongside `AgentRunTerminalCommitBarrier`:

| Case | Meaning |
|---|---|
| `ordinary` | Verified normal completion or failure, without a lifecycle/user-cancel cause |
| `userCancel` | Explicit user cancellation |
| `appQuit` | R4 app-quit teardown |
| `windowClose` | R4 window-close teardown |
| `providerProcessLost` | Unrecoverable provider transport/process loss |

Do not add a live `appCrash` case: crashes are inferred during cold restore. Do not add a safe-restart route.

Extend the existing terminal request and terminal revision with `cause`. Require each production request-construction site to supply it explicitly; do not use a default that conceals missed callers.

Persist an additive optional `cause` on the existing run-attempt terminal evidence value:

- Stable serialized strings match the cases above.
- Missing legacy cause remains **unspecified**, not `userCancel`.
- An unrecognized cause is treated conservatively as unspecified.
- Reuse existing per-attempt shutdown evidence for legacy app-quit/window-close/provider-loss attribution.

The exact terminal-evidence declaration and codec are outside the supplied slices. Locate them through `recordTerminalEvidence`; extend those existing types rather than introducing a second terminal record.

#### Terminal commit ordering

Within the existing ownership-checked barrier:

1. Validate the current ownership/run identity using the existing checks.
2. Drain and prepare terminal transcript state through existing hooks.
3. Resolve the committed turn ID using the existing terminal join.
4. Stamp `turn.interruption` for `appQuit`, `windowClose`, or `providerProcessLost`.
5. Persist the same cause with terminal evidence through the existing lane.
6. Publish bindings only after the in-memory terminal projection includes the stamp.

The stamp uses the actual run-attempt ID, existing provider conversation identity, observation time, and last confirmed transcript activity. Never invent an attempt ID or runtime reference.

Keep existing terminal-state behavior: cold interruption sanitization remains `.cancelled`; a live provider-loss path may retain its existing `.failed` state. The optional interruption record supplies the causal presentation.

**Race rules:**

- First accepted terminal commit wins under existing ownership checks.
- A late provider-loss callback cannot overwrite a completed run or explicit user cancellation.
- R4 Stage A shutdown preparation is **provisional**, not itself a live interruption. Cancelling Stage A must leave the live turn unstamped.
- If ordinary completion wins before teardown, its successful terminal evidence takes precedence over a previously prepared shutdown reason.
- Repeated commits do not refresh `observedAt` or manufacture new recovery events.

#### Shared classification

Use one pure classifier for startup reconciliation, recovery-only attempts, and catalog presentation. Extend the existing recovery status type rather than adding a separate UI-only classifier.

| Authoritative evidence | Presentation |
|---|---|
| Successful completion | Completed; transcript tail may be missing |
| Verified failure without interruption cause | Failed; transcript tail may be missing |
| Explicit user cancellation | Cancelled by you; transcript tail may be missing |
| App quit/window close/provider loss | Interrupted, with its reason |
| Open prior attempt without terminal evidence | Existing cold-restore interruption inference |
| Contradictory or unrecognized terminal evidence | Status unknown; never “completed” |

Only use tail-missing wording when reconciliation establishes a missing/stale transcript representation. Do not claim completion happened “while RepoPrompt was closed”; the available evidence does not establish that timing.

Extend `AgentColdRestoreInterruptionContext` to consult joined terminal evidence before inventing an interruption:

- A stale open transcript with authoritative user-cancel evidence closes as cancelled **without a recovery interruption**.
- Successful/failed terminal evidence closes according to that outcome, rather than acquiring a new crash interruption.
- Existing unresolved interruption evidence remains subject to the same typed classification.
- Preserve the existing exclusion for a run owned by the current launch.

`completedAt` inferred by sanitization remains a display/closure timestamp, never proof of provider success.

### B. Schema-8 bounded metadata hints

Add `recoveryHint` to `AgentSessionMetadataRecord`, using a small value type in `AgentSessionMetadataIndex.swift`.

| Field | Type/default | Meaning |
|---|---|---|
| `state` | `unknown`, `none`, `needsAttention`; missing → `unknown` | Aggregate discovery hint |
| `reason` | Optional existing interruption reason; default `nil` | Latest relevant interruption reason, if known |
| `unsentCount` | Optional nonnegative `Int`; default `nil` | Count of unresolved queued/dispatching/delivery-unknown/failed intents |
| `hasDraft` | Optional `Bool`; default `nil` | Nonempty durable composer content |

Here, “unsent” means **saved input still requiring a decision**, not proof of non-delivery. The UI must retain delivery-specific wording.

Rules:

- `needsAttention` if authoritative inputs identify an unresolved interruption, held input/draft, historical question, schedule needing confirmation, or unreadable recovery state.
- `none` only when all relevant inputs were inspected and clear.
- Otherwise `unknown`.
- Ignore acknowledgements when deriving the hint: acknowledged input and unresolved safety conditions still exist.
- Select `reason` from the most recent relevant interruption, using stable identity as the tie-breaker.
- No prompt text, answer text, entity arrays, or transcript fragments enter the hint.

Retain `hasUnresolvedInterruption` as a legacy compatibility field for this cut; do not make it a second authority.

#### Read/write and rebuild behavior

- Increment `currentSchemaVersion` to 8 and update coding keys, memberwise construction, decoding, and equality/matching.
- Reuse the current cache version-validation/rebuild mechanism for schema 7. Do not rewrite every session.
- `record(from:…)` gains an optional recovery-hint input; existing callers may omit it and receive a conservative hint.
- A transcript-only save must not replace previously known recovery-store facts with fabricated zero/false values.
- Recovery commits refresh the relevant in-memory projection and schedule existing per-session index maintenance. No whole-index rewrite on every question keystroke.

**Keep `rebuildMetadataIndex` stub-based.** Join stubs with the recovery inventory already obtained by startup; where evidence is missing, emit `unknown`. Do not hydrate all transcripts to populate hints.

The index cannot validate recovery-store freshness using session file size/mtime: recovery writes do not necessarily touch the session file. Therefore:

- Recovery-record inventory is always consulted independently of negative hints.
- Existing active-run/interruption inspection rules remain conservative.
- Stale or missing hints affect discovery work, never dispatch permission or item existence.

### C. Coordinator-owned catalog and minimal UI

#### Catalog ownership

Add `AgentRecoveryCatalog.swift` under the existing Core recovery directory. It contains immutable, `Sendable`, `Equatable` projection values—not a new actor, store, or independently refreshed service.

`AgentRecoveryCoordinator` owns and publishes the snapshot on the main actor. Inputs remain:

- startup reconciliation;
- current recovery records and lane commits;
- held/ownerless input already tracked by the coordinator;
- crash holds and restrictions;
- the scheduler’s existing summary of ordinary `needsConfirmation` records.

Use these Phase-2 item kinds:

- `interruptedTurn`
- `terminalOutcome`
- `savedInput`
- `savedDraft`
- `unansweredQuestion`
- `scheduleNeedsConfirmation`
- `crashHold`
- `heldScheduleTransfer`
- `statusUnknown`
- `saveFailure`

Each item carries:

- typed stable identity;
- session/workspace destination and display name;
- typed reason/status;
- existing display payload or references needed by the row adapter;
- action descriptors;
- typed blockers;
- semantic freshness;
- acknowledgement state.

Do not add surviving-process or Resume variants.

#### Projection and publication

Move domain row selection out of `recoveryListRows` into the coordinator projection. Keep App-specific formatting and action routing in the existing recovery-list adapter.

Update the catalog after committed record changes, terminal commits, reconciliation refreshes, and scheduler summary changes. Use the coordinator’s existing publication mechanism; discard asynchronous refresh results superseded by a newer refresh generation.

- Startup facts are overlaid by current committed facts.
- Current-launch active questions stay in their live cards, not duplicate historical rows.
- A persisted current-launch question becomes historical when its owning request/session is detached and its transport expires, including window close.
- Deduplicate a run’s transcript-backed and recovery-only representations by run-attempt identity.
- Deduplicate schedule-transfer and ordinary schedule rows by schedule/attempt identity, preferring the transfer-specific row.

Build maps once per projection; traversal is linear in the inspected records/items, plus stable display sorting. Do not introduce polling or a benchmark campaign.

#### Schedule integration

Read the scheduler’s existing confirmation summaries; do not infer confirmation state from deadlines in the catalog.

- Existing deadline, confirmation, dispatch, and cancellation rules remain unchanged.
- Catalog schedule actions route to the existing scheduled-message action path.
- Confirmation is still a separate explicit action.
- Catalog acknowledgement never changes a scheduled-send record.

#### Banner and Needs Attention

- The existing banner becomes a **session-filtered projection of the shared snapshot**.
- Add one app-wide **Needs Attention** sheet, using the existing Scheduled Messages presentation/navigation pattern.
- Its command remains available with affected tabs closed. If no document window is available, reuse the app’s existing window-opening/presentation route; opening this UI must not hydrate providers.
- Closed-session rows offer safe Open plus Dismiss where supported. Editing input still uses the existing lane-bound action after opening.
- Unknown/unreadable authority rows offer explanation and existing retry/open recovery, not invented destructive actions.

The sheet has one necessary secondary filter: **Show dismissed**. This preserves access to acknowledged input/questions without adding another storage or management surface.

Maintain a non-dismissible compact blocker indication while sending remains paused, even if the corresponding explanatory card was acknowledged.

**Snapshot/rendering contract:** the sheet renders the exact selected snapshot item IDs, in snapshot order. The banner renders the exact session-filtered subset. Presentation adapters may restrict actions for the current navigation context, but must not independently rediscover or remove rows.

### D. Durable Dismiss without resolution side effects

#### Persisted acknowledgement

Extend `AgentRecoveryRecord` with additive `cardAcknowledgements`, defaulting to an empty collection. Prefer an existing suitable recovery-decision encoding if present; the required semantics are:

- `itemKey`: typed semantic identity;
- `freshness`: typed semantic state at acknowledgement;
- `acknowledgedAt`: existing recovery timestamp.

Identity includes session incarnation, the item’s own reset generation where applicable, kind, and durable entity ID.

Use:

- run-attempt ID for a joined run/turn; turn ID only for legacy turns;
- intent ID for input;
- interaction ID for questions;
- schedule ID and relevant attempt/confirmation identity for schedules;
- existing composer revision for saved drafts;
- the existing crash-hold identity for crash holds.

Do not key acknowledgement by row text, array position, whole-record revision, or `updatedAt`.

#### Freshness minimum

| Item | Reappears when |
|---|---|
| Run/turn | Its classified outcome or interruption cause changes materially |
| Input | Delivery classification or typed hold/blocker state changes |
| Question | A new interaction ID is created; ordinary partial-answer edits do not unhide it |
| Draft | A different composer revision becomes the recoverable draft |
| Schedule | A new confirmation occurrence/attempt, deadline, or confirmation reason appears |
| Crash hold | The underlying uncertainty/attempt identity changes |

Ordinary composer writes, question edits, receipts, or other changes to the recovery record must not unhide unrelated cards.

#### Action contract

Add a coordinator acknowledgement operation taking the displayed item key and freshness. It:

1. Resolves the current item and validates lifecycle/destination.
2. Acquires existing session/lane serialization.
3. Revalidates freshness against current authoritative facts.
4. Writes the acknowledgement with the current record revision.
5. Publishes the resulting catalog only after commit.

Repeated clicks join the same in-flight action; an identical acknowledgement is an idempotent success. Revision conflicts caused by unrelated writes are retried through the existing lane mechanism. Changed semantic freshness returns “This item changed; review it again.”

For closed sessions, reuse the coordinator/DataService session-gated mutation path. Do not create a competing live lane or bypass an existing owner.

On failure, leave the card visible with a retryable inline error.

Replace `.hide` with `.dismiss` and remove local `.resolved` suppression for acknowledgement-backed rows. Shared action progress/errors belong with the coordinator so multiple windows agree.

**Dismiss must not modify:**

- `turn.interruption.resolution`;
- intents, composer content, questions, or attachment ownership;
- crash-hold acknowledgements or restrictions;
- schedule confirmation/cancellation;
- run/process ownership.

Question deletion remains a separate explicit **Remove saved question** action. Rename existing “dismiss” wording around `discardDraft`/question removal so it cannot be mistaken for acknowledgement.

Unpersistable errors and unreadable-authority rows do not offer durable Dismiss. Do not invent a global acknowledgement store for them.

### E. Pending-question crash persistence

#### Timing assumption

Record this under `assumed:`, not Decisions:

> Question creation and queue insertion use immediate, non-debounced persistence; non-secret draft changes reuse a 300 ms debounce with a 2-second maximum delay; explicit resolution flushes pending question changes. These bounds apply on healthy storage and are not a live-performance qualification.

Reuse the composer lane’s scheduling pattern and clock support; do not introduce a general persistence framework.

#### Capture and ownership

Extend `AgentRecoveryQuestionSnapshotBuilder` with per-interaction capture helpers so creation can capture a request **before exposing its active/queued UI state**. Keep its existing aggregate capture for R4 Stage A.

Each session’s existing recovery lane owns:

- pending question updates keyed by interaction ID;
- dirty/debounce timing;
- one serialized in-flight write;
- interaction lifecycle/generation checks;
- local terminal markers preventing late edits from resurrecting resolved requests.

Immutable snapshots cross to the store actor. Controllers, continuations, and mutable sessions do not.

For elicitation, preserve the first captured `askedAt` for an interaction. The current `Date()` on each capture must not manufacture freshness changes.

#### Creation and queueing

For `askUser` and native/elicitation producers:

1. Validate admission, request identity, and existing interaction rules.
2. Reserve the interaction under existing session ownership so concurrent requests cannot both pass validation.
3. Build and commit its sanitized snapshot immediately.
4. Revalidate ownership/request currency after the await.
5. Publish the active request or queue entry; install routing, continuation, and timeout using existing semantics.

`askUser` retains its public `async throws -> AgentAskUserResponse` signature. Native producer routes gain an awaited internal persistence boundary where needed; preserve their external provider protocol contracts.

On persistence failure, do not report the question as durably available. Use the producer’s existing failure response, preserve any already-entered local state, and surface a save error. Never synthesize a successful provider reply.

If ownership expires after commit, do not install a continuation on the new owner. Keep the committed snapshot as historical data.

#### Draft updates

After a validated non-secret edit:

- update live state immediately;
- capture that interaction’s latest sanitized snapshot;
- schedule the bounded lane write;
- update the published recovery record/catalog only when the write commits.

Hook actual mutation methods, including queued request changes. Do not rely only on `session.$pending…`: the supplied observation list omits queue/draft mutations and is primarily an MCP observation path.

Question navigation index, card focus, or activity notifications do not require a persistence write.

Secret handling remains structural:

- `isSecret` answers and selections never enter snapshots, extras, logs, error descriptions, or freshness.
- Preserve only the existing request text/options fields.
- Secret draft activity continues to trigger R4’s unsavable-answer veto.
- Do not add secure storage.

#### Resolution, cancellation, and teardown

For answer submission:

1. Reserve resolution and reject further stale edits for that interaction.
2. Flush the latest non-secret snapshot.
3. Execute the existing live response path exactly once.
4. Remove the snapshot by interaction ID after the live response is accepted by that path.
5. Finish the local persistence operation and clear error state only after removal commits.

If the response succeeded but removal fails, retain the historical snapshot and retry removal **without sending the response again**. Its recovery wording must say the old request expired and its response status may be uncertain, rather than definitively claiming it was unanswered.

For explicit decline/cancel/timeout, preserve existing protocol behavior and remove exactly that interaction through the same serialized lane. A timeout cannot wait indefinitely for storage; failed cleanup remains retryable and cannot resume the expired transport.

R4 preservation differs from resolution:

- Window close/app quit preserve snapshots and expire continuations; they do not remove questions.
- Stage A freezes edits, drains the live question lane, and uses the existing aggregate capture to close any remaining capture gap.
- Failure follows existing reversible Stage A behavior.
- Late completions after retirement/reset/delete fail existing ownership/lifecycle checks.

Queue promotion does not create a new interaction identity. Removal cancels pending coalesced upserts for that ID. Other queued, historical, or closed-window questions are untouched.

Elicitation persists only its existing title/prompt/message and actual **Accept / Decline / Cancel** lifecycle. No form or partial-answer subsystem is added.

## 4. File-by-file impact

Paths below are exact where supplied or explicitly proposed as new files. Some integration declarations were not included in the source packet; their physical paths must be source-mapped before editing, not guessed.

### Core

| File | Changes | Dependency |
|---|---|---|
| `Sources/RepoPromptAgentCore/AgentMode/Runtime/AgentRunTerminalCommitBarrier.swift` | Typed cause; terminal request/revision plumbing; ownership-checked live stamping | Recovery terminal model/codec |
| `Sources/RepoPromptAgentCore/AgentMode/Models/AgentTranscriptModels.swift` | Update interruption documentation for live and cold writers; reuse existing fields | No schema change |
| `Sources/RepoPromptAgentCore/AgentMode/Runtime/AgentSessionRestoreSupport.swift` | Terminal-evidence precedence; prevent explicit cancellation becoming interruption | Shared classification |
| `Sources/RepoPromptAgentCore/AgentMode/Runtime/AgentSessionDataService.swift` | Correct terminal classification; schema-8 hint inputs; conservative discovery; closed-session acknowledgement serialization | Models, classifier, index |
| `Sources/RepoPromptAgentCore/AgentMode/Runtime/AgentSessionMetadataIndex.swift` | Schema 8; hint type, decoding, construction, equality/matching | Classification semantics |
| `Sources/RepoPromptAgentCore/AgentMode/Models/AgentRecoveryModels.swift` | Additive terminal cause/acknowledgement model fields; update question documentation | Existing codec extension |
| `Sources/RepoPromptAgentCore/AgentMode/Runtime/Recovery/AgentRecoveryStore.swift` | Acknowledgement mutation; preserve new fields through every replacement; retain exact question updates; correct deletion-vs-dismiss comments | Models/codec |
| `Sources/RepoPromptAgentCore/AgentMode/Runtime/Recovery/AgentRecoveryCoordinator.swift` | Published catalog; shared action state; acknowledgement routing; schedule-summary integration | Catalog, lane/store |
| `Sources/RepoPromptAgentCore/AgentMode/Runtime/Recovery/AgentRecoveryCatalog.swift` **(new)** | Immutable catalog/item/identity/freshness/action/blocker projection types | Existing recovery/schedule types |
| `Sources/RepoPromptAgentCore/AgentMode/Runtime/Recovery/AgentRecoveryQuestionSnapshotBuilder.swift` | Reusable per-request capture; stable elicitation timestamp; unchanged secret boundary | Question producers |
| `Sources/RepoPromptAgentCore/AgentMode/Runtime/Codex/CodexAgentModeCoordinator.swift` | Explicit user/lifecycle/provider-loss cause forwarding; retain existing recovery grace/fallback behavior | Terminal cause interface |
| `Sources/RepoPromptAgentCore/AgentMode/Runtime/Scheduling/AgentScheduledSendCoordinator.swift` | Expose/reuse confirmation-summary observation only | Catalog integration |

`AgentTranscriptServices.swift` needs **tests, not a planned production rewrite**: reuse `preservingInterruptedTurnEnvelopes`.

### App

| File | Changes | Dependency |
|---|---|---|
| `Sources/RepoPrompt/App/AgentRecoveryAppComposition.swift` | Connect shared catalog/scheduler observation and app presentation; retain startup ordering | Coordinator/catalog |
| `Sources/RepoPrompt/Features/AgentMode/ViewModels/AgentModeViewModel.swift` | Immediate `askUser` persistence; draft/resolve hooks; lifecycle cause forwarding | Lane/builder/barrier |
| `Sources/RepoPrompt/Features/AgentMode/ViewModels/AgentModeViewModel+RecoveryList.swift` | Adapt shared catalog; replace transient Hide; retain guarded existing actions; distinguish Remove from Dismiss | Catalog/acknowledgements |
| `Sources/RepoPrompt/Features/AgentMode/ViewModels/AgentModeViewModel+RecoveryQuestions.swift` **(new)** | Small VM integration helpers for capture, flush, and resolution ordering—not a second persistence owner | Existing lane |
| `Sources/RepoPrompt/Features/AgentMode/Views/AgentRecoveryNeedsAttentionSheet.swift` **(new)** | Minimal snapshot-driven sheet, Show dismissed, existing row/actions reuse | Catalog and app presentation |

### Mandatory source mapping before implementation

The excerpts do not expose these declarations’ files. The worker must identify and record their exact paths in the evidence manifest:

- `AgentRecoverySessionLane`, its underlying controller/write queue, terminal evidence codec, and all `AgentRecoveryRecord` reconstruction sites.
- Terminal request/revision definitions and **every constructor/finalizer caller**, grouped by provider, explicit cancel, and R4 teardown.
- Native user-input and elicitation creation, queue, draft, response, cancellation, and timeout producers.
- `AgentRecoveryListProps`, `AgentRecoveryListRowProps`, existing row/banner views, and their exhaustive action switches.
- Existing Scheduled Messages summary/action source, sheet host, app command registration, and closed-session navigation route.
- Existing test suite physical paths and build registration conventions.

This is a mechanical call-site inventory, not permission to redesign those subsystems. No implementation checkpoint is complete with an unmapped producer or terminal caller.

### Tests and planning artifacts

Extend the existing suites:

- `AgentRecoveryStartupReconciliationTests`
- `AgentTranscriptRefreshDiagnosticsTests`
- `AgentSessionMetadataRecordExtensionTests`
- `AgentRecoveryCoordinatorTests`
- `AgentRecoveryStartupCompositionTests`
- existing R4 question/lane/shutdown suites

Add focused question tests under `Tests/RepoPromptTests/AgentMode/Recovery/` only where existing suites lack the producer boundary.

Create the distinct workstream:

- `docs/context/plans/2026-10-21-lossless-app-restart-phase2.md`
- `docs/context/plans/evidence/2026-10-21-lossless-app-restart-phase2/`

The plan file contains status lines and actual owner Decisions only. Put this design, file inventory, validation results, review findings, and deferred items in the evidence directory.

Suggested initial status:

> Step 1 — todo | rounds 0/2 | open: remaining Phase 2 implementation and review | downgraded: none | assumed: immediate question creation writes; non-secret drafts 300 ms debounce/2 s maximum; one coupled worker | deferred: optional polish/retention; O3 real-app/live acceptance

Do not copy implementation assumptions into Decisions or rewrite frozen earlier evidence.

## 5. Risks and migration

- **Recovery schema:** New terminal cause and acknowledgement fields are additive in schema 1. Missing acknowledgements decode empty. Preserve unknown members and every unrelated field through replacement. Unreadable/future records remain unmodified.
- **Index migration:** Schema 7 is handled as a rebuildable cache. Rebuild remains stub-based. Metadata loss or rebuild must never erase recovery authority.
- **Rollback:** Older builds may ignore new acknowledgements or lose live cause information on resave. Cards may reappear; this must not discard input. The existing warning about older builds not enforcing recovery fences still applies.
- **Question crash windows:** A crash after response handoff but before snapshot removal can leave historical text. This is intentional conservative preservation, not permission to replay a response.
- **Privacy:** The highest-risk regression is leaking secret draft data through a new capture, codec, diagnostic, or freshness path. Test serialized bytes, not only model properties.
- **R4 regression:** New lane work must not create a second owner, outlive retirement, bypass Stage A freeze, or extend its absolute deadline.

No owner answer is needed to proceed with these reversible assumptions. If a dependent action requires signing approval/manual credentials, changes externally visible behavior beyond the requested scope, or reaches a contested P0, main asks with choices and a recommendation. Continue unaffected work.

## 6. Implementation order

1. **Establish the workstream and source manifest.**
   Confirm the reported baseline and dirty-file boundaries when tools are available. Map the missing declarations above; inspect the latest post-review guards without reopening R4 architecture. Preserve inactive Platform checkpoint `b2ee22a8` and prior input checkpoint `c9138767`.

2. **Land typed terminal plumbing as one atomic compile unit.**
   Update cause definitions, request/revision constructors, terminal persistence, all callers, live stamping, and classification together.
   Validate success/failure/user-cancel/provider-loss distinctions; cancelled Stage A; completion racing teardown; stale provider callbacks.

3. **Extend the existing question lane.**
   Add immediate creation/queue writes, bounded non-secret draft writes, serialized resolution, and R4 drain integration.
   Validate creation/edit/remove races, queue promotion, failed writes, owner replacement, reset/delete, timeout, response-success/removal-failure, stable elicitation identity, and expired transports. Inspect persisted fixtures for secret-answer absence; retain R4 secret-veto tests.

4. **Add schema-8 hints and durable acknowledgements.**
   Validate old/missing/unknown fields, equality, all record-copy paths, concurrent unrelated writes, and closed-session acknowledgements.
   Confirm a stub rebuild performs no new eager transcript decode solely for hints; stale negative hints cannot suppress recovery-record discovery.

5. **Publish the catalog and switch both UI surfaces together.**
   Extract domain selection, merge ordinary confirmation schedules, adapt the banner, add Needs Attention and app entry point, replace Hide, and expose Show dismissed.
   Validate shared snapshot/rendered-row identity, closed workspace/session access, cross-window updates, run/schedule deduplication, and acknowledgement freshness.

6. **Run focused boundary validation.**
   Use coordinated `make dev-test FILTER=<SuiteName>` runs plus affected lint/build and repository pre-commit checks. Include:
   - interruption record survives incremental/full rebuild and save/reload;
   - recovery-only attempts and repeated restarts;
   - Dismiss leaves input, questions, crash holds, schedule confirmation, and admission unchanged;
   - unrelated record revisions do not unhide cards; genuinely new items do;
   - no provider is created by startup/catalog/Needs Attention;
   - no resumed continuation or automatic send follows restored questions.

   Record fixture/stub results as such. Do not run the visible app, real providers, live qualification, or a full-root campaign without a concrete risk requiring it.

7. **Main conducts review and signs the local checkpoint.**
   Main alone launches OracleA/OracleB, independently, against the same complete snapshot. Attach the supplied **Review policy verbatim** to each request. Save findings outside the plan; fix P0/P1 and apply the specified maximum two re-review rounds. Rerun affected validation after later edits; re-review when reviewed behavior changes.

   Stage only this workstream’s hunks, inspect the entire staged diff, run required checks, and use the configured signer. No unsigned bypass and no push.

8. **Close the code workstream honestly.**
   Mark implementation/review complete only after the required gates pass. Keep **O3 live acceptance pending** in the final status. Do not describe isolated tests as real-app crash, provider, or performance acceptance.

## Recommendations

- Use **one coupled worker**, with the ordered internal cuts above and one final product review checkpoint; shared lane/store/catalog ownership makes parallel editing riskier than helpful.
- Adopt the stated question timing as an explicit reversible assumption, not an owner Decision.
- Keep Dismiss entirely separate from resolution and safety admission; use semantic identity rather than record revision.
- Stop at complete Phase-2 behavior. Defer retention, polish, process registry, Resume, history import, and all live qualification.
