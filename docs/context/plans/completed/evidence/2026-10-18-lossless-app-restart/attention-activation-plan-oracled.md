# Step 8-attention / 9-activation plan consultation — OracleD

Scope: read when the task touches Needs Attention UX (O34), the one-button check-and-resolve idea, recovery-action activation (O32), or the verifier live scenarios.
Authority: Reference
Last-verified: 2026-10-26
Covers: OracleD (preset 7F177418-1980-4BF5-9768-B278FBC7C2BB, Claude Code Fable 5.1 High) plan-mode answer, chat untitled-chat-90FFDC, recovered from the saved chat because the CLI export did not complete.



# Recovery activation (O32), Needs Attention triage (O34), and "Check and resolve" — implementation plan

All statements below are grounded in the attached excerpts; anything about code outside them is marked **[inference]** and listed as a validation item. Review policy Stakes apply: data loss, duplicate sends, and externally visible actions (process signalling, provider sends) get full rigor; UI grouping and wording get "correct in normal use".

## 1. Summary

Four changes, in dependency order: (1) the catalog gains a per-item **attention class** (`needsAction` / `informational`) and a projection-time **auto-clear** rule, computed in `AgentRecoveryCatalogProjection`, so banner, badge, sheet, and bulk actions share one source of truth; the composer banner becomes an exact *needs-action* session filter and disappears otherwise. (2) The Needs Attention sheet renders two sections with per-section/per-workspace **bulk Dismiss** and a lane-only **bulk "It stopped"**, each item still going through the existing revision-checked per-item path (`dismissCatalogItem`, `confirmCrashHold`). (3) `AgentRecoveryActionQualification.production` turns on same-conversation resume and history reconciliation (fresh-Claude-conversation and safe restart stay off — not in O32), Phase 3 registration is activated, and an exhaustive `liveQualification(of: AgentRuntimeFamily)` switch records O32 in code; unqualified providers run through the *same* fences and refuse only when ownership/identity cannot be proven, not when completion is merely unconfirmed. (4) **Check and resolve** is a VM-level orchestration that reuses Refresh, Reconcile, and crash-hold confirmation, auto-resolves only what the registry or verified history proves, never dispatches, and ends with a typed report. This is a targeted change, not a refactor: every mutation keeps going through the existing coordinator/runner fences; the new code is classification, grouping, and sequencing.

## 2. Current-state analysis

### Catalog → surfaces
- `AgentRecoveryCatalogProjection.build` (`AgentRecoveryCatalog.swift:234-254`) produces an immutable `AgentRecoveryCatalog` with `items` in stable display order and `blockers` per session. Twelve `kind`s (`:11-25`) and 24 `payload` cases (`:58-116`). Each item carries `acknowledgement` (nil = no durable Dismiss, `:143-145`), `isDismissed` (`:148`), and `actionFacts` (`resolvedByAction`, `runNeverHandedOff`, `runTranscriptResetGeneration`, `delegatedChildLinks`, `:154-180`).
- Two filters exist: `needsAttentionItems(includeDismissed:)` (`:205-207`) and `bannerItems(sessionID:workspaceID:tabID:)` (`:212-219`), the latter excluding dismissed items.
- **Banner**: `recoveryListProps(forActiveSession:)` (`AgentModeViewModel+RecoveryList.swift:13-69`) builds rows from the dismissed-crash-hold "paused indicator" (`:36-43`), runtime items (`:50`), and `bannerItems` minus schedule-domain items (`:51-52`); computes `otherItemCount` over *all* undismissed items not shown (`:55-58`); returns `nil` only when `props.isEmpty` (`:68`). **[inference]** `AgentRecoveryListProps.isEmpty`/`headerText` live after `AgentComposerUIModels.swift:430` and treat `otherItemCount > 0` as non-empty, which is why every session shows "Nothing interrupted in this session. N items elsewhere…". The header button "Needs Attention (N)…" is at `AgentRecoveryListBanner.swift:66-70`.
- **Sheet**: `AgentRecoveryNeedsAttentionSheet` (`AgentRecoveryNeedsAttentionSheet.swift:10-85`) renders `recoveryNeedsAttentionRows(includeDismissed:activeSession:)` (`+RecoveryList.swift:73-84`) flat, in snapshot order, with only "Dismissed · Another workspace" labels (`:88-94`). Refreshes on `.agentRecoveryCatalogDidChange` (`:78`).
- **Badge**: `recoveryNeedsAttentionCount` = all undismissed items (`+RecoveryList.swift:87-90`); the sidebar button hides at 0 (`Sheet.swift:120-124`).
- **Per-item actions** all funnel through `performRecoveryListAction(rowID:action:)` (`+RecoveryList.swift:722-765`): shared `catalogActionStates[rowID]` (`.working`/`.failed`) is the only progress/failure channel; Dismiss → `coordinator.dismissCatalogItem(item)` with the *displayed* item (`:857-861`), store-side revalidated by `recordStillMatches` (`AgentRecoveryCatalog.swift:905-927`); "It stopped" → requires a live, non-retired lane and *opens the session* if none (`:1310-1324`), then `coordinator.confirmCrashHold(hold, lane:)`; Let finish → revision-checked (`:790-798`); Refresh → `refreshRuntimeOwnership()` (`:784-787`); Continue/Send saved/Answer/Reconcile → `performRecoveryResumeAction` (`:752-753`).
- **Gates**: `AgentRecoveryActionQualification.production` is all-false (`AgentRecoveryActionRunner.swift:48`); `allows(kind)` couples Continue/Send saved/Answer under `sameConversationResume` (`:50-55`); the runner's `isAvailable` additionally requires `registrationActive()` (`:151-153`), i.e. Phase 3 registration, which is a **separate switch not in this struct** (oracle plan §2; spec "Deliberately gated"). Row text already says "Stop is not offered (recovered Stop is disabled in production)" (`+RecoveryList.swift:800-801`), and `AgentRecoveryListRowProps.Action` has no stop case (`AgentRecoveryListBanner.swift:244-287`).
- **Reconcile semantics** are typed (`Runner.swift:59-85`): `confirmed(runAttemptID)` only with verified terminal evidence (never Claude), `associationUnavailable`/`blocked` block every continuation. "Sent" semantics (provider acceptance only) are owned by the intent delivery state (`needsDecision`, `AgentRecoveryCatalog.swift:930-937`) and are untouched by this plan.

