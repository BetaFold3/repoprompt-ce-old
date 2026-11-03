# Phase 1b shutdown initial review — OracleA

Scope: read when the task touches review of the complete R4 quit/window-close preservation step.
Authority: Reference
Last-verified: 2026-10-21

Preset identity verified: OracleA, `61D024A4-CCFB-4C9C-A614-CC65E0A1864C`. Chat: `restart-shutdown-initial-307F0E`. Frozen tree: `4dab2d618a1c2babb3e06a4d4155af2d6f91b5eb`. Each lane reviewed the same snapshot independently.

# Oracle Review

The changes introduce an app-scoped two-stage shutdown coordinator, scoped admission holds, pre/post-teardown transcript flushing, pending-question snapshots, and asynchronous window-close routing. The architecture remains consistent with R4, but the supplied snapshot does **not yet satisfy the complete preservation contract**: historical answers can be deleted, clean-exit correction is not guaranteed before termination, and several freeze/retry/deadline boundaries remain incomplete. This is a static review of the supplied diff; no tools, production actions, or live validation were performed. O3 remains explicitly pending.

## P0 — Must fix

### R4-01 — A subsequent normal quit deletes unresolved recovered questions

**Evidence:**
- `Sources/RepoPrompt/Features/AgentMode/ViewModels/AgentModeViewModel+Shutdown.swift:161–179` captures only currently pending requests and passes their snapshots unconditionally to `prepareForShutdown`.
- `Sources/RepoPromptAgentCore/AgentMode/Runtime/Recovery/AgentRecoveryStore.swift:1497–1531` replaces the entire stored question collection with the supplied snapshots.

**Scenario:** Launch A saves a question with a partial answer during quit. In launch B, the owner opens that session but leaves its recovered question unresolved. The historical request correctly has no live continuation, so the next shutdown captures an empty array. That array replaces—and permanently deletes—the saved question and answer.

This also occurs when a new live question replaces an older unresolved recovered question. Historical input survives only until the next preservation pass.

**Smallest fix:** Preserve unresolved historical snapshots when updating live shutdown snapshots. Upsert captured interactions and remove specific interactions only after explicit dismissal, successful composer transfer, or confirmed live resolution. Do not interpret an empty live capture as permission to clear historical input.

**Required regression:** Save a partial answer, reconstruct the next launch, open the session without resolving it, run shutdown preparation again, and verify the original snapshot survives another reconstruction.

## P1 — Should fix

### R4-02 — Quit Anyway can exit before the unclean correction reaches disk

**Evidence:**
- `Sources/RepoPrompt/App/AgentLifecycleShutdownCoordinator.swift:395–408` starts and awaits the clean-mark write.
- `Sources/RepoPrompt/App/AgentLifecycleShutdownCoordinator.swift:429–435` enqueues the corrective `shutdownInProgress` write but discards its result.
- `Sources/RepoPrompt/App/AgentLifecycleShutdownCoordinator.swift:484–486` immediately completes after Quit Anyway.

**Scenario:** The clean write is slow enough to exceed the deadline. The coordinator queues an unclean correction and presents the failure prompt. The owner selects Quit Anyway while the clean write or its correction is still pending. Termination can occur after `cleanExit` commits but before the correction commits. A failed correction produces the same problem.

Ordering writes does not establish that the final ordered write happened before process exit.

**Smallest fix:** Fence obsolete clean commits at the persistence boundary and require durable confirmation of any necessary unclean correction before authorizing termination. Do not describe an enqueued correction as completed.

**Test inadequacy:** The fake environment records marks when requested, not when durably committed (`Tests/RepoPromptTests/App/AgentLifecycleShutdownCoordinatorTests.swift:245–249`). Its ordering assertion cannot establish the claimed no-false-clean guarantee. Add independently gated clean/correction commits and assert reply ordering, including correction failure.

### R4-03 — The payload-bearing `ask_user` submission bypasses the shutdown freeze

**Evidence:**
`Sources/RepoPrompt/Features/AgentMode/ViewModels/AgentModeViewModel.swift:20853–20878` guards the no-payload submission overload, but the adjacent `draftsByQuestionID` overload directly replaces drafts and resolves the request without checking shutdown state. The supplied legacy `submitQuestionResponse` shim calls that unguarded overload.

**Scenario:** A caller submits through the payload-bearing route while Stage A is suspended. The response changes after the preservation capture and is delivered to the provider despite the claimed synchronous answer freeze. The stored snapshot can describe an unanswered request that was subsequently answered through this route.

