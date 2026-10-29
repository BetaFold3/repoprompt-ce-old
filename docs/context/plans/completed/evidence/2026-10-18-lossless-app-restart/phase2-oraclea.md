# Phase 2 initial review — OracleA

Scope: read when the task touches review of Phase 2 interruption, question durability, catalog, index hints, or durable acknowledgement.
Authority: Reference
Last-verified: 2026-10-21

Preset identity verified: OracleA, `61D024A4-CCFB-4C9C-A614-CC65E0A1864C`. Chat: `restart-phase2-initial-o-060569`. Frozen tree: `923f69a840be1fc0e297e8eb80dade18c1ecec92`. Both lanes received the same snapshot independently.

# Oracle Review

The patch extends the existing terminal barrier, recovery store, and session lanes with typed terminal causes, schema-8 discovery hints, question persistence, durable card acknowledgements, and a shared Needs Attention catalog. The architecture is largely retained, but several implementation paths still violate the lossless-persistence and honest-presentation contracts. This review covers the supplied frozen diff and supporting code; the reported validation was not independently executed, and O3 remains pending.

## P0 — Must fix

### F01 — Answer submission proceeds even when preservation fails
**Evidence:** `Sources/RepoPrompt/Features/AgentMode/ViewModels/AgentModeViewModel+RecoveryQuestions.swift:81–95`, particularly the discarded flush result at line 87.

- **Failure:** A non-secret answer’s write fails or exceeds two seconds. The code nevertheless calls `resolve(session)`, sends the response, and clears the live question. The subsequent non-preserving ending cancels its pending upsert and requests removal. An app kill before the provider durably records the response can therefore lose the submitted answer.
- **Impact:** The required **flush → reply → exact-ID removal** ordering becomes “attempt flush → reply regardless.” The new `testStorageCannotHoldAnAnswersReplyPastTheBound` explicitly asserts this contract violation; its passing result is not preservation evidence.
- **Smallest fix:** Require a successful preservation result before submitting an answer. On failure or timeout, retain the answer and request, release the resolution reservation, and show a retryable error. Keep bounded, non-blocking cleanup for actual timeout/decline paths separately. Test both failed and delayed writes without allowing an early reply.

## P1 — Should fix

### F02 — Native question creation ignores persistence failure and loses ownership checks across suspension
**Evidence:** `Sources/RepoPromptAgentCore/AgentMode/Runtime/Codex/CodexAgentModeCoordinator.swift:7239–7252,7276–7288`.

- **Failure:** Both native producers test only whether `commitCreation` returned a tuple—not whether its `result` succeeded. They publish or queue the question after a failed write. During that await, a reset or replacement run can also change the lane/controller; checking only `runState.isActive` allows an old request to appear in the replacement run.
- **Impact:** Questions can appear without durable preservation, or with obsolete transport ownership. The claimed save-error presentation is also missing: the catalog projects composer failures, not `questionPersistence.lastWriteFailure`.
- **Smallest fix:** Capture the lane, run ownership, and controller/request identity before awaiting; require successful persistence and unchanged ownership before publication. Route failures through the existing producer failure path and visible save-error handling. Add native-producer tests for write failure and replacement while suspended.

### F03 — Cold restore still invents interruptions for ordinary terminal outcomes
**Evidence:** `Sources/RepoPromptAgentCore/AgentMode/Runtime/AgentSessionRestoreSupport.swift:335–343`.

- **Failure:** When terminal evidence says `.completed/.ordinary`, `.failed/.ordinary`, or `.cancelled/.ordinary` but the transcript was saved open, `interruption(for:)` still returns an interruption. Only `.userCancel` is excluded. An ordinary completion following provisional Stage A shutdown evidence can consequently acquire an app-quit stamp.
- **Impact:** The catalog’s separate classifier does not repair the incorrect durable turn envelope. A verified ordinary outcome remains represented as an unresolved interruption.
- **Smallest fix:** Carry and classify the joined terminal state before sanitizing. Close ordinary completed/failed/stopped turns with their authoritative outcome, without manufacturing an interruption. Add sanitizer/save/reload tests—not only classifier tests—for these combinations.

### F04 — The catalog does not project newly interrupted live runs
**Evidence:** `Sources/RepoPromptAgentCore/AgentMode/Runtime/Recovery/AgentRecoveryCatalog.swift:341–375,456–482`.

- **Failure:** Run rows come exclusively from startup resolution arrays. Later committed records are consulted for intents and questions, but their run attempts and newly stamped turns are not projected. A session created this launch can lose its provider, successfully persist terminal interruption evidence, and still have no interruption item.
- **Impact:** Banner and app-wide discovery remain incomplete until another startup. Existing startup rows also retain their original outcome rather than being recomputed from newer terminal evidence.
- **Smallest fix:** Join current committed run evidence with the existing turn identities when rebuilding the catalog, deduplicating by attempt ID and excluding current active attempts. Test provider loss after startup and updates to an already-listed attempt across two windows.

### F05 — Durable drafts disappear from discovery when their session has no live lane
**Evidence:** `Sources/RepoPromptAgentCore/AgentMode/Runtime/Recovery/AgentRecoveryCatalog.swift:377–388,487–517`.