### Reusable vs blocking
- Reuse: `Builder.append` as the single item constructor (`:285-322`) — classification belongs there. `dismissCatalogItem`, `confirmCrashHold`, `letRuntimeFinish`, `refreshRuntimeOwnership`, `performRecoveryResumeAction`, `catalogActionStates`.
- Blocking: nothing structural. Unknowns to validate before Step 4: where `registrationActive` is composed; whether a coordinator-level Stop API exists (Phase 3 source is "committed and reviewed but inactive"); whether `AgentRecoveryRecord` exposes an *open* (unfinished) action for a card key.

## 3. Design

### A. O34 — attention class, banner rule, sheet sections, bulk actions

#### A1. Classification (one exhaustive function, catalog-owned)

New in `AgentRecoveryCatalog.swift`:

```swift
package enum AgentRecoveryCatalogAttention: Equatable { case needsAction, informational }

package enum AgentRecoveryCatalogAutoClear: Equatable {
    case resolvedByAction            // facts.resolvedByAction
    case conversationCleared         // attempt generation < current generation
    case sessionContinued            // a later run attempt exists in the same generation
    case aged(since: Date)           // durable timestamp older than retention
}

// AgentRecoveryCatalogItem gains:
package let attention: AgentRecoveryCatalogAttention
package let autoClear: AgentRecoveryCatalogAutoClear?
package var isHidden: Bool { isDismissed || autoClear != nil }
```

`AgentRecoveryCatalogProjection.attention(for payload:) -> AgentRecoveryCatalogAttention` is a `static`, pure, exhaustive switch (a new payload case must be classified to compile). Rule of thumb that produced the table: **needs action = something is paused, or text/a decision is lost or stays unsent if the user does nothing; informational = nothing is paused and nothing is lost.**

| Payload (`AgentRecoveryCatalog.swift`) | Kind | Class | Why |
|---|---|---|---|
| `workspaceFailure` (:59) | statusUnknown | needsAction | pauses sending+scheduling in the workspace (`+RecoveryList.swift:204`) |
| `nonactionable`, `duplicateDestination`, `noDestination` (:60-62) | statusUnknown | needsAction | "sending to it stays paused" (:206-210) |
| `crashHold` (:63) | crashHold | needsAction | blocker (`blockers[sessionID] == .crashHold`) |
| `scheduleTransfer` (:64) | heldScheduleTransfer | needsAction | a schedule is held, never sent until resolved |
| `turn`, `outcomeTurn`, `recoveryOnlyRun` (:65-68) | interruptedTurn / terminalOutcome | **informational** | transcript is saved; nothing paused (the crash hold is its own item); Continue/Reconcile are optional |
| `intent` (:69) | savedInput | needsAction | unsent/uncertain input |
| `question` (:72) | unansweredQuestion | needsAction | owner list |
| `editProposal` (:76) | pendingEditReview | needsAction | not dismissible (acknowledgement nil, :573-581); only resolved by Copy/Discard — if informational it would sit forever |
| `heldDraft` (:78) | savedDraft | needsAction | held composer blocks writes until resolved (:652) |
| `closedSessionDraft` (:81) | savedDraft | **informational** | durable text that restores itself when the session opens; dismissible |
| `composerRestoreFailed`, `unsavedPredecessor`, `composerWriteFailed`, `ownerlessDraft`, `composerPreparationFailed`, `questionSaveFailed` (:82-96) | saveFailure | needsAction | text at risk |
| `scheduleNeedsConfirmation` (:97) | scheduleNeedsConfirmation | needsAction | owner list |
| `scheduleIndexUnavailable` (:100) | statusUnknown | **informational** | doesn't pause sends; clears itself when the index read succeeds |
| `survivingRuntime` (:104) | survivingProcess | needsAction | pauses sends to that conversation/worktree |
| `runtimeOwnershipUnknown` (:107) | survivingProcess | needsAction | pauses ownership-dependent work everywhere |

