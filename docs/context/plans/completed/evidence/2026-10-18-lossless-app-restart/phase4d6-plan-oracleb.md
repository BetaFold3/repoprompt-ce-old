# Step 4d6 — OracleB planning

Scope: read when the task touches the bounded historical-tool presentation and unchanged proof-refusal work for lossless restart Step 4d6.
Authority: Reference
Last-verified: 2026-10-24

Exact preset identity verified by main; complete independent responses follow. The later continuation supersedes its initial execution-context proposal.

## Continuation after ownership scout (current guidance)

# Oracle Plan

# Revised Part B: show neutral status when a tool call has no result (option a)

## Summary

I recommend **(a)**: a tool call with no result and no error evidence shows `.neutral` whether it is live or historical. This replaces the `executionLive` parameter from the previous plan. You confirmed that no execution context tied to the specific item reaches the renderer, so that parameter can't be wired honestly. Part A (the proof-refusal early exit) is unchanged.

- **Cancel stays exactly as eligible as today.** It is gated on "no result evidence, or the resolver says running", not on the displayed status.
- **No new state or authority.** No pipeline metadata, no attempt→turn map, and no change to stored rows.
- Both changes are in `ToolCardRouter.swift`.

## How the options compare against the slices

**What the code does today**
- `AgentModeView.transcriptRowView` (3113) → `AgentMessageBubble` (291) → `ToolCardRouter.callView` (120–145). Every generic tool call ends in `ToolCallCard`.
- `ToolCallCardStateResolver.status(for:)` (967–978) returns `.running` whenever `toolResultJSON == nil && toolIsError == nil`. This is the claim that has no support.
- `showRunScopedToolCancel` (AgentModeView 3086–3103) is a heuristic. It checks that the run is running, an `activeRunID` exists, and `sequenceIndex > latestUserSequenceIndex`. It does not identify the specific call.
- `ToolCallCard.showsCancelButton` needs `status == .running` plus that heuristic, a cancel action, and a RepoPrompt tool name.
- `AgentTranscriptActivity.toItem()` copies only the execution's `resultJSON` and `toolIsError`. It does not carry any canonical execution status.
- The canonical-transcript path already maps `.pending` and `.running` to `.neutral` (`ToolCardStatus.fromTranscriptStatus`). So (a) makes the generic call card match a precedent that already ships.

**Option (b), pass "session active": reject.**
- An interrupted call keeps spinning whenever any later run is active, including right after a steer.
- It still treats a session-level fact as per-call evidence.

**Option (c), block until a new mapping exists: reject.**
- It leaves a visible false "running" state in normal post-interrupt and restart use, in exchange for tracking state you've told us to cut.

**Option (d), spin only when `showRunScopedToolCancel` is true: reject.**
- It turns the cancel heuristic into per-call liveness evidence, which you ruled out.
- A current-turn call whose result is late or was dropped would still spin for the rest of the run.
- Other callers of `callView`, which default to `false`, would behave differently from the main path.

**Option (a), cut the per-call claim: accept.** The result-driven outcome stays. "Unknown" is shown as neutral, and nothing is invented.

## What changes in behavior

| Item state | Before | After |
|---|---|---|
| No result, no error (live or historical) | `.running` (spinner) | `.neutral` |
| `toolIsError` or `toolResultJSON` present | `ToolResultStatusResolver.resolve(..., fallback: .running)` | Unchanged, fallback included |
| Cancel button | `status == .running` ∧ run-scoped gate ∧ action ∧ RepoPrompt tool | `(no evidence ∨ resolved == .running)` ∧ same gates. Same set of cases as before |

**Why the cancel gate is unchanged.** Today `status == .running` covers two cases: no evidence, and evidence that resolves (or falls back) to `.running`. The new gate names both cases explicitly. So the cancel button shows for exactly the same items as before. It still calls the run-scoped `cancelActiveToolsForRun(runID:)`, and it is never treated as proof that this particular call is running.

**What is promised now.** A missing result is never shown as running, cancelled or completed. A neutral card means "no outcome recorded". The session's active-run indicator remains the only claim about liveness.

