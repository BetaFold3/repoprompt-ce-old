# 9-live round-3 T1: OracleA plan for the fix
Scope: read when the task touches Claude Reconcile or Continue when live output cannot be matched to Claude history.
Authority: Reference
Last-verified: 2026-10-29
Covers: OracleA plan for the fix

## Summary

**Choose B: claim-safe continuation with output import withheld.** Exact outbound claims protect against replaying an unknown user message; output association protects against duplicate transcript rows. When only output association fails, withhold the entire import but permit an explicitly requested continuation through the existing dispatch gates. This is simpler and more useful than N: matching tool names cannot prove that tool results are already visible, and any additional native output would make N block ordinary interrupted turns again.

## Current-state analysis

- The diagnosis establishes that K1/K3/K4 pass baseline, prefix, and outbound-claim checks. Their earlier warm-ups are not the cause.
- Claude’s native Bash call projects to a deterministic row ID; its live canonical row has a random invocation UUID. Consequently, `AgentProviderHistoryAssociationPreflight.check` returns `.canonicalOutputAssociationUnavailable`.
- `AgentModeViewModel+RecoveryActions.swift` maps that to `.associationUnavailable`. `AgentRecoveryActionRunner.stopBeforeDispatch` then blocks Continue.
- The existing `.nothingImported` result already permits continuation **without bypassing** completion, interruption, never-handed-off, generation, or record-readability checks. Reuse it.
- Import mutations occur after preflight: ledger replacement, pending commit creation, appended items, and session save. The new path must return before all of these.

**Product trade-off:** B preserves existing rows and does not delete provider history, but it does **not** guarantee a complete local transcript. If “no lost message” means every provider output must appear locally immediately, neither N nor B meets that requirement; durable native tool identity and merging are needed.

## Design

### Exact rule: verified claims, withheld output

Add a distinct preflight result case, `.canonicalOutputImportWithheld`, to `AgentProviderHistoryAssociationRefusal`. Keep `check`’s existing optional-refusal return signature; avoid a broader result-type refactor.

Return this case **only when all of the following hold**:

1. Claude history was read successfully, with all existing structural, ambiguity, unsupported-record, and prefix checks passing.
2. The captured baseline belongs to the expected conversation, source run attempt, and transcript generation.
3. `claimAssociation(window:)` is **`.associated`**: every native user entry after the frontier matches the dispatch window’s claims under the existing identity, digest, and ordering rules.
4. Canonical output is fully enumerable.
5. All applicable existing validations of explicit associations pass, including payload availability, equality, and ordering.
6. The remaining failure is that canonical output IDs are not covered by the known associations.

**Do not return this case at the current early subset-failure check without completing the other validations.** Record the output-association gap, finish validation of known associations, then classify it. Any independent refusal wins.

No text/tool-name comparison is introduced. Extra native text or valid tool results do **not** block this withheld-import path. Claim mismatch, malformed history, unsupported shapes, unavailable canonical payload, and conflicting known associations still block.

The preflight implementation was supplied only through the diagnosis; implementation must inspect its remaining checks to preserve their precedence.

### View-model mapping and state

At the Claude preflight call in `AgentModeViewModel+RecoveryActions.swift`:

- Map **only** `.canonicalOutputImportWithheld` to `.nothingImported(...)`, and only for an unconfirmed observation.
- Map every other refusal to the existing `.associationUnavailable(...)`.
- Defensively block if the new case accompanies confirmed completion; Claude is currently always unconfirmed.
- Keep the existing main-actor session revalidation immediately before preflight.
- Do not invoke the planner, write ledger associations, advance either cursor, create a commit, append rows, or mark the session dirty on this path.

Reconcile-only remains read-only with respect to conversation/history state; its action outcome may still be recorded. Continue sends only the user-confirmed continuation text through the existing runner and coordinator. It never replays the interrupted prompt.

Repeated reconciliation produces the same informational result unless history or session state changes. Double-click handling, cancellation, and handoff settlement remain unchanged.

### User-facing text

For withheld import when the observation contains projectable native output:

> Claude’s history contains output that RepoPrompt couldn’t safely match to this conversation. Nothing was imported; some output may be missing here. Claude retains its own history.

When it contains no projectable output:

> RepoPrompt couldn’t safely match this conversation’s output to Claude’s history. Nothing was imported. This conversation may be incomplete.

