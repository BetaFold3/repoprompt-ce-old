# Phase 1b production cutover — OracleB R1

Scope: read when the task touches the first re-review findings for lossless-restart Phase 1b production input cutover.
Authority: Reference
Last-verified: 2026-10-21

Preset identity verified by the main agent. Review snapshot: `93e8db40525e7facb1e4fa7ea3ef2b496b45831f`. The following review is verbatim.

# Oracle Review

# R1 re-review: lossless app restart, Phase 1b production cutover

I reviewed the supplied diff between the 8e55c2b2 tree and the immutable 93e8db40 tree. I did not run any code. Line positions below are approximate, from the hunk positions.

Every P1 from my initial review is closed at P1. The fixes do what was asked:

- **Early identity guards (F-1):** checks run before the bubble, attachment reservation and MCP signal. The `nil` defaults are gone, so the compiler lists every caller.
- **Crash-hold confirmation (F-2):** it is now durable and matches the hold exactly. No terminal evidence is invented.
- **Wait-tool sends (F-3):** acceptance is recorded at the point where the waiting continuation is claimed. Remote sessions are excluded from local crash holds.
- **Queued input and the wait tool (F-4):** the durable queue head is now delivered to the instruction wait, in order.
- **Dropped queue items (F-5):** inputs taken out of live queues show up as held input in the current launch.
- **Held drafts (F-6):** there are explicit Restore, Discard and Retry rows. Restore is fenced against typing that arrives during it.
- **Same-launch loads (F-7):** `LoadPurpose` separates cold restores from storage mutations. Only runs this launch still owns are excluded.

I checked the new Codex MCP bounded-acknowledgement driver and the deferred dispatch commit for regressions and found none. What is left is three narrow P2 gaps, one validation gap, and a few P3s. Nothing at P0 or P1 is open.

## Contest (F-8)

**I do not contest.** I accept the downgrade to P2/deferred. No path that brings back a removed accepted bubble was shown, and no measured failure was established.

Two notes for the deferral record:
1. Spec R1 still says "a record is deleted once it holds no unresolved items, which keeps the launch scan small." The implementation deliberately keeps accepted and terminal evidence. Record that difference in the spec or the step's deferred line, so the spec doesn't claim something the code doesn't do.
2. This delta makes keeping history somewhat more expensive:
   - `commitPublisher` sends the whole record to the main actor on every write.
   - `liveRecordCommits` keeps a full copy of each written record for the rest of the launch.
   - `presentUncertainInputOfEndedRuns` scans every intent on every commit.

   The deferred item should name per-commit cost that grows with history as its trigger, not only the length of the startup scan.

## New and residual findings

### R1-1 (P2) — Two paths still leave a durable input saved but invisible, with a bubble that looks sent (remainder of F-5)
- **Path 1 — continuation branch** (`submitPreparedUserTurn`, ~17026–17058):
  - **Scenario:** an MCP or composer input reaches the waiting-continuation branch. During the awaits in `augmentUserMessageForProviderSend`, which now include a possible `flushSaveDetailed`, the wait times out or is cancelled.
  - `guard session.instructionContinuation != nil else { return }` returns with no hold.
  - A failed `claimLiveInstructionWait` (wait, run attempt or lane changed) returns after `noteNoHandoff` without calling `holdBlockedDurableInput`.
  - **Result:** the intent is `queued` but sits in no queue and is not held. The bubble looks delivered until the next launch. The next wait call never receives the input.
- **Path 2 — run start** (`startAgentRun`, ~18660):
  - **Scenario:** the pending-handoff prefix can't be saved, so `augmented.blockedReason` is set, and the function returns `.failed` before the runner exists.
  - Because the runner was never created, `settleRunInputScope` never runs. The carriers are not held either.
- **Impact:** an unlikely race in both cases. The message is kept on disk, but the user is told the wrong thing until the next restart.
- **Smallest fix:**
  - At the two `return`s in the continuation branch: if the run is still active, put the input back at the head of `pendingInstructions`, so the requeue hook delivers it to the next wait. Otherwise call `holdBlockedDurableInput([inputIdentity], …)`.
  - In `startAgentRun`'s `blockedReason` exit, call `holdBlockedDurableInput(carriers, …)`.

### R1-2 (P2) — A `dispatching` intent from an earlier launch is listed with no action, on every launch, forever (follow-on from the F-12 fix)
- **Where:** `recoveryListIntentActions`: `.dispatching → []`. The store's `withdraw` refuses "while one may be in progress".
- **Scenario:** Claude acceptance waits for the turn to complete (`WrittenDispatchHandoff`), and full R4 shutdown hasn't landed. So a crash, or a quit during an active Claude turn, often leaves the intent in `dispatching`. On every later launch:
  - the intent's row is view-only;
  - the crash-hold acknowledgement stops it from blocking sends, but the banner count never goes down;
  - the record can never be cleared.