## Design (all in `ToolCardRouter.swift`)

1. **`ToolCallCardStateResolver.status(for:)`.** Keep the signature, so no call sites need changing. Only the no-evidence branch changes, from `return .running` to `return .neutral`. The result-evidence branch, including `fallback: .running`, is untouched. That keeps the attached-result classification as it is.

2. **New static helper on `ToolCallCardStateResolver`.** It is a pure function and exists so the cancel rule can be unit-tested; it is not a framework.
   ```swift
   static func showsCancel(for item: AgentChatItem,
                           showRunScopedToolCancel: Bool,
                           hasCancelAction: Bool) -> Bool
   // (noEvidence || resolvedEvidenceStatus == .running) && showRunScopedToolCancel
   //   && hasCancelAction && MCPIntegrationHelper.isRepoPromptToolNameAfterNormalization(item.toolName)
   ```
   - `noEvidence` means `toolResultJSON == nil && toolIsError == nil`.
   - `resolvedEvidenceStatus` is computed only when evidence exists, using the same `resolve` call.

3. **`ToolCallCard.showsCancelButton`.** Delegate to the new helper.
   - `showsTimestamp: !showsCancelButton` and the header cancel view stay as they are.
   - When the button is shown, it is now rendered on a neutral card. That is intended: the button means "cancel active tools for this run", not "this call is running".

4. **Explicitly unchanged:**
   - `AgentModeView.showRunScopedToolCancel` and `cancelActiveToolsAction`.
   - `AgentMessageBubble`.
   - The core transcript builder and `toItem`.
   - The stored rows.
   - Part A of the previous plan.
   - Proof refusal, retention, imports and activation.

5. **Withdrawn from the previous plan:**
   - `status(for:executionLive:)`.
   - The `ToolCallCard.executionLive` field.
   - The router wiring for it.
   - Unknown #3 (the router's run context), which this design no longer needs.

## Usability and regression check

- **Lost during a live run:** the spinner on each in-progress generic tool card.
  - Still there: the session run indicator, the cancel button for current-turn RepoPrompt tools, and the success or failure state when the result arrives.
  - Cost: you can no longer tell at a glance which specific card is executing. I rate this P3 usability, with no lost data or results.
- **Gained:** interrupted and restored calls, calls left before a steer, and calls whose result was late or rejected no longer claim to be running. They also no longer offer cancel while idle, because cancel still requires `runState == .running`.
- **Specialized cards are not affected** (`ContextBuilderCallCard`, ask-user pending view, hidden tools), because `AgentMessageBubble` branches to them before reaching `callView`.
- **Validate:**
  - Grep `ToolCallCardStateResolver.status` for consumers outside `ToolCallCard`, such as summaries or accessibility, that read `.running` as "active". If any exist, they get the same honest `.neutral` and need no change, but list them in the review packet.
  - Grep tests that assert `.running` for a call with no result. Update them as an intended contract change, not a regression.

## Owner decision

**Not owner-only.** The change is local, reversible and presentation-only, and not externally visible. Under the review policy it doesn't wait for an answer. Proceed and record it under `assumed:`.

**Optional, non-blocking question** to include in the status report:
> "Generic tool cards no longer spin, because no per-call liveness evidence reaches the renderer. The session indicator shows run activity and cancel is unchanged. Is a per-call live spinner a requirement? (a) No, keep neutral (recommended). (b) Yes: approve a future step that carries attempt→turn ownership and paired execution status through the transcript pipeline."

If the owner picks (b), that becomes a separate step later. The cut stays in place until then.

## Minimal tests (`Tests/RepoPromptTests/AgentMode/ToolCards/`)

- **T1.** No result and no error gives `.neutral`. This replaces the existing assertion that expected `.running`.
- **T2.** `toolIsError == true` gives `.failure`. A success result gives the resolved status. Existing classification tests stay green unchanged.
- **T3.** The `showsCancel` truth table:
  - No evidence, gate true, action present, RepoPrompt tool → `true`.
  - Same but `showRunScopedToolCancel == false` → `false`.
  - Same but no action → `false`.
  - Non-RepoPrompt tool → `false`.
  - Success result present → `false`.
  - Evidence that resolves to `.running` → `true`. This pins that the cancel set is preserved.
