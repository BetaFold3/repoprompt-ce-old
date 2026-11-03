# Step 8-attention / 9-activation plan consultation — OracleA

Scope: read when the task touches Needs Attention UX (O34), the one-button check-and-resolve idea, recovery-action activation (O32), or the verifier live scenarios.
Authority: Reference
Last-verified: 2026-10-26
Covers: OracleA (preset 61D024A4-CCFB-4C9C-A614-CC65E0A1864C, CLI·GPT-6 Astra High) plan-mode answer, chat untitled-chat-3013F6, recovered from the saved chat because the CLI export did not complete.



## 1. Summary

Use a **targeted extension of the existing catalog, action runner, and recovery guards**, not a recovery-system rewrite. Separate recovery obligations from historical information; remove “items elsewhere” as a reason to show the composer banner; add snapshot-bound bulk dismissal and a conservative **Check and resolve** operation. The checker may refresh ownership, reconcile history, and clear crash holds only with positive exit evidence—it must never send, resume, stop processes, discard input, or confirm schedules automatically. Follow O32 by enabling the supported action capabilities without a Claude/Codex allowlist, while making missing provider evidence a hard refusal. Qualify the activated path externally with Claude and Codex before changing production defaults.

**Evidence boundary:** This plan uses only the supplied excerpts. The coordinator’s mutation implementations, process-stop implementation, provider adapters, complete UI model declarations, and existing tests were not supplied. Their required contracts are specified below; implementation must verify those contracts rather than assume that the comments prove them. No tools, tests, or independent reviews were run.

## 2. Current-state analysis

### Catalog → presentation → action → durable state

1. `AgentRecoveryCatalogProjection.build` reads coordinator startup results, committed records, live lanes, held input, schedule summaries, and runtime restrictions. It constructs no provider or view model.
2. `AgentRecoveryCatalog` retains stable item IDs, acknowledgement freshness, action facts, and crash-hold blockers.
3. `recoveryListProps(forActiveSession:)` selects current-session/tab/workspace items, adds runtime restrictions, and computes an elsewhere count.
4. `recoveryNeedsAttentionRows` renders all undismissed catalog items. The sidebar counts all undismissed items, including historical outcomes.
5. `AgentRecoveryListRow` invokes `performRecoveryListAction`. The VM publishes shared `.working`/`.failed` state, invokes the existing operation, then refreshes presentation.
6. Dismiss calls `coordinator.dismissCatalogItem(item)`; crash confirmation calls `coordinator.confirmCrashHold(hold, lane:)`. Rows should change only after authoritative state changes.

Sources: `AgentRecoveryCatalog.swift:1–260,300–520,700–966`; `AgentModeViewModel+RecoveryList.swift:13–145,719–850,1309–1364`.

### What should be reused

- **One authoritative catalog**, not separate rediscovery for the sheet, banner, or checker.
- Existing semantic card keys and freshness tokens for acknowledgement.
- Existing run-action reservations, history reconciliation, normal dispatch, and durable settlement.
- Existing deep-link routing for opening closed/other-workspace sessions without starting a provider.
- Existing process discovery, ownership restrictions, and qualified Stop implementation.
- Shared per-row action state and notification-based UI updates.

The action runner already documents the important chain:

> Qualification + registration → durable reservation → reconciliation → completion suppression → dispatch fence → normal submission → settlement → durable outcome.

Sources: `AgentRecoveryActionRunner.swift:1–160`; `AgentModeViewModel+RecoveryList.swift:1330–1364`.

### What is blocking O34

- **Catalog kind is not attention severity.** A run’s classification can change after startup; its payload and current action evidence matter.
- **Dismissal is not resolution.** A dismissed crash hold remains a sending blocker; the banner already recreates a compact paused indicator.
- **Available buttons are not a severity signal.** Production qualification currently hides meaningful actions; another window may offer only Open.
- **All undismissed items count equally.** This produces noisy badges and banners.
- **Row-ID-only bulk execution would be unsafe.** The existing dismiss helper looks up the item at execution time. A bulk confirmation must retain the item the user actually selected, not silently act on a newer item with the same ID.
- **Single-row crash confirmation uses a user assertion.** It does not itself establish registry-proven process exit.
- The existing confirmation dialog is discard-specific; Stop needs a process-specific preview and confirmation.

Sources: `AgentRecoveryCatalog.swift:117–205,390–520`; `AgentModeViewModel+RecoveryList.swift:35–104,835–850,1309–1326`; `AgentRecoveryListBanner.swift:133–183`.

### Important inference: interrupted notes may still be obligations

The scheduled-send text explicitly says interrupted sessions can block automatic sending until recovery is resolved. Therefore, classifying every `.interruptedTurn` as informational would risk hiding the only explanation for a blocked workflow.

