# 9-live fix 3 (O43): OracleA round-0 review

Scope: read when the task touches the crash-hold acknowledgement write, Check's exit proof, "It stopped", or delivery-unknown recovery rows.
Authority: Reference
Last-verified: 2026-10-28
Covers: the OracleA review of the Step 3 diff, copied from its export; no P0/P1; the owner kept only the path-neutral row text and the subset `covers` fix


## Verdict

**No demonstrated P0/P1 in the supplied diff.** Settlement and acknowledgement use the same record replacement, qualification is rechecked inside the store, and no new dispatch path is visible.

There is one **P2 projection issue** and a few targeted coverage gaps. This is a static review of the supplied material; the worker’s reported test results were not independently verified.

## Findings

### P2 — “Settled” can be inferred for an intent the settlement explicitly skipped

**Evidence:** In `AgentRecoveryModels.swift`, `crashHoldSettlementQualifies` rejects current-instance intents and attempts. However, `isSettledByCrashHoldExitProof` checks only:

- acknowledgement incarnation and intent membership;
- `deliveryUnknown`;
- attempt references to acknowledged or terminal runs.

It does **not** establish that settlement qualified or occurred. Meanwhile, `.qualifyingIntents` deliberately includes skipped intents in the acknowledgement.

**Concrete failure scenario:** Using the added store fixture:

1. Create the fixture under `instanceA`.
2. From that same instance, acknowledge `fixture.unknown` and `fixture.open` with `.qualifyingIntents`.
3. Settlement skips the intent because it belongs to the current instance.
4. The acknowledgement still lists it.
5. `isSettledByCrashHoldExitProof` returns `true`.

The catalog therefore makes an explicitly **unsettled** message informational and enables Edit. An older acknowledgement-only record containing a run-linked `deliveryUnknown` intent also passes this predicate, contrary to the worker report’s claim that such records are excluded.

**Smallest robust fix:** Persist the IDs actually qualifying for settlement alongside the acknowledgement, using extensible record metadata if available, and derive the fact from that provenance. Include already-`deliveryUnknown` intents even when their attempts already have outcomes; checking only the new outcome message would miss them.

**Regression test:** `.qualifyingIntents` skips a current-instance attempt on an earlier-instance intent; acknowledgement membership remains, but `settledByExitProof` is false and attention remains `.needsAction`.

This is P2 rather than P1 because the supplied context does not demonstrate a production admission path that creates this combination while a process remains alive.

## Safety assessment

| Concern | Assessment |
|---|---|
| Wrong run or missing run reference | Qualification requires at least one attempt and checks **every** attempt. Uncovered, nonterminal runs and missing references refuse Check. |
| Current-instance attempt | Explicitly rejected by the store qualification, independently of the intent’s instance. |
| Atomic settlement and acknowledgement | Modified intents and attempts remain local value copies until the existing single `replace(...)`. A later `.intentConflict` does not persist earlier loop changes. |
| Revision and freshness failures | Existing guards are retained; no new preceding persistent mutation is visible. |
| Alive process | Existing registry proof remains required for Check. The added live-process test exercises refusal with an uncertain message present. |
| Automatic resend | No new dispatch operation is introduced. Settled messages remain `deliveryUnknown`; the tested action producers exclude Send saved. |
| Typed text | Settlement preserves payloads. Actual Edit execution needs stronger coverage below. |

## Test gaps worth closing

The tests cover the main happy path and several refusals, but two particularly useful cases are missing:

1. **Mixed-attempt qualification:** One earlier-instance intent with both a covered earlier attempt and a current-instance attempt; separately, one covered attempt plus an untied attempt. The current same-launch test can fail on the intent’s instance alone, without exercising the per-attempt check.
2. **Real settled-message Edit:** The new row test constructs a synthetic catalog item and verifies buttons, not execution. Exercise a persisted, settled intent through the actual edit action and assert:
   - exact payload reaches the composer;
   - the intent is withdrawn;
   - no dispatch occurs;
   - a nonempty composer or failed write does not lose either text.

These are verification gaps, not demonstrated implementation failures.

## Deviation judgments

1. **“It stopped” settles qualifying intents and acknowledges the rest — accept.** This preserves the explicit manual escape hatch. Check correctly remains all-or-nothing. Skipped messages must remain needs-action; the projection issue above weakens that guarantee.

2. **Different attempt explanations for proof versus manual confirmation — accept.** This correctly distinguishes registry evidence from user confirmation. Identical row wording follows O46’s specified presentation.

3. **Stricter settled fact than acknowledgement membership — sound intent, incomplete implementation.** The additional run-reference checks help, but do not establish actual qualification or settlement.

4. **Require at least one attempt and inspect closed attempts too — accept.** This is conservative and consistent with the all-attempts qualification rule. An untied historical attempt appropriately requires manual confirmation.

5. **Allow Edit for settled `deliveryUnknown` — accept.** This implements O46, not automatic replay. Add the execution-level preservation test above.

Two additional report notes:

- **Intents-only holds still refuse:** Conservative, but it limits the terminal-run exception. The tests establish that exception only alongside an open held run; do not claim terminal-only holds are supported.
- **Qualification failure uses `.intentConflict` without retry:** Accept. A semantic qualification failure is not a transient revision conflict; ordinary revision-conflict handling remains separate.

## Recommendations

- Fix settled-state provenance so acknowledged-but-skipped intents cannot become informational.
- Add mixed-attempt qualification and real Edit preservation tests.
- Retain the atomic write and existing registry/freshness gates.
- No P0/P1 blocker is established by the supplied diff; live validation remains outstanding.