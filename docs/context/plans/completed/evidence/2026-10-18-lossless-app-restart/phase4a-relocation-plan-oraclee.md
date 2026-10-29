# O11 saved-input relocation — OracleE planning guidance

Scope: read when the task touches the owner-approved canonical saved-input move/reconstruction follow-up.
Authority: Reference
Last-verified: 2026-10-22

OracleE identity verified: `95F2BD07-4A94-417C-AAAF-17CAB847EC35`, explicit selection, continued planning chat `lossless-restart-forward-E4C686`. This is planning, not a new review round or activation. Main read the complete response and adopted preservation of historical containers plus a distinct new execution identity, rather than the worker's initial regroup/rekey proposal. The owner selected only O11's product semantics. See [bounded implementation evidence](phase4a-saved-relocation.md).

Markdown trailing whitespace is normalized to explicit line-break markup for local checkpointing; response wording is unchanged and the original tool export remains local.

## Complete response

# Oracle Plan

## Summary

**O11 resolves the product semantics; the remaining problem is preserving execution identity through the canonical rebuild and save paths.** I would not implement the worker’s regroup/rekey proposal. Its “activities never change parent” claim contradicts moving them into Q or X, and leaving recovery references unchanged after rekeying their historical turn does not preserve their meaning. The smaller coherent alternative is to **retain every historical turn and span identity, detach only the conclusively unsent user item, and place that same item in a distinct execution turn at the conversation end**. New attempts must record that execution turn’s actual ID rather than assume it equals the user-item ID. This stays within the canonical owner, normal dispatch, and existing recovery store, but it requires a bounded correction to canonical reconciliation and turn-ID propagation; it is not credibly a three-file change with submission and joins untouched. **`.suppressed` cannot prove the required commit.**

This is a plan against the supplied packet for `deb4ae5335cab845d61be64d63d992eb3e885bb0`; no implementation or validation has occurred here.

## Current-state analysis

### What the supplied code establishes

`AgentTranscriptTurn.id` and `AgentTranscriptRequestAnchor.id` are separate persisted fields. The turn initializer and decoder do not require equality. Response spans, interruption/recovered-outcome records, terminal state, summaries, and completion timestamps belong to the turn independently of its optional request. This makes a requestless historical envelope representable without renaming it. <br>
**Source:** `AgentTranscriptModels.swift`, `AgentTranscriptTurn`, `AgentTranscriptRequestAnchor`, and their initializers/serialization.

Conversely, the earlier supplied `importLegacyItems` derives a new turn’s ID from a user item’s ID. That is a construction rule, not a model invariant. The refreshed merge code also replaces full turns by matching turn ID, falling back to position. Therefore, simply installing a canonical turn with a different request ID does **not** establish that it will survive the next ordinary rebuild. <br>
**Sources:** prior packet, `AgentTranscriptServices.swift:3297–3409`; refreshed `AgentTranscriptServices.swift:2700–2859`, `transcriptByReplacingWorkingTurns`.

`preservingInterruptedTurnEnvelopes` copies interruption and recovered-outcome markers by turn ID. Its preservation of cancelled/failed state additionally checks request, span, and activity identities. Reusing an old turn ID for a new execution can therefore attach historical evidence to the new execution; changing grouping can also prevent preservation of historical terminal state. <br>
**Source:** refreshed `AgentTranscriptServices.swift:2700–2859`, `preservingInterruptedTurnEnvelopes`.

The owner save distinguishes a real write from reset acknowledgement and other non-writing outcomes. It can return a valid `.written` receipt with `projectionClean: false` when the captured snapshot was committed but later content remains dirty. Thus “projection is clean” and “the required snapshot was written” are different questions. <br>
**Source:** `AgentModeViewModel.swift:14820–15009`, supplied save excerpt.

### Why the worker’s proposal is not coherent as written