**Required validation:** Trace the predicates producing `AgentScheduledSendRecoveryBlocker.interruptedSessionIDs` and the admission restrictions. Presentation must use the same underlying unresolved-state facts, not create an independent “resolved” definition.

Source: `AgentComposerUIModels.swift:264–293`.

## 3. Design

### A. Attention classification and automatic clearing

#### A1. Add presentation facts, not persisted state

In `AgentRecoveryCatalog.swift`, add:

- `AgentRecoveryCatalogAttention`, a package enum:
  - `.needsAction`
  - `.information`
- `AgentRecoveryCatalogRunAttention`, a package enum:
  - `.unresolved`
  - `.savedInputOwnsDecision(itemID: String)`
  - `.continued`
  - `.terminalOutcome`
- An optional `runAttention` field on `AgentRecoveryCatalogActionFacts`; `nil` for non-run cards.
- Computed item properties for attention classification and automatic presentation clearing.

These are **derived, transient catalog facts**. Do not add a persistence schema, a second acknowledgement mechanism, or an attention-specific action ledger.

Rules for run facts:

- `.unresolved`: interrupted/unknown run still needs a decision, including an unfinished recovery action.
- `.savedInputOwnsDecision`: the run is verifiably never handed off **and** an exact saved-input catalog item represents the remaining obligation. Missing or ambiguous linkage falls back to `.unresolved`.
- `.continued`: durable evidence proves an explicit continuation associated with this source run reached provider acceptance. Submission acceptance, queueing, reservation, and an arbitrary later user message are insufficient.
- `.terminalOutcome`: an ordinary terminal result, or reconciliation-proven completion. This does not automatically mean the user has seen its result.

Build these facts from the existing record/action evidence. A final in-memory pass may link run cards to saved-input cards; use dictionaries, not repeated record or filesystem scans.

**Validation requirement:** Inspect `record.resolvingAction(for:)` before using `resolvedByAction` for automatic clearing. Its current Boolean deliberately conflates “sent” and “proved finished,” which require different presentation treatment. Source: `AgentRecoveryCatalog.swift:148–171,315–345`.

#### A2. Exhaustive payload policy

Classification is independent of provider qualification and whether the current window can perform the action.

| Kind / payload | Classification and behavior |
|---|---|
| `.statusUnknown` / `.workspaceFailure` | **Needs action.** Workspace check failed; preserve pause explanation. |
| `.statusUnknown` / `.nonactionable` | **Needs action.** Missing/unreadable/mismatched authority must remain visible. |
| `.statusUnknown` / `.duplicateDestination` | **Needs action.** Never choose a destination automatically. |
| `.statusUnknown` / `.noDestination` | **Needs action.** Preserved data has no usable destination, even if this does not currently block sending. |
| `.crashHold` / `.crashHold` | **Needs action while the authoritative hold blocks.** Dismissal never changes this. |
| `.heldScheduleTransfer` / `.scheduleTransfer` | **Needs action.** No automatic cancellation, transfer, or resend. |
| `.interruptedTurn` or `.terminalOutcome` / `.turn` | Use current run facts: unresolved → **Needs action**; saved-input-owned, continued, or terminal → **Information**. Never classify by item kind alone. |
| Same kinds / `.outcomeTurn` | Same rule; current evidence may have reclassified a startup outcome. |
| Same kinds / `.recoveryOnlyRun` | Same rule; do not infer completion from missing transcript rows or `terminal != nil` alone. |
| `.savedInput` / `.intent` | **Needs action** while projected: queued, failed, dispatching, or delivery-unknown. Old generation and remote uncertainty do not downgrade it. |
| `.unansweredQuestion` / `.question` | **Needs action.** Historical answer text is not an expired callback response. |
| `.pendingEditReview` / `.editProposal` | **Needs action.** View/Copy/Discard only; never Apply. |
| `.savedDraft` / `.heldDraft` | **Needs action.** Preserve Restore/Discard decision. |
| `.savedDraft` / `.closedSessionDraft` | **Needs action.** A closed session is not grounds for hiding a draft. |
| `.saveFailure` / `.composerRestoreFailed` | **Needs action.** |
| `.saveFailure` / `.unsavedPredecessor` | **Needs action.** Includes every retained predecessor, even though the current card exposes the first. |
| `.saveFailure` / `.composerWriteFailed` | **Needs action.** |
| `.saveFailure` / `.ownerlessDraft` | **Needs action.** |
| `.saveFailure` / `.composerPreparationFailed` | **Needs action.** Tab-keyed and potentially sessionless. |
| `.saveFailure` / `.questionSaveFailed` | **Needs action**, including an unsent answer even if the write error itself clears. |
| `.scheduleNeedsConfirmation` / `.scheduleNeedsConfirmation` | **Needs action.** Remains on scheduled-send surfaces and in the sheet. |
| `.statusUnknown` / `.scheduleIndexUnavailable` | **Needs action.** Do not interpret absence of indexed schedules as absence of schedules. |
| `.survivingProcess` / `.survivingRuntime` | **Needs action while restricted**, including tool-only survivors and “Let finish” choices. |
| `.survivingProcess` / `.runtimeOwnershipUnknown` | **Needs action.** Global uncertainty cannot be dismissed or aged away. |

