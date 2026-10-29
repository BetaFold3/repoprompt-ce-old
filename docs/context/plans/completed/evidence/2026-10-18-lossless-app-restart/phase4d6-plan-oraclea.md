# Step 4d6 — OracleA planning

Scope: read when the task touches the bounded historical-tool presentation and unchanged proof-refusal work for lossless restart Step 4d6.
Authority: Reference
Last-verified: 2026-10-24

Exact preset identity verified by main; complete independent responses follow. The later continuation supersedes its initial execution-context proposal.

## Continuation after ownership scout (current guidance)

# Oracle Plan

## 1. Summary

Recommend **(a): remove inferred liveness from generic tool-call cards**, while preserving the existing independently gated **run-scoped cancellation shortcut**. Unresolved calls become neutral in both live and historical transcripts; separate result cards retain their outcomes, and the active-session indicator retains overall execution status. This is a targeted presentation change—not recovery completion—and needs no execution mapping, paired-status metadata, persistence change, or new authority. **STOP gate remains honored: this is a plan only.**

## 2. Current-state analysis

The supplied slices establish the actual path:

- `AgentModeView.swift:3083–3103` computes cancel eligibility from running session state, active run ID, retention/archive flags, and sequence position after the latest user message. **This is not exact invocation ownership.**
- `cancelActiveToolsAction` captures an existing run ID and invokes `cancelActiveToolsForRun`; its scope is the run, not the displayed invocation.
- `transcriptRowView` → `AgentMessageBubble.swift:291` → `ToolCardRouter.callView` forwards that eligibility and closure.
- `ToolCallCardStateResolver` at `ToolCardRouter.swift:967` defaults missing or unclassifiable attached results to `.running`.
- `ToolCallCard.showsCancelButton` additionally requires that inferred `.running` status. Changing only the resolver would therefore remove cancellation shortcuts unintentionally.

The core’s `stableExecutionID` grouping does not supply the missing context: render blocks contain flattened items, and `AgentTranscriptActivity.toItem()` does not expose canonical execution status. Turn closure also cannot establish actual run ownership across steering messages.

**Reuse:** existing result classification, `.neutral`, run-scoped eligibility, captured cancellation closure, and session-level activity presentation. Do not extend the transcript pipeline.

## 3. Design

### Generic call presentation

Keep the existing synchronous interface:

`ToolCallCardStateResolver.status(for: AgentChatItem) -> ToolCardStatus`

Change its behavior:

| Call evidence | Display |
|---|---|
| Neither `toolResultJSON` nor `toolIsError` present | `.neutral` |
| Attached evidence classified by `ToolResultStatusResolver` | Preserve that classification |
| Attached evidence not classifiable | `.neutral`, replacing the current `.running` fallback |

This removes the **inference** that an unresolved call is executing. It does not fabricate success, failure, cancellation, or completion.

Do not examine separate result rows or invent pairing. A protected pending call may remain neutral beside its separate result card; the result card owns that outcome.

Scope remains the generic `ToolCallCard` branch. Hidden tools, `ask_user`, and `ContextBuilderCallCard` retain their existing paths.

### Preserve cancellation without claiming invocation liveness

Decouple cancellation eligibility from the displayed status.

Add one synchronous internal predicate on the existing resolver:

`allowsRunScopedCancel(for: AgentChatItem) -> Bool`

Its contract is **exactly the previous resolver’s `.running` eligibility**, not a new execution assertion:

- No attached result/error evidence → eligible.
- Attached evidence → eligible only when the existing `ToolResultStatusResolver`, using the previous `.running` fallback, would return `.running`.

This deliberately preserves the old affordance boundary, including unclassifiable results. Reuse the existing classifier; do not implement another result parser.

`ToolCallCard.showsCancelButton` then requires:

1. This compatibility predicate.
2. Existing `showRunScopedToolCancel`.
3. Existing non-nil cancellation closure.
4. Existing RepoPrompt-tool-name check.

The card may therefore be **neutral with a run-scoped cancel shortcut**. That is coherent: eligibility to invoke an existing run command is not evidence that this individual call is running.

Give the button explicit help/accessibility wording: **“Cancel active tools for this run.”** Do not describe it as cancelling this invocation. The button implementation was not supplied; validate its existing label/tooltip before editing, applying the wording at the shown construction site where possible.