Note: the turn-with-`runNeverHandedOff` case stays informational because the *intent* item (needsAction) carries the Send saved route (A P1-06); the turn is a note.

#### A2. Auto-clear (projection-time, no writes)

Computed in `Builder.append` for informational `turn`/`outcomeTurn`/`recoveryOnlyRun` only; `closedSessionDraft` and `scheduleIndexUnavailable` never auto-clear (durable data / self-clearing). Inputs: the item's run attempt (from `record.runAttempts`), `record`, current generation (already computed in `addResolution`, :458-460), and `now: Date` — **`build(...)` gains a `now:` parameter** (coordinator passes `Date()`; tests inject). Evaluated in order; first match wins:

1. `facts.resolvedByAction` → `.resolvedByAction`.
2. **Never clear** if the card has an open (unfinished) prior action — "Resume was interrupted; status unknown" (spec R5) must stay visible. Needs a new fact `openActionID: UUID?` in `AgentRecoveryCatalogActionFacts`. **Unknown**: whether `AgentRecoveryRecord` exposes open actions (the runner returns `.priorAction(actionID:join:)`, so the record stores them; find the accessor next to `resolvingAction(for:)`). If no accessor exists, add one; do not ship auto-clear without this guard.
3. Attempt's `transcriptResetGeneration` < current generation → `.conversationCleared`.
4. Any attempt *after* this one in `record.runAttempts` (array order = commit order **[inference]**, validate) with the same generation → `.sessionContinued`.
5. `now - timestamp > informationalRetention` (constant, 7 days) → `.aged(since:)`, where timestamp = `attempt.terminal.recordedAt` for runs/outcomes and `interruption.observedAt` for turns; no timestamp → never ages.
Legacy turns without `runAttemptID` get rules 5 only.

Items with `autoClear != nil` are still in `items` (catalog stays complete; Show-dismissed reveals them labelled "Cleared: session continued" etc.); every count/filter uses `isHidden`. Re-evaluation happens on every rebuild (launch, any change); an item aging out mid-session appears at the next rebuild — acceptable, documented.

Why projection-time rather than writing acknowledgements: no per-launch write storm over ~69 items, deterministic, reversible (toggle), and no new persistence schema. What it must not hide: needs-action items (never auto-cleared by construction), items with open actions (rule 2), and crash-hold blockers (separate items).

#### A3. Catalog API changes
- `needsAttentionItems(includeDismissed:)` → `needsAttentionItems(includeHidden: Bool)`; add `needsAttentionSections(includeHidden:) -> (needsAction: [Item], informational: [Item])` preserving snapshot order within each.
- `bannerItems(...)` additionally requires `item.attention == .needsAction` and uses `isHidden`.
- `var needsActionCount: Int { items.count { !$0.isHidden && $0.attention == .needsAction } }`.

#### A4. Banner (O34-1)
`recoveryListProps(forActiveSession:)`:
- Keep `.loading` and `.failed` banners (sending is paused; `.failed` carries Retry).
- When `status == .ready`: rows = paused indicator (unchanged) + runtime items (already needsAction) + `bannerItems` minus schedule-domain. **Return `nil` when rows is empty**, regardless of `otherItemCount`.
- `otherItemCount` becomes needs-action-only (`!isHidden && attention == .needsAction && !shown`); keep the header button `Needs Attention (N)…` (`Banner.swift:66-70`) — it only appears while the banner is visible for the session's own rows, so it doesn't violate O34-1. Remove the "Nothing interrupted in this session…" branch from `headerText` and the `otherItemCount`-only non-empty case from `isEmpty` **[inference on location]**.
- Keep `AgentRecoveryListBanner.reservedHeight` unchanged.

#### A5. Sheet sections, labels, counts
- `AgentRecoveryNeedsAttentionRow` gains `attention` and `autoClear`; `label(for:)` adds "Cleared: session continued / conversation cleared / resolved / older than 7 days".
- `recoveryNeedsAttentionRows` → returns `AgentRecoveryNeedsAttentionSections { needsAction: [Row], informational: [Row] }`, each sorted: current workspace first, then by workspace name, stable within.
- Sheet: two headers "Needs action (n)" / "Informational (m)" with accessibility IDs `agent.recoveryNeedsAttention.section.needsAction|informational`; a workspace sub-header when a section spans >1 workspace. Toggle renamed "Show dismissed and cleared". Empty-section text per section.
- `recoveryNeedsAttentionCount` → `catalog.needsActionCount`; sidebar button and View-menu label count needs-action only (informational items are reachable via View menu → sheet; the menu command is always available per `Sheet.swift:109`).