- **T4.** None needed for stored rows. `AgentChatItem` is passed by value and the resolver is pure, so there is no mutation path to test.

Run the focused ToolCards and Recovery suites, then compile and style checks. After that, send the combined diff (Part A plus revised B) to OracleA and OracleB for review per the policy. No provider prompts are needed.

## Recommendations

1. **Choose (a).** In `ToolCallCardStateResolver.status(for:)`, change only the no-evidence branch to return `.neutral`. Keep the signature, and keep the result-evidence branch and its fallback unchanged.
2. **Preserve cancel exactly** with the pure helper `ToolCallCardStateResolver.showsCancel(...)`, gated on `(noEvidence ∨ resolved == .running)` plus the existing run-scoped, action and tool-name gates. `ToolCallCard.showsCancelButton` delegates to it. Never treat cancel as per-call liveness.
3. **Withdraw the `executionLive` design.** Don't build attempt→turn mapping or paired-status metadata, and don't touch `toItem`, the builder, stored rows, or `AgentModeView` and `AgentMessageBubble` wiring.
4. **Keep Part A unchanged:** the read-free `ledgerHasUnprovenEntries` early exit with `recoveryHistoryProofClearedText`, and the composer as the manual fallback. Proof refusal, retention, imports and activation (OFF) don't change, and final live qualification stays pending.
5. **Tests T1–T3**, plus deliberate updates to any existing tests that asserted `.running` for a call with no result. Grep for other consumers of `ToolCallCardStateResolver.status` and list them in the review packet.
6. **Not owner-gated.** Proceed and record the assumption. Ask the owner the optional question about a per-call spinner, with (a) recommended.
7. **Status line:** `Step 4d6 — todo | rounds 0/2 | open: | downgraded: | assumed: proof-cleared → refusal + composer fallback (a); unresolved generic call → neutral, no per-call liveness claim | deferred: Move-to-composer control; hide known-blocked Continue; per-call live spinner (needs owner-approved ownership/status pipeline)`.

## Initial guidance (historical)

# Oracle Plan



# Plan: proof-refusal fallback and unresolved tool-call status

## 1. Summary

This step makes two small, independent changes. Neither adds a dispatch path, a durable authority, or a stored field.

- **A. Proof-cleared Continue.** Keep the existing fail-closed refusal. Detect the cleared-proof condition before any history read, in the same place `baselineRefusal` already runs. Return `.blocked` with a message that says verified continuation isn't possible and that the composer is the manual fallback. The runner, the ledger and the reader stay unchanged.
- **B. Unresolved historical tool calls.** `ToolCallCardStateResolver.status(for:)` takes a "live execution" input. A call with no result and no live execution shows `.neutral` instead of a spinner. Stored rows aren't touched.

I recommend against extending `continueInNewConversation` or adding an unverified continue. Both would reduce the verified-Resume promise, so that is an owner decision (§5).

## 2. Current-state analysis

**Why Continue can't send after a lossy reload**
1. The refusal policy clears the producer-owned proof: `NativeItem.envelopeDigest` becomes `nil`. The associations stay.
2. In `ClaudeSessionHistoryReader.ledgerConflict` (lines 527–548), any applicable known entry must satisfy `items.allSatisfy { $0.envelopeDigest == entry.digest }`. A `nil` digest never equals the observed `String`, so the read always returns `.unsupported(.ledgerConflict)`.
3. `recoveryHistoryObservation` maps that to `recoveryHistoryChangedText`. `reconcileRecoveryHistory` turns it into `.blocked`.
4. In the runner, `stopBeforeDispatch` (lines 242–265) maps `.blocked` to `.notDispatched`. Dispatch never runs.