These describe uncertainty honestly; do **not** say “nothing new” or “already shown.” Neither claims that Continue has been sent.

Split the existing refusal text:

- **`.nativeUserAssociationUnavailable`:**  
  “Claude’s user messages couldn’t be safely matched to this conversation. Nothing was imported; continuation is blocked.”
- **`.canonicalOutputAssociationUnavailable`:**  
  “Output already shown in this conversation couldn’t be safely checked against Claude’s history. Nothing was imported; continuation is blocked.”

Keep existing claim-mismatch and baseline-specific messages.

### Required tests

Extend the existing `AgentRecoveryReconciliationTests` harness:

1. **Exact K1/K3/K4 shape:** unsupported warm-up in another attempt; claimed interrupted Bash turn; random-ID failed summary row; native call without result. Reconcile withholds import; Continue dispatches the edited text exactly once.
2. **Additional native output:** add a valid result and final reply absent locally. Still withhold everything and allow Continue; assert the incomplete-transcript notice.
3. **Existing later-turn regression:** deliberately update `testUnassociatedLiveOutputInALaterPersistedTurnRefusesWithoutChangingAnything` to the B contract. Preserve zero transcript/ledger/cursor mutations and assert honest reporting of potentially missing output.
4. **Safety failures:** claim missing/extra/reordered/digest mismatch, prefix rewrite, wrong baseline, ambiguous/unsupported history, unavailable canonical payload, and conflicting known associations all block sending.
5. **Gate preservation:** verified completion, never-handed-off, non-interruption, generation change, unreadable record, or session changes during reading cannot dispatch through the new path.
6. **Lifecycle:** repeated Reconcile sends nothing; double-clicked Continue hands off once; cancellation before handoff sends nothing; uncertain handoff retains existing conservative outcome semantics.
7. **Diagnostics:** distinguish both blocking association messages and both withheld-import messages. Include empty native output and the continuation-frontier orphan-result fixture; an independently rejected tool association must remain rejected.

## File-by-file impact

- **`Sources/RepoPromptAgentCore/AgentMode/Runtime/Recovery/AgentProviderHistoryImport.swift`** — add the distinct case and deferred classification; preserve all hard-validation checks. This location is identified by the diagnosis; verify the enum’s declaration location before editing.
- **`Sources/RepoPrompt/Features/AgentMode/ViewModels/AgentModeViewModel+RecoveryActions.swift`** — add the narrow mapping, observation-sensitive notice, and diagnostic split; update the comment asserting all unassociated live output refuses.
- **`Sources/RepoPromptAgentCore/AgentMode/Runtime/Recovery/AgentRecoveryActionRunner.swift`** — documentation only: explain the verified-claim, withheld-import exception. Leave dispatch logic unchanged.
- **Existing file declaring `AgentRecoveryReconciliationTests` under `Tests/RepoPromptTests/AgentMode/Recovery/`** — add the tests above using `admitClaimedDispatch`, `appendHistory`, and `reconcileAction`. Its exact filename was not supplied.
- **`docs/context/plans/evidence/2026-10-18-lossless-app-restart/diag-9live-r3-t1-worker.md`** — append the chosen B decision and its explicit local-transcript limitation; preserve the historical diagnosis.

## Risks and migration

No session schema or cursor migration is intended. Verify that the refusal enum is transient and audit its exhaustive switches before adding the case.

The intentional behavioral change is that unmatched output no longer universally blocks continuation. **No import means no newly duplicated transcript rows; exact claims plus unchanged dispatch gates protect against automatic or duplicate prompt sends.** An explicitly requested continuation can still cause Claude to repeat a tool operation; neither option establishes exactly-once external side effects.

## Implementation order

1. Inspect preflight validation order, enum consumers, and the existing test harness.
2. Land the preflight case, view-model mapping, exhaustive-switch updates, and core positive/negative tests **atomically**.
3. Add lifecycle and gate regressions; run recovery and provider-history suites.
4. Update comments and the decision record. Do not change activation settings or claim live acceptance without a live check.

## Recommendations

Land **B**, not N, with the incomplete-transcript notice as part of the fix. It removes the demonstrated blocker without speculative shape matching or another predictable failure when Claude has additional output. Follow separately with persisted native tool identities for lossless local reconciliation.