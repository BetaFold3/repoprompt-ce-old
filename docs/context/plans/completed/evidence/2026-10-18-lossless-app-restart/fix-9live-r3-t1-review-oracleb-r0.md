# 9-live round-3 T1: OracleB review, round 0
Scope: read when the task touches Claude Reconcile or Continue when live output cannot be matched to Claude history.
Authority: Reference
Last-verified: 2026-10-29
Covers: OracleB review, round 0



# Review: T1 fix for withheld Claude import (option B)

I found no P0 or P1 issues, so nothing in this diff is a must-fix before merging. I reviewed the diff and the files you supplied but didn't build or run anything.

The diff adds `.canonicalOutputImportWithheld` to `AgentProviderHistoryAssociationPreflight.check`. It's returned only when all of these hold:

- the outbound claims matched exactly (`claimed != nil`);
- every earlier check passed (baseline, user association, item‑less rows, enumerability);
- `canonicalPayloadRefusal` found no problem;
- the only failure is canonical output IDs that aren't associated.

The view model maps that case, for an unconfirmed completion only, to `.nothingImported(…)`. It returns before the planner, so nothing changes: no rows, ledger, receipt, cursor or dirty flag. The runner's existing `stopBeforeDispatch` gates then decide whether Continue proceeds. The two older association refusals now have their own texts. Tests cover the K1/K3/K4 shape, claim mismatches, unsupported history, a rewritten prefix and a second kill.

Checked against your acceptance criteria:
- **Ordering:** any other refusal still wins. The legacy path (`claimed == nil`) still refuses before the payload check, exactly as before. With exact claims, `canonicalPayloadRefusal` runs before the withheld verdict, so a conflicting or unprovable known association still blocks.
- **Fails closed:** the new case sits in the refusal enum, so any other caller that treats a non‑nil result as "block" stays safe.

## P2 — Consider

### 1. The second‑kill orphan rows are only blocked by chance; with no live output in the second turn they get imported
**Files:** `AgentProviderHistoryImport.swift:401-418` (unchanged logic); test `testSecondKillAfterAResumeWithholdsTheOrphanResultAndSendsOnce`.

The new test passes only because the second turn also has an unassociated live Bash row. Suppose the continuation is killed before it produces any live output, or its only output qualified for deterministic IDs:
- canonical output after the second dispatch is then `∅` (or fully associated), so `check` returns `nil`;
- the planner then appends Claude's resume‑written interrupted `tool_result` (an orphan, whose call is before the frontier) and the "No response requested." text.

That failed Bash result duplicates what the first turn's live row already shows. This isn't introduced by this diff; §4 of the diagnosis predicted it. But option B makes it much easier to reach, because Continue after a Bash kill now works. The test name also suggests the orphan case is covered when it isn't.

**Suggestion:** add a composition test for that shape with an empty or associated second turn, and pin today's behaviour, even if it's a known gap. Then decide separately on a reader or preflight rule for orphan `tool_result`s whose `tool_use` lies before the frontier. Until then, rename the test so it doesn't overclaim.

### 2. The new `.nativeUserAssociationUnavailable` text can state something false
**File:** `AgentModeViewModel+RecoveryActions.swift:1664-1665`

The text says "Claude's history has a message from you that RepoPrompt couldn't safely match". That refusal also fires from `guard Set(baseline.userItemIDs).isSubset(of: associatedUserItemIDs)`, which is about a *local* user item having no association. In the legacy/no‑claim path, Claude's history may hold no such entry at all, so the text claims something that wasn't observed.

**Suggestion:** use neutral wording, e.g. "A message of yours couldn't be safely matched between this conversation and Claude's history. Nothing was imported or sent." Or split the two sub‑causes if the diagnostic value matters (T2).

### 3. Missing test: exact claims plus non‑enumerable (compacted) output must still block
**Files:** `AgentProviderHistoryImport.swift` (the `guard case let .enumerated(ids)` before the new branch); the new preflight unit test around `AgentRecoveryReconciliationTests.swift:1655`.

