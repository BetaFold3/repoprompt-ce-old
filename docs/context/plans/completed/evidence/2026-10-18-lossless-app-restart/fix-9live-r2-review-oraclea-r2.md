# 9-live round-2 fixes: OracleA review, round 2
Scope: read when the task touches the round-2 live-check fixes (Claude history shapes and claim, Codex full item view, recovery wording).
Authority: Reference
Last-verified: 2026-10-29
Covers: OracleA review round 2 of the S1, S3, S4 and S5 fixes

Round 2 addresses both remaining qualification blockers: the live classifier accepts the two observed thinking-only metadata keys with type checks, and configured Claude paths can carry admitted outbound UUIDs and qualify live evidence under the retained backend/environment restrictions. Neither change relaxes answer attribution, translation matching, or recovery claim checks. Review used the supplied diff, source, and report; tests were not independently run.

**No P0/P1 findings in these changed behaviors.**

## Recommendations

- **Proceed to live verification with a fresh launch and newly captured baseline.** Confirm the saved claim UUID equals both the shim-forwarded frame UUID and the native user-entry UUID.
- Exercise thinking → answer → interruption → Reconcile twice: verify one canonical reply, unchanged rows on repeat, and no send from Reconcile. Fixture success does not yet establish the complete shim path.
- Preserve safe refusal for old unsupported baselines, mismatched claims, and ambiguous history copies. Keep `deferred_tools_record` and `silent_turn_reminder` refused pending semantic qualification.