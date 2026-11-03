# Step 4d7 — OracleA initial review

Scope: read when the task touches source review findings for lossless restart Step 4d7 agreement-proof retention.
Authority: Reference
Last-verified: 2026-10-24

Independent fresh review on eight-file staged tree `fb60e9de8f535c0a63b2752a8f1e53f4fc44f2ab` (+600/-42), with main-verified 349 tests, compile and style evidence. Exact preset identity verified; full response read by main.

# Oracle Review

Step 4d7 changes Claude’s transient ownership map to track only newly inserted, **unagreed** keys. Exact single-text or whole-Read-chain agreement releases those keys from later launch-level revocation, while preserving the refusal latch and revocation of remaining keys. Single-text agreement now validates the full reader-derived identity and canonical payload. Recovery refusal messages and regression tests are updated without changing activation, persistence schemas, or classifier behavior.

## Review assessment

**No actionable findings in the supplied frozen diff.**

- **Ownership consumption is correctly bounded.** `AgentModeViewModel.swift`, `consumeClaudeLiveTranscriptOwnership`, subtracts only the specified keys from the specified producer’s existing set and removes empty entries. It neither acquires ownership nor changes ledger proofs, rows, accounting, receipts, cursors, or save state.

- **Single-text agreement is substantially stronger.** `claudeLiveTranscriptTextAgreementKey` requires one Claude association for the local ID, a unique ledger key, conversation agreement when known, full equality with the reader-derived ledger entry, and the existing canonical-payload holding check across persisted turns and suffix. Reconstruction is comparison-only; missing or invalid proofs cannot be healed.

- **Read-chain checks remain unchanged before consumption.** Ownership is released only after the existing complete-chain predicate succeeds. Failure still invokes permanent producer refusal, which invalidates only remaining owned keys. Imported rows and other producers’ ownership remain untouched.

- **Retained proofs do not bypass fresh recovery validation.** In the supplied `ClaudeSessionHistoryReader.decode` path, parsing, graph validation, and prefix-fence verification precede projection; ledger validation covers all projected history before frontier filtering. Recovery then performs canonical association preflight before planning and saving. Claude completion remains unconfirmed. The ordinary baseline path is deliberately separate.

- **The tests exercise the changed semantics meaningfully.** Coverage includes later refusal, old-key contradiction, failed and post-refusal agreement, ambiguous identity, duplicate/incomplete canonical payloads, persisted-only payloads, non-owned agreements, and save/relaunch reconciliation. The already-loaded test does not force hydration into an artificial state.

This is a static review of the supplied diff and context. The reported validation results were not independently executed; they do not establish live-profile qualification or full-suite acceptance.

## Recommendations

Accept this frozen snapshot for the bounded **pre-live Step 4d7 source change**. No corrective edits are requested. Keep activation off and retain the planned isolated live qualification and final acceptance work as outstanding.
