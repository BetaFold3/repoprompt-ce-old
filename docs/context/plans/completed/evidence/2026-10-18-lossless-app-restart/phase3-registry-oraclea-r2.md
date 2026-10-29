# Phase 3 registry — OracleA final re-review

Scope: read when the task touches Phase 3 registry final re-review findings for frozen tree `c25b94f0c854aee8577495d9f71ed6cfc247863d`.
Authority: Reference
Date: 2026-10-22

Preset identity verified: OracleA, `61D024A4-CCFB-4C9C-A614-CC65E0A1864C`, explicit selection. Chat `lossless-restart-phase-3-DA6176`. This is text-only review; no live validation by the reviewer.

# Oracle Review

The repair delta closes this lane’s three required findings: Claude now rejects stale buffered input after transport replacement, checks cancellation after reservation and write admission, and authorizes automatic replies through the registry before writing. Shared changes coordinate cross-provider retirement and narrow discovery/scheduler blocking without changing the architecture or enabling production gates. This is a text-only review of the supplied frozen snapshot; validation results are supplied evidence, not independently reproduced.

## Required finding dispositions

| ID | Verdict | Evidence |
|---|---|---|
| **P3-R05** | **Closed** | `handleStdoutChunk` captures the originating launch and checks both launch identity and stdout token before each line. Observed-conversation association receives that captured launch. `testClaudeBufferedInboundLinesNeverReachAReplacementTransport` exercises replacement during association and verifies no replacement bytes or associations. |
| **P3-R06** | **Closed** | `reserveSpawn` releases a cancelled registered reservation through `spawnFailed`; `sendUserMessage` rechecks cancellation after `writeAdmission`. Dedicated suspended-reservation and suspended-admission tests cover both remaining windows. |
| **P3-R12** | **Closed** | Automatic replies now pass an authorize-only registry fence followed by the synchronous receiving-transport check. Tests cover successful delivery, replacement during authorization, and revoked authority for both unsupported requests and RepoPrompt auto-approval. |

## P2 — Consider

### P3-R13 — Wall-clock age is not conclusive ancestry evidence

**Evidence:** `Sources/RepoPromptAgentCore/AgentMode/Runtime/Recovery/AgentProcessRegistry.swift:491–509` (`birthOrderingMarginSeconds`, `predatesFamily`).

**Scenario:** The clock moves backward by more than five minutes between root creation and descendant creation. After the root exits, a reparented descendant with unreadable environment evidence appears older than the root and is excluded by `predatesFamily`.

**Impact:** Discovery can classify the runtime as exited despite a surviving writer, releasing its restrictions. The five-minute margin reduces this uncommon edge case but does not establish reliable ordering.

**Smallest fix:** Retain uncertainty for unreadable non-zombie processes unless birth ordering has a reliable basis independent of wall-clock adjustments. The zombie exclusion can remain. Add a backward-clock counterexample if addressing this deferred edge case.

## Recommendations

- **Required closure verdict: CLOSED.** P3-R05, P3-R06, and P3-R12 are closed; no required finding remains open in this lane’s bounded scope.
- Record P3-R13 as a nonblocking deferred edge case; **do not run another review round solely for it**.
- Keep coupled production activation, marker injection, fresh Claude session IDs, and recovered Stop **OFF**. Live acceptance/O3 remains pending; this verdict does not establish live readiness.
