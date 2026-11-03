# Phase 1b production cutover — OracleB initial review

Scope: read when the task touches the lossless-restart production cutover's initial review findings.
Authority: Reference
Last-verified: 2026-10-21

Preset identity verified: OracleB, `7CDD523E-1D7C-47EA-98FE-D5FEA24D2D8C`. Chat: `restart-production-cutov-121C4F`. Same immutable code tree `8e55c2b2ed48bc3bb504f00a6e9ef0f99bb2abe8`; the initial packet used full unified context. Neither review lane received the other's findings.

# Oracle Review

# Review: lossless app restart, Phase 1b production input cutover

This diff turns lossless-restart recovery on in production. Every window now shares one app-wide recovery store, its gated session data service and one recovery coordinator. The scheduler stays closed until startup checks finish. Composer, MCP, waiting-continuation, steering, follow-up, Codex fallback, scheduled and remote sends are each saved as a recovery record (an "intent") before they are shown or sent, and each send then records what actually happened to it. Startup now scans closed sessions, marks interrupted turns, repairs half-finished scheduled sends, puts a "previous run may still be running" hold on affected sessions, and shows a basic recovery list. The building blocks hold up well: exact identities are kept, acknowledgements need a receipt from the store, uncertain sends are kept rather than retried, and tests use real temporary stores. The main problems are at the production edges:

- Several recovery states never end, so the restart holds and rows come back on every launch.
- Two routes record "delivery unknown" even when the send worked normally.
- Some refusals have no way for the user to clear them.
- Durable queued input is not delivered when the agent waits for instructions.
- Any caller left unconverted fails closed only after the message bubble has appeared.

I could not run anything or open files beyond the diff. Line numbers below are approximate, taken from the diff hunk positions; function names are exact.

---

## P0

None confirmed. F-1 becomes P0 if any production caller turns out to be unconverted (see its fix).

## P1

### F-1 Unconverted callers fail closed only after the bubble is shown and MCP is told "delivered"
- **Where:** `AgentModeViewModel.swift`, `submitPreparedUserTurn` (~16560–16830), and `startAgentRun` (~18427). Both new parameters (`admittedIdentity`, `inputConstituents`) default to `nil`.
- **Scenario:** Under mandatory mode, a path that calls `submitUserTurn` or `submitPreparedUserTurn` without an admitted identity still runs:
  - `appendPreparedUserTurn`, which adds the bubble and uses up the interview-first choice;
  - attachment reservation;
  - for remote sessions, `signalMCPInstructionDeliveredFireAndForget`.

  Only after that do the identity checks (`remoteSendDispatch` and the Codex/generic identity checks) return `.blocked(durableQueueAdmissionRequiredMessage)`. `startAgentRun` without constituents returns `.stale` for non-Codex providers. Codex reaches `sendCodexNativeMessage` with no context and returns `.stale("no durable recovery admission")`.
- **Impact:**
  - A "sent" bubble for a message that was never sent and has no durable copy.
  - A false delivered signal to the MCP caller.
  - Composer state may already be cleared, so the input is lost.
  - Every XCTest run has production composition off, so nothing in the validated suites would catch a missed caller.
  - I cannot see the rest of the file. Callers I could not confirm as converted: agent_run start for child sessions, oracle runs, resend/edit/fork submit flows, and `submitPreparedUserTurnAfterRunPreparation`.
- **Smallest fix:**
  1. At the top of `submitPreparedUserTurn` (before `appendPreparedUserTurn`) and of `startAgentRun`, return blocked/stale when `requiresDurableRecoveryAdmission(session)` is true and no identity was passed.
  2. Remove the `= nil` defaults so the compiler lists every caller. Grep for `submitUserTurn(`, `startAgentRun(` and `sendCodexNativeMessage(` without an identity. If agent_run start is among them, this is P0.

### F-2 Recovery holds and rows come back on every launch
- **Where:** `AgentRecoveryCoordinator.deriveCrashHolds`, `confirmCrashHold` (confirmation is kept in memory only), and `AgentSessionRecoveryResolution.hasRecoveryItems` / `unresolvedLegacyInterruptedTurnIDs`.
- **Scenario:**
  - A previous launch's run attempt is never given terminal evidence afterwards.
  - Intents in `dispatching` or `deliveryUnknown` keep `appInstanceID != current` forever.
  - Interruption `resolution` is never written by anything in this package.

  So every later launch rebuilds the same hold and the same "Run interrupted…" and "Message may have been delivered" rows. This happens even after the user pressed "It stopped" and sent new turns in that session. An open run attempt alone keeps the hold forever.
- **Impact:**
  - After each restart the user must confirm the same old sessions again before they can send.
  - `hasUnresolvedSession(inWorkspace:)` blocks scheduled new-session starts across the whole workspace, closed sessions included, until every hold is re-confirmed.
  - On the owner's always-on, frequently rebuilt machine, these pile up.