This covers all current kinds and payloads. Make the payload classification switch exhaustive, so adding a payload requires an explicit decision.

Sources: `AgentRecoveryCatalog.swift:12–111,390–700,700–910`.

#### A3. Visibility, counts, and automatic clearing

Use three separate concepts:

1. **Semantic attention:** needs action versus information.
2. **Acknowledged:** existing durable Dismiss.
3. **Automatically cleared from ordinary presentation:** a derived result, not deletion.

Exact rules:

- Automatically clear only `.continued` historical run cards.
- Do not automatically clear newly recovered terminal outcomes. “Completed while closed” can contain the result the user came back to see.
- Do not clear on elapsed age, session opening, unrelated subsequent activity, reset generation, or a pending continuation reservation.
- Never auto-clear a card with an active or failed shared action state. Failed checks must remain discoverable until retried successfully or explicitly dismissed where dismissal is allowed.
- Do not remove records, input, attachments, children, or acknowledgements when hiding an informational card.
- Extend the sheet toggle to **“Show dismissed and cleared”**. Show the reason, such as “Continued” or “Dismissed.”
- Keep informational outcomes available in a collapsed **Information** section even when they do not contribute to the attention badge.

**Cut age-based expiry from this change.** There is no supplied durable “result seen” marker. A time limit would hide unread results or need a new persistence feature whose rigor is disproportionate to reducing noise.

For a dismissed but still-blocking crash hold, show a compact **Sending paused** row in Needs Action even with the toggle off, matching the existing banner behavior. Mark it “Card dismissed; sending still paused.” Do not show it twice when the toggle is on.

The sidebar badge counts visible **Needs Action** entries, including these mandatory blocker indicators. Information contributes zero. The View menu remains available at zero.

### B. Composer banner and Needs Attention organization

#### Banner

Modify `recoveryListProps(forActiveSession:)`:

- Preserve loading, composition-failure, and startup-failure notices. They explain why sending is unavailable.
- In ready state, include only:
  - Current-session Needs Action items.
  - The active tab’s sessionless preparation failure.
  - Applicable workspace restrictions.
  - Applicable runtime/global ownership restrictions.
  - The existing dismissed-crash-hold paused indicator.
- Preserve the existing schedule-domain exclusion; the scheduled-send banner already owns those items.
- Return `nil` when ready and this filtered row list is empty.
- Do not use `otherItemCount` to keep the banner alive.
- Remove the banner’s elsewhere-count button and corresponding obsolete props/callback fields after auditing their complete declarations and uses.

A globally uncertain runtime still applies to the current composer; it is not merely an “elsewhere” item.

Sources: `AgentModeViewModel+RecoveryList.swift:13–133`; `AgentRecoveryListBanner.swift:52–85`.

#### Sheet

Order sections:

1. **Needs Action**
2. **Information**, collapsed initially
3. Dismissed/automatically cleared entries, revealed by the toggle

Within each section, group by exact `workspaceID`; use a distinct **App-wide / Unassigned** group for nil workspace IDs. Preserve catalog order within each group and first-occurrence order between groups.

Do not assign global runtime warnings to whichever workspace happens to be open.

The sheet and sidebar must observe both catalog and coordinator changes on the main run loop. The sheet currently observes only catalog changes, while the sidebar also observes coordinator changes. The new operation progress and failure state must refresh both.

Source: `AgentRecoveryNeedsAttentionSheet.swift:15–80,119–158`.

### C. Bulk operations

#### C1. Shared execution model

Add a small app-scoped `@MainActor` `AgentRecoveryBatchController`, owned by `AgentRecoveryCoordinator`.

It owns transient state only:

- Current operation ID and kind.
- Immutable captured target items, in displayed order.
- Progress and per-item results.
- Cancellation request.
- Task handle.
- Last completed report, retained until replaced or dismissed.

Operation kinds:

- `.dismiss`
- `.confirmVerifiedStopped`
- `.checkAndResolve`

Per-item result variants:

- `.succeeded(message)`
- `.unchanged(message)`
- `.needsDecision(message)`
- `.skipped(reason)`
- `.failed(message)`
- `.cancelled`

