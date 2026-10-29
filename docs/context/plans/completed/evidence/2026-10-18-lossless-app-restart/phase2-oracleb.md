# Phase 2 initial review — OracleB

Scope: read when the task touches review of Phase 2 interruption, question durability, catalog, index hints, or durable acknowledgement.
Authority: Reference
Last-verified: 2026-10-21

Preset identity verified: OracleB, `7CDD523E-1D7C-47EA-98FE-D5FEA24D2D8C`. Chat: `restart-phase2-initial-o-03E313`. Frozen tree: `923f69a840be1fc0e297e8eb80dade18c1ecec92`. Both lanes received the same snapshot independently.

# Oracle Review



# Phase 2 lossless restart — initial review (OracleA/B lane)

This review covers the frozen tree `923f69a8` against R4 `57e45120`. I worked only from the supplied diff and current-file excerpts, with no repository access. Line numbers for new files are approximate (≈). Where a finding depends on code outside the diff, I mark it **PLAUSIBLE** and say what to verify.

## Summary

The diff finishes the Phase 2 work along the lines of the adopted plan:

- **Terminal causes.** There is a typed terminal cause, `AgentRunTerminalCause`. Its effective resolution lets completion win and keeps an explicit user cancel. The cause is persisted as an additive member of the existing terminal evidence and drives the live interruption stamp.
- **Classifier.** One shared classifier means failed or cancelled runs are no longer shown as completed. Cold restore no longer stamps a run the user cancelled.
- **Schema-8 hint.** The bounded metadata hint is a cache only. It is built from in-memory record facts, and the stub rebuild still decodes no transcripts.
- **Catalog and UI.** A coordinator-owned, immutable catalog feeds the session banner, an app-wide Needs Attention sheet, a View-menu command and the sidebar button. Durable, semantically keyed Dismiss replaces the old in-memory Hide.
- **Questions.** A lane-owned question persistence controller writes at creation, coalesces non-secret drafts (300 ms debounce, 2 s maximum), flushes before a reply and removes by ID.

Most acceptance items check out on reading:

- **Dismiss isolation:** Dismiss writes only acknowledgements, and `replace` preserves everything else.
- **Secret answers:** they are absent from the stored bytes, and the R4 veto is kept.
- **R4 Stage A:** it drains the question lane before its aggregate capture.
- **Crash-hold blocker:** it stays visible after Dismiss.
- **Schedules:** the scheduler gains only a read-only summary and a notification-only signature change.
- **Needs Attention routing:** the menu is always enabled and routes without hydrating anything.

I found **no confirmed P0/P1**. Two P2s (F1, F5) would become P1 if the verification I ask for fails.

---

## P2

### F1 — Live interruption stamp depends silently on the transcript turn; no end-to-end test (PLAUSIBLE, P1 if verification fails)

- **Scenario.** Stage B or window-close teardown commits a run with cause `appQuit` or `windowClose`. `stampLiveInterruption` looks up `session.transcript.turns.firstIndex(where: { $0.id == turnID })`. `turnID` is the **last user item**, which may not be a turn ID — for example a Claude/ACP steering row, or a transcript projection that hasn't caught up. If the lookup misses, the guard returns with no stamp and no diagnostic.
- **Impact.** The saved turn is closed as `.cancelled` with no `interruption`. On the next launch:
  - cold restore doesn't stamp it, because it isn't open;
  - it isn't recovery-only, because the turn exists.

  The quit- or close-interrupted turn therefore appears **nowhere** as interrupted, even though the record's terminal cause says `appQuit`. That is the core "honest interruption" acceptance.
- **Evidence:**
  - `AgentRunTerminalCommitBarrier.swift` ≈ lines 344–357 (call site), ≈ 480–488 (guard);
  - `terminalTurnID` is taken from `items.last(where: .user)` at ≈ line 244.
  - `testLiveStampRecordsInterruptionCauseOnce` sets `session.transcript` by hand.
  - `testCancelRecordsEffectiveTerminalCause` checks only `revision.cause`; nothing covers teardown → save → reload → reconciliation.
- **Smallest fix:**
  1. Add one integration test: a running session with a real transcript, then `prepareForWindowClose(reason: .windowClose)`, then save, reload, and confirm `interruptedTurns` has `reason == .windowClose`. Add a steering variant if Claude steering creates user rows.
  2. Make reconciliation robust. In `AgentSessionDataService` startup reconciliation, treat a closed turn whose joined attempt has `terminal.cause?.interruptionReason != nil` as an interrupted item even without a stamp. At minimum, add a DEBUG diagnostic when the stamp lookup misses.

### F2 — Answered questions can be presented as "Unanswered question"