So the outcome is already correct and fail-closed. Only the explanation is wrong: "history no longer matches" suggests the provider's history diverged, when actually RepoPrompt's own proof was cleared. Each attempt also does a pointless history read.

**Why `continueInNewConversation` isn't a safe bypass**
- `recoveryRunActions` offers it only when `recoveryResumeUnavailableConversationID == providerSessionID`, i.e. a real resume-startup failure.
- `dispatchRecoveryContinuation` re-checks that same condition before retiring the conversation.
- If `kind.reconcilesBeforeDispatch` is true for it, its reconcile reads the old conversation and hits the same `ledgerConflict`, so it is blocked too.
- Using it for proof refusal would need three new things: a new offering predicate, permission to retire a conversation that can still be resumed, and skipping reconcile. Skipping reconcile is exactly the bypass that review A P1-02 forbids.
- The user would also lose Claude-side context without being told.

**Ordinary composer send** still works once the action hold ends. `captureClaudeDispatchBaseline` reads in `.baseline` mode with `ledger: nil`, so the cleared digests don't affect it. In production `capturesDispatchBaselines` is false. This is an honest fallback, but it is not a verified recovery.

**Tool card status**
- `ToolCallCardStateResolver.status(for:)` returns `.running` whenever there is neither `toolResultJSON` nor `toolIsError`. That covers interrupted turns and cold restores.
- `showsCancelButton` is keyed on `.running`, so the wrong status can also show a cancel button.
- `ToolCardStatus.fromTranscriptStatus` already maps `.pending` and `.running` to `.neutral` for the canonical-transcript path. That is the precedent B follows.

## 3. Design

### A. Pre-read refusal for cleared proof

**1. New predicate in `ClaudeSessionHistoryReader`.** It lives next to `ledgerConflict` so a single file owns the criterion.

```swift
package static func ledgerHasUnprovenEntries(
    _ ledger: AgentSessionProviderHistoryRecovery?,
    nativeSessionID: String
) -> Bool
// true iff any nativeItems entry has providerRaw == Self.providerRaw,
// nativeSessionID == nativeSessionID, envelopeDigest == nil
```

- It uses the same applicability filter as `ledgerConflict`.
- It is synchronous, pure and non-failing.
- `ledgerConflict` itself is not modified. A test pins that whenever the predicate is true, `read(...)` returns `.unsupported(.ledgerConflict)`, so the early exit can never be more permissive than the reader.

**2. Early exit in `AgentModeViewModel.reconcileRecoveryHistory`.**
- Placement: Claude branch only, immediately after the existing `baselineRefusal` check and before `claudeWindow` and the observation.
- Condition: `ClaudeSessionHistoryReader.ledgerHasUnprovenEntries(ledgerAtStart, nativeSessionID: conversationID)`.
- Result: return `.blocked(Self.recoveryHistoryProofClearedText)` with the default `completion: .unconfirmed`.

Rules this must keep:
- No history read, no roots lookup (`test_recoveryClaudeHistoryAccessCount` stays unchanged), no ledger mutation, no `pendingHistoryImportCommit`, no cursor commit.
- Return `.blocked`, not `.associationUnavailable`. A new `AgentProviderHistoryAssociationRefusal` case would ripple through exhaustive switches and possibly persisted diagnostics, for the same runner effect.
- Completion stays unconfirmed. Without the read nothing can be proven, and that is the same as today, because `ledgerConflict` fires before any completion evidence.

**3. New text.** One static `recoveryHistoryProofClearedText`, roughly:

> "RepoPrompt can no longer verify the history it recovered earlier for this conversation, so it can't continue the interrupted turn as a verified recovery. Nothing was sent. To continue anyway, send a new message from the composer; it won't be tracked as a recovery."

`recoveryHistoryChangedText` stays in use for genuine reader `ledgerConflict` and `rewrittenHistory` results.

**4. Runner: no change.**
- `.continueWithText` and `.questionAnswerAsInput`: `stopBeforeDispatch` → `.blocked` → `(.notDispatched, text)` → `.completed(.notDispatched, reason)`. The view model returns `reason`, which is the row's inline text.
- `.reconcileOnly`: the `.blocked` arm → `.notDispatched`.
- After `perform` returns, the hold is released and `scheduledSendCoordinator?.recordDidChange()` runs, so the composer is usable.

