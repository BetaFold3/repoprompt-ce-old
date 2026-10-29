# 9-live round-2 fixes: OracleA review, round 0
Scope: read when the task touches the round-2 live-check fixes (Claude history shapes and claim, Codex full item view, recovery wording).
Authority: Reference
Last-verified: 2026-10-29
Covers: OracleA review round 0 of the S1, S3, S4 and S5 fixes

The patch addresses the diagnosed causes: Claude accepts additional observed metadata and skips assistant thinking while retaining graph, prefix and ledger checks; refusal messages preserve the saved reason; Codex requests full items and rejects partial views; and S4/S5 improve recovery wording. S2 appropriately remains unchanged. No concrete unsafe-import, duplicate-row or unrequested-send regression is evident in the supplied changes. Validation results below are from the reports, not independently executed.

## P2 — Consider

### Exercise S1 through reconciliation, not just decoding and baseline capture
**Files:** `Tests/RepoPromptTests/AgentMode/Recovery/AgentRecoveryReconciliationTests.swift:1902–1915`; `ClaudeSessionHistoryReaderTests.swift:1058`

The new tests establish that the expanded history parses and a baseline commits, but do not demonstrate successful reconciliation against already-persisted live output. Two relevant boundaries remain:
- The report explicitly says the live classifier still refuses thinking.
- The new history fixture uses array-valued user content, whereas `parseEntry` computes the outbound-claim digest only for string content.

Neither establishes a defect by itself, but reader success does not establish that the owner-profile Reconcile/Continue path now works.

**Suggestion:** Add an end-to-end fixture using the actual outbound message representation plus thinking and persisted live text/tool rows. Assert the expected import or explicit safe refusal, unchanged existing rows, idempotence on repeated Reconcile, and no send during reconciliation.

### Pin the Codex compatibility retry’s failure paths
**File:** `Sources/RepoPromptAgentCore/AI/Providers/Codex/AppServer/CodexNativeSessionController.swift:1867–1885`

The retry without `itemsView` executes inside the `catch`. If it throws, its error bypasses the generation check and unsupported-method handling applied to the initial request. This remains fail-closed, but leaves the compatibility path with inconsistent error handling; the new test covers only a successful retry.

**Suggestion:** Apply shared error classification to retry failures. Add tests for transport replacement during the retry and an unsupported-method response, verifying stale-observation handling and the intended `thread/read` fallback respectively.

## Recommendations

- **Proceed to another live verification round**, but do not mark S1 fully resolved solely from baseline/reader tests. Repeat the previously blocked Claude scenarios with thinking enabled and existing live output.
- **Keep `deferred_tools_record` refused for now.** Its `toolInputCopies` needs semantic qualification beyond structural key names. Establish whether copies can differ from, replace or supplement canonical `tool_use` inputs before treating it as ignorable metadata.
- **Keep `silent_turn_reminder` refused for now.** Injected turn text is not established as non-conversational metadata. Supporting it requires an explicit association/projection contract, not merely an allow-list entry.
- Preserve the existing fail-closed behavior for both shapes; expanding coverage should not weaken prefix integrity, overlap checks or send authorization.