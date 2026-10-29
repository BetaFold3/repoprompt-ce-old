# 9-live round-2 fixes: OracleA review, round 1
Scope: read when the task touches the round-2 live-check fixes (Claude history shapes and claim, Codex full item view, recovery wording).
Authority: Reference
Last-verified: 2026-10-29
Covers: OracleA review round 1 of the S1, S3, S4 and S5 fixes

The round-1 changes address the earlier S1 gap: live thinking no longer disqualifies the supported pre-answer path, and exact single-text-block user content now receives the outbound-claim digest. The new reconciliation test covers persisted live output, duplicate prevention, repeat idempotence, and no send. Saved refusal reasons are more specific. The full diff retains the scoped S3–S5 fixes without an evident new correctness regression. Review was limited to the supplied code and reports; tests were not independently run.

**No P0/P1 findings in the supplied round-1 diff.**

## Recommendations

- **Proceed to live re-verification**, using newly captured dispatch baselines. Previously unsupported baselines should remain refused, not be retroactively reconstructed.
- **Keep `deferred_tools_record` refused for now.** Establish whether `toolInputCopies` can override, supplement, or differ from canonical tool inputs before treating it as ignorable metadata.
- **Keep `silent_turn_reminder` refused for now.** Its injected text needs an explicit conversation-association contract; occurrence frequency alone does not establish that skipping it preserves meaning.
- Verify the previously blocked Claude Reconcile/Continue scenarios with thinking enabled and existing live output, confirming unchanged rows on repeat and no send from Reconcile.