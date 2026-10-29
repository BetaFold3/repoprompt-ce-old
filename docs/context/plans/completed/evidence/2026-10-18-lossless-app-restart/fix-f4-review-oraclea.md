# Step 7-F4 — OracleA initial review (2026-10-26)

Scope: read when the task touches lossless restart Step 7-F4 (/compact after a cancelled Codex compaction) implementation or review evidence.
Authority: Reference
Last-verified: 2026-10-26

Fresh chat, explicit slices (policy, spec F4, local fix-f4-review.diff, worker report, coordinator context); preset identity verified from the result.

# Oracle Review

The patch distinguishes reconnect failures and pending reconnects from a genuinely missing conversation, adds content-free refusal diagnostics, and rechecks session/run eligibility after readiness. The changes are focused; no blocking defect is established from the supplied code. Validation results are worker-reported, not independently rerun.

## P2 — Consider

### F4-R1 — Test the supersession guards independently
**Evidence:** `Sources/RepoPromptAgentCore/AgentMode/Runtime/Codex/CodexAgentModeCoordinator.swift:1699–1713`; `CodexCompactReadinessTests.swift`, `testConcurrentSubmissionDuringReadinessIsNotOverlappedByCompaction`.

- **Scenario:** A turn starts **and finishes** while reconnect is suspended, leaving `runState` idle; alternatively, the tab binds to another agent session during readiness.
- **Impact:** These cases depend on the new generation/ownership and session-identity checks, respectively. The current concurrent-submission test leaves the turn active, so the active-state check alone can prevent compaction. It does not independently protect the generation/ownership checks, and no test exercises session rebinding.
- **Smallest fix:** Add gated tests that complete an intervening run attempt before releasing reconnect, and rebind the agent session during reconnect. Assert refusal and zero compaction requests.

## Recommendations

- **Keep the current synchronous check-to-reservation sequence.** There is no suspension between the final readiness check and `beginCodexCompaction`. However, `withRuntimeOperation` introduces an async boundary before the RPC. Exclusion therefore relies on `beginCodexCompaction` synchronously reserving the run and normal admission respecting that reservation—not on a suspension-free path through `compactThread`. Those helper implementations were not supplied.
- **The counter bookkeeping appears balanced:** each added increment has a same-scope `defer`, including recovered starts. Throws, early returns, and completed cancellation unwinds therefore clear their marks. A still-suspended start retains its mark legitimately.
- **Add production-lease coverage when practical.** The worker places controller installation and lease acquisition before the new start marker. Exercise replacement while waiting for that lease to verify that an ongoing reconnect is not classified as a completed failure.
- The diff does not alter cancellation fences or reconnect-metadata retention. Added log arguments contain fixed reasons and identifiers, not user content. The exact live race remains an inference; the reported tests demonstrate representative failure modes, not live causation.