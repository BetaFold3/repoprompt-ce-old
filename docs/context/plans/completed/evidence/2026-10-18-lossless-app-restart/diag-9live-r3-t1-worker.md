# 9-live round 3, T1: why Claude Reconcile and Continue still refuse
Scope: read when the task touches Claude Reconcile or Continue matching earlier messages in a conversation.
Authority: Reference
Last-verified: 2026-10-29
Covers: read-only diagnosis of T1 from the round-3 live check
Content: cause with file:line and record evidence (IDs/structure only), the smallest fix, the next blocker if any, and unit tests that would have caught it.

This is a read-only diagnosis on HEAD `f6c87229`. No source edits, builds or tests were run.

> **Superseded in part:** this header's "smallest fix" is replaced by option B, implemented later with edits and tests (see Changes).

- **Records read:** the K1/K3/K4 (and K2) agent session files, the recovery records and the Claude history files.
- **What was printed:** only IDs, record types, key names, byte offsets, line numbers and digest-equality booleans. No message text, tool input or tool output was printed or saved.
- **Scripts:** `.agent-artifacts/t1-diag/` (git-ignored), run with `python3 -I`.

## Cause in one paragraph

The refusal is **`.canonicalOutputAssociationUnavailable`**, returned at `AgentProviderHistoryImport.swift:395-396`. It is not the native-user case, and the warm-up turn plays no part.

For each fixture, everything up to that check passes:

- the kill turn's baseline was **captured** and carries an outbound claim;
- the only native user entry after that baseline is the kill prompt, whose `uuid` and digest equal the claim, so `claimAssociation` returns `.associated`.

What fails is the next check. After the kill turn's user item, the canonical transcript holds the **live Bash tool row**, and that row has no association to any native row.

- The live producer gives deterministic, reader-matching IDs only to single-text answers and `Read` exchanges (`ClaudeLiveTranscriptQualification.swift:1-27`). A Bash `tool_use` disqualifies it.
- The translator replaces Claude's `toolu_…` id with a random invocation UUID (`ClaudeSDKNDJSONTranslator.swift:297-303`), and only that UUID is persisted.
- The live row's ID therefore never equals the reader's deterministic `toolCall` row ID for the same native entry. The ledger has no `nativeItems`.

The refusal itself is correct: importing would show the Bash call twice. But `associationUnavailable` blocks every continuation (`AgentRecoveryActionRunner.swift:352-353`), so **any interrupted Claude turn whose live output included a non-`Read` tool call can never be continued.** That is every K1/K3/K4-shaped fixture.

## 1. Which refusal, and where

- **The text:** `AgentModeViewModel+RecoveryActions.swift:1649-1650`. It is shared by `.nativeUserAssociationUnavailable` and `.canonicalOutputAssociationUnavailable`.
- **Which call site:** the text can only come from `:1265-1277`, the full preflight after a successful history read.
  - The other site, `:1206`, only returns `baselineRefusal` cases (`baselineUnavailable` or `baselineTargetMismatch`).
  - So the history read succeeded, and the baseline was found and matched.
- **The steps inside `AgentProviderHistoryAssociationPreflight.check`** (`AgentProviderHistoryImport.swift:328-404`) for K1/K3/K4:

| Step | Line | Result |
|---|---|---|
| `baselineRefusal` (captured, cursor, same conversation, generation and run attempt, user items present) | 339-347, 809-828 | passes |
| `outputItemIDs(after: baseline.userItemIDs)` | 350-352 | `.enumerated({live Bash row})`: every turn is `full` and none is compacted |
| `claimAssociation(window:)` | 354-366, 751-786 | **`.associated`**: one claim; native user entries after the frontier are exactly `[claim uuid]`; digest equal; the constituent is in the canonical view |
| every baseline user item is associated | 372-384 | passes (claimed constituent) |
| no unclaimed item-less row | 387-389 | passes: the only item-less row is the claimed user row; attachments project no rows |
| canonical output is enumerable | 390-392 | passes |
| **canonical output ⊆ (ledger `localItemID`s ∪ observation row item IDs)** | **393-397** | **fails**: ledger empty; observation item = deterministic `toolCall` ID of the native `tool_use` entry; canonical = the live Bash row's random ID |

### Record evidence

**Dispatch baselines** (`providerHistoryRecovery.dispatchBaselines` in each `AgentSession-<id>.json`). The kill turn is the attempt whose recovery-record outcome is `deliveryUnknown`. The "Later send" column is the turn sent after the refusal.