- **Scenario A.** The user answers. The reply runs (`completeAskUserResolution` / `completeUserInputResponse`), and then the removal is only *enqueued* (`end` → `scheduleImmediateWrite`). If the app crashes before that write commits, the next launch lists the question as "Unanswered question … The agent was waiting for an answer".
- **Scenario B.** The removal write fails. It is owed, but no timer retries it. It is retried only by the next *question* write, or by Stage A's drain at close or quit. Meanwhile the catalog lists the ended question as a current-launch "Unanswered question" item, because it is no longer in `liveInteractionIDs`.
- **Impact.** This states something false as fact. The user may re-send the answer as a new message, so the agent acts on it twice. The plan explicitly required wording that says the response status may be uncertain.
- **Evidence:**
  - `AgentModeViewModel+RecoveryList.swift`, `case let .question` (≈ 245–262), titled "Unanswered question";
  - `AgentRecoveryQuestionPersistenceController.writePending` failure branch (≈ 300–315), which reschedules nothing;
  - `AgentModeViewModel.swift` ≈ 6593 (`endRecoveryQuestions` runs after the reply).
- **Smallest fix:**
  - Change the title and detail to "Saved question (answer status unknown)" whenever the snapshot can't be shown to be unanswered.
  - Optionally, put a resolved marker in the same flush as the reply's reservation.
  - Re-arm a debounce-length retry timer on a failed write.

### F3 — Question save failures are not shown anywhere

- **Scenario.** Creating a native question, writing a draft or removing a question fails. The controller sets `lastWriteFailure` and calls `stateDidChange`. The catalog, however, projects only `lane.composer.lastWriteFailure`.
- **Comment contradiction.** The Codex creation path says "A failed write still shows it (the lane surfaces the save error)". Nothing actually surfaces it.
- **Impact.** Draft answers silently aren't durable. A crash loses them with no warning, and the quit-time Stage A blocker is the first signal the user gets. The plan required surfacing a save error.
- **Evidence:**
  - `AgentRecoveryCatalog.swift` `addLaneComposerState` (≈ 470–520), which has no question branch;
  - `CodexAgentModeCoordinator.swift` ≈ 7237 (the comment).
- **Smallest fix.** Add a `.saveFailure` item when `lane.questionPersistence.lastWriteFailure != nil`, with Retry calling `questionPersistence.flush()` and no Dismiss.

### F4 — Schema bump yields a permanent, non-dismissible "couldn't be checked" item per unopened workspace (PLAUSIBLE)

- **Scenario.** On first launch after upgrade, every existing index is schema 7.
  - `recoveryIndexedSessionRecords` reads through `readMetadataIndexIfAvailable`. That presumably rejects the old schema, as the persistence test shows schema 6 is rebuilt.
  - It never rebuilds, so every closed workspace with session files gets a `schedule-index-<ws>` `.statusUnknown` item with no acknowledgement.
  - The item stays until each workspace is opened.
- **Impact.** The sidebar badge, the banner's "Needs Attention (n)" and the sheet stay non-empty and can't be dismissed, which hides real items. This is advisory, but the same stale indexes may also make every launch inspect every session in those workspaces until they are opened.
- **Evidence:**
  - `AgentSessionDataService.swift` ≈ 3520–3535;
  - `AgentRecoveryCatalog.swift` `addUnavailableScheduleIndexes` (≈ 590–605).
- **Smallest fix:**
  - Treat an index whose schema is older but still decodable as available for this read-only purpose, since `scheduledSendSummary` hasn't changed shape since schema 7.
  - Alternatively, offer a durable app-level acknowledgement for this item. Either way, confirm `readMetadataIndexIfAvailable`'s behavior first.

### F5 — New row-ID prefixes may not reach existing action parsers (PLAUSIBLE, P1 if verification fails)

- **Scenario.**
  - The paused crash-hold indicator uses row ID `paused-<sessionID>` with the action `.confirmStopped`.
  - Schedule items use `schedule-<session>-<schedule>` with `.open`.

  `confirmRecoveryCrashHold(rowID:)` and `openRecoveryListSession` resolve the session through `recoveryListSessionID(rowID)`. That function isn't in the diff and was written for the Phase 1b prefixes (`crash-`, `intent-` and so on).
- **Impact.** If parsing fails, "It stopped" on the paused indicator returns an error. Sending then stays paused until the user finds the dismissed crash-hold card under Show dismissed. Open on schedule rows fails in the same way.
- **Evidence:**
  - `AgentModeViewModel+RecoveryList.swift` ≈ 38–43 (paused row), ≈ 118 (`rowID = "paused-…"`), ≈ 967–975 (open);
  - no test exercises either action.
- **Smallest fix:**
  - Resolve the session from `coordinator.catalog.item(id:)`, or map `paused-` to the underlying `crash-<id>` item ID before dispatching.
  - Add two focused tests.

