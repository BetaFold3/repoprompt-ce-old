# 9-live fix 3 (O43): OracleB round-0 review

Scope: read when the task touches the crash-hold acknowledgement write, Check's exit proof, "It stopped", or delivery-unknown recovery rows.
Authority: Reference
Last-verified: 2026-10-28
Covers: the OracleB review of the Step 3 diff, copied from its export; no P0/P1; the owner kept only the path-neutral row text and the subset `covers` fix


# Review (round 0): Step 3 / O43 — Check settles delivery-uncertain messages of a proven-exited run

**Verdict: no P0 or P1 found in the diff.** The qualification rule, the single write, the refusal paths and the Send-saved exclusion all match Step 3 of the plan and O46. There are four P2s. Two are honesty problems in the row text, one is a possible stale-hold fallout to check, and one is that Edit, the only path back to sending, has no test. There are also a few cheap P3 test gaps.

I reviewed `9fix-o43.diff` alone. The repo isn't reachable from this session. Anything that depends on context lines the diff doesn't show is marked **verify**, not confirmed.

## What holds up (checked against the hard fails)

**Qualification (`crashHoldSettlementQualifies`)** — sound for every case the brief lists:
- **Current-instance input:** excluded twice. Once on the intent (`intent.appInstanceID`) and once on every attempt.
- **Missing run reference:** `runAttemptID == nil` returns false. `!attempts.isEmpty` means a message with no attempts never qualifies.
- **Wrong run:** every attempt must be on `exitedRunAttemptIDs` (the hold's run attempts) or on a run with recorded terminal evidence. Closed attempts count too.
- **Terminal-evidence runs:** for Check, these are only safe because proof (d) covers every earlier-launch record naming the session. Proof (c) alone wouldn't cover them. That's acceptable, but worth a comment at the rule.

**Atomic write:**
- The settle is computed from `current` inside the same actor call. The intents, attempts and acknowledgement go into the one existing `replace(...)`.
- `.everyIntent` throws `.intentConflict` before `replace`, so nothing is written.
- The qualification is evaluated on the record the store is about to replace, not on the coordinator's reconciliation snapshot. So even a stale `expectedRevision` can't settle against old data.
- A revision-conflict retry recomputes the settle from scratch, so no partial state is possible.
- *Verify:* I couldn't see whether `requireRevision` and the card-freshness check run before or after the settle loop (lines 1599–1619 are elided). Either order is safe because nothing is mutated before `replace`. Only which error is reported changes.

**Idempotency:** an identical repeat qualifies, changes nothing (`settledAny == false`) and returns `.unchanged`. This is tested.

**Send saved:**
- `recoveryListIntentActions` never returns it, for any state, flag or generation. This is tested exhaustively.
- `recoveryIntentActions` gives none for the settled message. This is tested.
- The settled state (intent `deliveryUnknown`, attempts closed as `.deliveryUnknown`) is the same shape the existing T4-style retry already produces. So downstream readers have seen it before.

**Hold lifted while a process may be alive:**
- Proof steps (c) to (f) are unchanged.
- The new pre-check runs before the registry query, and the store re-checks the qualification in the write.
- `testDispatchingMessageOfARunWithALiveProcessIsNotSettled` pins the alive case.

## Findings

### P2-1 — The settled row claims process proof the "It stopped" path never had (PLAUSIBLE, honesty)

**Evidence:**
- The row detail for every settled message is `recoveryListSettledByExitProofDetail`: "Every process of its run exited before the provider confirmed it."
- `isSettledByCrashHoldExitProof` can't tell which path did the settling. It's true after "It stopped" (`.qualifyingIntents`, no registry consulted).
- It's also true for an intent whose attempts are on a terminal-evidence run that wasn't in the proof.
- It's also true for an intent that was already `deliveryUnknown` (from T4 or a recorded outcome) and is listed by an older acknowledgement-only record from before this change.

The implementer did pick a separate attempt message for "It stopped" for exactly this reason, but the row text undoes it.

**Failure scenario:**
1. The user clicks "It stopped" while a process of the run is in fact still alive.
2. The row reads "Every process of its run exited", which is a factual claim nobody proved.

The user then trusts it when deciding whether to Edit and resend.

**Smallest fix:** make the detail path-neutral, for example "Its run stopped before the provider confirmed it. It won't be sent again." This keeps O46's "one row state". Alternatively, choose the text from the settled attempt's `extras["message"]`.

### P2-2 — Edit is the only route back to sending, and nothing tests it (CONFIRMED gap)

**Evidence:**
- `editRecoveredIntent`'s guard was widened to accept a `deliveryUnknown` message when the catalog fact says it was settled.
- `testSettledMessageRowIsInformationalAndNeverOffersSendSaved` only checks that the row *lists* `.edit`.
- No test drives `editRecoveredIntent` itself: text into the message box, intent withdrawn. There is also no test that an unsettled `deliveryUnknown` message is still refused with "may already have been delivered" and the message box left untouched.

**Why it matters:** this is where both hard fail classes meet: typed text lost, and a message sent without the user asking.

**Smallest fix:** one reconciliation test with two parts:
- **Settled message:** Edit succeeds, the message box holds the payload text, the intent is `withdrawn`, and there is still one attempt.
- **Unsettled message:** Edit is refused with the existing text, and the message box and intent are unchanged.

### P2-3 — Edit or Remove on a settled message may bring the hold back at the next launch (verify)

**Evidence:**
- The acknowledgement's doc says a later startup treats a hold as acknowledged only when it "matches it exactly (… every uncertain identity)".
- The settle closes no run, so the held run attempt stays open. Every launch will derive a hold for it again.
- After Edit or Remove, the intent is `withdrawn`. It leaves `uncertainIntentIDs`, but the stored acknowledgement still lists it.

**Failure scenario:** if `covers` means set equality rather than ⊇:
1. The user Edits the settled message.
2. They relaunch the app.
3. A new crash hold appears for the same dead run and sending is paused again.

This already happened for Remove after "It stopped". O46 now makes it more likely by offering Edit.

**Smallest fix:** check `AgentRecoveryCrashHoldAcknowledgement.covers`. If it is equality, accept a hold whose uncertain sets are a subset of the acknowledgement's, as long as the incarnation and reset generation match. Add one test: settle, Remove, relaunch, and assert no blocking hold.

### P2-4 — The settle now closes attempts; check that `isVerifiedNeverHandedOff` doesn't flip (verify)

**Evidence:** the settle writes an outcome on every open attempt of the intent. The run card's `runNeverHandedOff` (`record.isVerifiedNeverHandedOff`) isn't in the diff. The plan's argument that no resend is offered rests on it being false for a `dispatching` intent, and the intent is no longer `dispatching`.

**Mitigating factor:** the same state already exists in production through T4. So this is likely fine, but it is the one reader that could re-open a resend.

**Smallest fix:** read the rule. Add one assertion to `testClaudeShapedHoldWithADispatchingMessageIsConfirmedAndSettled` that the run card's `actionFacts.runNeverHandedOff` is false after the settle.

### P3 (cheap)

- **Two branches of the rule have no test of their own:**
  - **Mixed attempts:** one attempt on the exited run and one on an open run the proof doesn't cover. This should be `.intentConflict`.
  - **Earlier-launch intent with a current-launch attempt:** today's `sameLaunch` test fails the intent guard first, so the attempt-level guard never runs.
- **No test for the in-write refusal mapping in the coordinator:** `.failure(.store(.intentConflict))` → `messageNotOnProvenRun` is never reached. Even a test-store seam that throws once would pin it.
- **`provenExitMessage` is recorded for terminal-evidence-only attempts under Check.** These were proven by the terminal commit, not by process records. Low impact.
- **Remote messages:** the settled detail now takes precedence over `recoveryListRemoteUncertainty`. If `isRemote` means the run happened on another host, not just that the input came from the phone, local process records prove nothing there. Check what `isRemote` means. If needed, exclude such messages from the rule.
- **Naming:** `settledByExitProof` / `isSettledByCrashHoldExitProof` also cover "It stopped". Consider `settledByCrashHold`.

## The five deviations

| Deviation | Judgement |
|---|---|
| "It stopped" never refused; settles the qualifying messages, only acknowledges the rest | **Agree.** Refusing would leave no way to lift the hold. The untied messages keep their needs-action, Remove-only row, which is honest. Pinned at store level; a coordinator-level test is optional. |
| A separate attempt message per path | **Agree**, but the row detail undoes the distinction (P2-1). |
| "Settled" fact stricter than "acknowledgement lists the intent" | **Agree, with a gap.** It filters untied messages, but it can't tell an older acknowledgement-only record from a real settle, nor "It stopped" from proof (P2-1). |
| Qualification needs ≥1 attempt; closed attempts with `runAttemptID == nil` refuse Check | **Agree.** Conservative, matches the plan's "every attempt", and "It stopped" remains as the fallback. |
| Edit needed widening `editRecoveredIntent`'s guard from the catalog fact | **Agree with O46**, but untested (P2-2). A stale catalog fact could only let an unsettled `deliveryUnknown` message be edited, which is still the user's choice and keeps the text. Acceptable. |

Two further judgement calls are also fine:
- **Intents-only holds still refuse with `notOnlyRuns`:** fine.
- **`.intentConflict` isn't retried:** better than the plan's "retry branch", because a retry against the same record can't change the answer.

## Recommendations

1. **Before merge:** do P2-1 (one string, or derive it from the attempt message) and P2-2 (one Edit test pair). Both are small. P2-2 covers the only path left to a resend.
2. **Read two rules and pin them with one assertion each:** `AgentRecoveryCrashHoldAcknowledgement.covers` (P2-3) and `isVerifiedNeverHandedOff` (P2-4). If `covers` turns out to be equality, fix it to accept a subset, or record it as a known re-ask for the live re-check.
3. **Add the two cheap rule tests:** mixed attempts, and a current-launch attempt on an earlier-launch intent. These pin every branch of `crashHoldSettlementQualifies`.
4. **Settle what `isRemote` means** before the live re-check. If it means a remote run, exclude those messages from settling.
5. **For the live re-check (§6):** add a step that Edits the settled Claude message, relaunches, and confirms that no hold comes back and no second delivery happens on its own.
6. **Leave the deviations as implemented.** Note D1 ("It stopped" settles too) and its user-confirmed message under `assumed:` if the owner hasn't explicitly answered D1.