| Fixture | Warm-up baseline | Kill-turn baseline | Later send |
|---|---|---|---|
| K1 `0AED4A8E` | `1C58F5D2`, run `74BA1C12`: **unsupported** ("no Claude conversation identity before sending"), no claim | `734AFD77`, run `C5D0B637`: **captured**, offset 495812, claim uuid = dispatchID | `BA408EEB`, run `042A5DCE`: captured, offset 502768, claim |
| K3 `258136C1` | `BDD84828`, run `7332EDFB`: **captured**, offset 0 (file absent), claim | `F065DE22`, run `C5304D8F`: **captured**, offset 495820, claim | `73D4A5A7`, run `7289DF70`: captured, offset 502773, claim |
| K4 `2B40196C` | `2F3F21C3`, run `02A0B12C`: **unsupported** (no identity), no claim | `F64BA899`, run `C73A6FFA`: **captured**, offset 495820, claim | none |
| K2 `4BB73911` (control) | `F3FF52E2`: unsupported (no identity) | `29249156`: captured, offset 495820, claim | none |

- Every session's ledger has **0 `nativeItems`**. `lastImportCommit` is a 0-row baseline receipt.
- **Recovery-record actions:**
  - K1: `reconcileOnly` on `C5D0B637`, `notDispatched` with the T1 text.
  - K3: `reconcileOnly` twice on `C5304D8F`, both `notDispatched` with the T1 text.
  - K4: `continueWithText` on `C73A6FFA`, `notDispatched` with the T1 text.

**Native history after the kill-turn baseline**, at reconcile time. The files were 34 lines, matching `cycle16/after-b/k1-before-e2.txt` and `k3-before.txt`.

| Fixture (file) | Line 29 | Line 30 | Line 34 |
|---|---|---|---|
| K1 `37b27f87…` | user, one `{type,text}` block, uuid `734afd77` (= claim, digest equal) | attachment `total_tokens_reminder` | assistant `[tool_use]` (Bash) uuid `dc722d8b`, no result |
| K3 `a8e6b1b9…` | user uuid `f065de22` (= claim, digest equal) | same | assistant `[tool_use]` uuid `3f3d38ec`, no result |
| K4 `5ae97b34…` | user uuid `f64ba899` (= claim, digest equal) | same | assistant `[tool_use]` uuid `43454d67`, no result |

Lines 27-28 and 31-33 are `queue-operation`/`api-request*` records, which have no graph identity.

**Canonical turn of the kill dispatch:** request = the claimed user item. It has one activity:

| Fixture | Activity |
|---|---|
| K1 | `749F222E` |
| K3 | `AEA2A433` |
| K4 | `855D1429` |

Each is `itemKind toolResult` with `toolExecution`: `toolName bash`, `status failed`, `summaryOnly true`, and `invocationID`/`stableExecutionID` that are plain UUIDs, not `toolu_…`.

**Digest check:** every claimed native prompt (all 7 claims across K1-K4) has the uuid and SHA-256 equal to its claim. Each warm-up prompt that had no claim (K1 `11022935`, K4 `dd6029db`, K2 `5cb33ceb`) lies before the kill turn's frontier.

## 2. The verifier's guess is ruled out

- **The warm-up isn't in the claim window.** The window is `dispatchBaselines.filter { $0.runAttemptID == sourceRunAttemptID }` (`RecoveryActions.swift:1212-1214`). Each warm-up is its own run attempt.
- **Native user entries before the baseline are never considered.** `userMessageEntries` keeps only `isNew` entries, those at or after the cursor frontier (`ClaudeSessionHistoryReader.swift:502-504`). The import rows use the same filter (`:501`).
- **K3 is the counterexample.** Its warm-up was itself captured and claimed, yet K3 refused identically.

The rule the guess suggests ("only native user entries after the interrupted dispatch's baseline must match its claims, in order") is **already the implemented rule**, and it is the right one. The baseline's byte-prefix fence pins everything before it, and every user entry after it must be claimed, which is the double-send guard. No change is needed there.

## 3. The smallest correct fix

> **Superseded by option B:** this shape-match rule was not implemented; see Changes.

Today's refusal protects against a real duplicate: the native `tool_use` row would be appended next to the live Bash row. Neither of these fixes is right:

- **Relaxing the association** would duplicate the call.
- **Codex-style blanket withholding** (`codexOverlapRefusal` → `.nothingImported`, `RecoveryActions.swift:1281-1295`) would flip a deliberately tested Claude contract. `AgentRecoveryReconciliationTests.testUnassociatedLiveOutputInALaterPersistedTurnRefusesWithoutChangingAnything` (`:4294`) has native output that isn't shown live (the first dispatch's reply `a1`). Hiding that output while letting Continue go ahead would be a real loss.

**Proposed rule ("live output already covers the history"), needing main/owner sign-off because it narrows review A P1-02 ("associationUnavailable blocks every continuation"):**

In `check`, when **all** of these hold:

1. the claim association is `.associated` (exact claims, so no unknown user entry, so no double-send risk);
2. canonical output after the boundary is `.enumerated(ids)`, with `ids` not a subset of the associated set (the current `:395` failure);
3. the observation's new projectable rows (`item != nil`) add nothing that isn't already shown. Their unit sequence must equal the unit sequence of the **unassociated** canonical output after the boundary, in canonical order:
   - **native units:**
     - each assistant text row → `text(row.text)`;
     - each `toolCall` row → `tool(normalizedToolName(name))`;
     - each `toolResult` row must pair, by `toolUseID`, with a `toolCall` row of the same observation and folds into that unit. A result whose call lies before the frontier makes the check fail.
   - **canonical units:**
     - an assistant or assistantInline item → `text(item.text)`;
     - an item with a `toolExecution` (or a toolCall/toolResult pair with the same invocation ID) → `tool(toolName)`, one unit per execution;
     - thinking items are skipped, because native thinking projects no rows.
   - Text must match exactly. Tools match by normalized name only, because the live row is `summaryOnly`. Use `AgentTranscriptToolNormalizer.normalizedToolName`, as `comparePayload` does at `:638-639`.

…return a new, distinct refusal (for example `.canonicalOutputAlreadyShown`). The caller at `RecoveryActions.swift:1265-1277` maps it to **`.nothingImported(<new text>)`**: zero rows, ledger and cursor unchanged, as in the Codex precedent at `:1292`. Every other case keeps `.canonicalOutputAssociationUnavailable` and still blocks.

Draft text: "Claude's history for the interrupted turn shows only what this conversation already shows, so nothing new was imported."

Why this is safe and correct:

- **No duplicate:** zero rows are planned.
- **No double send:** exact claims are required.
- **No false completion:** a Claude observation is always `.unconfirmed`.
- **No hidden output:** any extra native row (a reply or a result not shown live) breaks the sequence equality and keeps today's refusal, so `:4294` still holds unchanged.
- **For K1/K3/K4:** native units = `[tool(bash)]` and canonical unassociated units = `[tool(bash)]`, so the result is `.nothingImported`.
  - Reconcile-only records `notDispatched` with the new text.
  - Continue's `stopBeforeDispatch` falls through: the attempt has no terminal, it is an interruption, it is `deliveryUnknown` (not never-handed-off), and the generation is the same.
  - The continuation is then dispatched.

**Diagnostic split (also recommended, tiny):** give `.nativeUserAssociationUnavailable` and `.canonicalOutputAssociationUnavailable` different texts at `:1649-1650`. Today the shared text made T1 impossible to tell apart live, which is related to T2.

**Durable direction (not small; later):** persist Claude's native `tool_use` id on live tool items. The translator has it at `ClaudeSDKNDJSONTranslator.swift:298-303`. The preflight could then associate live tool rows by identity instead of by shape. This only helps sessions recorded after the change.

## 4. What comes next for these fixtures once the fix lands

Traced against the records; no throwaway test was run.

- **Continue dispatch:**
  - The continuation's own baseline capture runs on exactly this file shape: 34 lines ending in an unanswered `tool_use`. That is proven live: K1 `BA408EEB` (offset 502768) and K3 `73D4A5A7` (offset 502773) were captured **and claimed** on that shape.
  - The fence against `lastImportCommit` (the kill-turn receipt) verified at that time too.
  - The send went through once in each case (one "after" entry each).
  - **No further blocker is expected on Continue.**