Preserve timestamp suppression while the button is shown and preserve the closure unchanged. No new cancellation dispatch or authorization is introduced.

### Usability and lifecycle

The intentional loss is per-call spinning animation for unresolved live calls. The benefit is eliminating false activity for interrupted history, including while a later run executes. Overall activity remains visible through the session indicator.

Cancellation discoverability and behavior remain unchanged apart from clearer scope wording. There is no demonstrated unacceptable workflow cost requiring option (c).

All new behavior is pure derived presentation:

- Existing SwiftUI updates recompute status and eligibility.
- No tasks, caches, subscriptions, or actor crossings are added.
- Attached-result updates can change classification; missing/dropped results remain neutral.
- Duplicate rendering is harmless.
- Tab selection and `isBackground` do not participate.
- Existing stale-run handling of the captured cancellation closure is unchanged.

## 4. File-by-file impact

| File | Planned change |
|---|---|
| `Sources/RepoPrompt/Features/AgentMode/Views/ToolCards/ToolCardRouter.swift` | Change status fallbacks; add the compatibility eligibility predicate; decouple `showsCancelButton`; clarify run-scoped button wording and the obsolete “calls in progress” comment. |
| `Tests/RepoPromptTests/AgentMode/ToolCards/ToolCallCardStateResolverTests.swift` | Proposed test file; extend the existing equivalent if present. Cover display classification and cancellation eligibility independently. |

**No changes** to `AgentModeView.swift`, `AgentMessageBubble.swift`, transcript models/services, recovery, imports, or storage. No caller signatures change.

Exact existing test filenames and `ToolCardCancelButton` labeling remain implementation-time lookup items, not grounds for pipeline expansion.

### Minimal tests

1. Missing evidence → neutral, cancellation predicate true.
2. Unclassifiable attached evidence → neutral; eligibility matches the previous resolver.
3. Existing success/warning/error fixtures → unchanged classifications and unchanged cancellation eligibility.
4. Card cancellation gate preserves all existing restrictions: caller eligibility, closure, and RepoPrompt tool identity.
5. An unresolved fixture remains unchanged after resolution; active versus historical context cannot affect its status because neither is an input.

Use focused unit coverage and the existing UI testing mechanism for the button gate; do not add a UI harness solely for this step. Run affected tests and required compile/style checks. No provider prompts or new live qualification.

## 5. Implementation order

1. Record the bounded contract and confirm button-label ownership and existing test location.
2. **Atomically** change fallback presentation and decouple cancellation eligibility, with focused tests. Landing only the fallback change would regress cancellation.
3. Run affected validation and repository-required checks.
4. Main alone obtains the required fresh A/B source reviews, attaching the policy verbatim; follow its bounded retry rules.
5. Record presentation completion separately from restart coverage and final live acceptance.

## Recommendations

- **Choose (a), preserving run-scoped cancellation separately.** Reject (b): it knowingly leaves false historical activity during later runs.
- No owner-only product decision is needed for this reversible proposal; record it under **`assumed:`**, not Decisions. Source edits remain stopped until the current gate is lifted.
- If per-call liveness becomes a mandatory product requirement, choose **(c)** and ask: “Accept neutral calls with session activity and existing run cancellation, or authorize exact execution mapping? Recommend neutral calls.”
- Keep proof refusal, manual Edit/Copy fallback, retention, imports, and activation unchanged. **Activation stays OFF; verified lossless-restart coverage and final live acceptance remain pending.**

## Initial guidance (historical)

# Oracle Plan

## 1. Summary

Choose a targeted **honest historical-tool presentation** step, backed by regression tests preserving recovery refusal. Do **not** introduce a continuation or new-conversation bypass. Retain explicit manual Edit/Copy as the unverified fallback, without presenting it as recovered execution. This fixes a real misleading state while leaving proof authority, summarized retention, recovery architecture, and production activation unchanged. It does **not** establish that pre-live lossless restart work is complete.

## 2. Current-state analysis

### Recovery and proof

The supplied code establishes this flow:

1. `performRecoveryResumeAction` builds a stable, durable action request.
2. `AgentRecoveryActionRunner.perform` acquires the coordinator’s action hold and reserves the action.
3. When qualified, the runner invokes history reconciliation before applicable continuation actions.
4. Claude reconciliation reads from the source attempt’s own baseline, validates history and associations, then plans an import.
5. Successful imports save rows, ledger, and receipt together; the recovery cursor advances afterward.
6. `stopBeforeDispatch` blocks on `.blocked` or `.associationUnavailable`; only an allowed result reaches ordinary dispatch.

