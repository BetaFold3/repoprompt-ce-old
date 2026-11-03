# Step 8-attention-1 final re-review — OracleB (round 2)

Scope: read when the task touches Needs Attention classification, the composer recovery banner rule or the needs-action counts (Step 8-attention-1).
Authority: Reference
Last-verified: 2026-10-26
Covers: OracleB (preset 7CDD523E-1D7C-47EA-98FE-D5FEA24D2D8C) fresh-chat final re-review of att1-delta and att1-delta2.

# Round-2 re-review: Step 8-attention-1 (att1-delta, att1-delta2)

I could only read the attached diffs, review notes and the `AgentRecoveryActionModels.swift` excerpt, not the full repository. I didn't build or run anything; the validation counts in the request come from the worker. Two checks need code I don't have: how intents get removed, and what the run row says. I've marked those findings as plausible.

## Summary

The deltas make run cards needs-action in three cases:
- **Hold:** while a recovery action holds their session, matched by session and exact card key. This includes the time between the outcome write and the hold's release.
- **Unsent text:** while typed continuation text exists only on an action.
- **Dismissed rows:** the sheet's section counts exclude them, and `AgentRecoveryNeedsAttentionRow.attention` is now a required field.

att1-delta2 rewrites `hasUnsentContinuation(for:)` so a later Reconcile that doesn't resolve the card no longer clears the flag. That fixes ATT1-R1-1. `resolvesItem` is moved into a shared helper, and `resolvingAction(for:)` behaves exactly as before: same predicate, same `last` lookup. No gate, Dismiss or send path is touched.

On the points you asked about:
- **Supersession before an outcome (`:334`):** handled. A continuation replaced by a later textless choice falls through to the intent check and the "later resolving action" check.
- **Isolation:** the new code is a pure value-type extension in the same extension as `isSuperseded` and `resolvingAction`.
- **Invalidation on hold begin and end:** the tests read the catalog synchronously right after `beginRecoveryAction` and `endRecoveryAction`, which shows those paths invalidate it.

**I found no P0 and no confirmed P1.** One finding is P2 that becomes P1 if one storage behaviour holds, which a quick grep can settle.

## P2

### ATT1-R2-1: The intent check can flip back after the user acts on the intent (PLAUSIBLE; P1 if intents are deleted or pruned)
- **Evidence:** `AgentRecoveryActionModels.swift:337`. The flag is cleared only while `intents` still holds an entry with `userItemID == plannedUserItemID`.
- **Scenario:**
  1. A typed continuation commits its intent with the planned item ID, but sending is refused. The outcome is not `dispatched`, so the intent stays queued and shows as a held-input card.
  2. Correctly, the run card is informational, because the intent's own card asks for the decision.
  3. The user then sends that held input from its own card (a `sendSaved` action keyed to the intent card, not the run card), or chooses **Remove**.
  4. If either path deletes the intent from `record.intents`, or record compaction later drops delivered intents, the check at `:337` fails.
  5. No action on the run card resolves it, so `hasUnsentContinuation` becomes `true` again. The run card comes back as needs-action: banner, badge, "Needs action" section.
  6. The text was either sent or explicitly thrown away by the user.