- **Smallest fix:** Make confirmation durable at the narrowest point. When the user confirms a hold, write terminal/abandoned evidence for its exact `uncertainRunAttemptIDs` (keep the intents' delivery states as they are), and derive holds only from attempts or intents that have no such mark. Alternatively, derive holds only from evidence written by the immediately previous instance.

### F-3 Remote sends and waiting-continuation sends always end as `deliveryUnknown`
- **Where:**
  - `RemoteAgentModeCoordinator.startRemoteSession` / `steer`: `evidence.noteDeliveryUnknown()` runs after every successful host response.
  - `submitPreparedUserTurn`, the continuation branch: `dispatchEvidence.noteDeliveryUnknown()` runs after `liveContinuation.resume`.
- **Scenario:** These are normal, successful deliveries. Nothing later upgrades them, so after any restart every such intent from the earlier launch:
  - places a crash hold on the session (remote sessions included, although the spec says the hold and registry do not apply to remote);
  - shows a "Message may have been delivered… could deliver it twice" row;
  - for remote request bubbles with no saved output, gets stamped "not sent" by the R1a join.
- **Impact:** Remote sessions and every agent that uses the wait tool produce false uncertainty and blocked sessions after every restart. Combined with F-2, this grows without limit.
- **Smallest fix:**
  - **Continuation:** returning the text to the waiting tool is the stage-delivery boundary this code already uses. Record `noteAccepted()` there, or settle on the tool result.
  - **Remote:** either treat the host's acceptance as `providerAccepted` for remote sessions, or skip crash holds and uncertain rows for remote bindings (`session.remoteHost != nil`, or the intent's target).

### F-4 Durable follow-ups are not delivered when the agent asks for instructions
- **Where:** `AgentModeViewModel.swift` ~20104, `waitForUserInstruction`: `if let head = session.pendingInstructions.first, !head.isDurable`.
- **Scenario:** In mandatory mode every queued input is durable. A user follow-up sent while a headless or ACP run is active is queued. When the agent then calls the wait-for-instruction tool, the queue is skipped, the session goes to "waiting", and the agent blocks until timeout. If the user then types again, that message reaches the waiting continuation directly, ahead of the older queued one.
- **Impact:** A regression for the most common follow-up path: the message looks sent but is held back, and messages are delivered out of order. The code comment says this is deferred ("wired by the VM routes batch"), but this package claims all drains are covered.
- **Smallest fix:** Use the same pattern as the continuation branch. Run `AgentRecoveryDispatchEvidence.begin(constituents: head.constituents, …)`, revalidate, `removeFirst`, return the text, and record acceptance (see F-3). On a failed begin, leave the head where it is.

### F-5 Durable inputs dropped from live queues have no visible copy during the current launch
- **Where:**
  - `AgentModeRunService.restoreQueuedClaudeSteeringDrafts` / `restoreAllQueuedClaudeSteeringDrafts` / `restoreAllQueuedDraftsForExecutionLocationChange`: durable entries are removed from the queue and filtered out of restored drafts.
  - Runner failures that settle an intent back to `queued` after it was taken off `pendingInstructions` (for example Claude `handleAcquireFailure` on a follow-up).
  - The continuation branch: `guard session.instructionContinuation != nil else { return }`, and the failed-begin `return`.
- **Scenario:** Cancel or fail Claude steering, change execution location, or have the continuation vanish during augmentation. The durable intent stays `queued` in the store, but it is:
  - not in any live queue,
  - not restored as a draft,
  - not marked as a stale target.

  The bubble still looks sent. The recovery list is built from the startup snapshot only (limitation 5), so nothing appears until the next relaunch.
- **Impact:** From the user's point of view the message is lost for the rest of the session, and the bubble wrongly suggests it was delivered. Only Codex calls `holdDurableCodexFallbackInput`.
- **Smallest fix:** On these paths, call `lane.markTargetStale(intentID:)` and append an inline error item ("Saved, not sent — see recovery after restart"). Or keep the old draft restore and explicitly `withdraw` the intent so the composer holds the only copy. Either way, one owner and one visible surface.