`ClaudeSessionHistoryReader.ledgerConflict` requires every applicable known entry’s digest to match, including entries preceding the new frontier. Under the stated producer policy, cleared proof cannot be reconstructed from summarized Read data. Retained associations identify rows; they do not establish payload equality.

The separate storage-comparison allowance in `AgentProviderHistoryImport.swift` likewise requires unique key/local-item mappings and matching digest evidence. It is not a repair mechanism.

`continueInNewConversation` currently means explicit replacement after a recorded Claude resume failure. Its dispatch clears the old conversation target only after the runner’s preceding checks. Using it to escape proof refusal would expand its meaning and authorization contract.

### Tool presentation

`ToolCallCardStateResolver.status(for:)` currently returns `.running` when a call has no result fields. `ToolCallCard` consequently renders a spinner and may offer cancellation even when the call belongs to interrupted history.

`ToolCardStatus` already provides `.neutral`, and `fromTranscriptStatus` maps `.pending`/`.running` to `.neutral`. Reuse these presentation semantics; do not change the immutable canonical call or manufacture a result.

The missing input is **whether this invocation belongs to execution that is actually active**, plus any already-paired result—not whether the tab is selected or whether output was marked `isBackground`.

## 3. Design

### A. Preserve the recovery boundary

**No production behavior changes** to:

- `AgentRecoveryActionRunner`;
- Claude ledger/digest validation;
- stored-Read comparison eligibility;
- baseline capture, cursor movement, or import transactions;
- `continueInNewConversation` eligibility and dispatch;
- activation qualifications.

An explicit choice authorizes sending its payload; it does not supply missing historical evidence. Although a separately designed manual-send operation could omit reconciliation, that is not the existing verified recovery contract and is unnecessary for this step.

Manual fallback remains:

- The user deliberately copies or edits available message content and sends it through the existing ordinary composer.
- No automatic submission, action retry, fresh conversation, or replacement recovery action follows a refusal.
- No refusal outcome becomes “recovered,” “completed,” or “verified.”
- Summarized content remains summarized; Copy must not imply recovery of discarded raw Read content.

Do not add new fallback buttons or callbacks in this step. The slices do not show their ownership or availability. If existing recovery UI copy needs clarification, use:

> History could not be verified. Nothing was sent. Sending a message manually does not verify or recover the interrupted turn.

Place such text only at an existing refusal presentation boundary after locating it; do not change the underlying failure classification merely to obtain different copy. This wording adjustment is not required for the core source step.

### B. Make tool-call status execution-aware

Keep `ToolCardStatus` unchanged. Extend the existing resolver and card, rather than adding a service or durable model.

Proposed internal interface shape:

- Before: `status(for: AgentChatItem) -> ToolCardStatus`
- After: `status(for: AgentChatItem, pairedResultStatus: ToolCardStatus?, hasActiveExecution: Bool) -> ToolCardStatus`

`pairedResultStatus` is a presentation value derived from the router’s **existing exact invocation/result pairing**:

- `nil`: no paired result;
- terminal status: a paired result with that resolved status;
- `.neutral`: a paired result exists but its outcome cannot be classified;
- never `.running`.

`hasActiveExecution` means the call belongs to the current, nonterminal consuming execution—not simply that some run in the session is active. An older call must remain inactive while a subsequent run executes. Do not use tab visibility or `isBackground`.

Resolution order:

1. An exactly paired result wins, including `.neutral` for an unclassifiable result.
2. Otherwise, resolve result/error fields already attached to the call through `ToolResultStatusResolver`, preserving its classifications.
3. Without conclusive result evidence, return `.running` only when `hasActiveExecution` is true; otherwise `.neutral`.

For attached but unclassifiable result fields, use the same active/inactive fallback as step 3. A separately paired result, by contrast, establishes that a result exists and never falls back to a spinner.

Consequences:

- Interrupted historical pending call: neutral, no spinner.
- Historical call with a known result: preserve success/warning/failure.
- Current active unresolved call: running.
- Unknown invocation ownership: neutral, not a claim of execution.
- No invented failure, cancellation, or completion.

Add corresponding immutable inputs to `ToolCallCard`’s initializer, **without defaults**. Its existing `showsCancelButton` gate then suppresses cancellation for inactive historical calls without introducing another cancellation path.

