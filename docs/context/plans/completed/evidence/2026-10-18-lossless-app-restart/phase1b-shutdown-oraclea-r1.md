# Phase 1b shutdown re-review 1 — OracleA

Scope: read when the task touches review of R4 shutdown preservation fixes and sealed window admission.
Authority: Reference
Last-verified: 2026-10-21

Preset identity verified: OracleA, `61D024A4-CCFB-4C9C-A614-CC65E0A1864C`. Chat: `restart-shutdown-r1-orac-34284E`. Frozen tree: `1c704e777d0ca799bcd7a1a93d24ae290280ead7`. Each lane received only its own prior findings and dispositions.

# Oracle Review

The delta fixes historical-question replacement, shared answer guards, terminal-evidence retries, absolute deadline capture, and native-card reseeding. The sealed registration boundary and request-owned clean write also address the original correction race under the stated delayed-acknowledgement interpretation. However, **R4-01 is not fully closed**: overlapping preparations from different shutdown requests can delete a successor’s preserved question. This is a static review of the supplied snapshot; reported validation was not independently executed, and O3 remains pending.

## P0 — Must fix

### R4-01-R1 — A cancelled preparation can delete the next request’s preserved question

**Scenario:** Stage A writes question Q, then suspends while recording run evidence. Its deadline expires; the user cancels and immediately quits again. The new request starts preparation before the old preparation finishes. It upserts Q and sees it as already stored. The old preparation subsequently returns, detects that its freeze was superseded, and enqueues removal of Q. That removal can execute **after the new upsert**, deleting the question and partial answer that the successful successor relies on.

**Exact evidence:**
- `Sources/RepoPrompt/App/AgentLifecycleShutdownCoordinator.swift`, `requestApplicationQuit` / `startPreparationAttempt`: a new request is allowed after Cancel, but serialization joins only that request’s `workTask`. It does not join the cancelled request’s preparation. Stage-A window-close supersession likewise leaves its work running.
- `Sources/RepoPromptAgentCore/AgentMode/Runtime/Recovery/AgentRecoveryCoordinator.swift:1706–1764`, `prepareForShutdown`: question persistence precedes further awaited run-evidence operations; the question receipt is returned only after those operations.
- `Sources/RepoPrompt/Features/AgentMode/ViewModels/AgentModeViewModel+Shutdown.swift:180–184`: preparation joins the removal task present **at entry**, not unfinished predecessor preparations that can enqueue removals later.
- Same file, `prepareRecoveryForShutdown:247–285`: a stale completion executes `stale.formUnion(tracked.introduced)`, clears `shutdownQuestionSnapshots[session.tabID]`, and enqueues deletion without checking whether a successor has adopted those IDs.
- Same file, `finalizeTranscriptsAfterShutdown:375–395`: finalization neither reconciles this race nor establishes that the required question still exists before reporting success.

**Impact:** A normal successful quit can lose a pending question’s partial answer and still authorize `cleanExit`. Exact interaction IDs prevent unrelated deletion, but do not establish ownership between successive preparations of the **same** interaction.

**Smallest fix:** Serialize the entire preparation and its cleanup per VM across request replacement—not merely retries within one request. A successor must join the predecessor and its resulting removals before capturing/upserting questions. Fence stale bookkeeping updates so they cannot clear successor tracking.

**Focused regression:** Hold the first preparation after its question upsert, timeout → Cancel → start another quit, then release the predecessor. Verify the successor preserves Q through teardown and a fresh store read, with no late deletion after clean authorization. Cover window-close → app-quit supersession through the same seam.

## P2 — Consider; no separate review loop

### R4-01-R2 — Failed snapshot removals silently lose their retry ownership

**Scenario:** Stage A persists Q, then encounters a storage failure. Cancel clears tracking and attempts to remove Q while storage remains unavailable. After storage recovers, the user answers Q. Its resolution is now untracked, so the obsolete saved question remains indefinitely.

**Exact evidence:**
- `AgentModeViewModel+Shutdown.swift:101–110`: Cancel removes all tracking before cleanup succeeds.
- `AgentModeViewModel+Shutdown.swift:114–123`: the serialized update discards `lane.updateQuestionSnapshots`’s result.
- `AgentModeViewModel+Shutdown.swift:403–415`: live resolution requires tracking and also removes it before durable deletion succeeds.

**Impact:** Recovery can show an already-resolved question and stale partial answer. Explicit recovery-list removal provides a workaround.

**Smallest fix:** Retain failed removal IDs with their lane ownership; retry them before subsequent preparation and expose persistent failure rather than silently dropping it.

## Prior-finding disposition

- **R4-01:** Original wholesale-replacement defect fixed; remains open through **R4-01-R1**.
- **R4-02:** Original correction-write race addressed. Accept the delayed-ACK interpretation; acknowledgement delay alone does not invalidate a genuinely stable preservation proof.
- **R4-03 / R4-04 / R4-05 / R4-06:** Addressed by the supplied changes. Native UI behavior remains compile-only evidence.

## Recommendations

- **Keep Phase1b-shutdown open** for R4-01-R1; repair cross-request preparation ownership before the remaining re-review.
- Fix R4-01-R2 if cheap, otherwise explicitly defer it without another polish-only round.
- Retain the existing architecture and keep O3 live acceptance pending.