#### A6. Bulk actions

New VM API (`AgentModeViewModel+RecoveryBulk.swift`):

```swift
enum AgentRecoveryBulkAction: Equatable { case dismiss, confirmStopped }
struct AgentRecoveryBulkOutcome: Equatable {
    var succeeded: Int
    var failed: [(rowID: String, reason: String)]   // also set inline via catalogActionStates
    var skipped: [(rowID: String, reason: String)]  // guard refused before any write
    var cancelled: Bool
}
func performRecoveryBulkAction(_ action: AgentRecoveryBulkAction, rowIDs: [String]) async -> AgentRecoveryBulkOutcome
```

Shared mechanics:
- `rowIDs` are captured by the sheet from the *displayed* section at click time (catalog generation G0). Items are processed **sequentially**; before each, the item is re-fetched from `coordinator.catalog.item(id:)`; missing → skipped "changed". Each item then goes through the **existing single-item function** (refactor the inner `switch` of `performRecoveryListAction` into `performRecoveryListActionFailure(rowID:action:) -> String?` and call it from both). Per-item `.working`/`.failed` state and `refreshRecoveryListUI()` behave exactly as single clicks.
- One bulk at a time app-wide: coordinator flag `bulkActionInProgress: Bool` (published via `.agentRecoveryCoordinatorDidChange`); bulk and Check buttons disabled while set. A sheet "Stop" button sets a cancellation token checked between items; committed items stay committed.
- Reporting: summary line under the section header (`agent.recoveryNeedsAttention.bulkSummary`): "Dismissed 12 of 14 · 1 failed (see row) · 1 skipped: can't be dismissed". Failures remain inline on their rows (existing channel), so nothing is lost when the summary is replaced.

**Dismiss all** (per section, per workspace sub-group):
- Eligibility per item: `acknowledgement != nil && !isDismissed && !isHidden`; otherwise skipped with "No Dismiss for this item" (save failures, runtimes, proposals, legacy schedules). Each eligible item → `dismissCatalogItem(item)` with the re-fetched item, so freshness revalidation (`recordStillMatches`) holds for every one.
- Informational section: no confirmation. Needs-action section/workspace: `confirmationDialog` stating the count and: "Dismiss only hides these cards. Saved messages, questions, drafts and schedules stay saved and are never sent. Sending stays paused for crash holds until you confirm they stopped." This preserves R8 (Dismiss acknowledges only) and keeps crash-hold/restriction gates untouched (a dismissed hold still blocks; the paused indicator still renders).