- **Impact:** a wrong needs-action state that keeps coming back. If delivered intents are pruned, this happens on every continuation sent through its held-input card, not only on Remove. Dismiss is the only workaround.
- **Smallest fix:**
  1. Grep the store for how intents are removed or compacted.
  2. If they really are deleted, the clearing condition must not depend on the intent still existing. Options: a durable marker that the text became an intent (a tombstone, or the action's outcome/`join` evidence), or a check against `attempts` and the transcript's planned user item.
  3. Add a test for the full sequence: refused continuation → intent committed → intent removed → run card stays informational.

### ATT1-R2-2: The supersession branch and the "replaced by newer text" case have no tests
- **Evidence:** `AgentRecoveryActionModels.swift:332–336`. Every new test records an outcome on the continuation, so the `else if !isSuperseded(continuation)` path never runs.
- **Untested cases:**
  - **(a)** A continuation with no outcome (left open by a crash in an earlier launch) that a later Reconcile supersedes. It should be needs-action while the Reconcile is open, and still needs-action after `importedUnconfirmed`.
  - **(b)** An open continuation that hasn't been replaced. The flag should be `false`, and the card should be needs-action only through `hasUnfinishedAction`.
  - **(c)** Newer typed text with outcome `dispatched` after older unsent text. Everything should clear.
- **Impact:** the branch reviewers worried about most is protected only by reading the code.
- **Smallest fix:** add these three cases to the `RunCardFixture` tests. The fixture needs a `supersedesActionID:` parameter on `request(...)`.

### ATT1-R2-3: A run card flagged by `hasUnsentContinuation` may not say why it needs action (PLAUSIBLE)
- **Evidence:** neither delta changes `recoveryListRow(for:)`; the only consumer of `hasUnsentContinuation` is the classifier. The coordinator's inline failure text exists only at runtime, so it is gone after a relaunch.
- **Scenario:**
  1. After a relaunch, the banner shows the interrupted-run row as needs-action.
  2. Its detail and actions match the informational version: there's no mention of unsent text and no way to view or restore it.
  3. The user can't tell what decision is being asked for. The likely outcome is a Dismiss, which loses the text the classification was meant to protect.
- **Smallest fix:** check the row copy in the app. If it's generic, add a detail line such as "Your message was not sent", and ideally prefill or offer to view the text. Or record this as deferred to 8-attention-2.

## P3

### ATT1-R2-4: The `hasUnsentContinuation` doc in `AgentRecoveryCatalogActionFacts` is out of date
- **Evidence:** `AgentRecoveryCatalog.swift:~165–166` still says "The card's latest action carried typed text and resolved without sending…".
- **Problem:** that describes att1-delta. After att1-delta2 the flag means the latest action that *carries text*, also counts a continuation replaced before it had an outcome, and survives later textless actions that don't resolve the card.
- **Fix:** reword it to match the doc at `AgentRecoveryActionModels.swift:320–328`.

### ATT1-R2-5: A `text` that is set but empty counts as a continuation
- **Evidence:** `AgentRecoveryActionModels.swift:330` tests `$0.text != nil`.
- **Problem:** if Resume or a canned continue is ever stored as `continueWithText` with `""`, a refused Resume shows as "unsent text" when there is no user text.
- **Fix:** use `text?.isEmpty == false`, or leave it as is and note that it's intended.

### Carried over from OracleB round 0 (B had not seen att1-delta until now)
- **ATT1-2 (rows moving between sections):** this now also happens when a typed continuation fails on a row in the Information section, so the row jumps to "Needs action". It still needs the live check.
- **ATT1-4 (dismissed rows):** fixed for the header counts. Dismissed needs-action rows still appear inside the Needs action section while "Show dismissed" is on; record the separate dismissed section as deferred.
- **ATT1-7 and ATT1-8:** addressed by making `attention` required, the `openNeedsActionCount` doc fix, the clearer fallback comment and the reflowed banner doc.

## Recommendations

1. **Before commit:** settle ATT1-R2-1 by grepping the store for how intents are removed or compacted. If intents are deleted, it's a P1. That falls past the round limit, so it goes to you with the fix options above. If they are kept, it's moot and only the regression test is needed.
2. Add the three supersession and replacement tests from ATT1-R2-2. They're cheap and cover the branch in question.
3. Fix the stale facts doc (ATT1-R2-4) now. Decide on ATT1-R2-5 or record it as intended.
4. **Live pass:** check the run-row copy when the card is needs-action only because of unsent text (ATT1-R2-3), plus OracleB's ATT1-2 row movement and banner flash during a hold.
5. **Status line:** this round produces no confirmed P0/P1. List ATT1-R2-1 as "open pending grep" until the storage behaviour is known; ATT1-R2-2 through R2-5 and the dismissed section go under deferred if they aren't fixed.