| Proposal claim | Assessment |
|---|---|
| “The new tail turn must be A.” | The current importer and reported join assignments impose that assumption. The persisted model does not. Correcting those local assumptions is preferable to renaming historical executions. |
| Removing full envelope A and letting its activities regroup into Q/X preserves ownership. | It changes each affected activity’s owning turn and potentially its span. Adjacency does not establish that Q owned that execution. |
| Rekeying compacted A while leaving recovery records unchanged is safe. | Existing references to turn A would then name the new execution, or cease to identify the retained historical envelope. Neither outcome is preservation. |
| Selecting a single open attempt resolves two claimants on A. | That is an ambiguity-resolution rule, not evidence that references now point to the correct execution. |
| Run-attempt-keyed cards are unaffected. | Stable card keys do not guarantee correct associated turn, payload, interruption, or navigation target. |
| Keeping the same sets of non-A IDs proves preservation. | Equal ID sets permit changed ownership, ordering, payload, lifecycle, and reference targets. The required postcondition is stronger. |
| A second rebuild is sufficient validation. | The normal save preparation, serialized reload, subsequent refresh, and terminal join must also preserve the structure. Validation only before compaction misses the eventual saved result. |

The worker’s claims about terminal-barrier selection, join assignments, cache keys, and hydration installation are useful **source-check leads**, but those implementations are not reproduced in this follow-up. In particular, “the barrier selected A” does not by itself prove that every activity under A belongs to P, still less that Q is its correct replacement owner.

## Answers to the six questions

| Question | Decision |
|---|---|
| **1. Conflicting interruption markers on Q** | **Do not merge the envelopes.** Keep both markers on their original turns. If a proposed operation requires merging conflicting evidence, refuse that operation; never choose the later marker merely by time or position. Under the recommended design, two historical markers are not themselves grounds to reject O11. |
| **2. Evidence without remaining content, belonging to another attempt** | **Keep its original turn, ID, and evidence—even if the turn has no request or stored activities.** Do not move it to the preceding turn. Also do not transfer evidence merely because its attempt belongs to A’s intent: it still describes an earlier execution, not the forthcoming execution. |
| **3. Commit the absent/erased case before handoff** | **Yes; this is required.** Reconstruct the same user-item ID from the saved payload, preserve available original chronology, install its canonical destination, and obtain an authoritative covering write before submission. The recovery intent protects the payload; the session write establishes its canonical placement and execution target. |
| **4. Count `.suppressed` as committed** | **No.** Suppression is not affirmative evidence that this snapshot committed. A separately retained, matching `.written` receipt could establish durability, but then that receipt is the proof. The smallest implementation requires a real covering write for each newly performed saved-input action. |
| **5. Keep the obsolete “isn’t supported yet” wording** | **Reword it and update expectations.** Suggested final-placement refusal: “This saved message isn’t ready to send at the end of the conversation. Nothing was sent. Review it and choose Send saved again.” Keep the refusal itself. A direct call that bypasses preparation is not necessarily a race. |
| **6. Move cancelled/failed state to Q, or let rebuild show completed** | **Neither.** Preserve cancelled/failed state, span lifecycle, timestamps, and interruption/outcome evidence on the original historical envelope. Start the new execution without inheriting them. Turning a historical failure into completed is not a harmless presentation choice. |

O11 already approves movement and reconstruction. No further owner decision is needed about that semantic choice. A further owner decision is needed only if implementation cannot preserve the required historical cases and a narrower scope is proposed.

## Design

### 1. Separate message identity from execution identity

Use these names throughout implementation:

- **A:** the existing deterministic user-item ID.
- **H:** a historical turn containing A or historical execution data. H may currently equal A.
- **E:** the destination execution turn for sending A now.

For a relocation requiring a new destination:

| State | Historical envelope H | Destination E |
|---|---|---|
| Turn identity | Unchanged | New UUID, distinct from all existing turn IDs |
| Request | Remove only the request whose item ID is A, if present | Request ID remains **A** |
| Historical activities | Keep their IDs, order, payload, turn ownership, and span ownership | None transferred |
| Historical spans and evidence | Keep IDs, provider/run IDs, lifecycle, terminal state, interruption, recovered outcome, timestamps | No inherited execution evidence |
| Recovery references | Existing references continue to identify H | The forthcoming attempt records E |