The new unit test covers claim, legacy and payload precedence, but not `.notEnumerable` together with `.associated` claims. That ordering is what stops the withheld verdict from covering a compacted turn. A later refactor that moves the enumerability guard below the new branch would silently turn a compacted turn into "withheld, Continue proceeds".

**Suggestion:** add one assertion with a compacted or non‑full turn holding the dispatch and exact claims, expecting `.canonicalOutputAssociationUnavailable`.

### 4. Please confirm `.sendSaved` can't reach the withheld path for a delivered attempt
**File:** `AgentRecoveryActionRunner.swift:340-356`

The withheld verdict needs an exact claim match, which proves Claude already received the dispatched message. If `.sendSaved` (or `.questionAnswerAsInput`) has `reconcilesBeforeDispatch` and is eligible for a `deliveryUnknown` attempt, `.nothingImported` would fall through and resend the saved intent. That would be a replayed send.

The same exposure already existed on the "imported, unconfirmed" path, so this diff doesn't create it, but it does make the path reachable much more often. I couldn't confirm eligibility from the supplied context.

**Suggestion:** check that `sendSaved` is limited to never‑handed‑off attempts. If it isn't, add a runner test showing it's refused on the withheld path.

## P3 — Minor

- **The warning text shows in the exact case it was built for:** `AgentModeViewModel+RecoveryActions.swift:1278-1281`. `hasNativeOutput` is true in the K1 shape, where the only native row is the Bash `tool_use` the conversation already shows. Users will see "some of it may not show here" on every Bash interruption, even when nothing is missing. "May" keeps it honest, but if you can cheaply say "Claude has output beyond the interrupted tool call", the warning would mean more.
- **Unreachable fallback text:** `recoveryAssociationText(.canonicalOutputImportWithheld)` at `:1668-1669` only matters for a confirmed Claude completion, which can't happen. That's fine for exhaustiveness. A short comment saying so would stop someone later reading it as a normal blocking path; the text also lacks the "or sent" the blocking texts carry.
- **A "refusal" that isn't one:** `.canonicalOutputImportWithheld` lives in `AgentProviderHistoryAssociationRefusal`, whose type doc says every refusal blocks, yet this case lets Continue proceed. That's acceptable and fails closed, but the type‑level doc should name the exception so a later caller doesn't miss the special‑casing.
- **Stale sections in the evidence doc:** `diag-9live-r3-t1-worker.md`
  - The header says "read‑only diagnosis… No source edits", but the file now ends with a Changes section.
  - §3 ("keep `:4294` unchanged") and §5 item 2 ("must still refuse, and Continue must stay blocked") contradict the contract that shipped.
  - Mark those sections as superseded by option B, or move the Changes section to its own report.
- **Test assertion label:** at `AgentRecoveryReconciliationTests.swift:1537-1540` the check labelled "without exact claims, nothing is withheld: it refuses" returns `.nativeUserAssociationUnavailable` before the output branch, so it never reaches the `claimed == nil` output path. The new unit test's ledger case does cover that path; relabel this one so it says what it checks.

## Recommendations

1. **Merge as is from a P0/P1 standpoint.** The precedence and no‑mutation guarantees hold as written.
2. **Before the next live run (V5/V6/E2):**
   - add the compacted‑turn assertion (P2‑3);
   - add the empty‑second‑turn orphan composition test (P2‑1). That orphan shape is the most likely next live surprise now that Continue works after a Bash kill.
3. **Confirm the `sendSaved` eligibility rule (P2‑4)** and record the answer in the evidence doc.
4. **Fix the wording of the `.nativeUserAssociationUnavailable` text (P2‑2)** while the texts are being split anyway.
5. **Keep "persist the native `toolu_` id on live tool rows" as the durable follow‑up.** It's the only fix that removes the withheld case instead of reporting it.