### F6 — In-launch live interruptions never enter the catalog

- **Scenario.** Interruptions stamped during this launch never reach the catalog:
  - a window is closed with a running session (`windowClose` stamp);
  - Codex provider loss (`providerProcessLost`).

  The catalog projects turns only from the startup `reconciliation.sessions[*].interruptedTurns`. `addHeldInputOfUnlistedSessions` adds only intents and questions, and terminal commits add no turn or run item.
- **Impact.** Needs Attention doesn't show the interrupted turn until relaunch. That contradicts plan §C ("update the catalog after … terminal commits") and Done-when #7 (items stay discoverable after their window closes).
- **Evidence:** `AgentRecoveryCatalog.swift` `addResolution` (turn loop ≈ 330–365) and `addHeldInputOfUnlistedSessions` (≈ 433–465).
- **Smallest fix.** Project run attempts from the live record whose terminal cause has an `interruptionReason` and whose session has no live lane. Reuse `.recoveryOnlyRun` and the same run key, so Dismiss and deduplication carry over.

### F7 — Cold restore still writes a crash interruption on runs that ended with completed or failed evidence

- **Scenario.** A run completes, or fails ordinarily, and its terminal evidence commits. The app crashes before the transcript save. `interruption(for:)` returns `nil` only for `userCancel`, so the open turn is stamped `reason = .appCrash` (or the launch reason) and that stamp is persisted.
- **Impact.**
  - The displayed status is right, because the classifier says completed or failed.
  - The transcript, the schema-8 hint (`needsAttention` with `reason`) and Phase 4 Resume eligibility will all treat it as an unresolved crash interruption.
  - The plan said such runs close "according to that outcome, rather than acquiring a new crash interruption".
- **Evidence:** `AgentSessionRestoreSupport.swift` ≈ 333–345.
- **Smallest fix.** Return `nil` (close as its outcome) whenever the joined attempt has terminal evidence whose cause is not an interruption cause, and let F1's reconciliation path list it as a `.terminalOutcome` card.

### F8 — Dismiss acknowledgements may be dropped by empty-record removal (PLAUSIBLE)

- **Scenario.** Dismiss a transcript-backed turn card, or an index or scheduler schedule card. The acknowledgement then lives in a record whose other content could later empty out, for example when the last held intent is withdrawn. If the store's existing "delete when nothing unresolved" predicate ignores `cardAcknowledgements`, the record is deleted and the card reappears after an unrelated write.
- **Impact.** This violates "unrelated writes don't [unhide]". The test only withdraws a second intent and keeps the first, so it doesn't cover this. The converse also holds: ack-only records created for closed sessions are never removed.
- **Evidence:**
  - `AgentRecoveryStore.acknowledgeCard` (≈ 1675–1735) creates or rewrites the record;
  - the removal predicate is not in the diff.
- **Smallest fix.** Count acknowledgements whose backing items still exist as non-empty in the removal predicate, and add one test that withdraws the last intent and then re-reads the acknowledgement.

### F9 — Live question becomes "historical" after a same-session lane replacement

- **Scenario.** An owner change or same-binding hand-over replaces the lane while a question is still live. The new controller's `knownIDs` is empty, so:
  - the catalog lists the live question as an "Unanswered question" historical item at the same time as the live card;
  - draft edits are ignored (`knownIDs` guard);
  - answering ends nothing, because `end` intersects with `knownIDs`, so the snapshot stays until the user explicitly removes it.
- **Evidence:**
  - `AgentRecoveryQuestionPersistenceController.draftDidChange` and `end` (≈ 140, ≈ 180);
  - catalog `addQuestions` (≈ 420);
  - the worker evidence acknowledges that "lane-keyed" liveness turns these into historical items.
- **Smallest fix.** When a lane is claimed, seed the controller's known and live set from `AgentRecoveryLiveQuestions.liveInteractionIDs(of: session)` for interactions already stored.

### F10 — Provider loss is typed only for Codex

- **Scenario.** The Claude, ACP and headless runners pass `.ordinary` on every finalize, including transport or process loss. A Claude process dying mid-turn is therefore "failed", never `providerProcessLost`, and is never stamped.
- **Evidence:** `ClaudeIntegratedAgentModeRunner.swift` ≈ 821, `ACPIntegratedAgentModeRunner.swift` ≈ 2096, against `CodexAgentModeCoordinator.terminalCause` (≈ 6895). The Codex mapping is a string match on two finalize reasons, and no test covers it.
- **Smallest fix:**
  - Pass `.providerProcessLost` from the existing Claude process-exit/transport-loss finalize branch after its recovery is exhausted, or record this in the evidence as an explicit deferral.
  - Add a test for the two Codex reasons.

### F11 — Test gaps on acceptance-critical producer paths