The controller accepts injected main-actor performers; it must not depend on App-layer VM or SwiftUI types. One app-wide batch runs at a time; another window joins its progress rather than starting another batch.

Execution rules:

- Freeze target identities and displayed item snapshots before confirmation.
- Process sequentially. No unbounded task group or simultaneous writes to many sessions.
- Use existing per-row `.working`/`.failed` publication.
- A busy row is skipped, not joined to an unrelated action.
- Revalidate each target immediately before its operation.
- Do not require a matching **global catalog generation**: earlier successful items legitimately change it. Validate the individual item’s identity, binding, semantic key, freshness, and operation-specific evidence.
- If an item disappeared, report skipped/already resolved; never substitute another item.
- Continue after individual failures.
- Closing the sheet does not cancel the job. An explicit **Stop checking / Cancel remaining** stops before the next operation.
- Let an in-progress atomic write settle; cancellation does not pretend to roll it back.
- Window loss or inability to obtain the required owner becomes a per-item skip/failure.

Report totals by outcome, with expandable session/item details. Preserve failed targets for an explicit retry; that retry captures a fresh snapshot.

#### C2. Dismiss eligible items

Offer:

- **Dismiss eligible information…**
- **Dismiss eligible items…** within a workspace’s Needs Action section

The confirmation states the exact count and:

> Dismiss hides these cards. It does not discard messages, stop processes, resolve sending restrictions, or confirm schedules.

Eligibility:

- Existing acknowledgement exists.
- Not already acknowledged.
- Not working.
- Item remains identical in all acknowledgement-relevant facts.

Call `dismissCatalogItem` with the **captured item**, not `performRecoveryListAction(rowID: .dismiss)`, which would fetch a newer item.

Reuse and verify both projection-level and store-atomic revalidation. `recordStillMatches` explicitly covers only some record-backed conditions; do not mistake it for the entire dismiss contract.

Sources: `AgentModeViewModel+RecoveryList.swift:835–850`; `AgentRecoveryCatalog.swift:913–940`.

Non-dismissible restrictions, save failures, proposals, held transfers, and legacy schedules requiring Open remain untouched. Report how many were ineligible; do not offer a misleading “Dismiss all” label.

#### C3. Bulk crash confirmation

Label it **Confirm verified-stopped runs…**, not “They all stopped.”

Eligibility is much narrower than ordinary manual “It stopped”:

- An exact current crash hold exists.
- Registry enforcement and discovery are qualified and active.
- Every execution identity relevant to that hold is covered by the existing ownership/discovery contract.
- Fresh discovery positively establishes exit of all relevant writers, launchers, and blocking tools.
- No global, session, or relevant worktree uncertainty remains.
- The session binding, incarnation, reset generation, and hold freshness still match.
- The existing recovery/admission reservation prevents a competing managed start during confirmation.

**Absence of a runtime record is not proof of exit.** Legacy holds without sufficient identity coverage stay manual.

Add a coordinator operation conceptually shaped as:

`confirmCrashHoldIfVerifiedStopped(expectedItem:) async → verified / decisionRequired / failed`

It must acquire the existing appropriate recovery reservation, obtain/revalidate registry evidence, and call the existing durable crash-hold confirmation through its lane. It must not write directly to recovery records or use a Boolean supplied by the UI as proof.

A registry-owned, transient exit-evidence value may carry the hold identity, covered runtime identities/revisions, and binding. Construction must remain inside the validating core path. Do not persist it as a new authority.

**Race boundary:** Discovery is an OS observation, not a database transaction. Proven-dead birth identities cannot become live again; the existing admission reservation must exclude a newly managed competing start, and complete discovery must cover surviving descendants. Recheck bindings and restrictions after every awaited preparation step.

If these guarantees cannot be established cheaply from current APIs, **omit bulk confirmation**. Bulk dismissal and checking still deliver most of O34.

### D. “Check and resolve”

**Yes—but it is an evidence-gathering operation, not permission to continue work automatically.**

#### Scope and UI

Default scope: **this workspace’s current catalog items plus applicable global restrictions**.

Offer an explicit **All catalog workspaces** scope. It operates only on captured catalog items, never on every folder under Application Support.

Before starting, show:

- Item, session, and workspace counts.
- “No messages will be sent and no processes will be stopped.”
- Whether existing navigation may open/switch session tabs.
- Unsupported or inactive capabilities.

Do not enumerate transcripts to calculate these counts.

#### Algorithm

1. Capture the selected catalog targets.
2. Refresh runtime ownership once through the existing registry.
3. Reclassify against the resulting authoritative snapshot.
4. Group work by session; reuse each prepared session owner.
5. For each unresolved run eligible for history observation