**Creating E does not create a new message.** A remains the one user item and the same recovery intent. E is a container for a new execution of previously unsent input.

Allocate E once during preparation. Retain it in the installed canonical transcript and reuse it when a later preparation finds that same clean, unexecuted destination. Do not derive a fresh destination from every repeated click: the existing action join already prevents duplicate performance, and the canonical request identifies an existing prepared destination after reload.

Retain empty historical envelopes rather than deleting them. An envelope can remain the target of recovery or navigation references even when its request and activities are absent. Keeping it is cheaper and safer than introducing an exhaustive external-reference rewrite. Its rendering must not synthesize a second user bubble.

### 2. Make canonical reconciliation preserve ownership

This is the essential change. The relocation operation must not hand a modified flat list to an importer that guesses new historical ownership.

Extend the **existing canonical reconciliation path in `AgentTranscriptIO`** with this rule:

> For items already represented in the canonical transcript, canonical turn and span ownership are authoritative. Reconciliation may update an item’s content in its existing container; it may not infer a different historical container from neighboring user rows. Derive structure only for genuinely new items or an explicitly requested structural mutation.

For O11:

1. Produce the structural edit directly in the canonical transcript.
2. Produce the corresponding working items through the existing projection/installation mechanisms.
3. Preserve explicit canonical turn IDs when rebuilding the working portion.
4. Preserve requestless historical full turns; do not feed their output back through user-boundary regrouping.
5. Resolve A’s destination through `request.id == A`, obtaining E. Do not use `turn.id == A` as the lookup.
6. Route subsequent new output and terminal evidence through the normal execution context carrying E.

Do not use a retention-tier change to force preservation. Do not convert full turns to condensed merely to bypass rebuilding. Do not run a new compaction pass as part of relocation. Retention optimization is deferred.

The ordinary legacy importer remains appropriate for legacy input lacking canonical ownership. It is not an acceptable structural authority for reinterpreting already owned historical output after this edit. This is an extension of the current owner’s reconciliation, not a second transcript or dispatcher.

#### Exact bounded source check before implementing this rule

Read the actual paths that:

- rebuild full working turns during refresh;
- prepare the transcript for owner save;
- hydrate and project a saved transcript;
- normalize the transcript and its frontier;
- apply incremental output to the active turn.

The worker reports the entry anchors as `AgentTranscriptServices.swift`’s rebuild/merge helpers and VM refresh, save-preparation, and hydration routines. Confirm the current implementations at HEAD.

**Required result:** those paths can preserve the canonical ownership graph and an explicit `turn.id != request.id` through the existing owner, while ordinary payload updates and intentional removals continue to work.

If they cannot, the unresolved boundary is precise: **ordinary refresh/save reconstructs historical ownership from a lossy flat sequence and cannot retain a requestless full historical envelope plus a distinct execution turn for A.** A relocation-only patch cannot fix that boundary.

### 3. Define the pure canonical operation

Keep the worker’s useful idea of one pure operation within `AgentTranscriptIO`, but change its responsibilities.

Its inputs should include the canonical transcript, working items, saved/reconstructed user item, proposed destination-turn identity, and existing sequence counters. It should not need a list of “A’s own run IDs” for evidence transfer, because it transfers no historical execution evidence.

Its result has three meanings:

- **Unchanged:** a valid unexecuted destination already exists; return its user-item and execution-turn identities.
- **Prepared:** return the edited canonical transcript, corresponding working items, next sequence value, destination identity, and affected projection identities.
- **Refused:** return a reason without mutating the session.

“Already last user row” is not sufficient for `unchanged`. The destination must also be the correct canonical tail request and must not carry a previous execution’s output or evidence that the next start would overwrite or inherit. A last bubble sitting over historical failure/output still needs a separate destination.

#### Placement handling

