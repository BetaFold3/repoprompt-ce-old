# Phase 1b production cutover — OracleA R1

Scope: read when the task touches the first re-review findings for lossless-restart Phase 1b production input cutover.
Authority: Reference
Last-verified: 2026-10-21

Preset identity verified by the main agent. Review snapshot: `93e8db40525e7facb1e4fa7ea3ef2b496b45831f`. The following review is verbatim.

# Oracle Review

The R1 delta addresses the original preservation, ownership, reconciliation, and recovery-UI findings, with substantial focused coverage. Most findings can close, but the held-draft restore failure path can still lose previously durable input, and the instruction-wait changes introduce incorrect acceptance evidence and retain a FIFO gap. This assessment uses only the supplied delta and context; the reported 239-test pass is fixture evidence, not live acceptance.

## P0 — Must fix

### R02-R1 — A failed restore rollback leaves the durable draft vulnerable to overwrite

- **Scenario:** Restore commits an old-generation held draft; typing races that commit; the attempt to restore the held slot fails transiently. Storage subsequently recovers and the pending typing flushes.
- **Impact:** The previously durable held draft becomes memory-only and disappears after a crash.
- **Evidence:** `AgentRecoveryComposerPersistenceController.swift:374–411`, `revertRacedRestore`: failure clears `heldComposerRevision`, adopts the restored composer’s revision as `durableComposerRevision`, and leaves newer typing pending. `AgentRecoveryCoordinator.swift:1260–1298`, `resolveHeldComposer`, changes the lane to `.ready` and retains the displaced draft in `unsavedPredecessorInputs`. The controller can subsequently replace the restored draft with pending typing; that predecessor array is not durable.
- **Smallest fix:** Keep the restored snapshot protected against subsequent composer writes until rollback succeeds or another durable record owns its content. Do not reopen ordinary composer replacement merely because the draft is presented as unsaved input. Add a focused test that fails the rollback write, permits later writes, and verifies the original draft remains recoverable after reconstruction.

**Disposition:** R02’s UI omission is fixed, but this preservation regression prevents closure.

## P1 — Should fix

### R05-R1a — Resuming a local continuation does not prove provider acceptance

- **Scenario:** An instruction wait receives saved input locally. Its acceptance write commits, but RepoPrompt crashes before the tool response reaches the provider.
- **Impact:** Recovery treats an undelivered instruction as accepted, suppressing its saved-input recovery action and presenting unjustified delivery certainty.
- **Evidence:** `AgentModeViewModel.swift:20340–20525`: `deliverDurableQueuedInstructionHead` calls `evidence.noteAccepted()` before returning `UserInstructionResponse`; `claimLiveInstructionWait` calls it immediately after `liveContinuation.resume(...)`. Neither operation establishes that the RPC response reached the provider. The previous continuation path explicitly recorded uncertainty at this boundary.
- **Smallest fix:** Record `.deliveryUnknown` at the local return/continuation boundary unless a downstream acknowledgement actually proves acceptance. Keep the durable payload available for explicit recovery. Adjust the new acceptance tests accordingly.

**Contest:** I do not accept the disposition’s “consumed result boundary” as implemented: these functions enqueue or return a local result; they do not observe provider consumption. This requires no additional live-provider qualification to correct.

### R05-R1b — A requeued head can still be overtaken through the live wait

- **Scenario:** Head A is reinserted after the instruction wait is installed. Its preparation or dispatch suspends—or its required-prefix attachment fails, leaving the wait installed. New instruction B then arrives.
- **Impact:** B can claim the continuation while A remains queued, violating FIFO and potentially leaving A stranded.
- **Evidence:** `AgentModeViewModel.swift:20340–20525`, `deliverRequeuedHeadToLiveInstructionWaitIfNeeded`, retains both the head and continuation on failure. The direct continuation path at `AgentModeViewModel.swift:17005–17060` claims that wait without checking whether an older queued head owns priority. `testRequeuedHeadWhosePrefixCannotBeAttachedStaysQueuedDuringLiveWait` explicitly verifies the vulnerable intermediate state but never submits B.
- **Smallest fix:** While `pendingInstructions` has a head, enqueue new submissions behind it rather than letting them claim the continuation. Give the head-drain operation exclusive priority over that wait. Extend the existing test with a second submission and assert it cannot overtake A.

**Disposition:** The ordinary queued-head drain is fixed; R05 remains open for these two integration defects.

## Open / closed

| Status | Original IDs | Assessment |
|---|---|---|
| **Open** | R02 | UI added; restore-rollback failure can demote durable input to memory-only storage. |
| **Open** | R05 | Normal drain added; acceptance evidence and requeued-head FIFO remain incorrect. |
| **Closed** | R01 | Withdrawal now requires verified durable composer restoration; otherwise input stays held. |
| **Closed** | R03, R04 | Preparation-created prefixes gain durable carriers; Edit preserves context and rejoins after withdrawal. |
| **Closed** | R06, R07 | Dispatch freeze/drain and final lane checks added; Codex records compatible run ownership before handoff. |
| **Closed** | R08, R09 | Turn joins and unmatched terminal-run presentation address the reported scenarios. The stated keyless-terminal limitation is accepted. |
| **Closed** | R10, R11 | Exact schedule cancellation and per-item, receipt-aware delivery presentation added. |
| **Closed** | R12, R13 | Admitted snapshots flow through submission; outgoing-tab flushing is wired and covered. |

## Recommendations

**Do not approve the cutover yet.** Fix the three bounded issues above and rerun affected composer-recovery and instruction-wait tests for R2. No broader audit, full-root suite, or new live-provider acceptance gate is requested. Keep shutdown, later phases, and live crash acceptance explicitly deferred.