- **Gates before Continue:** K4's Continue reached reconcile, so the hold and lane gates already pass.
- **K3's record cursor** is still the warm-up's (`A69BD14E`, offset 0), because a baseline commits the record cursor only when none exists (`RecoveryActions.swift:1115-1116`). An offset-0 fence is trivially true, so it doesn't block.
- **Tool turns (V5 on K3/K4):**
  - With the fix, Reconcile returns "nothing new" rather than a refusal. That is accurate: the history after the baseline holds only the prompt and the Bash call already shown.
  - The Bash result doesn't exist yet. Claude writes it only at the next resume: K1/K3 line 37 is a user `tool_result` with `is_error: true`, `toolUseResult`, `toolDenialKind` and `sourceToolAssistantUUID`; line 38 is an assistant `<synthetic>` text with `isApiErrorMessage` present (not true).
  - It is useful, because Continue is then unblocked.
- **A later issue (not a blocker now):** those resume-written lines 37-38 fall *after* the continuation's baseline and *before* its prompt (K1/K3 lines 37-39).
  - If that continuation turn is itself interrupted and reconciled, the `toolResult` row's call lies before the frontier. Under the proposed rule that makes the check fail, so Reconcile refuses (safe).
  - Without the rule (no unassociated live output), it would import an orphan "failed" result plus the synthetic assistant text.
  - This only matters for a second kill in the same conversation. It is worth a unit test, and possibly a reader rule tied to the `<synthetic>` model and its interrupted-result pairing, decided separately.