| Location of A | Canonical mutation |
|---|---|
| Request anchor in a full turn | Remove that request anchor; preserve the historical turn and all response spans. Put A in E. |
| Mid-turn user activity | Remove only activity A from its original span. Leave every other activity in its original span and turn. Put A in E. |
| Canonical-only request/activity in a non-full turn | Edit that canonical location directly. Do not reconstruct missing historical output or change its retention tier. Put A in E. |
| Compaction-erased input | Reconstruct A from the intent. Keep any historical turn whose **turn ID** happens to equal A; that equality does not establish a surviving user-item occurrence. Put A in E. |

A canonical representation and its working projection are two representations of one logical item. Do not reject their consistent coexistence as “more than one copy.” Reject conflicting payloads or multiple authoritative occurrences, not the ordinary canonical/suffix projection pair.

#### Derived presentation references

Removing a request requires removing its old request presentation. In particular, inspect the projection of `summary.requestText` so it cannot recreate the moved bubble in the historical turn.

If `conclusionActivityID == A`, do not categorically refuse the entire mid-turn case. Remove the reference to the relocated input and use the existing conclusion-selection/projection rules for the remaining canonical content. Preserve unrelated output-derived conclusions and summaries.

The exact dependence of summary/conclusion fields is not shown. Read those specific projection and summary-building functions before changing them. Do not edit opaque summary prose by text matching. If a compacted representation cannot distinguish the relocated input’s derived presentation from historical output, record that exact unsupported boundary rather than silently discarding the summary.

Keep existing span IDs, summary-item IDs, and frontier turn IDs. There is no A* namespace and no historical rekey.

#### Sequence and chronology

Copy the existing item when available, preserving timestamp, payload, provenance, and recovery presentation. For erased input, reconstruct from the saved intent and use its durable creation chronology when no original item timestamp survives; do not claim that this is a newly observed send time.

Assign the moved item a sequence after the current canonical/working execution order, advance the shared counter once, and leave all other sequence values unchanged. Preserve the saved intent’s original chronology and ordering data.

The upcoming attempt/footer obtains its new execution time through the existing start path. The user item’s original timestamp must not be overwritten with that time.

#### Strong postconditions

Validate these on the candidate, then demonstrate they survive the normal save/reload path:

- Exactly one logical user item A exists, at the current execution end.
- Its ID, saved payload, provenance, and chronology are preserved.
- Every other user item is unchanged.
- Every historical activity other than A retains its original **turn ID, span ID, relative order, and content**.
- Historical span identities, provider/run identities, lifecycle, terminal evidence, and reference targets are unchanged.
- Existing turn identities remain present; the new destination does not collide with them.
- E contains no inherited historical execution evidence.
- The next attempt will join E.
- Repeating preparation without intervening work is idempotent.

Equality of ID sets alone is not an adequate substitute.

### 4. Carry the actual execution-turn ID through normal submission

The worker’s “normal submission and joins unchanged” boundary must be dropped.

The existing prepared-turn/run context must distinguish:

- `userItemID = A`;
- `transcriptTurnID = E`.

Carry E through the existing user-anchor and handoff path. At every point currently using a user-item ID as a turn ID, resolve or use the captured actual canonical turn identity. In particular, inspect:

- `PreparedUserTurnAppend` and `recordAgentTurnUserAnchor`;
- `AgentProviderHandoff`’s run-attempt construction;
- `AgentRunTerminalCommitBarrier`’s turn selection and recorded join;
- cold-restore matching and subsequent recovery-card targeting.

The worker reports `AgentProviderHandoff.swift:273–276` and `AgentRunTerminalCommitBarrier.swift:247,337–352,476–500`; these are **reported inspection anchors**, not independently verified implementations in this packet.

Do not rewrite old recovery attempts. They continue to reference H. Only the new attempt references E. Do not rely on the “single open claimant” rule to repair aliasing between historical and new executions.

This is local execution identity, not Claude/native provenance work. Provider protocols remain unchanged.

#### Prevent bypass of the required preparation

Add one small, transient preparation result to the existing admitted saved-input path. It carries the action/intent/user/destination identities and the owner-write evidence needed for final validation. It is not a new reservation authority and is not persisted separately.

For an authorized saved-input resend, synchronous submission must require:

- a matching preparation result;
- the existing queue receipt and action authorization;
- the current canonical destination E containing A at the end;
- matching payload and session ownership.