**It stopped (bulk)** — "only when safe", resolved as:
- Scope: crash-hold items (`kind == .crashHold`, not dismissed-indicator rows) whose session has a **live, non-retired lane** (`coordinator.lane(for:)`). No session is opened by a bulk operation (the single-item path's auto-open, `:1316-1318`, is a navigation side effect unacceptable ×N). Others skipped: "Open the session to confirm".
- Safety guard when the registry is active: if any runtime bound to the session's `hold.uncertainRunAttemptIDs` is `live`/`reserved`/`unknown` (`coordinator.runtimeSendRestriction(sessionID:)` non-nil, `+RecoveryList.swift:119`), skip with "A process may still be running; see its item". No registry evidence (pre-activation runs) ≠ unsafe: the action remains the user's explicit assertion, as it is today.
- Freshness: re-fetch `coordinator.crashHold(for:)`, compare `crashHoldFreshness` with the displayed item's `acknowledgement.freshness`; mismatch → skipped "changed".
- Confirmation dialog always, listing session names: "Confirm that the previous run of these N sessions has stopped. This unpauses sending; nothing is sent." Then `confirmCrashHold(hold, lane:)` per item.

What bulk must not do: send, resend, Stop processes, discard drafts/proposals, cancel/confirm schedules, remove saved input or questions, navigate. None of those get a bulk form.

### B. "Check and resolve"

**Placement**: `AgentModeViewModel+RecoveryCheck.swift`, `func performRecoveryCheck() async -> AgentRecoveryCheckReport`, launched from the sheet header (`agent.recoveryNeedsAttention.checkAndResolve`) and the View menu. It is an orchestration over existing per-item actions; no new write path. Coordinator gets `isRecoveryCheckRunning` (app-wide, one at a time, shares the bulk flag's exclusivity).

```swift
struct AgentRecoveryCheckReport: Equatable {
    struct Entry: Equatable { let rowID: String; let sessionName: String; let text: String }
    var resolved: [Entry]      // proven and acted on automatically
    var needsYou: [Entry]      // real decisions, with the specific choice named
    var unverifiable: [Entry]  // why it could not be checked
    var failed: [Entry]
    var cancelled: Bool
    var startedGeneration: UInt64, endedGeneration: UInt64
}
```

**Algorithm** (sequential; each step uses the per-row `.working` state so all windows see progress):
1. Mark running; capture `G0 = catalog.generation`.
2. **Refresh** (read-only): `refreshRuntimeOwnership()` if `hasProcessRegistry`; indexed-schedule refresh — needs an awaitable form of `requestIndexedScheduleRefresh()` **(unknown; add `refreshIndexedSchedules() async` if only fire-and-forget exists)**.
3. Re-read the catalog. Build the work list from **non-hidden items only**, grouped by session, **restricted to sessions that have catalog items** (never a cross-workspace scan; see risk on 50k fixture workspaces). Skip remote-host sessions for process checks (`resolution.remoteHostID != nil`, `AgentRecoveryCatalog.swift:466`) with "remote session: processes aren't tracked".
4. Per session, in order:
   a. **Crash hold**: auto-confirm only when (i) registry active, (ii) every runtime bound to `uncertainRunAttemptIDs` is proven `exited` (identity mismatch / changed boot session — R6), (iii) a live lane exists. Needs a coordinator query `runtimeEvidence(for runAttemptIDs: Set<UUID>) -> .allExited | .someUnresolved([runtimeID]) | .noRecords` **(new, read-only over registry state the coordinator already holds for `runtimeRestrictions`)**. `.noRecords` → needsYou "No process record for this run (started before tracking); confirm It stopped yourself". `.someUnresolved` → needsYou "Process still running / unknown: Let finish or Stop". No lane → needsYou "Open the session, then re-run Check".
   b. **Interrupted/terminal turn items** (informational, visible): if `runner.isAvailable(.reconcileOnly)` and the session's provider has a reconcile performer → run the existing `.reconcileHistory` action. Map: `imported(.confirmed)` → resolved "finished while RepoPrompt was closed; result imported" (the record's resolving action makes the item auto-clear by rule A2-1); `imported(.unconfirmed)`/`nothingImported` → needsYou "last answer recovered; completion unconfirmed — Continue or leave it"; `associationUnavailable`/`blocked` → unverifiable with the typed message. Providers without a reader (ACP, Oh My Pi) → unverifiable "no provider history reader".
   c. **Intents**: after (b), re-read; an intent that disappeared/became `providerAccepted` → resolved "delivered (found in provider history)"; `runNeverHandedOff` → needsYou "never delivered: Send saved or Remove"; else needsYou "delivery unknown: View / Edit / Remove".
   d. **Surviving runtimes**: items gone after Refresh → resolved "process exited"; remaining → needsYou "still running: Let finish or Stop".
   e. Questions, schedules, drafts, proposals, save failures → needsYou (named action). `statusUnknown` payloads → unverifiable.
5. Per-item budget 60 s via structured cancellation (the runner lists cancellation as `blocked`, `Runner.swift:80-85`); global Stop button; `cancelled = true` keeps partial results.
6. Present the report in the sheet (`agent.recoveryNeedsAttention.checkReport`), persisted only in memory.

**Never automatic**: Continue/Send saved/Answer (dispatch), Stop (O1), Discard/Remove, schedule confirm/cancel, Dismiss of needs-action items, opening sessions. The only automatic *writes* are reconcile imports (history-only, dedup'd, tool-free per R7) and crash-hold confirmation under registry-proven exit. "Sent" still arises only from provider acceptance evidence inside reconcile; the report never claims delivery otherwise.

**Dependence on activation**: with Phase 3 registration inactive, step 4a always yields `.noRecords`, and reconcile is refused by `registrationActive()` (`registrationInactiveText`). So **before activation Check is exactly "Refresh + a structured report"** — honest and still useful (it names what needs you). Don't bypass the runner's registration contract to make Reconcile work earlier (oracle §3E).

### C. Activation for all providers (O32)

**Flags** (`AgentRecoveryActionRunner.swift:48`): `production = AgentRecoveryActionQualification(sameConversationResume: true, historyReconciliation: true, freshClaudeConversation: false, safeRestart: false)`, doc comment citing O32 (2026-10-26). Fresh-Claude-conversation and safe restart are not in O32's list; they stay off (oracle §3B-6/7).

**Record the decision in code** so a new provider is forced to decide:

```swift
package enum AgentRecoveryLiveQualification: Equatable {
    case qualified(on: String, evidence: String)   // "2026-10-xx", evidence file name
    case pendingLiveQualification(scenarios: String)
    case unqualified(note: String)
}
extension AgentRecoveryActionQualification {
    /// O32 (2026-10-26): recovery actions are ON for every provider; only Claude Code and Codex are
    /// live-qualified. Exhaustive on purpose: adding an AgentRuntimeFamily case fails to compile
    /// until it is classified here. Unqualified families run the same fences and refuse when
    /// ownership or identity cannot be proven (never "proceed on unknown").
    package static func liveQualification(of family: AgentRuntimeFamily) -> AgentRecoveryLiveQualification
}
```
Initially `.pendingLiveQualification` for the two owner families, `.unqualified` for `claudeCompatible`, `claudeHeadless`, `acp`, and whichever Codex family the owner does *not* use. Runtime use: one log line per performed action naming the family and status (helps the verifier), plus a unit test asserting Claude/Codex are not `.unqualified`. No gating by it (owner override of the oracle's pair-aware proposal — note this in the spec).

**Unknown — Codex family**: `AgentRuntimeFamily` has `codexAppServer` and `codexExec` (`+RecoveryList.swift:844-851`); confirm via a registry dump which one the owner's Codex sessions register as before marking it qualified.

**Phase 3 registration**: find the switch behind the runner's `registrationActive` closure and the registry's activation (oracle names `AgentProcessRegistrySupport.supportedPairs` and an `AgentApplicationLaunchAuthority` that selects the production policy independently — **both unverified**). Requirement: one immutable composition (`production` flags + registration on) consumed by launch authority, VM runner construction, and row presentation, landed atomically with the flag change so a button never appears without its enforcement.

**Stop action**: add `.stopProcess(runtimeID:)`-style case to `AgentRecoveryListRowProps.Action`, map in `performRecoveryListAction`, require a confirmation that lists the processes about to be signalled (spec R6: revalidate identity, SIGTERM → 3 s → SIGKILL → rediscover), and update `recoveryListRuntimeText` (`:800-801`). **Unknown**: whether a coordinator/registry Stop entry point exists; if not, this is Phase 3 work and is the first thing to cut (ship Let finish + Refresh; Stop deferred, two-writer rule still blocks competing sends).

**Unqualified provider behaviour when a precondition can't be proven**:

| Precondition | Status | Behaviour |
|---|---|---|
| Ownership (runtime bound to the conversation live/reserved/unknown) | unprovable | **refuse** (`refused`, two-writer rule); no override |
| Identity/association for history merge | unprovable | **refuse** (`associationUnavailable` blocks continuation) |
| Completion of the interrupted turn | unconfirmed | **proceed** with Continue — this is the normal Claude case (`unconfirmed`), with the continuation text telling the agent to check state; Check reports "completion unconfirmed" |
| Provider has no history reader (ACP/Oh My Pi) | n/a | Reconcile not offered (hide the row action when the window has no performer for the family); Continue allowed only if the provider's existing same-conversation resume path exists, else `.notDispatched` typed reason |
| Run started before activation (no runtime record) | no evidence | the crash hold blocks until the user's "It stopped"; afterwards Continue proceeds — user asserted |

Principle: *unknown ≠ safe for ownership and identity; unknown = normal for completion.*

### D. Live scenarios for the external verifier (Claude Code = C, Codex = X)

Evidence sources: on-disk recovery records / runtime registry / transcript via `rpce-cli-debug` dumps (the verifier should use whatever dump subcommands exist; the plan names the fields, not commands), `ps -eo pid,ppid,pgid,comm` + `ps eww <pid>` for the `RPCE_RUNTIME_ID` marker, and accessibility IDs listed above. "Send count" = number of run attempts in the session's record plus the provider's own history length; **every scenario's hard fail = any send/run attempt the steps didn't ask for**.

| # | Scenario | Kill/relaunch | Setup & steps | Expected evidence / pass |
|---|---|---|---|---|
| 1 | Banner visibility | no | Session A clean; session B (other tab) has a saved-input item. Open A. | A: no `agent.recoveryList.banner`; sidebar badge = count of needs-action items; B: banner with its row only. |
| 2 | Classification + auto-clear | **SIGKILL app** mid-turn (C) | Relaunch; sheet shows crash hold in Needs action, interrupted turn in Informational. Click It stopped; send a new message normally; reopen sheet. | Turn item gone from Informational; "Show dismissed and cleared" reveals it labelled "Cleared: session continued"; record has no new acknowledgement write. |
| 3 | Bulk Dismiss informational | reuse #2 state ×3 sessions | Dismiss all (informational). | Summary "Dismissed 3 of 3"; each record has an acknowledgement with the item's exact freshness token; saved inputs/questions unchanged; needs-action count unchanged. |
| 4 | Bulk It stopped | **SIGKILL** with 3 sessions mid-turn (C,C,X), one tab closed before relaunch | Relaunch; sheet → It stopped (bulk). | Two open-lane holds confirmed (records show hold acknowledged, sending unpaused); closed one skipped "Open the session to confirm"; no tab switch occurred; no sends. |
| 5 | Phase 3 registration live (C) | **SIGKILL app** during a long Bash tool | Before kill: registry record `reserved`→`live` for the run, child `ps eww` shows `RPCE_RUNTIME_ID`. Relaunch. | Survivor item (provider, PID, worktree); Let finish → item persists with "You chose to let it finish"; when the process exits, Refresh clears it and the conversation's send restriction lifts. Sends to that conversation refused while alive. |
| 6 | Registration live (X) | **SIGKILL app** mid-turn | Same as 5. | Codex children exit (as previously observed) → record `exited`, no survivor item after Refresh; crash hold still present until It stopped. |
| 7 | Stop (C) | reuse #5 | Stop → confirmation lists PIDs → confirm. | Listed PIDs gone (`ps`), record `stopped`, fresh discovery ran, item cleared; no other process signalled (compare `ps` before/after). Cut if Stop is deferred. |
| 8 | Reconcile (X) | **SIGKILL** mid-turn, let Codex finish on its own if it does | It stopped → Reconcile → Reconcile again. | First: rows imported, `turn_aborted`/terminal evidence recorded, item becomes "finished"/resolved and auto-clears; second: 0 new rows; Codex thread has **no new turn**. |
| 9 | Reconcile (C) | **SIGKILL** mid-turn | It stopped → Reconcile ×2; watch `ps` for any `claude --resume` during reconcile. | Rows imported labelled recovered, item says completion unconfirmed; second pass 0 rows; no claude process spawned; refusals (unsupported shape) show typed text, nothing changed. |
| 10 | Continue (X then C) | **SIGKILL** mid-turn; C variant: kill during a tool call (dangling tool_use) | It stopped → Continue… → edit text → Send; double-click Send quickly. | Exactly one continuation intent + one run attempt; same thread/session id in provider history; second click shows joined state; C dangling case either continues or refuses with typed reason — never a fresh conversation. |
| 11 | Send saved (X, C) | **SIGKILL** while a queued follow-up is saved but unsent | Relaunch → saved-input item with `runNeverHandedOff` → Send saved. | One dispatch; intent keeps its ID and chronology (relocated to the current end if older content exists); provider history shows one message; on refusal it stays unsent at the new position. |
| 12 | Answer as input (X, C) | **SIGKILL** while a question is pending | Relaunch → question item → Send answer as message. | New input via normal dispatch; question snapshot removed; no permission/question callback fired (provider log shows a user message, not a tool result). |
| 13 | Check and resolve | **SIGKILL** with mixed state (one C survivor, one X finished, one unsent, one question) | Run Check. | Report: survivor → needsYou; X finished → resolved via reconcile; unsent → needsYou; question → needsYou; run-attempt counts unchanged; no session opened. |
| 14 | Pre-activation Check honesty | no (use a build with registration off, or a pre-activation run's records) | Run Check on old items. | All crash holds "no process record"; reconcile "process tracking not active"; nothing resolved automatically. |

Scenarios 5–7 are the R6 live gates (marker propagation, reparenting); 15 "reserved-before-registration crash cut" stays a deterministic test unless the verifier can place a debugger cut.

### E. Work order (one implement/review/commit cycle each) and what to cut

0. **Fixture-leak cleanup (prerequisite for live work)** — dry-run script listing Application Support workspaces matching known test names (e.g. `Workspace-Agent Mode Chat Switch*`), owner approves the list (data-loss rigor), delete, re-time the index scan. Cut: the test-isolation fix (DEBUG app-support root override, O3-a) is a separate plan; here only the cleanup. Also make Check and the indexed-schedule refresh **catalog-bounded** regardless.
1. **Catalog classification + auto-clear + banner rule** (Step A1–A4). Tests: exhaustive payload classification, auto-clear rules incl. open-action guard, banner nil when session has only informational items, paused indicator still renders. Cut if rigor balloons: ship classification + banner first, auto-clear second (age/continued rules are the riskiest).
2. **Sheet sections, counts, bulk Dismiss** (A5–A6 dismiss). Tests: eligibility skips, freshness mismatch → skipped, partial failure summary, cancellation leaves committed items. Cut: per-workspace sub-grouping (keep per-section).
3. **Bulk It stopped (lane-only)**. Tests: closed session skipped, live/unknown runtime skipped, freshness mismatch skipped, no navigation. Cut entirely if a lane-less path is requested — don't add one.
4. **Activation (atomic)**: flags, `liveQualification` switch, Phase 3 registration on, unify composition (launch authority/VM/UI), unqualified-provider refusal audit, update "Stop is not offered" wording. 4b: Stop action with confirmation. Tests: `allows` matrix, registration composition, ACP without reader → Reconcile absent/Continue typed refusal, double-click joins. Cut: 4b (Stop) if no entry point exists; never cut the composition unification.
5. **Check and resolve**. Tests with stubbed performers: registry `.noRecords`/`.someUnresolved`/`.allExited` paths, reconcile result mapping, cancellation, no dispatch ever (assert dispatch performer uncalled). Cut: auto crash-hold confirmation (keep Check as Refresh + reconcile + report).
6. **Verifier handoff + docs**: scenarios D into the evidence directory, spec status lines `Step 8-attention`, `Step 9-activation`, O32/O34 recorded; `liveQualification` flipped to `.qualified` per provider only after its scenarios pass (no re-review needed for that constant flip if behaviour is unchanged).

## 4. File-by-file impact

| File | Change | Driven by / depends on |
|---|---|---|
| `Sources/RepoPromptAgentCore/.../Recovery/AgentRecoveryCatalog.swift` | Add `AgentRecoveryCatalogAttention`, `AgentRecoveryCatalogAutoClear`; item fields `attention`, `autoClear`, `isHidden`; `openActionID` in `ActionFacts`; `attention(for:)`, `autoClear(...)`, `informationalRetention`; `build(now:)`; `needsAttentionItems(includeHidden:)`, `needsAttentionSections`, `needsActionCount`; `bannerItems` filter | A1–A3; Step 1 |
| `AgentRecoveryCoordinator` **[not attached]** | pass `now:` to projection; `bulkActionInProgress`/`isRecoveryCheckRunning`; `runtimeEvidence(for:)`; awaitable indexed-schedule refresh; expose Stop entry if present | A6, B, C; Steps 2,4,5 |
| `AgentRecoveryRecord` **[not attached]** | open-action accessor if missing | A2 rule 2; Step 1 |
| `Sources/RepoPrompt/.../ViewModels/AgentModeViewModel+RecoveryList.swift` | banner nil rule, needs-action `otherItemCount`, sections API, count; extract `performRecoveryListActionFailure`; `.stopProcess` mapping; update runtime text | A4–A6, C; Steps 1,2,4 |
| new `AgentModeViewModel+RecoveryBulk.swift` | `performRecoveryBulkAction` | A6; Step 2–3 |
| new `AgentModeViewModel+RecoveryCheck.swift` | `performRecoveryCheck`, report | B; Step 5 |
| `.../ViewModels/UI/AgentComposerUIModels.swift` | `AgentRecoveryListProps.isEmpty`/`headerText` (post-430 **[inference]**), `AgentRecoveryNeedsAttentionRow` fields, `Action.stopProcess`, bulk/check prop types | A4, A5, C |
| `.../Views/Components/AgentRecoveryNeedsAttentionSheet.swift` | sections, bulk buttons + confirmations, summary, Check button/report, toggle rename, new a11y IDs | A5, A6, B |
| `.../Views/Components/AgentRecoveryListBanner.swift` | `title(for:)` + destructive handling for `.stopProcess`; Stop confirmation listing processes | C/4b |
| `AgentRecoveryActionRunner.swift` | `production` flags; `AgentRecoveryLiveQualification` + exhaustive switch; log line | C; Step 4 |
| Launch authority / registry activation **[names unverified]** | single composition, registration on | C; Step 4 (atomic) |
| View menu / sidebar count call sites **[not attached]** | use `needsActionCount` | A5 |
| `Tests/RepoPromptTests/AgentMode/Recovery/` | tests per step; any test calling `needsAttentionItems(includeDismissed:)` renamed | all |
| `docs/context/plans/2026-10-18-lossless-app-restart-spec.md`, evidence dir | O32/O34 scope, status lines, scenario list | Step 6 |

## 5. Risks and migration
- No persistence schema change; auto-clear is projection-only and reversible. Turning flags back off later must not erase reservations/imports (unchanged behaviour).
- Activation exposes Phase 3 live gates (marker propagation, reparenting) that were never live-verified — scenarios 5–7 are mandatory before marking `.qualified`.
- The 50k leaked fixture workspaces make any cross-workspace scan unusable; Check is bounded to catalog sessions by design, but Step 0 is still needed for the verifier's timing.
- Bulk Dismiss of needs-action items hides unsent input; mitigated by the confirmation text and the toggle.

## Recommendations
1. Do Step 1 (classification + banner) first and alone — it fixes the owner's most visible complaint with zero risk to gates, and everything else keys off `attention`/`isHidden`.
2. Land activation (Step 4) only as one atomic composition change, and ship Stop only if a reviewed Phase 3 entry point already exists; otherwise defer Stop, keep Let finish/Refresh.
3. Keep `freshClaudeConversation` and `safeRestart` off (not in O32); record the override of the oracle's pair-gating as an owner decision in the spec and in the `liveQualification` comment.
4. Make Check and resolve honest by construction: automatic resolution only on registry-proven exit or verified terminal evidence; before activation it is Refresh + report, and that should be stated in its UI.
5. Clean the fixture-workspace leak (dry run → approval → delete) before any live scenario; otherwise scan timing will invalidate the verifier's results.
6. Blind spots to validate before coding: open-action accessor on the record, `runAttempts` commit ordering, the `registrationActive` composition site, the Codex family actually in use, and an awaitable indexed-schedule refresh.