- **Failure:** Startup records contribute intents and questions, but never their `composer`. Saved-draft rows are generated only from a live lane’s `.held(snapshot)` state. A closed session containing only a saved draft therefore contributes no draft item; a held draft likewise loses its row when its lane goes away.
- **Impact:** Needs Attention cannot discover preserved draft content in closed sessions, despite the authoritative recovery record containing it.
- **Smallest fix:** Project recoverable durable composers directly from current records when no live composer already represents them. Use the composer revision for acknowledgement identity and provide safe Open routing. Test draft-only closed sessions and lane release/relaunch.

### F06 — Claude and ACP finalization cannot report provider-process loss
**Evidence:**
`Sources/RepoPromptAgentCore/AgentMode/Runtime/Runners/ClaudeIntegratedAgentModeRunner.swift:818–825`
`Sources/RepoPromptAgentCore/AgentMode/Runtime/Runners/ACPIntegratedAgentModeRunner.swift:2092–2101`.

- **Failure:** These finalizers unconditionally supply `.ordinary`. An unrecoverable provider process/transport failure reaching either finalizer cannot produce `.providerProcessLost`, regardless of the failure’s origin.
- **Impact:** The new interruption attribution works for selected Codex reasons but is absent from these provider finalization paths.
- **Smallest fix:** Thread a typed cause from the existing exhausted-recovery/process-loss branches into each finalizer. Keep ordinary provider errors ordinary and successful recovery unstamped. Test the actual runner boundaries, not just the cause helper.

## P2 — Consider

### F07 — Acknowledgement eviction makes unchanged dismissed cards reappear
**Evidence:** `Sources/RepoPromptAgentCore/AgentMode/Runtime/Recovery/AgentRecoveryStore.swift:1670–1721`.

- **Failure:** Dismissing a 129th distinct card drops an earlier acknowledgement even if its underlying item still exists unchanged.
- **Impact:** Durable Dismiss is undone by an unrelated acknowledgement write. The added bounded-store test explicitly expects this behavior.
- **Smallest fix:** Remove this eviction policy for now. Retention was deferred; the required bounded object is the index hint, not the acknowledgement history.

### F08 — Schedule freshness changes merely because the session hydrates
**Evidence:** `Sources/RepoPromptAgentCore/AgentMode/Runtime/Recovery/AgentRecoveryCoordinator.swift`, `readIndexedSchedules` (`attemptID: nil`); `Sources/RepoPromptAgentCore/AgentMode/Runtime/Recovery/AgentRecoveryCatalog.swift:205–209`.

- **Failure:** An index-sourced schedule can be acknowledged with `"-"` as its attempt component. Hydration supplies the existing attempt UUID and makes the same confirmation occurrence appear fresh.
- **Impact:** A dismissed card reappears without a semantic change. This reported limitation is a real, non-blocking defect—not merely missing live validation.
- **Smallest fix:** Include the optional attempt identity in the existing bounded schedule summary, or require Open before acknowledging an index item whose occurrence cannot be established.

### F09 — Historical wording asserts outcomes the evidence cannot establish
**Evidence:** `Sources/RepoPrompt/Features/AgentMode/ViewModels/AgentModeViewModel+RecoveryList.swift:224–240,480–500`.

- **Failure:** A response succeeds but snapshot removal fails: its retained card says “Unanswered question” and “ended before it was answered.” Separately, successful terminal evidence is labelled “Completed while RepoPrompt was closed,” although it may have committed before the crash.
- **Impact:** Users receive misleading recovery guidance, including a suggestion to reuse an answer that may already have been delivered.
- **Smallest fix:** Use “Expired question; response status may be uncertain” where delivery is unproven, and “Completed; transcript tail may be missing” without the unsupported timing claim.

### F10 — The banner’s “elsewhere” entry disappears when there are no local rows
**Evidence:** `Sources/RepoPrompt/Features/AgentMode/ViewModels/UI/AgentComposerUIModels.swift:393–395`; `Sources/RepoPrompt/Features/AgentMode/ViewModels/AgentModeViewModel+RecoveryList.swift:50–58`.

- **Failure:** `otherItemCount` is positive, but `isEmpty` checks only `rows.isEmpty`. The view model returns `nil`, suppressing the banner containing the Needs Attention affordance.
- **Impact:** Closed-session items lose the intended composer-level discovery link. The always-available menu remains a workaround.
- **Smallest fix:** Include `otherItemCount == 0` in the empty-state predicate and test a session with only elsewhere items.

## Recommendations

- **Do not approve this snapshot yet:** address F01–F06 within the existing architecture.
- Replace the early-answer test with preservation-order assertions; add focused native-producer, cold-restore, live-catalog, and closed-draft regressions.
- Fix the inexpensive P2 issues where practical; record any deferrals explicitly.
- Treat closed unknown-authority Dismiss requiring Open as acceptable. Keep UI/live qualification and O3 explicitly pending; no broader benchmark or live-provider campaign is needed for these fixes.