**5. Offering: no change.** Continue stays offered. Hiding it would remove the explanation, and the runner stays the authority. A "known blocked" catalog fact is deferred polish.

**6. Manual fallback is text only.** A "Copy/Move continuation to composer" control would need the recovery card view and `AgentRecoveryListRowProps` wiring, which are not in the provided slices. It is deferred; see the missing context list in §5.

### B. Neutral status for unresolved non-live tool calls

**1. Resolver signature (before → after).**

```swift
static func status(for item: AgentChatItem) -> ToolCardStatus
static func status(for item: AgentChatItem, executionLive: Bool) -> ToolCardStatus
```

- Result or error present → `ToolResultStatusResolver.resolve(...)`, unchanged.
- Otherwise → `executionLive ? .running : .neutral`.
- No default parameter value, so the compiler finds every call site.

**2. `ToolCallCard`.**
- New stored `let executionLive: Bool`.
- `init` gets `executionLive: Bool = true`. This keeps any previews or call sites outside the router unchanged; the router always passes it explicitly.
- `status` passes it through. `showsCancelButton` becomes false automatically because it already requires `.running`.

**3. Source of `executionLive`.** It must mean "this item's run is the session's currently active run".
- If the router's existing `showRunScopedToolCancel` is already computed from that condition, reuse it. Otherwise use the router's run-active plus active-turn context.
- **This wiring is not visible in the provided lines (968–1043).** The implementer must read the `ToolCallCard(...)` construction site in `ToolCardRouter.swift` and every other caller of `ToolCallCardStateResolver.status`.
- Acceptable fallback if only session-level `runState.isActive` is available: an unpaired call from an older turn still spins while a new run is active. That is a P3 to document, not to fix here.
- Do not use `isBackground`.

**4. Paired results.** If results can live on a separate result item instead of being merged into the call item, the router decides pairing as it does today. This change only affects calls the router already treats as unpaired.

**5. Not gated.** This is presentation-only and ships active. It is not part of `AgentRecoveryActionQualification`.

## 4. File-by-file impact

| File | Change | Depends on |
|---|---|---|
| `RepoPromptAgentCore/.../ClaudeCode/SDK/ClaudeSessionHistoryReader.swift` | Add `ledgerHasUnprovenEntries(_:nativeSessionID:)` next to `ledgerConflict` | — |
| `RepoPrompt/.../ViewModels/AgentModeViewModel+RecoveryActions.swift` | Early exit in `reconcileRecoveryHistory` (Claude, after `baselineRefusal`); add `recoveryHistoryProofClearedText` | Reader predicate |
| `RepoPrompt/.../ToolCards/ToolCardRouter.swift` | `ToolCallCardStateResolver.status(for:executionLive:)`; `ToolCallCard.executionLive`; pass it at the construction site | Router run context (validate) |
| `ToolCardStatus.swift` | No change; `.neutral` is reused | — |
| `AgentRecoveryActionRunner.swift`, `AgentProviderHistoryImport.swift` | No change | — |
| `Tests/RepoPromptTests/AgentMode/Recovery/…` | Tests A1–A5 | A |
| `Tests/RepoPromptTests/AgentMode/ToolCards/…` | Tests B1–B4 | B |

**Tests for A**
- **A1.** A ledger with an applicable nil-digest entry: the predicate is true, and the reader on a fixture returns `.unsupported(.ledgerConflict)`. This pins that the early exit matches the reader.
- **A2.** `reconcileRecoveryHistory` (Claude, qualified, baseline present, nil-digest entry):
  - returns `.blocked(proofClearedText)`;
  - the history-access count doesn't change;
  - `providerHistoryRecovery` is unchanged;
  - `pendingHistoryImportCommit` is nil;
  - no cursor commit.