If the item is absent at this point, refuse. Do not fall back to appending it inside synchronous submit: the absent case should already have been reconstructed and committed asynchronously.

Ordinary new composer input keeps its existing behavior. The existing `.reused` disposition remains valuable: after preparation, failure cleanup must treat A as reused and must not remove it. <br>
**Source:** `AgentRecoveryVMProducerAdmissionTests.swift:760–929`, including `testPreparedAppendReportsReusedBubblesAsNeverRemovable`.

### 5. Exact mutation, persistence, and dispatch ordering

Run session mutation and final validation on the main actor. Store access and owner saving retain their existing isolation.

1. **Read and validate the claimed intent.** Keep all current not-delivered, attachment, target, and authorization checks. Add the remote-host refusal before mutation. Revalidate the session/lane and idle state immediately after `lane.readRecord()` returns, not only after later awaits.

2. **Prepare and install synchronously.** With no suspension between snapshot validation and installation, obtain the pure candidate and install canonical transcript plus working items through the existing paired owner operation. Invalidate affected projection/raw-input reuse caches; clearing the turn projection cache once for this explicit action is acceptable. Do not invent a cache framework.

3. **Mark dirty, then capture the save requirement.** Capture source revision, persistence mutation generation, binding identity/generation, incarnation/reset generation, A, and E after installation and dirty marking.

4. **Obtain a real owner write.** Force the normal detailed owner save for a newly performed action, including an unchanged destination. This avoids making `isDirty == false` a durability inference. If an older save is in flight, join it and make at most one further explicit flush attempt. No unbounded retry loop.

5. **Require a covering `.written` receipt.** Apply the existing write-covers-capture rule under the same binding/ownership epoch. The receipt must cover both captured source revision and mutation generation. Revalidate the action, owner, target, idle/local state, and destination.

6. **Issue the existing queue receipt.** Its claimed intent/payload must still correspond to the prepared input. Use the existing revision/authorization checks; revalidate after this suspension.

7. **Submit synchronously through the normal path.** Validate preparation and destination once more, reuse A, and carry E into the new attempt before provider bytes. The existing authorization remains held through handoff settlement.

The receipt proves the write only if normal save preparation preserves the canonical candidate. That is why a test must inspect the saved/reloaded transcript, not merely inject `.written` into a mock.

#### Save-outcome policy

| Outcome | May authorize this send? |
|---|---|
| `.written` covering the capture, current owner and destination | Yes |
| Covering `.written` with `projectionClean == false` | Yes, if the required placement is committed and remains current; unrelated later dirty state need not invalidate that proof |
| `.written` for an older capture or obsolete owner | No |
| `.suppressed`, `.notWritten`, `.resetAcknowledged` | No |
| Deferred without an eventual covering write, or save failure | No |

Do not require a clean projection merely for additional rigor. Equally, do not let a reset acknowledgement stand in for a write of the relocated input.

On failure before handoff, retain A and its prepared placement in memory; do not restore a duplicate composer draft or withdraw the intent. A failed storage write cannot guarantee that the new position survives a subsequent crash, but the original durable input remains recoverable. Once the relocation write commits, a crash before dispatch restores A at the end without automatic sending.

O11 does not change delivery uncertainty: if bytes may have reached the provider, retain the existing delivery-unknown semantics rather than relabeling the input “unsent.”

## File-by-file impact