- **T3 (the row lost Continue… and Check provider history):** both come from `recoveryRunActions`, which returns `[]` when the row's session isn't the open one (`RecoveryActions.swift:61`). Both disappearing together fits that. It is by design (an inference; the UI state wasn't traced).

## 5. Unit tests that would have caught it

All go in `AgentRecoveryReconciliationTests`, using the existing harness (`admitClaimedDispatch`, `appendHistory`, `reconcileAction`).

1. **`testInterruptedClaimedBashTurnWhoseLiveRowCoversHistoryReconcilesAsNothingNewAndContinues`**
   - **Setup:**
     - a first turn sent without identity, so its baseline is unsupported;
     - a claimed kill dispatch in its own run attempt;
     - native history after the baseline: the claimed prompt as one `{type,text}` block, a `total_tokens_reminder` attachment, and an assistant `[tool_use Bash]` with no result;
     - canonical turn 2: a live `toolExecution` item (`bash`, random invocation UUID, `summaryOnly`, `failed`).
   - **Today:** `.associationUnavailable(.canonicalOutputAssociationUnavailable, …)`.
   - **After the fix:** `.nothingImported`, with items, ledger and cursor unchanged; Continue dispatches exactly once.
   - This is the exact K1/K3/K4 shape. Existing tests use only live text items or `Read` exchanges.
2. *(Superseded by option B: this shape now withholds the import and Continue proceeds; see Changes, `:4683`/`:4391`.)* **Negative twin:** the same, plus a native `tool_result` and a final assistant text that aren't shown live. It must still refuse, and Continue must stay blocked. Keep `:4294` unchanged.
3. **Preflight unit (pins the ruled-out guess):** `claimAssociation`/`check` with an unclaimed, unsupported warm-up baseline in another run attempt and its native prompt before the frontier gives `.associated`. Earlier turns must never matter.
4. **Text split:** the two association refusals map to different texts.
5. **Later issue:** a continuation baseline captured before resume-written lines 37/38. Reconcile of that turn must refuse rather than import the orphan result.

## Validation

None run: read-only diagnosis. The scripts in `.agent-artifacts/t1-diag/` are git-ignored and print only IDs, structure, offsets and booleans.

`Scripts/check-agent-context` reports this report as an orphan, like the S1 report before it. It needs a link from a reachable document, which is main's call.

## Changes (option B: verified claims, output import withheld; not committed or staged)

Main chose OracleA's option B (`prompt-exports/oracle-plan-2026-10-29-140908-9-live-r3-t1-plan-a-cb63.md`) instead of the shape-match rule proposed in §3. The texts are main's shorter wording.

**What B accepts.** When only output association fails, the whole import is withheld, so some of Claude's output may not show in the conversation. The withheld text says so. Persisting Claude's native tool ids on live rows (§3, "Durable direction") remains the follow-up that would let that output be imported safely.

### Code

- **`AgentProviderHistoryImport.swift`:**
  - `:231-236`: new refusal case `.canonicalOutputImportWithheld`, with a doc comment.
  - `:334-335`: the `check` doc says when that case is returned.
  - `:401-418`: the early return on uncovered output is restructured:
    - **Without exact claims** (the ledger-only/legacy path), uncovered output still returns `.canonicalOutputAssociationUnavailable` at once (`:404-406`). Precedence there is unchanged.
    - **With `claimAssociation == .associated`**, the gap is only recorded. `canonicalPayloadRefusal` (conflicting or unprovable known associations, order) runs first and wins. Only then does an uncovered gap return `.canonicalOutputImportWithheld` (`:418`).
    - Baseline, prefix, claim, user-association, item-less-row and enumerability refusals all come earlier and are untouched.
- **`AgentModeViewModel+RecoveryActions.swift`:**
  - `:1260-1265`: comment updated. It used to say that all unassociated live output refuses.
  - `:1278-1281`: only `.canonicalOutputImportWithheld` with an `.unconfirmed` completion maps to `.nothingImported(…)`. The return comes before the planner, so there is no ledger, receipt, row, cursor or dirty-session change. Every other refusal, and a (currently impossible) confirmed completion, keeps `.associationUnavailable`.
  - `:1350-1357`: two new texts, chosen by whether the observation has a projectable native row (`rows.contains { $0.item != nil }`; a claimed prompt row carries no item):
    - `recoveryClaudeOutputWithheldText`: "Claude's history has output RepoPrompt couldn't safely match to this conversation. Nothing was imported, so some of it may not show here; Claude still has it."
    - `recoveryClaudeOutputUnmatchedText`: "RepoPrompt couldn't safely match this conversation's output to Claude's history. Nothing was imported."
  - `:1664-1669`: the shared text is split:
    - `.nativeUserAssociationUnavailable` (neutral after review round 0, P2-2): "A message of yours couldn't be safely matched between this conversation and Claude's history. Nothing was imported or sent."
    - `.canonicalOutputAssociationUnavailable`: "Output shown in this conversation couldn't be safely checked against Claude's history. Nothing was imported or sent."
    - `.canonicalOutputImportWithheld` falls back to the unmatched text (exhaustive switch).
- **`AgentRecoveryActionRunner.swift:70-71`:** doc comment only, on `.nothingImported`. No logic change: `nothingImported` already lets Continue reach the unchanged gates (verified completion, never handed off, not an interruption, cleared generation, unreadable record, lane validity).

The refusal enum is transient (never persisted). Its only exhaustive switch is `recoveryAssociationText`.

### Tests (`AgentRecoveryReconciliationTests`)

**Updated to the new contract:**

- `:1527-1541` (`testOutboundClaimsAssociateOnlyAnExactNativeUserMatch`):
  - exact claims plus a live row now give `.canonicalOutputImportWithheld`;
  - added: reordered claims plus a live row → `.outboundClaimUnmatched`;
  - added: a claimless steer plus a live row → `.nativeUserAssociationUnavailable`.
- `:1625-1629` (`testCanonicalOutputOfEveryLaterPersistedTurnIsChecked`): a later turn's live output now gives `.canonicalOutputImportWithheld`. It is still never skipped.
- `:4391`: renamed to `testUnassociatedLiveOutputInALaterPersistedTurnWithholdsTheImportWithoutChangingAnything`.
  - It expects `.nothingImported(recoveryClaudeOutputWithheldText)`.
  - Every no-change assertion is kept (items, ledger, cursor). It adds that the unshown "Done." isn't imported.
  - The positive control and the replay checks are unchanged.

**New:**

- `:1655` `testWithheldOutputImportNeedsExactClaimsAndLosesToEveryIndependentRefusal` (preflight unit):
  - withheld with and without native output; `nil` when nothing is unassociated;
  - missing, extra and digest-mismatched claims → `.outboundClaimUnmatched`;
  - legacy (no claims) → `.nativeUserAssociationUnavailable`, or `.canonicalOutputAssociationUnavailable` with a ledger user association;
  - an equal known association plus a later live row → withheld;
  - a conflicting known association → `.canonicalPayloadMismatch`;
  - an unprovable one → `.canonicalPayloadUnavailable`.
- **Real composition** (real reader, persistence, recovery store and runner; the dispatch performer only records the text it is handed). Fixture helpers: `killTurnHistory`, `makeKilledBashTurn` and `continueThroughRunner`.
  - **The K1 fixture:** a warm-up recorded unsupported (no identity, unclaimed native prompt), then a claimed kill turn. Native after its baseline: the prompt as one `{type,text}` block, a `total_tokens_reminder` attachment, and a Bash `tool_use` with no result. The live `bash` row has a random invocation ID.
  - `:4653` `testKilledClaimedBashTurnWithholdsTheImportAndContinueSendsTheEditedTextOnce`, on the exact K1/K3/K4 shape:
    - Reconcile twice gives the withheld text, with items, ledger, pending receipt and cursor unchanged.
    - Continue hands the edited text to dispatch exactly once.
    - The same request repeated `.joined`, so it is never sent twice.
  - `:4683` `testWithheldImportNamesWhetherClaudeHasOutputAndContinueProceeds`:
    - result plus reply not shown locally → withheld text, and Continue proceeds;
    - only the claimed prompt → unmatched text, and Continue proceeds;
    - the two withheld texts differ, and the two blocking association texts differ.
  - `:4725` `testWithheldImportNeverCoversAClaimMismatchUnsupportedHistoryOrARewrittenPrefix`, each with the same live row:
    - an extra unclaimed user entry and a changed prompt → `.outboundClaimUnmatched`;
    - an unsupported attachment (`hook_success`) and a same-length rewrite before the baseline → `.blocked`;
    - in every case Continue dispatches nothing, and items, ledger and cursor are unchanged.
  - `:4781` `testSecondKillAfterAResumeWithholdsTheOrphanResultAndSendsOnce`, pinning the second-kill shape:
    - After the continuation's baseline come Claude's resume-written interrupted `tool_result` (`is_error`, `toolUseResult`, `sourceToolAssistantUUID`) and a reply ("No response requested."), then the claimed continuation and a new Bash call.
    - The reader accepts the resume entries. The import is withheld: no orphan result and no synthetic row.
    - The first kill's attempt now refuses with `.outboundClaimUnmatched`, because the continuation is an unclaimed user entry in its window.
    - Continue on the second attempt sends its text once.

Not added from OracleA's list (the runner is unchanged, and these gates have their own existing tests):

- per-gate runner regressions on the withheld path (verified completion, never handed off, generation change, unreadable record, session changed during the read);
- cancellation before handoff;
- the uncertain-handoff outcome.

### Validation

| Command | Result | Ticket |
|---|---|---|
| `make dev-test FILTER=AgentRecoveryReconciliationTests` | 84/84 passed (also on the first run, before the lint fix) | `940e3c6c-0662-4d52-a0ff-c0b6604133e6` (final), `edebb824-…`, `4b581ede-…` |
| `make dev-test FILTER=ClaudeSessionHistoryReaderTests` | 45/45 passed | `1f45be9f-7686-4ebe-81e2-3fc113ca844a` |
| `make dev-test FILTER=AgentRecoveryStartupCompositionTests` | 23/24. The one failure (`testCompositionAndViewModelDefaultReadTheOneProductionActivation`, `:873`) asserts `production == .off`. It comes from the uncommitted `production = .claudeAndCodex` line in `AgentRecoveryActivation.swift`, not from this change. | `4b59f435-abe5-4d49-933c-cfdfbee056a9` |
| `make dev-lint` | passed, 0/2207 files need formatting, after one `hoistAwait` fix in the new test helper | `e4bf9f70-9c25-44b9-a200-95dd6ba30109` |

Not run:

- the full suite;
- `AgentRecoveryActionTests`: it builds a `.nativeUserAssociationUnavailable` result with its own literal text and doesn't read the mapping;
- any live check.

V5/V6/E2 on Claude need another live run on a build with this change.

### Review round 0 follow-up

- **B P2-4 (read-only):** `.sendSaved` and `.questionAnswerAsInput` can't reach the withheld `.nothingImported` path.
  - `reconcilesBeforeDispatch` is true only for `.continueWithText` and `.continueInNewConversation` (`AgentRecoveryActionModels.swift:37-39`). So for the other kinds the runner never runs a reconcile (`AgentRecoveryActionRunner.swift:270-273`), and `stopBeforeDispatch` returns early (`:348`).
  - `.sendSaved` also claims only a `.queued`, never-handed-off intent (`AgentRecoveryStore+Actions.swift:246-249`).
- **A/B P2-2:** the `.nativeUserAssociationUnavailable` text is now neutral (`AgentModeViewModel+RecoveryActions.swift:1665`). It is pinned in `testWithheldImportNamesWhetherClaudeHasOutputAndContinueProceeds`.