- **A3.** Runner with `.continueWithText`: result is `.completed(.notDispatched, reason: proofClearedText)` and the dispatch performer is never called. With `.reconcileOnly`: the same outcome.
- **A4.** A nil-digest entry for another `nativeSessionID` or another `providerRaw`: no early exit, the read proceeds. Existing all-digests-present tests stay green.
- **A5.** After the refused Continue, the action hold is released and an ordinary `submitUserTurn` on the session is not refused by the hold.

**Tests for B**
- **B1.** No result: `executionLive: true` gives `.running`, `false` gives `.neutral`.
- **B2.** Result present with `executionLive: false` gives the resolved status (success, warning or failure). `toolIsError == true` gives `.failure`.
- **B3.** `ToolCallCard` with `executionLive: false` and `showRunScopedToolCancel: true` shows no cancel button.
- **B4.** The item is value-identical before and after the status computation.

Focused suites, compile and style checks are run as usual.

## 5. Risks, unknowns, owner decision

**Assumptions to validate**
1. *Proof clearing means `envelopeDigest = nil`, not a sentinel string.* Check the refusal-policy writer. If it is a sentinel, the predicate must match the sentinel.
2. *Whether `AgentRecoveryActionKind.continueInNewConversation.reconcilesBeforeDispatch` is true.* Read the enum. Either way, this step doesn't change it.
3. *Router run context (B3).* Read the `ToolCallCard(...)` construction site in `ToolCardRouter.swift` and how `showRunScopedToolCancel` is derived.

**Missing context for the deferred "Move to composer" control**
- The recovery card or row view that renders `AgentRecoveryListRowProps.Action`.
- Whether any run-row Edit/Copy action already exists. Today only intent rows refer to "Edit".

**Owner decision (doesn't block this step)** — should a proof-cleared conversation get an explicit unverified continuation?
- (a) No: refusal plus composer fallback. **Recommended.**
- (b) "Continue without verification": dispatch without reconciliation, recorded as unverified.
- (c) Allow fresh-conversation continuation for proof refusal.

Options (b) and (c) weaken R7 and A P1-02. If unanswered, proceed with (a) and record it under `assumed:`; it is reversible.

**Activation.** Recovery actions stay OFF (`AgentRecoveryActionQualification.production`). B ships active as a presentation-only change. No new durable data, so there is no rollback concern.

## 6. Implementation order

1. Add the reader predicate and test A1. Compiles on its own.
2. Add the view-model early exit, the new text, and tests A2–A5. Depends on step 1.
3. Add the resolver parameter, the `ToolCallCard` field, the router wiring after validating unknown 3, and tests B1–B4. Independent of steps 1–2. The resolver signature change and its call sites must land together.
4. Run focused tests, compile and style checks. Then run OracleA and OracleB reviews on the combined diff per the review policy, and save the evidence.

## Recommendations

1. **Keep the proof refusal.** Make it explicit and read-free with `ClaudeSessionHistoryReader.ledgerHasUnprovenEntries` plus `.blocked(recoveryHistoryProofClearedText)` in `reconcileRecoveryHistory`. Leave the runner, ledger, reader and associations unchanged. Don't re-mint proof, drop entries, or ignore invalid entries.
2. **Manual fallback is text only for now:** the message points to ordinary composer sending, which is untracked and not presented as recovery. A "Move to composer" control is deferred until the recovery card view context is provided.
3. **Don't widen `continueInNewConversation` and don't add an unverified continue.** That is owner decision (a/b/c); proceed on (a) and record it under `assumed:`.
4. **Ship the neutral unresolved-call status** via `status(for:executionLive:)`, sourced from the router's existing run context. Validate the construction site first. If only session-level run state is available, document the older-turn-spins case as P3.
5. **Activation stays OFF** and final live qualification stays pending. This step needs no provider prompts, which is consistent with the exhausted budget.
6. Status line: `Step 4d6 — todo | rounds 0/2 | open: | downgraded: | assumed: proof-cleared → refusal + composer fallback (a) | deferred: Move-to-composer control; hide known-blocked Continue; per-turn liveness for older unpaired calls`.