**Smallest fix:** Enforce the freeze before mutation in the shared submission/resolution boundary, covering both overloads and local/remote routing. Return an explicit refusal without changing drafts or resuming the continuation.

**Required regression:** Freeze a real VM, invoke the payload-bearing overload, and assert that drafts, pending request, continuation, and provider submission remain unchanged. The native-question fixture does not cover this route.

### R4-04 — Retry does not retry failed terminal-evidence persistence

**Evidence:**
- `Sources/RepoPrompt/Features/AgentMode/ViewModels/AgentModeViewModel+Shutdown.swift:283–300` waits for evidence writes, reports `terminalEvidenceFailures`, then retries only composer and transcript persistence.
- `Sources/RepoPrompt/App/AgentLifecycleShutdownCoordinator.swift:377–389,482–483` repeats finalization without repeating teardown.

**Scenario:** A terminal-evidence write fails during teardown because storage is temporarily unavailable. The owner fixes the storage problem and selects Retry. Finalization checks the recorded failure again, but does not reissue the failed terminal write. With the provider already stopped, no new terminal event necessarily arrives to repair it. Retry therefore cannot recover this supported failure path.

**Smallest fix:** Retain the failed terminal-evidence operation and retry it through the existing lane before evaluating finalization readiness. Clear its failure only after a successful receipt; do not repeat provider teardown.

**Required regression:** Fail a terminal-evidence write once, restore storage, select Retry, and verify durable terminal evidence, one teardown, and clean marking only afterward.

### R4-05 — The deadline is one relative sleep, not an absolute request deadline

**Evidence:**
- `Sources/RepoPrompt/App/AgentLifecycleShutdownCoordinator.swift:259–273` schedules preparation before scheduling the deadline task.
- `Sources/RepoPrompt/App/AgentLifecycleShutdownCoordinator.swift:502–519` starts `sleep(deadline)` when that task executes.
- `Sources/RepoPrompt/App/AgentLifecycleShutdownCoordinator.swift:350–357,395–408` performs irreversible/clean-completion transitions without comparing an absolute expiry.

**Scenario:** A busy main actor or synchronous preparation work delays execution of the deadline task. That task then grants a fresh eight seconds from its eventual start. Likewise, when both timeout and work completion become runnable after a busy period, completion can win without checking that the deadline already elapsed.

The supplied virtual-clock test proves that Stage B does not arm a second sleep; it does not prove eight seconds from the user attempt.

**Smallest fix:** Capture a monotonic expiry synchronously when the attempt begins, sleep until that expiry, and check it before crossing the irreversible boundary and authorizing clean completion. Ensure blocking preparation work cannot monopolize the executor needed to present the timeout.

**Required regression:** Delay deadline-task execution relative to attempt creation and verify that neither the budget nor successful completion extends past the captured expiry.

### R4-06 — Reused native-question cards discard the restored draft projection

**Evidence:**
- `Sources/RepoPrompt/Infrastructure/UI/Agent/AgentQuestionCard.swift:349–362` uses `initialDrafts` only to initialize `@State`.
- `Sources/RepoPrompt/Infrastructure/UI/Agent/AgentQuestionCard.swift:383–385` resets that state to empty defaults when the request changes.
- `Sources/RepoPrompt/Features/AgentMode/Views/AgentModeView.swift:2752–2776` supplies session-owned drafts but uses the constant identity `"pendingUserInputRequest"`.

**Scenario:** A reused card switches between pending requests, such as when navigating between tabs. Returning to a request with session-owned partial answers takes the `onChange` path, which ignores those answers and shows empty fields. The next edit reports a replacement draft derived from that empty state, overwriting the previously retained partial answer.

**Smallest fix:** Key the card by the request identity, or reseed its state from the corresponding session-owned drafts when the request changes. Keep the visible draft and shutdown snapshot source consistent.

**Required regression:** Exercise request A → request B → request A with partial answers, then edit one field and verify that the other retained content remains intact.

## Recommendations

- **Keep Phase1b-shutdown open** until these preservation and lifecycle-boundary defects are fixed.
- Add the focused regressions above within the existing fixtures. Also exercise the real VM Stage B path with queued input and terminal persistence; fake participants cannot establish those preservation semantics.
- Retain the existing architecture and defer optional polish/retention. Keep O3 pending; compile checks and the supplied fixture results are not live lifecycle acceptance.