- An earlier-launch `dispatching` intent is no longer "in progress". It means exactly what `deliveryUnknown` means, which the cold-restore presentation already treats it as (`unacceptedDelivery`).
- **Smallest fix:** when `intent.appInstanceID != current`, treat `dispatching` like `deliveryUnknown`:
  - offer Remove in the list;
  - allow `withdraw` for it in the store, as a derived check like `previousInstance`;
  - do not rewrite its delivery state.

  Durable dismissal of interrupted-turn and recovery-only-run rows remains Phase 2 and is not claimed here.

### R1-3 (P2) — Every remote send from the previous launch becomes a recovery row after restart (remainder of F-3)
- **Where:** `appendIntentRows` with `isRemote` shows `deliveryUnknown` intents. The remote host's response is recorded as `deliveryUnknown`.
- **Assessment:** I accept the rejection of `host response = providerAccepted`. The cost is that each restart lists every remote message from the previous launch, including ones the host clearly answered. The user can work around it by pressing Remove on each row.
- **Smallest fix:** use the evidence the bubble join already uses. Don't list a remote intent row when saved provider output follows its user item in the transcript. Its delivery state stays `deliveryUnknown`; only the row is suppressed.

### R1-4 (P2, validation method) — Suites whose assertions changed are not in the reported runs
- **What changed:** the delta reverses or changes assertions in these suites:
  - `AgentModeChatSwitchActivationTests` (`lastRunState` running vs. idle, flush ordering)
  - `AgentStaleResetOwnershipTests`
  - `RemoteWorkspaceSidebarTests`
  - `AgentTranscriptRefreshDiagnosticsTests`
  - `AttentionNotificationAdmissionTests`
  - `AgentModeViewModelDelegatedQuestionTests`

  The scheduled-send code also changed: cancel-transfer, the startup-admission observer, and the `startAgentRun` signature.
- **What was run:** the supplied filters (`AgentRecovery|AgentProviderHandoff|CodexFallbackFIFO|CodexSteerAckTracker|CodexAgentModeCoordinatorLiveness`, the lifecycle and handoff suites, and the startup suites) don't match these suite names. "Loaded38suite" is not itemised.
- **Impact:** the user-visible F-7 behaviour change (same-launch reads keep an active run) and scheduled-send flows have no run evidence on this tree.
- **Fix:** run these suites plus the `AgentScheduledSend*` suites on 93e8db40 and record the job IDs.

### P3
- **R1-5:** Composer consumption now depends on `recoveryInputContent(live) == content` (`admitRecoveryInput`). Check that the production Send path leaves the draft text in place until admission finishes. If the view clears the text first, the stored composer is never consumed in the same write. A crash within the ~300 ms debounce would then restore both the draft and the intent.
- **R1-6:** `recoveryDelivery` on `AgentTranscriptActivity` and `AgentTranscriptRequestAnchor` relies on synthesised `Codable`. An unknown future raw value would make the whole transcript fail to decode, whereas `AgentChatItem` uses `try?`. Decode leniently in both places for consistency.
- **R1-7:** Clear Chat with a draft leaves the identical text live while a held copy blocks composer writes. The row says "the message box has new text". When the live content equals the held content, resolving with `.discardReplacingWith(live)` erases nothing. This is optional; it doesn't conflict with the owner-choice rule.
- **R1-8:** If a durable queue head's prefix can never be attached (an attach conflict), every wait call returns `QueuedInstructionDeliveryError` and the head stays first indefinitely. The only way out is stopping the run. This is acceptable as a loud failure; consider listing the head as held.

## Open / closed

| ID | Status |
|---|---|
| F-1 | Closed |
| F-2 | Closed for holds. Row recurrence is Phase 2 durable dismissal; residual R1-2 (P2) |
| F-3 | Closed. Remote disposition accepted; residual R1-3 (P2) |
| F-4 | Closed |
| F-5 | Closed at P1; residual R1-1 (P2) |
| F-6 | Closed. Rejection of auto-discard accepted; optional R1-7 (P3) |
| F-7 | Closed |
| F-8 | Downgraded to P2/deferred. **Not contested**; see the notes above |
| F-9 to F-14, F-17 | Closed |
| F-15 | Deferred (P2), accepted |
| F-16 | Not reproduced, accepted |
| New Codex MCP bounded acknowledgement | No regression found |
| Deferred run-start dispatch commit | No regression found |
| **Open P0/P1** | **None** |

## Recommendations
1. Run the suites in R1-4, including the scheduled-send suites, on 93e8db40 before committing. This is the only thing here that affects confidence in the reviewed behaviour.
2. Fix R1-1 and R1-2 now. Each is a one- to three-line change, and together they close the last "saved but invisible" and "listed forever" cases this package created.
3. List R1-3 and R1-5 to R1-8 as deferred. Don't run another round for them.
4. Update spec R1's record-retirement sentence, or the step's deferred line, to reflect the F-8 retention decision. Name per-commit cost that grows with history as its trigger.
5. Once validation passes, the step can move to commit under the policy. No further re-review round is needed for P0/P1.