### F-6 A held composer or unsaved predecessor input can disable composer persistence or all sending, with no UI
- **Where:** `clearChatPreservingRecovery` and `performClearChat` (draft text is kept); `AgentRecoverySessionLane.admit` (refuses with `.unsavedPredecessorInput`); `beginRetirement(preserving: false)`; `recoveryListRows` (has no row for a held composer or for predecessor input). The plan's status line says explicit held-composer resolution is "required before production activation".
- **Scenario A (most common):** Clear Chat with a draft. The old-generation composer is written and held. The live draft stays in the composer, so every later composer write fails with `heldComposerUnresolved`. `lastWriteFailure` is shown nowhere, and `resolveHeldRecoveryComposer` has no caller in the UI.
- **Scenario B:** Click Clear and start typing during the reset commit, which saves a whole session. Those edits are pending on the old lane. After the commit, the binding-changing retirement turns them into `unsavedPredecessorInputs`, and every later send in that session returns "could not be saved for recovery". `resolveUnsavedPredecessorInput` has no UI. The same thing happens on any same-binding re-claim while a held composer blocks the pending write.
- **Impact:** Silent loss of draft durability (data loss on crash), or a session that cannot send until relaunch, with a misleading message.
- **Smallest fix:**
  - Have `performClearChat` (committed reset) discard the held composer after the commit, or auto-resolve it with `.discard` when the live draft equals the held content.
  - Add "Restore / Discard" rows for a held composer and for predecessor input to the existing banner. Both APIs already exist.
  - Freeze composer forwarding while reset preparation is active, or fold those edits into the successor lane instead of treating them as unsaved.
  - Show `composer.lastWriteFailure` in the composer, as R2 requires.

### F-7 A same-launch repair load stamps a live, just-finished turn as a previous-launch interruption
- **Where:** `AgentSessionDataService.repairScheduledSendTransferLocked` → `loadAgentSessionLocked` → `coldRestoreInterruptionContext` / `sanitizeColdRestoredTurn`. This repair is reached from `recheckScheduledSendTransferAwaitingEvidence` as soon as the run goes inactive.
- **Scenario:**
  1. A non-Claude/ACP scheduled send ends in a `.awaitingProviderEvidence` hold (the normal path).
  2. The run completes, and the recheck runs the gate-held repair.
  3. The session file still has the turn open (saves are debounced by 1 s; the dispatch save left it open).
  4. Normalization stamps it with `launchReason` from the *previous* launch (`appCrash`), sets it cancelled, rewrites the file, and the transfer mutation commits from that state.

  The live owner's next save probably overwrites it, but a crash or quit in between leaves a false "RepoPrompt quit unexpectedly" interruption. Because that turn has no run join (Codex has no run attempt), the index hint and a legacy-turn crash hold follow.
- **Impact:** False interruption rows and crash holds on turns that completed normally, in the main scheduled-send flow. Every gate-held load in the same launch carries the same risk (stale reload, resync, stub metadata recovery).
- **Smallest fix:** Pass `interruptionContext: nil` (load without stamping) from `repairScheduledSendTransferLocked` and the other same-launch helper loads. More generally, skip stamping when any intent or attempt in the record carries the current `appInstanceID`.

### F-8 Recovery records are never retired, so startup work and the scan's send-blocking time grow with total history
- **Where:** `reconcileRecoverySessionLocked` (`guard resolved.hasRecoveryItems || recordState.record != nil`), `AgentRecoveryStartupSweep.run` (`needsInspection = hasRecord || …`), and accepted intents being kept (the R1a accepted-bubble join depends on it; tests read accepted intents back).
- **Scenario:** Every session that ever had a sent or typed input keeps a record. Each launch then does a full gate-held load, normalization and possible rewrite of every such session before admission opens. Each record also holds the full text of every message ever sent, and keeps managed images alive. Accepted bubbles are restored again on any later load that is missing the item, so a bubble the user removed on purpose (rewind, scheduled removal) can come back.
- **Impact:** After each restart, sending stays blocked longer and longer as history grows (timing results are advisory, but the growth is in the design). Disk use grows, and per-send record rewrites get bigger.
- **Smallest fix:** Spec R1 already says to delete a record once nothing is unresolved. Prune accepted or withdrawn intents whose bubble is saved, plus terminal attempts. Or, at minimum, have the sweep skip records with no unresolved content without loading the session file. Downgrade this if the baseline store already prunes; nothing in the diff shows that.

## P2

- **F-9 Admission refusals all show "could not be saved for recovery".** `admitRecoveryInput` maps `crashHeld`, `restricted`, `startupFailed`, `unsavedPredecessorInput` and `resetPreparationInProgress` to `recoveryAdmissionFailedMessage`, which claims a save failure. Fix: map each refusal to its own text, for example "Confirm the previous run stopped (recovery banner)" for `.crashHeld`.
- **F-10 A failed startup followed by Retry leaves hydrated transfer holds stuck.**
  - `resolveScheduledSendTransfer` returns when `awaitStartupAdmission()` is false, and nothing observes `.agentScheduledSendStartupAdmissionDidChange` to call `retryScheduledSendTransferIfNeeded`. The hold keeps the session busy and blocks workspace-gated starts until relaunch.
  - The retry sweep may also repair the file without the live owner resyncing.
  - Fix: observe the notification and call the retry for each session.
