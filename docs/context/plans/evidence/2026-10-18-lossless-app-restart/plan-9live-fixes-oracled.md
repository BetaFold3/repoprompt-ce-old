# 9-live fix plan: OracleD

Scope: read when the task touches planning the fixes for the 9-live findings (R1–R7, O42, O43) before the recovery activation switch.
Authority: Reference
Last-verified: 2026-10-28
Covers: OracleD plan-mode answer (chat 9-live-fix-plan-oracled-E9A2E2) over the three 9-live diagnosis reports




# Fix plan: 9-live findings → activation switch

## Summary

Seven findings came out of the 9-live run. Two of them (Claude holds can't be confirmed; Claude history position never captured) and one Codex defect (turn ID never saved) stop the live re-check from reaching the Reconcile/Continue/Check scenarios; two UI defects lose typed text (R4b, R5), which is the universal hard fail; the rest are small UI or docs fixes. The plan is six small reviewed steps on five seams, in dependency order, then the live re-check on a candidate that differs from the committed tree only by the activation line, then the switch commit. O43 is implemented as a settle-and-acknowledge in one record write: the proof that every process of the held run exited moves the run's `dispatching` intents to `deliveryUnknown`, lists them in the same crash-hold acknowledgement "It stopped" writes, and makes their row informational, never offering a resend. O42 is implemented by classifying the native-installer Claude executable as the writer (so its `CLAUDE_CONFIG_DIR` is kept), with a bounded `<sessionID>.jsonl` search across recorded homes plus `~/.claude` as the fallback. R1 (early Claude acceptance) is cut: after O43 nothing depends on it.

## Current state, in one paragraph per seam

- **Crash hold and Check.** `deriveCrashHolds` (`AgentRecoveryCoordinator.swift:1019-1050`) puts every earlier-instance `dispatching`/`deliveryUnknown` intent into `hold.uncertainIntentIDs`. `confirmCrashHoldFromRegistryProof` (`AgentRecoveryCoordinator+CrashHoldProof.swift:56-146`) refuses when that set is non-empty (`notOnlyRuns`). "It stopped" writes `AgentRecoveryStore.recordCrashHoldAcknowledgement(... runAttemptIDs, intentIDs, transcriptTurnIDs ...)` (`AgentRecoveryStore.swift:1587`), which already lists intent IDs. Claude intents stay `dispatching` because `noteClaudeTurnCompleted` (`ClaudeAgentModeCoordinator.swift:1919`) is the only acceptance producer and fires on the turn's `result` event. Admission checks the hold before the runtime restriction (`admissionRefusal`, 1531-1555); Refresh never runs the proof.
- **Claude history location.** `captureClaudeDispatchBaseline` (`AgentModeViewModel+RecoveryActions.swift:930`) needs a conversation ID and ≥1 root from `recoveryClaudeHistoryRoots` (1340), which reads only `AgentProcessRegistry.claudeProviderHomes(conversationID:)` (1174). Homes come from `discoverFamily` (449) only for members classified `.writer` by basename (`classifyNewMember`, 585-596). The real CLI's executable path under the rotator is `~/.local/share/claude/versions/2.1.302`, basename `2.1.302` → `.unknown` → no home ever recorded. `registerSpawn` (812) reads the shim's env, which lacks `CLAUDE_CONFIG_DIR`.
- **Codex turn ID.** `performRecoveryResumeAction` (RecoveryActions 120, lines 140-149) derives `codexTurnID` from `responseSpans.last.providerTurnID`, which nothing in production writes. `installAuthoritativeCodexTurnForStart` (`CodexAgentModeCoordinator.swift:1913-1992`) has the native turn ID, `session.activeRunAttemptID` and the thread ID, in memory only. `AgentRecoveryRunAttempt.extras` already carries `providerKind` and `runtimeRegistration` through `runStartExtras` (store 1160).
- **Recovery list.** `recoveryListRow` (RecoveryList 140) always sets `continuationText` to the default (192) and stores refusals as the row's `.failed` state; `AgentRecoveryListRow` draws `row.error ?? row.detail` (`AgentRecoveryListBanner.swift:114`) and keeps the Continue draft in `@State continuationDraft` (101). Runtime items are appended last in `AgentRecoveryCatalogProjection.build` (`AgentRecoveryCatalog.swift:293-316`, `addRuntimeRestrictions` 1041).
- **Esc popover.** `AgentRecoveryNativePopoverKeyFocus.takeKey` (`AgentRecoveryNativePopover.swift:53`) is gated on `!isKeyWindow`, which a popover window copies from its parent, so it never runs; `decide` (16) closes only when `isInPopoverWindow`.

## 1. Triage

| Finding | Class | Reason |
|---|---|---|
| R1 (Claude intent stays `dispatching`) | **Needed for the re-check, via O43 only** | Blocks Check on every Claude hold and "sending resumes after Refresh"; O43 removes the dependency on acceptance evidence, so the acceptance fix itself is cut (§3). |
| Claude history position (`unsupported` baselines) | **Needed for the re-check; blocks the switch for the owner's use** | Claude Reconcile and Continue refuse on every session; O42 is binding. First-message crashes stay refused (cut, §4). |
| R2 (Codex turn ID never saved) | **Needed for the re-check; blocks the switch** | Codex Reconcile and Continue always refuse; the owner's second provider. |
| R3 running dot | **Defer** | Misread: the row is the restore-cancelled failure state, honest if blunt. |
| R3 later `success` rewrite | **Defer, watch in the re-check** | Unexplained one-off on a summary-only row; the provider history keeps the truth; a bounded trace only if it reproduces. |
| R4a (note hidden behind the error) | **Needed for the re-check (A9)** | Cheap; without it A9 fails again. |
| R4b (Continue reopens with the default) | **Blocks the switch** | Typed text is only in the record; the user retypes. Universal hard fail class. |
| R5 (Continue editor closes, text gone) | **Blocks the switch** | Lost typed text. Fix is draft retention, not popover presentation. |
| R6 (Esc) | **Needed for the re-check (P5)** | Cheap, design already done; does not block the switch on its own. |
| V1 refusal notice (3 s) | **Needed for the re-check (V1 "refusal while alive")** | Small input-bar change; otherwise the verifier can't observe it and the owner can't read it. |
| R7 (survivor row last) | **Defer-able, do anyway** | One-line reorder; the row was almost certainly off-screen. |
| V2 guide mismatch | **Needed for the re-check** | Docs only; also fix the V1 "Refresh resumes sending" step, which the code never did. |

## 2. Ordered steps

Each step is one reviewed unit under the policy (A/B review; docs steps unreviewed). Suggested status-line names in brackets.

### Step 1 — R6: Esc closes the View popover [9-fix-esc]

- **Goal/scope.** `AgentRecoveryNativePopover.swift`; its decision and key-focus tests.
- **Design (diag R6 option A, unchanged).** `AgentRecoveryNativePopoverEventDecision.decide` gains `isInAnchorWindow`; Esc returns `.closeAndConsume` when the key-down is in the popover window *or* the anchor's window, `.ignore` elsewhere and for non-Esc keys. `shouldConsume` computes `isInAnchorWindow` as `event.window != nil && event.window === anchor?.window`. Delete `AgentRecoveryNativePopoverKeyFocus`, `AgentRecoveryNativePopoverKeyWindow`, the deferred `takeKey`, `returnKey` in `close`, and `previousKeyWindow`. Keep the `willResignActive` observer. Fix the three comments the diag names.
- **Tests.** Decision-table: Esc in anchor window → consume; Esc in unrelated window → ignore; letter in anchor window → ignore; mouse-down table unchanged. Drop the four KeyFocus tests with the seam.
- **Unblocks.** P5 steps 1, 2, 3, 4, 9, 11; "Esc during a running turn"; new case: mention palette open + Esc (expected: popover closes, palette needs a second Esc).

### Step 2 — Recovery list: R4a, R4b, R5, R7, V1 notice [9-fix-list]

- **Scope.** `AgentRecoveryCatalog.swift` (facts, build order), `AgentModeViewModel+RecoveryList.swift`, `AgentRecoveryListBanner.swift`, `AgentModeViewModel` (one new dictionary), `AgentInputBar.swift` + `AgentModeViewModel+Recovery.swift:232-258` (notice).
- **R4b + R5 design.**
  - `AgentRecoveryCatalogActionFacts` gains `unsentContinuationText: String?`, computed in the projection from the same action the existing `hasUnsentContinuation` rule selects (latest `continueWithText` with non-empty text, `notDispatched`, unresolved).
  - `AgentModeViewModel` gains `recoveryContinuationDraftsByRowID: [String: String]` (main actor, in-memory, per window). `AgentRecoveryListRow`'s editor writes every change through a new `AgentRecoveryListActions.updateContinuationDraft(rowID:text:)`; on open the editor loads `draft[rowID] ?? facts.unsentContinuationText ?? recoveryContinueDefaultText`. `performRecoveryListContinuation` removes the entry on a `.completed` outcome and leaves it on `.refused`. Not persisted across launches (assumption: a kill while typing in the small editor is out of scope; the composer is the durable surface).
  - Why not fix the popover's self-closing: cause undetermined, and retention makes every close path harmless. Presentation change deferred.
- **R4a design.** In `recoveryListRow`, when the action state is `.failed(reason)` and `facts.hasUnsentContinuation`, the row's `error` is `recoveryListUnsentContinuationNote + " " + reason` (note first so truncation drops the reason, not the note). `AgentRecoveryListRow` gets a `detailLineLimit` parameter: 2 in the banner (fixed `rowHeight`), 4 in the sheet. No banner height change.
- **R7 design.** In `AgentRecoveryCatalogProjection.build`, call `addRuntimeRestrictions()` (and `runtimeOwnershipUnknown`) before the per-session builders. IDs unchanged.
- **V1 notice design.** The admission-refusal sentences mapped at `AgentModeViewModel+Recovery.swift:232-258` are shown through `showSteeringUnsupportedNotice` with a new `persistent: Bool` (default false, preserving the 3 s behaviour elsewhere). A persistent notice clears on the next submit attempt or composer text change. `shouldClearInput: false` stays.
- **Tests.** Projection: `unsentContinuationText` set/absent across the existing supersession cases; runtime items precede session items. Row props: refused continuation → `error` starts with the note; draft precedence (draft > unsent text > default); draft cleared on completed, kept on refused. Input bar: persistent notice survives the 3 s timer and clears on text change.
- **Unblocks.** A9 (both halves), R5 re-check, V1 "refusal while alive", R7 (verifier scrolls to the end anyway).

### Step 3 — O43: Check settles delivery-uncertain messages of a proven-exited run [9-fix-o43]

- **Scope.** `AgentRecoveryStore.recordCrashHoldAcknowledgement`, `AgentRecoveryCoordinator+CrashHoldProof.swift`, the "It stopped" caller in `AgentRecoveryCoordinator`, `AgentRecoveryCatalogProjection.attention`/`needsDecision`, `recoveryListTitle/Certainty` in RecoveryList, `AgentRecoveryCrashHoldCheckText`.
- **"Clears", defined.**
  - *Delivery state.* Each qualifying intent that is `dispatching` becomes `deliveryUnknown`; one already `deliveryUnknown` stays so. Every open attempt of it gets outcome `.deliveryUnknown` with the message "Process records show every process of this run exited before the provider confirmed the message." The payload is never removed. This is the spec's own R2 rule ("a crash during `dispatching` becomes `deliveryUnknown`") applied with registry proof.
  - *Record.* One `replace(...)` write: the rewritten intents + attempts, plus the `crashHoldAcknowledgement` listing the run attempt IDs, these intent IDs and transcript turn IDs, exactly as "It stopped" writes it today. The card-freshness check that 9-activation-b put inside the write stays, and the write re-validates each intent (still earlier-instance, still uncertain, attempts unchanged) under `expectedRevision`; a conflict goes to the existing retry branch.
  - *Row.* Title stays "Message may have been delivered"; detail becomes "Every process of its run exited before the provider confirmed it. It won't be sent again." Attention: **informational** (new `AgentRecoveryCatalogActionFacts.settledByExitProof`, true when the record's acknowledgement lists the intent ID), Dismiss allowed. The interrupted-turn run note is untouched and keeps Reconcile/Continue.
  - *User can still.* View, Edit (text into the composer — the user decides whether to resend), Remove (withdraw), Dismiss. **Never** Send saved: `recoveryListIntentActions` already excludes it for `dispatching`/`deliveryUnknown`; add a test pinning that.
  - *Hold.* Lifted by the acknowledgement as today; sending resumes.
- **Qualification rule (what stops clearing something delivered and still mattering).** An uncertain intent qualifies only if every attempt it has (a) was started by an earlier app instance, and (b) references a run attempt that is either in the proof's exited set or has a recorded terminal commit (covers the T4-style retry). Any attempt without a run-attempt reference, or on a run attempt not covered → refuse the whole hold with a new `AgentRecoveryCrashHoldCheckText` reason ("a saved message's attempt isn't tied to a proven run"); `notOnlyRuns` is kept for that case. Beyond the rule: the proof trusts the same registry evidence 9-activation-b already trusts (registration mark, identity match, `unknown` never counts as exited); a delivered message's answer lives in the provider's history, which Reconcile and `--resume` still reach; nothing is deleted; resend is never offered.
- **It stopped.** Route the manual action through the same settle so both paths produce one row state (owner decision D1, recommended yes). If declined, "It stopped" keeps today's acknowledgement-only write and the row stays needs-action.
- **Concurrency.** Coordinator main-actor → registry actor read (`crashHoldExitProof`) → store write inside `performRecoveryTransaction`; same shape as 9-activation-b. No new tasks.
- **Tests.** Store: acknowledgement write settles `dispatching` and `deliveryUnknown` intents, leaves `queued` and `providerAccepted` untouched, refuses when an attempt is on an uncovered run attempt, refuses on revision conflict. Proof: Claude-shaped record (run attempt + `dispatching` intent, earlier instance) with a proven-exited registry stub → confirmed, hold lifted, intent `deliveryUnknown`; same with an alive process → refused; same with an extra `queued` intent → confirmed and the `queued` one untouched. Catalog: settled intent is informational and offers View/Edit/Remove/Dismiss, not Send saved.
- **Unblocks.** "Check confirms a clean Claude hold" (K2), V1 "Refresh clears the survivor, Check lifts the hold, sending resumes", C2 "need you" counts dropping for Claude.

### Step 4 — O42: Claude history location [9-fix-claude-home]

- **Scope.** `AgentProcessRegistry.classifyNewMember`/`discoverFamily`, new `ClaudeHistoryLocator` (AgentCore, `AgentMode/Runtime/Recovery/`), `recoveryClaudeHistoryRoots` and `captureClaudeDispatchBaseline` in RecoveryActions, refusal texts.
- **Design.** Full detail in §4. (a) Classify the native-installer executable as `.writer` so its env's `CLAUDE_CONFIG_DIR` becomes `providerHome` through the existing path; (b) if no home is recorded for the conversation at baseline or reconcile time, run one registry refresh and re-read, then fall back to the locator; (c) locator: exact `<sessionID>.jsonl` under `<root>/projects/*/`, roots = all recorded Claude homes ∪ app env `CLAUDE_CONFIG_DIR` ∪ `~/.claude`; exactly one hit or refuse.
- **Tests.** Registry: a fake inventory with root `node … shim/bin/claude` (no `CLAUDE_CONFIG_DIR`) and a descendant at `…/claude/versions/2.1.302` carrying it → record `providerHome` set, member role `.writer`; a descendant tool at `…/versions/…` of a non-Claude family is not a writer. Locator (temp dirs): 0 roots → nil; 1 hit → that root; same file in 2 roots → ambiguous; non-UUID session ID → nil without any filesystem access; a hit in `~/.claude`-style default only when no recorded home has it. Baseline: with a home recorded after the retry, `captureClaudeDispatchBaseline` returns `.captured`.
- **Unblocks.** Claude Reconcile with a real import and a real Continue, for sessions with a prior completed turn.

### Step 5 — R2: Codex native turn ID on the run attempt [9-fix-codex-turn]

- **Scope.** `AgentRecoveryModels` (`AgentRecoveryExtras.providerTurnID`), `AgentRecoveryStore.recordRunProviderTurn(...)`, `CodexAgentModeCoordinator.installAuthoritativeCodexTurnForStart` + a host seam, `performRecoveryResumeAction` lookup, `CodexRecoveryAdapter.historyObservation` text.
- **Design.** §5. Record last-wins on user-kind authoritative turns; prefer the record over the span at lookup; found-but-unsupported items get their own text.
- **Tests.** Drive `test_handleCodexNativeEvent(.turnStarted …)` against a session with a run attempt in a temp store → `extras.providerTurnID` set; a compaction turn start → not written; a steer-accepted mismatch → overwritten. Rewrite the two reconciliation tests (`AgentRecoveryReconciliationTests.swift:4094, :4168`) to get the ID from the record, not a seeded span. Adapter: interrupted turn with tool items → "found, can't import" text, `isUnconfirmedObservation` still true.
- **Unblocks.** Codex Reconcile (import for message-only turns; honest text for tool-bearing turns), Codex Continue (V4, V6 Codex).

### Step 6 — Switch gates and guide [9-flip-gates]

- **Scope.** Tests + docs: `AgentRecoveryActivationTests` (provider kind → launch pair pinned: `.claudeStandard` and Codex register under `.claudeAndCodex`, every other kind launches unregistered and its actions refuse with the named reason); one release-configuration build (validate the exact target; `swift build -c release` of the app module at minimum). `verifier-scenarios.md`: V2 ("Check confirms the hold; It stopped is the fallback"), V1 ("Refresh clears the survivor; Check then lifts the hold"), fixture notes from §6. New brief `verifier-9live-r2-brief.md`.
- **Then:** live re-check on committed tree + the one line → switch commit as its own reviewed step.

### File impact (all steps)

| File | Change | Step |
|---|---|---|
| `AgentRecoveryNativePopover.swift` + tests | decision table, remove KeyFocus | 1 |
| `AgentRecoveryCatalog.swift` | facts `unsentContinuationText`, `settledByExitProof`; build order; attention rule | 2, 3 |
| `AgentModeViewModel+RecoveryList.swift` | error composition, draft precedence, settled-intent detail, `detailLineLimit` | 2, 3 |
| `AgentRecoveryListBanner.swift` | draft write-through, line limit param | 2 |
| `AgentModeViewModel` (+Recovery) | draft dictionary; persistent refusal notice | 2 |
| `AgentInputBar.swift` | persistent notice option | 2 |
| `AgentRecoveryStore.swift` | settle inside `recordCrashHoldAcknowledgement`; `recordRunProviderTurn` | 3, 5 |
| `AgentRecoveryCoordinator+CrashHoldProof.swift`, `AgentRecoveryCoordinator.swift` | qualification rule, It stopped routing, new refusal text | 3 |
| `AgentProcessRegistry.swift` | writer classification by native-installer path; refresh hook | 4 |
| new `ClaudeHistoryLocator.swift` | fallback search | 4 |
| `AgentModeViewModel+RecoveryActions.swift` | roots with retry + locator; codexTurnID from record | 4, 5 |
| `AgentRecoveryModels.swift` | `providerTurnID` extra | 5 |
| `CodexAgentModeCoordinator.swift`, host protocol | write on authoritative user turn | 5 |
| `CodexRecoveryAdapter.swift` | found-but-unsupported text | 5 |
| activation tests, verifier docs | gates, guide | 6 |

## 3. R1: early Claude acceptance — evaluated and cut

- **Evidence available.** Claude 2.1.302 prints `command_lifecycle queued/started (command_uuid=Cn)`, `system/init user_message_uuids=[Cn]`, and `user_message_uuid` on the first assistant record (Step 4d capture). Today only the qualification classifier reads them; nothing feeds delivery evidence.
- **Preconditions it would need.** The caller UUID is on the wire only for `.committedWithOutboundUserMessage` baselines (RecoveryActions 917), i.e. only after Step 4 and never for a first message (no conversation ID before the send). So the UUID path cannot cover the fixtures that failed.
- **Misattribution.** With steering, several commands are queued in one process; `command_lifecycle started` is per command and carries its UUID, so UUID-matching is exact. The risk is only in a no-UUID fallback ("first output of the expected turn") and in output from a successor controller after a fallback replacement. Ruling it out means: accept only a `started` event whose `command_uuid` equals the handoff's outbound UUID, emitted by the controller recorded in `WrittenDispatchHandoff.controller` (same `isEmittedBy` test `noteClaudeTurnCompleted` uses), with no fallback. That is safe but, see next point, pointless now.
- **Still needed after O43?** No. Check: O43 settles the intent from process proof. Refresh-then-resume: O43 via Check. Reconcile/Continue: they key on the dispatch baseline and the run attempt, not the intent's state; `runNeverHandedOff` is false for a `dispatching` intent, so no resend is offered either way. Row text: `providerAccepted` would only remove the "may have been delivered" wording for the minority of sends that carry a UUID. T4-style retry already settles to `deliveryUnknown`.
- **Verdict.** Cut. Keep `result`-based acceptance as is.

## 4. Claude history location (O42)

**Classifying the real descendant.** Under the rotator the chain is `bash -c` → `node …/.claude-rotator/shim/bin/claude` (root; sets `CLAUDE_CONFIG_DIR` only for its child) → real CLI whose kernel path is `~/.local/share/claude/versions/2.1.302`. `classifyNewMember` keys on basename; `2.1.302` → `.unknown`, so `discoverFamily` never keeps its env. Change: for Claude families, a marker-matched member is `.writer` when its basename is `claude` **or** its executable path's last two parent components are `claude/versions` (the native installer layout; the version name is anything). Home extraction stays where it is (writer members only); it now sees the real CLI. Classifying by path, not by "any member with `CLAUDE_CONFIG_DIR`", keeps home discovery and the two-writer rule consistent (the real CLI *is* the writer, and today it counts as unknown, which already weakens `writerAlive`). Unknown to validate: `proc_pidpath` returns the resolved `versions/…` path (lsof shows it; inferred). If it returns `~/.local/bin/claude`, the basename rule already matches, so both forms are covered.

**Getting the home before the baseline.** The home is learned by discovery, which has no guaranteed pass between spawn and the first dispatch. Smallest fix: in `recoveryClaudeHistoryRoots`, when `claudeProviderHomes(conversationID:)` is empty, `await registry.refresh()` once and re-read. One inventory scan on the send path, only when no home is known yet; bounded.

**Fallback search (`ClaudeHistoryLocator`).**
- Input: session ID (must parse as a UUID; otherwise nil with no filesystem access), roots in order: every `providerHome` recorded on any Claude runtime record (not just this conversation's — the rotator's other profiles), the app's own `CLAUDE_CONFIG_DIR` env if set, `~/.claude`. Deduplicated by standardized path.
- Per root: one `contentsOfDirectory` of `<root>/projects`; for each subdirectory, `fileExists(<sub>/<sessionID>.jsonl)`. No recursion, no symlink walking, no other names. Cost: O(roots × project dirs) stats.
- Result: exactly one hit → that root; zero → "Claude history location unknown" (existing text); more than one → new refusal "Claude history for this conversation exists in more than one location" at both baseline and reconcile. The UUID filename makes an accidental match impossible; the only collision is a duplicated profile, which is refused rather than guessed.
- Plugs into `recoveryClaudeHistoryRoots` after the recorded-home path; both `captureClaudeDispatchBaseline` and `readClaudeHistory` go through it, so baseline and reconcile read the same root (the cursor's file identity is the second guard).
- Not included: `~/.claude-rotator/profiles/*` as implicit roots — after step 4a every launched profile is recorded, and pre-fix runs have no baseline to reconcile anyway.

**First messages stay unsupported.** Before a first send there is no conversation ID and no process, so no baseline can be captured without `--session-id` preallocation (gated on a shim compatibility check) plus an "empty history" baseline design. Cut (§8): a first-message crash is handled by O43 (hold confirmed), and sending a normal composer message resumes the conversation with `--resume` anyway; Continue only adds the default text and the transcript import. The verifier's fixtures run one short turn before the kill turn.

## 5. R2: which turn, and the matcher

- **Which turn.** Write `extras.providerTurnID` on the run attempt from `installAuthoritativeCodexTurnForStart` whenever a **user-kind** turn becomes authoritative for `session.activeRunAttemptID`; skip compaction and any non-user kinds. Last-wins: a steer that Codex accepts under the same turn ID rewrites nothing; `reconcileAcceptedCodexSteerMismatch` installing a different authoritative identity rewrites it, so the record names the turn running at the kill, which is the one Reconcile must match. Record only; the transcript span stays unset (session saves are debounced and lost at a kill; the record write is explicit).
- **Write path.** Through the host seam the coordinator already uses for run-start writes (the 9-activation-a provider-kind capture; validate the exact name) — a fire-and-forget main-actor task into the session's recovery lane, serialized by `performRecoveryTransaction`, `expectedRevision: nil` (monotonic extras fill). Never awaited inside event handling. Failure → log; Reconcile says "not identified" as today. A kill between `turn/start` and the event leaves no ID — honest.
- **Lookup.** `performRecoveryResumeAction`: `codexTurnID = runAttempt.extras.providerTurnID ?? <existing span lookup>`.
- **Matcher now?** Minimal yes: `CodexRecoveryAdapter.historyObservation` must distinguish "no turn with that ID" from "turn found, items unsupported" and use the text "Codex's record of the interrupted turn contains tool calls that can't be imported; nothing was imported." Still `isUnconfirmedObservation`, so Continue proceeds. Importing message-only rows out of tool-bearing turns, and recognising a *finished* tool-bearing turn so Continue stops (spec R7 step 3), are deferred: they need a design for partial import and the finished-while-closed case is unreachable anyway (the app-owned app-server dies with the app, V2).

## 6. Live re-check

Candidate: committed tree after steps 1–6 plus the one activation line. Approvals per kill as before. Two kills should suffice.

| Must cover | Fixture change |
|---|---|
| Check confirms a clean Claude hold; row "Message may have been delivered" settled to informational; sending resumes | K2-style no-tool turn, but after one completed turn in the session |
| V1 full: survivor named; refusal notice visible and persistent; Let finish; Refresh clears the survivor; Check lifts the hold; one send accepted once | Bash tool `sleep 900` or longer (the earlier `sleep 590` died 1 m 46 s after relaunch); run V1 first after relaunch |
| Claude Reconcile real import (rows appear once) and real Continue (one message in history) | Prior completed turn; Claude session file must have the conversation ID before the kill |
| Codex Reconcile on a message-only interrupted turn (import) and on a tool-bearing one (new text); Codex Continue once | T14-style sessions; one fixture without tools |
| A9 row detail with the note; Continue reopens with the typed text; draft survives the editor closing | As before |
| P5 steps 1–4, 9, 11; Esc during a running turn; mention palette + Esc | As before |
| R7: survivor row visible in the sheet without opening the session (scroll to the end) | — |
| R3 watch: the restore-cancelled bash row after the next turn in that session still reads cancelled | Re-read T7-style session file before/after |
| V8 | Trigger a Claude question, type a partial answer, kill within the 5-minute timeout |
| V7 | **Not reachable from the composer** (follow-ups become live steers; the Codex fallback queue can't trigger with an app-owned app-server). Accept on unit coverage, like O25 (decision D3). |
| C2 "finished Codex run resolved via history" | Not reachable (app-server exits with the app). Record as such. |

## 7. Owner decisions remaining

- **D1 — "It stopped" also settles the run's uncertain messages to `deliveryUnknown`** (same write as Check). Choices: yes / acknowledgement-only as today. *Recommend yes*: one row state, one code path; the user's judgement is at least as strong as the proof.
- **D2 — Settled message row:** informational with View/Edit/Remove/Dismiss (recommended) / hidden automatically. *Recommend informational*: the payload is still saved input and Remove stays explicit, per R8.
- **D3 — V7 accepted on unit coverage** since no composer fixture exists (as O25 for `queuedFallback`). *Recommend yes.*
- **D4 — First-message Claude crashes:** keep Reconcile/Continue refused (recommended; composer send resumes the conversation) / add `--session-id` preallocation now. *Recommend defer.*
- **D5 — Fallback roots:** recorded homes + app env + `~/.claude` (recommended) / also scan `~/.claude-rotator/profiles/*`. *Recommend the bounded set.*

Unanswered and reversible → proceed on the recommendation under `assumed:`.

## 8. Cuts and deferrals

- R1 early acceptance from stdout UUIDs (§3).
- Claude `--session-id` preallocation and an empty-history baseline for first messages.
- Refresh running the crash-hold proof; guide says Refresh then Check.
- Codex partial import of tool-bearing turns; finished-turn recognition with tools.
- Transcript-span `providerTurnID` write.
- R3 "interrupted" look for restore-cancelled rows; the `success` rewrite trace unless the re-check reproduces it.
- Continue editor in the native popover; dismissal instrumentation.
- Persisting continuation drafts across launches.
- Disabled-send UI for admission refusals (persistent notice only).
- C2 finished-Codex-while-closed; V7 live.

## Unknowns to validate during implementation

- `AgentRecoveryAttempt` carries a run-attempt reference (set by `attachDeliveryAttempt`); if not, the O43 rule can't be evaluated and the step must add that link at dispatch (scope grows — stop and report).
- How `addIntents` and `needsDecision` treat intents already listed in an acknowledgement today (affects the facts flag vs. existing behaviour).
- The host-protocol seam the Codex coordinator uses for run-start record writes.
- `proc_pidpath` output for the native-installer CLI (both forms are matched regardless).
- The input bar's notice API shape and whether text-change observation is already available there.
- The release-configuration build target name.

## Implementation order

1. Step 1 (R6) — independent; small review.
2. Step 2 (list fixes + notice) — independent.
3. Step 3 (O43) — store + proof + catalog; land the store change and the proof change together (one write contract).
4. Step 4 (O42) — registry classification and locator can land as one step; the refresh-retry depends on the classification being in.
5. Step 5 (R2) — model + store + coordinator + lookup together (the lookup without the write is a no-op; the write without the lookup is dead data).
6. Step 6 — gates and guide; then rebuild the candidate, run the re-check, then the switch commit.

Steps 3, 4 and 5 are independent of each other and could be done in any order; 3 first because it unblocks the most scenarios.

## Recommendations

- Implement O43 as settle-and-acknowledge in the existing crash-hold write, with the qualification rule in §2 step 3; route "It stopped" through it (D1).
- Cut R1's early-acceptance work entirely; nothing depends on it after O43.
- Fix Claude history location by classifying the `claude/versions/<v>` executable as the writer plus one refresh before the baseline, with the bounded `<sessionID>.jsonl` locator as fallback; leave first-message crashes to the hold and a plain composer send.
- Save the Codex turn ID on the run attempt (last user-kind authoritative turn), fix only the matcher's text now.
- Fix R4b/R5 by retaining the continuation draft in the view model; this is the one finding class (lost typed text) that blocks the switch on its own.
- Do R6, R4a, R7 and the persistent refusal notice as the two cheap first steps; update the verifier guide (V1 Refresh step, V2 hold text) and fixtures (prior completed turn, ≥15-minute sleep, partial answer within the question timeout).
- Accept V7 and C2's finished-Codex case on unit coverage; they are not reachable live with an app-owned app-server.