| Component | Required impact |
|---|---|
| `Sources/RepoPromptAgentCore/AgentMode/Runtime/Transcript/AgentTranscriptServices.swift` | Add the pure canonical relocation/reconstruction operation. Correct the relevant canonical rebuild/merge path to preserve historical ownership and explicit turn/request identities. Reuse existing projection and conclusion logic. Remove regrouping, rekeying, and relocation-triggered compaction from the proposal. |
| `Sources/RepoPromptAgentCore/AgentMode/Runtime/Session/AgentTabSession.swift` | Add the explicit silent-replacement reason if needed, and use the existing paired installation boundary. Ensure source revision, sequence counter, indexes, and cache invalidation reflect the installed candidate. A new enum case alone does not establish these guarantees. |
| `Sources/RepoPrompt/Features/AgentMode/ViewModels/AgentModeViewModel+RecoveryActions.swift` | Prepare/install, await and verify a real owner write, revalidate, then obtain the queue receipt and submit. Reconstruct absent input here. Return honest refusal text and preserve failed input placement. |
| `Sources/RepoPrompt/Features/AgentMode/ViewModels/AgentModeViewModel.swift` | Integrate the transient saved-input preparation result, propagate actual execution-turn identity, and prevent synchronous saved-resend append from bypassing preparation. Ensure normal save preparation preserves the edited canonical graph. |
| `AgentProviderHandoff.swift` | Record the actual destination turn ID for the new attempt. Confirm the defining context and exact path at the worker-reported anchor. |
| `AgentRunTerminalCommitBarrier.swift` | Finalize and record the actual execution turn, without substituting the user-item UUID or accidentally selecting the retained historical envelope. |
| `AgentSessionRestoreSupport.swift` and recovery catalog consumers | Inspect for turn/request-ID equality assumptions. Change only demonstrated assumptions affected by E; leave historical attempts and IDs intact. |
| `Sources/RepoPromptAgentCore/AgentMode/Models/AgentTranscriptModels.swift` | No schema addition is inherently required for distinct turn/request IDs. Use the existing optional request and independent ID fields. |
| Existing transcript, admission, and terminal/restore tests | Replace regroup/rekey expectations with graph-preservation and actual-join assertions. Add coverage of authoritative save failure and normal save/reload behavior. |

Also inspect the detailed flush/coverage helper and DataService’s finalized scheduled-send protection. The save excerpt passes `intentionallyRemovingFinalizedScheduledSendItems`; it is insufficient to say that A is unsent and therefore this protection cannot matter. The entire edited snapshot must preserve unrelated finalized items. Do not add a bypass flag for O11.

The exact definitions of the prepared run context and some join consumers are absent from the packet. Inventory those named paths before patching; do not claim a complete three-file boundary prematurely.

## Minimal test requirements

Reuse existing suites and injected effects. The following are behavioral requirements, not a request for a new harness.

### 1. Canonical ownership and representation matrix

Use `AgentTranscriptRawInputReuseLifecycleTests` or `AgentTranscriptRefreshDiagnosticsTests` for:

- A as a full request anchor followed by B/C, with historical output and interruption under its old envelope.
- A as a mid-turn activity.
- A as a canonical-only non-full request/activity.
- A erased by compaction, including a retained historical turn whose ID equals A.
- Evidence-only historical envelopes and the conclusion-reference case.

Assert the ownership graph, not just ID sets. Old output remains under its original turn and span; no Q/X reparenting or A* rekey occurs. Run the result through normal refresh, owner save preparation, serialization/reload, and a subsequent refresh. B/C and historical references must remain stable.

Test unchanged preparation and repeated preparation. A last user bubble carrying historical execution evidence must not qualify as a clean new destination.

### 2. Real save boundary under the existing VM harness

Extend `Tests/RepoPromptTests/AgentMode/Recovery/AgentRecoveryVMProducerAdmissionTests.swift` to exercise the actual saved-action preparation/performer path:

- Inspect the committed snapshot before the fake provider’s first byte/start boundary.
- Fail `.suppressed`, non-writing/reset-only outcomes, stale-owner receipts, and insufficiently covering receipts with zero dispatch.
- Cover an in-flight older save followed by a successful covering write.
- Cover write failure followed by an explicit retry.
- Reset, replace the binding, or change the destination while saving; verify zero dispatch.
- Verify reconstructed input is committed and then reused, so start failure never removes it.

Preserve the direct-submit newer-message refusal as a guard test. Its current test bypasses the recovery performer; it does not test O11 completion. Tests that previously allowed an absent saved item to append and send synchronously need updating to the new required preparation contract.

### 3. New and historical execution joins

In the existing terminal/restore tests, create historical H with attempt P and destination E with the same user-item ID A:

- New attempt and terminal evidence reference E.
- P and its interruption/outcome still reference H.
- Cold restore resolves both correctly.
- Failure keeps A visible at its prepared destination.
- A duplicate action click **joins the existing action**, rather than creating another execution or requiring a new refusal policy.

Run the affected transcript lifecycle suite, the existing inactive-refresh/retention regression, admission tests, and the affected terminal/restore suite, followed by the relevant compile build. Broaden validation only for a concrete changed path or an existing required gate. No live provider, helper, application kill, performance qualification, or full Phase 4 re-review is implied.

## Risks, migration, and the exact scope boundary

The principal risk is **a correct in-memory canonical edit being undone or reinterpreted by the next normal rebuild**. That is the implementation gate, not marker conflict policy.

Distinct turn and request IDs use existing serialized fields, so a schema bump is not inherently needed. However, decoding compatibility does not establish safe resaving by an older build that reconstructs turns from user IDs. Before any future activation, verify that rollback behavior or document the affected-session limitation; do not promise that resolving recovery cards alone makes an older normalizer safe.

The recommended approach remains bounded if the owner’s canonical reconciliation and execution-binding seams can preserve this structure without historical reference migration. If inspection instead requires a broad replacement of transcript processing, stop that dependent implementation.

The smallest owner-facing cut would then be:

> Complete only cases that need no historical ownership detachment, continue refusing the affected historical cases, and keep the full O11/older-message requirement explicitly blocked.

That would be a scope reduction requiring an owner choice—not a complete O11 implementation and not permission to ship a suffix-only result. My recommendation is to attempt the named canonical-boundary correction first; do not invest in rekey maps, cross-store reference migrations, or provider provenance to avoid acknowledging the boundary.

## Implementation order

1. **Confirm the canonical and join seams at HEAD.** Resolve only the named missing source checks: rebuild/save/hydrate preservation, actual turn-ID consumers, derived request/conclusion projection, and covering-write semantics.
2. **Implement canonical preservation and the pure O11 operation together.** Prove all required placements through normal refresh/save/reload before connecting dispatch.
3. **Land preparation, covering-write admission, and actual-turn-ID propagation atomically.** No send path may use E before its canonical state commits, and no new attempt may still record A as its turn by assumption.
4. **Run affected validation and the separate O11 delta review.** Keep production gates and O3 unchanged. Do not reopen the capped Phase 4 review loop.

## Maintainer-guidance check

| Check | Guidance |
|---|---|
| **User invariant** | Same saved input and chronology; one destination bubble; historical executions and references preserved; failure does not remove the input. |
| **Confidence** | High that regroup/rekey and suppression-as-commit are unsound. The model supports the recommended alternative; its bounded integration still needs the named source checks. |
| **Authority** | Existing `AgentTranscriptIO`, owner save/DataService, action authorization, and recovery store. No new authority. |
| **State safety** | Pure candidate, synchronous installation, real covering write, post-await fences, actual execution-turn join, existing settlement hold. |
| **Scale / observability** | One explicit-action traversal and save. Existing counters and structural assertions suffice; no polling, provenance service, or retention project. |
| **Recommended scope** | Complete O11 historical placements through a targeted canonical reconciliation correction. Preserve historical containers instead of migrating their identities. |
| **Validation boundary** | Injected source tests and compile validation only. No activation or live qualification claim. |

## Recommendations

- **Reject regrouping into Q/X and renaming old envelopes.** Preserve historical turn/span identities and evidence; move only the unsent input into a distinct execution turn.
- **Correct actual turn-ID propagation and canonical rebuilding as part of O11.** The data model permits separate identities, but the current importer and reported join assumptions must not silently undo that distinction.
- **Require a real covering owner write.** `.suppressed`, a clean dirty flag, and reset acknowledgement are not substitutes. Reconstructed input must commit before the normal dispatch path can use it.
- **Keep the boundary explicit.** If the normal canonical owner cannot preserve the required historical graph boundedly, report that exact blocker and request a scope cut; do not call a suffix-only or historical-reparenting implementation complete.