- **F-11 A composer withdrawal after commit leaves the live draft without a saved copy.** `submitUserTurnAdmittingRecoveryInput` → `withdrawUnprojectedRecoveryInput` after the stored composer was used up. The live draft is not written again until the next edit. Fix: call `recoveryComposerDidMutate(session:)` after the withdrawal.
- **F-12 The list offers Edit/Remove where the store will refuse them.** Edit and Remove appear for `dispatching` and `deliveryUnknown` intents. Edit puts possibly delivered text into the composer, then fails to withdraw, which leaves two copies. Fix: offer only Remove (or View only) where the store refuses withdrawal.
- **F-13 The R1a "not sent" stamp reuses `isUndeliveredRemoteSend` on local bubbles.** The remote resend affordance has no persisted resend payload for local sessions, so the action does nothing or is misleading. Mid-turn steering bubbles are never stamped (limitation 1). Fix: use a local "not sent" presentation, or hide the action when `remoteHost == nil`.
- **F-14 `processRunID` is not a unique join key for Claude.** Claude reuses its run ID across turns. `attemptsByProcessRunID` keeps the last attempt, which can tie a turn to the wrong attempt and show a false "Completed while closed" status. `recoveryOnlyRunAttempts` also hides an open attempt behind an earlier saved turn. Fix: record `transcriptTurnID` on the run attempt and join by that first.
- **F-15 A stale publication leaves a durable head stuck.** `takeQueuedFollowUpIfReady` `.stale` keeps a durable head while blocking later heads. A new direct send can overtake it, and `hasPendingInstructions` keeps the scheduler busy. Fix: show it as held, or move it to the stale-target hold.
- **F-16 Missing context (load-bearing):**
  - `existingAgentSessionsFolder` builds the default session path itself (`applicationSupportRootURL()/Workspaces/<name,id>`), while the inventory base root honours `GlobalCustomStorageURL`. If this differs from the existing session-folder resolver (rename, global custom storage), affected sessions become `.noDestination` and are restricted, which blocks sending. Fix: reuse the existing resolver.
  - `AgentSessionDataService.shared` changes its tombstone root to `AgentRecovery/v1/tombstones`. If `defaultTombstoneRoot()` was a different path and the owner's debug builds already wrote tombstones there, those are orphaned.
- **F-17 Pending-handoff joins have no resolution UI.** Holds such as `.recoveryDeliveryUncertain` and `.recoveryCarriedByIntent` never end without a user action, so the handoff context, and possibly the provider lock it defers, stays held. Combined with F-3/F-2, this can last indefinitely.

## Verdicts on the worker-reported limitations

1. **"Not sent" stamping limited to the request bubble, with output treated as evidence:** sound for the turn's own request bubble, because output in that turn answers it. The problems are elsewhere: the flag reuse (F-13), and `deliveryUnknown` being shown as "not sent", which invites a duplicate resend. Steering bubbles are never stamped (F-5 and F-13).
2. **Flag not cleared on later acceptance:** in practice this does not arise locally, because no in-launch path re-sends the same local intent, and remote resend already clears the flag. P3.
3. **Recovery-only rows only for open attempts:** this rule only works because the join keys are missing. Codex terminal attempts are written with no turn or process ID (`recordTerminalEvidence(... nil, nil)`), so listing terminal attempts would show bogus rows. The spec wants terminal-only attempts to be discoverable. Fix the keys as in F-14, then include them. P2.
4. **Provisional `unknown` may never be refined:** acceptable. "Unknown" is honest. P3.
5. **Hidden-row state in memory, startup snapshot only:** acceptable only if held items created during the launch have another visible surface. Today they have none (F-5).

## Recommendations

1. Fix F-1 first: add early identity checks before `appendPreparedUserTurn` and in `startAgentRun`, remove the `nil` defaults, and audit every caller. Add one mandatory-mode test that composes the coordinator for agent_run start and oracle/MCP starts.
2. Make the recovery states end (F-2, F-3): durable confirmation or terminal marks for previous-launch attempts, acceptance at the continuation boundary, and no crash hold or uncertain rows for remote bindings. Without this, each restart adds holds.
3. Deliver durable heads in `waitForUserInstruction` (F-4), and give every durable drop path a stale mark plus an inline notice (F-5).
4. Deal with held composer and predecessor input before shipping (F-6): auto-discard after a committed reset, add the two banner rows, and show composer write failures. The plan's own status line lists held-composer resolution as a precondition for production.
5. Stop same-launch loads from stamping interruptions (F-7). Retire records, or skip unchanged ones in the startup sweep (F-8).
6. The P2s are cheap and can be deferred or batched. Do F-9, F-10 and F-11 now, since each is about one line.
7. Then rerun the lifecycle, Codex-liveness, startup and scheduled-send suites. Add a smoke test with production composition enabled, against temporary roots, that covers clear-chat-then-type, remote send then restart, and wait-tool follow-ups.