- **Codex creation ordering.** No test covers Codex native user-input or elicitation commit-before-publish, the `runState` revalidation after the await, or queue insertion.
- **Producer inventory.** There is no inventory showing that other native question producers are absent; the plan required one. Any other producer (ACP or Claude elicitation) would be covered only by Stage A.
- **Smallest fix.** Add one Codex coordinator test per request kind, and record the producer inventory in the evidence.

---

## P3

| ID | Issue | Evidence | Smallest fix |
|---|---|---|---|
| F12 | Failure policy is inconsistent: a failed `ask_user` creation refuses the question, while a failed native creation still shows it. The `ask_user` MCP error also embeds the raw `\(failure)` description, which may contain storage paths. | `AgentModeViewModel+RecoveryQuestions.swift` ≈ 28 | Document the asymmetry and use a generic error message. |
| F13 | Agent-initiated cancels (MCP `agent_run` cancel, agent manage, OMP) are recorded as `userCancel` and shown as "You cancelled this run". The instruction-wait path uses `.ordinary` with `intent: .userStop`. | `AgentRunMCPToolService.swift` ≈ 2336; `AgentModeViewModel.swift` ≈ 20451 | Use neutral wording ("Cancelled"), or add a cause for agent-requested cancels later. |
| F14 | Hashable synthesis may now include `AgentMCPElicitationRequest.askedAt = Date()`. Re-decoded or remote-mirrored requests would then compare unequal on every rebuild. | `UserInteractionModels.swift` ≈ 779 | Exclude `askedAt` from equality, or verify that Hashable is custom. |
| F15 | The question controller doesn't reschedule after a failed write, so a failed draft waits for the next event. Creation writes are unbounded, so a hung store stalls Codex event handling. | Controller `writePending`; Codex ≈ 7236 | Add a debounce retry on failure; bound creation the same way as `flush(within:)`. |
| F16 | Dead or duplicated logic: `AgentRecoveryCatalog.otherItemCount(...)` is unused (the VM recomputes it), and the `.restricted` blocker is never read. | `AgentRecoveryCatalog.swift` ≈ 140–150 | Remove them, or have the VM use them. |
| F17 | A Codex elicitation or user-input request cancelled by the provider during the creation await is still published, so the user sees a stale card. | Codex ≈ 7231–7247 | Re-check provider-side resolution after the await, if such a signal exists. |
| F18 | Index refresh re-reads the workspace inventory on every scheduler dashboard change. The schema-8 hint triggers a whole-index rewrite whenever the hint changes, which is about twice per send (unsent count 1 → 0) and on draft empty/non-empty toggles. | `AgentRecoveryCoordinator.adoptRecordCommit`; `AgentSessionDataService.noteRecoveryRecordCommitted` | Advisory only: coalesce hint rewrites per folder. |
| F19 | Dismiss failures show raw error text ("couldn't be dismissed (staleTranscriptResetGeneration…)"). The Open action is offered for other-workspace items that are then refused. | Coordinator ≈ 690; RecoveryList ≈ 975 | Map errors to user wording; hide Open for other workspaces. |

---

## Recommendations

1. **Verify F1 and F5 first**, because both could be P1:
   - add the teardown → save → reload → reconciliation integration test;
   - add the paused-indicator and schedule-row action tests.

   If either fails, fix it before the checkpoint. For F1, also add the reconciliation fallback that uses the terminal cause; it removes the dependency on the stamp lookup.
2. **Fix the cheap correctness and honesty items in the same pass:**
   - F2: uncertain-status wording, plus a retry timer;
   - F3: a question save-failure catalog item;
   - F7: no crash stamp over completed or failed evidence;
   - F9: seed live IDs when a lane is claimed;
   - F8: check the record-removal predicate.

   Each is small and local.
3. **For F4:** confirm the schema-7 behavior of `readMetadataIndexIfAvailable`. Then either read older-but-decodable indexes for schedule summaries, or make the item acknowledgeable.
4. **For F6 and F10:** either implement them (project live interrupted runs into the catalog; give Claude provider loss its cause) or record them explicitly as deferred, with the reasoning, on the Step 2 status line. Neither loses data.
5. **For F11:** add the Codex creation-ordering tests and the producer inventory to the evidence.
6. **P3s:** fix them where cheap, otherwise list them as deferred. None justifies an extra review round.
7. **Before re-review:** re-run the focused suites with their own returned tickets, especially the following, and keep stating that UI rendering and O3 live acceptance were not run:
   - `AgentRunTerminalCauseTests`
   - `AgentRecoveryCoordinatorTests`
   - `AgentRecoveryStartupCompositionTests`
   - `AgentRecoveryResetBoundaryTests`
   - `AgentRecoveryQuestionPersistenceTests`
   - `AgentRecoveryStoreTests`
   - the Codex coordinator suites