### C. Ownership, updates, and missing context

All new values are derived presentation inputs, recomputed through the existing SwiftUI rendering path. No asynchronous work, persistence, subscriptions, or cached mutable status is introduced.

Recompute on paired-result arrival and run lifecycle changes. Duplicate results follow the existing pairing rules; out-of-order results must not reactivate an inactive invocation. Missing results leave historical calls neutral.

**Exact context required before editing the callers:**

- The complete `ToolCallCardStateResolver` declaration and every `status(for:)` caller.
- Every `ToolCallCard(...)` construction and the enclosing router’s input properties.
- The existing call/result pairing code and its invocation identity.
- The existing mapping from the rendered item to its owning turn/run, including interrupted and superseded executions.
- The observation mechanism that invalidates that row when run state changes.

These are not present in the slices. Locate them by those symbols; do not invent a new pairing algorithm or infer ownership from tool names. If only session-wide activity is available, obtaining exact ownership is the sole prerequisite expansion—do not silently substitute that weaker boolean.

### D. Focused validation

Add resolver/routing tests covering:

1. Unresolved historical call → neutral; unchanged canonical item.
2. Active unresolved call → running.
3. Old unresolved call while another run is active → neutral.
4. Exactly paired success, warning, failure, and unclassifiable result → corresponding non-running status.
5. Existing attached result/error fields retain their classifications.
6. Active → interrupted transition removes spinner and cancel affordance.
7. Foreground/background tab changes alone do not change execution status.
8. A late paired result changes presentation without mutating the protected call.
9. Unknown ownership → neutral.

Add recovery regressions using fixtures/stubs, not provider prompts:

- Missing digest on an earlier known entry still refuses an otherwise valid new frontier.
- A summarized Read plus retained association does not regain storage-comparison eligibility.
- A blocked reconciliation invokes dispatch zero times and records `.notDispatched`.
- `.associationUnavailable` also invokes dispatch zero times.
- Exercise the new-conversation action with reconciliation enabled; proof refusal must not reach its target-clearing dispatch.
- Preserve existing production-OFF coverage.

Do not rerun all 435 tests by default: run affected suites plus required compile/style checks.

## 4. File-by-file impact

| File | Change and dependency |
|---|---|
| `Sources/RepoPrompt/Features/AgentMode/Views/ToolCards/ToolCardRouter.swift` | Modify resolver signature, `ToolCallCard` inputs, and in-file callers. Depends on validating existing pairing and invocation ownership. |
| Additional files constructing `ToolCallCard` or calling its resolver | Supply required context atomically with the signature change. Exact paths require the missing caller context above. |
| `Tests/RepoPromptTests/AgentMode/ToolCards/ToolCallCardStateResolverTests.swift` — proposed test file | Add status truth-table and lifecycle-context coverage; extend the existing equivalent if already present. |
| `Tests/RepoPromptTests/AgentMode/Recovery/` — existing reader/import/runner suites | Add the bounded refusal regressions above. Exact filenames are absent from the provided tree. |

`ToolCardStatus.swift`, the reader, import preflight, recovery runner, and recovery view-model behavior need **no production changes**. No persisted schema changes or migration.

## 5. Implementation order

1. Validate the missing router/caller context; record the exact source and test paths.
2. Add proof-refusal regression tests against unchanged recovery behavior.
3. **Atomically** update resolver, card initializer, and all callers; add presentation tests.
4. Run affected tests and required compile/style checks.
5. Main performs the prescribed fresh A/B review process on that bounded diff, attaching the review policy verbatim. No provider prompts or additional live runs.
6. Record this step’s result separately from production qualification and final live acceptance.

## Recommendations

- **Proceed:** proof-preserving historical-tool presentation, with bounded recovery regressions.
- **Reject for this step:** proof reconstruction, ledger pruning, invalid-entry skipping, raw retention, and new continuation bypasses.
- **Keep activation OFF.** O21 qualifies only the isolated installed-CLI observations described; it does not qualify app integration.
- **Owner-only product question:** if “verified Resume” promises recovery for *every* interrupted run, permanently lost proof remains an unresolved coverage blocker. Recommend preserving refusal and explicitly documenting that blocker—not silently redefining manual sending as verified recovery. No owner answer is needed to implement this reversible presentation fix.
