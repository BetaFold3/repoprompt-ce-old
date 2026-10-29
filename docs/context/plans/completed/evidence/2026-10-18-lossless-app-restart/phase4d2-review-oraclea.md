# Step4d2 initial review — OracleA

Scope: read when the task touches the initial Step4d2 Claude native history projection and reconciliation review.
Authority: Reference
Last-verified: 2026-10-23

Snapshot: `2026-10-23/2057`. Returned preset `61D024A4-CCFB-4C9C-A614-CC65E0A1864C` / `OracleA` verified; explicit selection. Findings below retained verbatim; main dispositions are in phase4-prerequisite-resolution.md.

# Oracle Review

The changes add the V2 Claude history projection, exact outbound-claim association, entry-level semantic proofs, and byte-prefix fences persisted with import receipts before cursor CAS. The supplied tests cover substantial refusal, round-trip, and replay behavior; production activation remains off. Review was static against the supplied snapshot, without independently running validation.

## P1 — Should fix

### R1 — Canonical-output checking skips subsequent persisted turns
**File:** `Sources/RepoPromptAgentCore/AgentMode/Runtime/Recovery/AgentProviderHistoryImport.swift:510–524` (`outputItemIDs`)

Once the baseline’s user item is found, `found` stays true across turns, but `afterUser` resets to `requestMatches` for each turn. Consequently, output in later full-retention turns is omitted unless those turns also contain an item from **the first baseline’s** `userItemIDs`.

For example, with the initial request in one persisted turn and a claimed steering request plus live output in another, exact claim matching can pass while the second turn’s live output remains unchecked. Reconciliation can then append native output already represented by unrelated live IDs. The helper predates this patch, but the new claim-association path makes this previously blocked import possible.

**Minimal fix:** Carry the “already passed the first user item” state across turn boundaries, while preserving first-turn filtering before that item. Add a regression with two persisted turns, matching dispatch claims, and unassociated live output in the second turn; expect `.canonicalOutputAssociationUnavailable` and no mutations.

## P2 — Consider

### R2 — Attachment-only siblings incorrectly trigger the tool-fork requirement
**File:** `Sources/RepoPromptAgentCore/AI/Providers/ClaudeCode/SDK/ClaudeSessionHistoryReader.swift:819–824` (`validateGraph`)

Continuation counting correctly ignores attachment-only branches, but the explicit-source requirement still uses `childIndexes.count > 1`.

A previously supported sequential tool call/result without `sourceToolAssistantUUID` therefore refuses when its call also has a whitelisted attachment-only child. There is still only one message-bearing child, so this is not a parallel tool fork.

**Minimal fix:** Apply the fork requirement only when there are multiple message-bearing children. Add a fixture containing one sequential result and one attachment-only sibling; retain refusal for genuine forks lacking an explicit source. This is fixture-contract consistency, not additional live-tool qualification.

## Recommendations

Fix R1 before accepting Step4d2; R2 is a small accompanying correction. Rerun the affected reconciliation and reader suites. Keep production gates off and live acceptance explicitly pending.
